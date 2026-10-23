//! Big-endian reading and writing, and ISO BMFF box framing.

use std::fmt;

/// Input that doesn't parse. Carries a short reason for the page's console.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

pub type Result<T> = std::result::Result<T, Error>;

pub fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}

/// A cursor over a byte slice whose reads fail instead of panicking.
pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Reader { data, pos: 0 }
    }

    pub fn remaining(&self) -> usize {
        self.data.len() - self.pos
    }

    pub fn bytes(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.pos.checked_add(n).filter(|&end| end <= self.data.len());
        match end {
            Some(end) => {
                let out = &self.data[self.pos..end];
                self.pos = end;
                Ok(out)
            }
            None => err("truncated box"),
        }
    }

    pub fn rest(&mut self) -> &'a [u8] {
        let out = &self.data[self.pos..];
        self.pos = self.data.len();
        out
    }

    pub fn skip(&mut self, n: usize) -> Result<()> {
        self.bytes(n).map(|_| ())
    }

    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.bytes(1)?[0])
    }

    pub fn u16(&mut self) -> Result<u16> {
        let b = self.bytes(2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }

    pub fn u32(&mut self) -> Result<u32> {
        let b = self.bytes(4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn u64(&mut self) -> Result<u64> {
        let hi = u64::from(self.u32()?);
        Ok(hi << 32 | u64::from(self.u32()?))
    }

    /// The version and flags that start a full box.
    pub fn full_header(&mut self) -> Result<(u8, u32)> {
        let v = self.u32()?;
        Ok(((v >> 24) as u8, v & 0x00ff_ffff))
    }
}

/// One box: its type, and its payload after the header.
pub struct Mp4Box<'a> {
    pub kind: [u8; 4],
    pub body: &'a [u8],
}

/// Where a box starting at `data[0]` ends, if its header is all there.
/// `Ok(None)` means more bytes are needed to know.
pub fn box_extent(data: &[u8]) -> Result<Option<(usize, usize)>> {
    if data.len() < 8 {
        return Ok(None);
    }
    let size = u32::from_be_bytes([data[0], data[1], data[2], data[3]]);
    let (size, header) = match size {
        0 => return err("box without size"),
        1 => {
            if data.len() < 16 {
                return Ok(None);
            }
            let mut r = Reader::new(&data[8..16]);
            (r.u64()?, 16)
        }
        n => (u64::from(n), 8),
    };
    if size < header as u64 {
        return err("box smaller than its header");
    }
    match usize::try_from(size) {
        Ok(size) => Ok(Some((size, header))),
        Err(_) => err("box too large"),
    }
}

/// The boxes laid end to end in `data`. A box that runs past the end fails.
pub fn boxes(data: &[u8]) -> Result<Vec<Mp4Box<'_>>> {
    let mut out = Vec::new();
    let mut pos = 0;
    while data.len() - pos >= 8 {
        let Some((size, header)) = box_extent(&data[pos..])? else {
            return err("truncated box header");
        };
        if size > data.len() - pos {
            return err("truncated box");
        }
        let mut kind = [0; 4];
        kind.copy_from_slice(&data[pos + 4..pos + 8]);
        out.push(Mp4Box { kind, body: &data[pos + header..pos + size] });
        pos += size;
    }
    Ok(out)
}

/// The first child box of the given type.
pub fn child(data: &[u8], kind: [u8; 4]) -> Result<Option<&[u8]>> {
    Ok(boxes(data)?.into_iter().find(|b| b.kind == kind).map(|b| b.body))
}

/// Follows a path of container boxes.
pub fn path<'a>(data: &'a [u8], kinds: &[&[u8; 4]]) -> Result<Option<&'a [u8]>> {
    let mut cur = data;
    for kind in kinds {
        match child(cur, **kind)? {
            Some(body) => cur = body,
            None => return Ok(None),
        }
    }
    Ok(Some(cur))
}

/// Appends big-endian values and boxes whose sizes are filled in on close.
#[derive(Default)]
pub struct Writer {
    pub buf: Vec<u8>,
    open: Vec<usize>,
}

impl Writer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn u8(&mut self, v: u8) {
        self.buf.push(v);
    }

    pub fn u16(&mut self, v: u16) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    pub fn u32(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    pub fn u64(&mut self, v: u64) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    pub fn bytes(&mut self, v: &[u8]) {
        self.buf.extend_from_slice(v);
    }

    pub fn begin(&mut self, kind: [u8; 4]) {
        self.open.push(self.buf.len());
        self.u32(0);
        self.bytes(&kind);
    }

    pub fn begin_full(&mut self, kind: [u8; 4], version: u8, flags: u32) {
        self.begin(kind);
        self.u32(u32::from(version) << 24 | flags);
    }

    /// Closes the innermost open box. Boxes here stay far below 4 GB: the
    /// largest is one fragment's mdat.
    pub fn end(&mut self) {
        if let Some(start) = self.open.pop() {
            let size = u32::try_from(self.buf.len() - start).unwrap_or(u32::MAX);
            self.buf[start..start + 4].copy_from_slice(&size.to_be_bytes());
        }
    }

    /// Writes a whole box with the given payload.
    pub fn boxed(&mut self, kind: [u8; 4], body: &[u8]) {
        self.begin(kind);
        self.bytes(body);
        self.end();
    }

    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn set_u32(&mut self, at: usize, v: u32) {
        if let Some(slot) = self.buf.get_mut(at..at + 4) {
            slot.copy_from_slice(&v.to_be_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_fail_past_the_end() {
        let mut r = Reader::new(&[1, 2, 3]);
        assert_eq!(r.u16(), Ok(0x0102));
        assert!(r.u16().is_err());
        assert_eq!(r.u8(), Ok(3));
    }

    #[test]
    fn writes_nested_boxes() {
        let mut w = Writer::new();
        w.begin(*b"moov");
        w.boxed(*b"free", &[1, 2]);
        w.end();
        assert_eq!(w.buf, [0, 0, 0, 18, b'm', b'o', b'o', b'v', 0, 0, 0, 10, b'f', b'r', b'e', b'e', 1, 2]);
        let top = boxes(&w.buf).unwrap_or_default();
        assert_eq!(top.len(), 1);
        assert_eq!(path(&w.buf, &[b"moov", b"free"]), Ok(Some(&[1u8, 2][..])));
    }

    #[test]
    fn extent_waits_for_the_header() {
        assert_eq!(box_extent(&[0, 0, 0]), Ok(None));
        assert_eq!(box_extent(&[0, 0, 0, 9, b'm', b'd', b'a', b't']), Ok(Some((9, 8))));
        assert!(box_extent(&[0, 0, 0, 4, b'm', b'd', b'a', b't']).is_err());
    }
}
