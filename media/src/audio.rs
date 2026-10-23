//! AAC to FLAC, one FLAC frame per AAC frame, so each output sample keeps
//! the input's timestamp and duration and segments stay independent.
//!
//! HE-AAC (SBR, and PS on top of it) is decoded as its AAC-LC core: half
//! the sample rate, and mono for PS. The FLAC stream declares what it holds,
//! and the timestamps don't change, so it stays in sync.

use symphonia_codec_aac::AacDecoder;
use symphonia_core::codecs::audio::well_known::CODEC_ID_AAC;
use symphonia_core::codecs::audio::{AudioCodecParameters, AudioDecoder, AudioDecoderOptions};
use symphonia_core::packet::PacketRef;
use symphonia_core::units::{Duration, Timestamp};

use crate::bytes::{err, Result};
use crate::flac;

const RATES: [u32; 13] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
const FRAME: usize = 1024;

/// What an `AudioSpecificConfig` says about the core the decoder will output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AacConfig {
    pub rate: u32,
    pub channels: u32,
}

impl AacConfig {
    pub fn parse(asc: &[u8]) -> Result<Self> {
        let mut r = Bits { data: asc, pos: 0 };
        let mut object = r.object_type()?;
        let rate = r.rate()?;
        let config = r.get(4)?;
        if object == 5 || object == 29 {
            r.rate()?;
            let core = r.object_type()?;
            if object == 29 {
                // Parametric stereo rebuilds stereo from a mono core.
                return Ok(AacConfig { rate, channels: 1 });
            }
            object = core;
        }
        if object != 2 {
            return err(format!("AAC object type {object} isn't supported"));
        }
        match config {
            1 | 2 => Ok(AacConfig { rate, channels: config }),
            _ => err(format!("AAC channel configuration {config} isn't supported")),
        }
    }

    /// A plain AAC-LC config for the core, which is all the decoder takes.
    fn lc_config(self) -> Vec<u8> {
        let mut bits: u64 = 2;
        let mut len: u32 = 5;
        if let Some(i) = RATES.iter().position(|&r| r == self.rate) {
            bits = bits << 4 | i as u64;
            len += 4;
        } else {
            bits = bits << 28 | 0xf << 24 | u64::from(self.rate & 0xff_ffff);
            len += 28;
        }
        bits = bits << 7 | u64::from(self.channels) << 3;
        len += 7;
        let bytes = len.div_ceil(8);
        let bits = bits << (bytes * 8 - len);
        (0..bytes).rev().map(|i| (bits >> (i * 8)) as u8).collect()
    }
}

struct Bits<'a> {
    data: &'a [u8],
    pos: usize,
}

impl Bits<'_> {
    fn get(&mut self, n: usize) -> Result<u32> {
        let mut v = 0;
        for _ in 0..n {
            let Some(byte) = self.data.get(self.pos / 8) else {
                return err("truncated AudioSpecificConfig");
            };
            v = v << 1 | u32::from(byte >> (7 - self.pos % 8) & 1);
            self.pos += 1;
        }
        Ok(v)
    }

    fn object_type(&mut self) -> Result<u32> {
        match self.get(5)? {
            31 => Ok(32 + self.get(6)?),
            t => Ok(t),
        }
    }

    fn rate(&mut self) -> Result<u32> {
        match self.get(4)? {
            15 => self.get(24),
            i => RATES.get(i as usize).copied().map_or_else(|| err("bad AAC sample rate"), Ok),
        }
    }
}

pub struct AacToFlac {
    pub config: AacConfig,
    decoder: AacDecoder,
    /// mdhd timescale of the track, to number FLAC frames by time.
    timescale: u32,
    planes: Vec<Vec<i16>>,
}

impl AacToFlac {
    pub fn new(asc: &[u8], timescale: u32) -> Result<Self> {
        let config = AacConfig::parse(asc)?;
        let mut params = AudioCodecParameters::new();
        params.for_codec(CODEC_ID_AAC).with_extra_data(config.lc_config().into_boxed_slice());
        let decoder = match AacDecoder::try_new(&params, &AudioDecoderOptions::default()) {
            Ok(d) => d,
            Err(e) => return err(format!("AAC decoder: {e}")),
        };
        Ok(AacToFlac { config, decoder, timescale, planes: Vec::new() })
    }

    /// The dfLa payload after its full-box header: one STREAMINFO block.
    pub fn dfla(&self) -> Vec<u8> {
        let mut out = vec![0x80, 0, 0, 34];
        out.extend_from_slice(&flac::streaminfo(self.config.rate, self.config.channels, FRAME as u32));
        out
    }

    /// One AAC frame in, one FLAC frame out. A frame that fails to decode
    /// becomes silence, so the timeline has no hole.
    pub fn convert(&mut self, aac: &[u8], dts: i64) -> Vec<u8> {
        let channels = self.config.channels as usize;
        let packet = PacketRef::new(0, Timestamp::new(dts), Duration::new(FRAME as u64), aac);
        let decoded = match self.decoder.decode_ref(&packet) {
            Ok(buf) if buf.frames() > 0 => {
                buf.copy_to_vecs_planar::<i16>(&mut self.planes);
                true
            }
            _ => false,
        };
        if !decoded || self.planes.len() != channels {
            self.planes = vec![vec![0; FRAME]; channels];
        }
        let samples = u64::from(self.config.rate) * dts.max(0) as u64 / u64::from(self.timescale.max(1));
        flac::encode_frame(&self.planes, self.config.rate, samples / FRAME as u64)
    }

    /// Forgets the overlap carried from the last frame, after a seek.
    pub fn reset(&mut self) {
        self.decoder.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_audio_specific_configs() {
        // X's AAC-LC, 44.1 kHz stereo.
        assert_eq!(AacConfig::parse(&[0x12, 0x10]), Ok(AacConfig { rate: 44100, channels: 2 }));
        // Explicit HE-AAC: SBR over a 22.05 kHz core.
        assert_eq!(AacConfig::parse(&[0x2b, 0x92, 0x08, 0x00]), Ok(AacConfig { rate: 22050, channels: 2 }));
        // HE-AACv2 decodes as a mono core.
        assert_eq!(AacConfig::parse(&[0xeb, 0x8a, 0x08, 0x00]), Ok(AacConfig { rate: 22050, channels: 1 }));
        // AAC-LC with an SBR sync extension decodes as the LC core.
        let he = AacConfig::parse(&[0x13, 0x90, 0x56, 0xe5, 0xa0]);
        assert_eq!(he, Ok(AacConfig { rate: 22050, channels: 2 }));
        assert!(AacConfig::parse(&[0x12, 0x30]).is_err());
    }

    #[test]
    fn writes_lc_configs() {
        assert_eq!(AacConfig { rate: 44100, channels: 2 }.lc_config(), [0x12, 0x10]);
        assert_eq!(AacConfig { rate: 22050, channels: 1 }.lc_config(), [0x13, 0x88]);
    }
}
