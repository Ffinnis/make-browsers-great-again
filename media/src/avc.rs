//! H.264 as MP4 stores it (avcC, length-prefixed NAL units), turned into the
//! Annex-B stream the engine's decoder takes. Configured with an avcC the
//! engine refuses H.264; without one it decodes Annex-B through `VideoToolbox`.

use crate::bytes::{err, Reader, Result};

const START_CODE: [u8; 4] = [0, 0, 0, 1];
const NAL_IDR: u8 = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AvcConfig {
    /// `profile_idc`, constraint flags and `level_idc`, as in "avc1.PPCCLL".
    pub profile: [u8; 3],
    pub nal_length: usize,
    /// SPS and PPS units in Annex-B form, put in front of every keyframe so
    /// decoding can start at any of them.
    pub parameter_sets: Vec<u8>,
}

impl AvcConfig {
    pub fn parse(avcc: &[u8]) -> Result<Self> {
        let mut r = Reader::new(avcc);
        r.u8()?;
        let profile = [r.u8()?, r.u8()?, r.u8()?];
        let nal_length = usize::from(r.u8()? & 3) + 1;
        let mut parameter_sets = Vec::new();
        for mask in [0x1f, 0xff] {
            let count = r.u8()? & mask;
            for _ in 0..count {
                let len = usize::from(r.u16()?);
                parameter_sets.extend_from_slice(&START_CODE);
                parameter_sets.extend_from_slice(r.bytes(len)?);
            }
        }
        if nal_length == 3 {
            return err("3-byte NAL lengths aren't allowed");
        }
        Ok(AvcConfig { profile, nal_length, parameter_sets })
    }

    /// The codec string `WebCodecs` takes, such as "avc1.64001f".
    pub fn codec_word(&self) -> u32 {
        u32::from(self.profile[0]) << 16 | u32::from(self.profile[1]) << 8 | u32::from(self.profile[2])
    }

    /// Rewrites one sample to Annex-B into `out`. Returns whether it holds
    /// an IDR picture, which is what the decoder accepts as a key frame.
    pub fn to_annex_b(&self, sample: &[u8], out: &mut Vec<u8>) -> Result<bool> {
        let mut nals = Vec::new();
        let mut idr = false;
        let mut r = Reader::new(sample);
        while r.remaining() > 0 {
            let mut len = 0usize;
            for _ in 0..self.nal_length {
                len = len << 8 | usize::from(r.u8()?);
            }
            let nal = r.bytes(len)?;
            if nal.first().is_some_and(|b| b & 0x1f == NAL_IDR) {
                idr = true;
            }
            nals.push(nal);
        }
        if idr {
            out.extend_from_slice(&self.parameter_sets);
        }
        for nal in nals {
            out.extend_from_slice(&START_CODE);
            out.extend_from_slice(nal);
        }
        Ok(idr)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyframes_carry_parameter_sets() {
        let avcc = [1, 0x64, 0, 0x1f, 0xff, 0xe1, 0, 2, 0x67, 1, 1, 0, 1, 0x68];
        let config = AvcConfig::parse(&avcc).unwrap();
        assert_eq!(config.codec_word(), 0x64001f);
        let mut out = Vec::new();
        assert!(config.to_annex_b(&[0, 0, 0, 2, 0x65, 9], &mut out).unwrap());
        assert_eq!(out, [0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 9]);
        out.clear();
        assert!(!config.to_annex_b(&[0, 0, 0, 1, 0x41], &mut out).unwrap());
        assert_eq!(out, [0, 0, 0, 1, 0x41]);
        assert!(config.to_annex_b(&[0, 0, 0, 5, 0x41], &mut out).is_err());
    }
}
