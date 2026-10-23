pub const BITS: u32 = 16;

pub fn streaminfo(rate: u32, channels: u32, block: u32) -> [u8; 34] {
    let mut w = BitWriter::default();
    w.put(block, 16);
    w.put(block, 16);
    w.put(0, 24);
    w.put(0, 24);
    w.put(rate, 20);
    w.put(channels - 1, 3);
    w.put(BITS - 1, 5);
    w.put(0, 4);
    w.put(0, 32);
    let mut out = [0; 34];
    out[..18].copy_from_slice(&w.bytes);
    out
}

pub fn encode_frame(planes: &[Vec<i16>], rate: u32, frame_number: u64) -> Vec<u8> {
    let block = planes.first().map_or(0, Vec::len);
    let mut w = BitWriter::default();
    w.put(0xfff8, 16);
    let (block_code, block_extra) = block_size_code(block);
    let (rate_code, rate_extra) = rate_code(rate);
    w.put(block_code << 4 | rate_code, 8);
    w.put((planes.len() as u32 - 1) << 4 | 0b100 << 1, 8);
    put_utf8(&mut w, frame_number.min(0x7fff_ffff) as u32);
    if let Some((v, bits)) = block_extra {
        w.put(v, bits);
    }
    if let Some((v, bits)) = rate_extra {
        w.put(v, bits);
    }
    let crc = crc8(&w.bytes);
    w.put(u32::from(crc), 8);
    for plane in planes {
        subframe(&mut w, plane);
    }
    w.align();
    let crc = crc16(&w.bytes);
    w.put(u32::from(crc), 16);
    w.bytes
}

fn block_size_code(block: usize) -> (u32, Option<(u32, u32)>) {
    match block {
        256 => (8, None),
        512 => (9, None),
        1024 => (10, None),
        2048 => (11, None),
        4096 => (12, None),
        _ => (7, Some((block.saturating_sub(1) as u32 & 0xffff, 16))),
    }
}

fn rate_code(rate: u32) -> (u32, Option<(u32, u32)>) {
    match rate {
        8000 => (4, None),
        16000 => (5, None),
        22050 => (6, None),
        24000 => (7, None),
        32000 => (8, None),
        44100 => (9, None),
        48000 => (10, None),
        96000 => (11, None),
        r if r <= 0xffff => (13, Some((r, 16))),
        _ => (0, None),
    }
}

fn put_utf8(w: &mut BitWriter, v: u32) {
    if v < 0x80 {
        w.put(v, 8);
        return;
    }
    let extra = match v {
        0..0x800 => 1,
        0x800..0x10000 => 2,
        0x10000..0x20_0000 => 3,
        0x20_0000..0x400_0000 => 4,
        _ => 5,
    };
    let lead = (0xff00u32 >> (extra + 1)) & 0xff;
    w.put(lead | v >> (6 * extra), 8);
    for i in (0..extra).rev() {
        w.put(0x80 | (v >> (6 * i)) & 0x3f, 8);
    }
}

fn subframe(w: &mut BitWriter, plane: &[i16]) {
    if let Some(&first) = plane.first() {
        if plane.iter().all(|&s| s == first) {
            w.put(0, 8);
            w.put_signed(i32::from(first), BITS);
            return;
        }
    }
    let samples: Vec<i32> = plane.iter().map(|&s| i32::from(s)).collect();
    let mut best: Option<(u64, usize, u32)> = None;
    for order in 0..=4.min(samples.len()) {
        let (bits, k) = rice_cost(&residual(&samples, order));
        let total = bits + order as u64 * u64::from(BITS);
        if best.is_none_or(|(b, _, _)| total < b) {
            best = Some((total, order, k));
        }
    }
    let verbatim = samples.len() as u64 * u64::from(BITS);
    match best {
        Some((bits, order, k)) if bits < verbatim => {
            w.put(0b001000 << 1 | (order as u32) << 1, 8);
            for &s in &samples[..order] {
                w.put_signed(s, BITS);
            }
            w.put(0, 2);
            w.put(0, 4);
            w.put(k, 4);
            for r in residual(&samples, order) {
                let u = zigzag(r);
                w.put_unary(u >> k);
                w.put(u & ((1 << k) - 1), k);
            }
        }
        _ => {
            w.put(0b000001 << 1, 8);
            for &s in &samples {
                w.put_signed(s, BITS);
            }
        }
    }
}

fn residual(s: &[i32], order: usize) -> Vec<i32> {
    (order..s.len())
        .map(|i| match order {
            0 => s[i],
            1 => s[i] - s[i - 1],
            2 => s[i] - 2 * s[i - 1] + s[i - 2],
            3 => s[i] - 3 * s[i - 1] + 3 * s[i - 2] - s[i - 3],
            _ => s[i] - 4 * s[i - 1] + 6 * s[i - 2] - 4 * s[i - 3] + s[i - 4],
        })
        .collect()
}

fn zigzag(r: i32) -> u32 {
    ((r << 1) ^ (r >> 31)) as u32
}

fn rice_cost(res: &[i32]) -> (u64, u32) {
    let sum: u64 = res.iter().map(|&r| u64::from(zigzag(r))).sum();
    let mean = sum / (res.len() as u64).max(1);
    let guess = (64 - mean.leading_zeros()).min(14);
    let mut best = (u64::MAX, 0);
    for k in guess.saturating_sub(1)..=(guess + 1).min(14) {
        let bits: u64 = res.iter().map(|&r| u64::from(zigzag(r) >> k) + 1 + u64::from(k)).sum();
        if bits < best.0 {
            best = (bits, k);
        }
    }
    (best.0.saturating_add(10), best.1)
}

#[derive(Default)]
struct BitWriter {
    bytes: Vec<u8>,
    acc: u64,
    bits: u32,
}

impl BitWriter {
    fn put(&mut self, v: u32, n: u32) {
        if n == 0 {
            return;
        }
        let v = u64::from(v) & ((1u64 << n) - 1);
        self.acc = self.acc << n | v;
        self.bits += n;
        while self.bits >= 8 {
            self.bits -= 8;
            self.bytes.push((self.acc >> self.bits) as u8);
        }
    }

    fn put_signed(&mut self, v: i32, n: u32) {
        self.put(v as u32, n);
    }

    fn put_unary(&mut self, zeros: u32) {
        let mut left = zeros;
        while left >= 32 {
            self.put(0, 32);
            left -= 32;
        }
        self.put(1, left + 1);
    }

    fn align(&mut self) {
        if self.bits > 0 {
            self.put(0, 8 - self.bits);
        }
    }
}

fn crc8(data: &[u8]) -> u8 {
    let mut crc = 0u8;
    for &b in data {
        crc ^= b;
        for _ in 0..8 {
            crc = if crc & 0x80 != 0 { crc << 1 ^ 0x07 } else { crc << 1 };
        }
    }
    crc
}

fn crc16(data: &[u8]) -> u16 {
    let mut crc = 0u16;
    for &b in data {
        crc ^= u16::from(b) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 { crc << 1 ^ 0x8005 } else { crc << 1 };
        }
    }
    crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_header_matches_the_spec() {
        let silent = vec![vec![0i16; 1024], vec![0i16; 1024]];
        let frame = encode_frame(&silent, 44100, 0);
        assert_eq!(&frame[..5], &[0xff, 0xf8, 0xa9, 0x18, 0x00]);
        assert_eq!(frame[5], crc8(&frame[..5]));
        assert_eq!(&frame[6..12], &[0, 0, 0, 0, 0, 0]);
        let n = frame.len();
        assert_eq!(crc16(&frame[..n - 2]).to_be_bytes(), [frame[n - 2], frame[n - 1]]);
    }

    #[test]
    fn utf8_frame_numbers() {
        let mut w = BitWriter::default();
        put_utf8(&mut w, 0x7f);
        put_utf8(&mut w, 0x80);
        put_utf8(&mut w, 0x1234);
        assert_eq!(w.bytes, [0x7f, 0xc2, 0x80, 0xe1, 0x88, 0xb4]);
    }

    #[test]
    fn predictable_audio_compresses() {
        let tone: Vec<i16> = (0..1024).map(|i| ((f64::from(i) * 0.06).sin() * 12000.0) as i16).collect();
        let frame = encode_frame(&[tone], 48000, 3);
        assert!(frame.len() < 1024, "{} bytes", frame.len());
    }
}
