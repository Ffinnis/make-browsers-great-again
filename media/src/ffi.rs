//! The C ABI worker.js calls. This is the only module with `unsafe`: it
//! turns the handles and buffers JS passes back into Rust references.
//!
//! JS owns nothing here. It writes input and encoded chunks straight into
//! buffers the converter reserves (`mm_reserve`, `mm_chunk_buffer`) and
//! says how much it wrote; it reads results straight out of memory through
//! the pointer and length getters, and must copy them before the next call
//! into the module, which may move them. A handle is a pointer to a boxed
//! `Converter`, valid from `mm_create` until `mm_destroy`.
//!
//! Status codes: 0 done, 1 a job waits (`mm_poll` only), -1 failed, with
//! the reason in `mm_error_*`.
#![allow(unsafe_code)]

use crate::conv::{Converter, JobSample, Poll};

fn status(c: &mut Converter, r: crate::bytes::Result<i32>) -> i32 {
    r.unwrap_or_else(|e| {
        c.fail(&e);
        -1
    })
}

/// # Safety
/// `h` comes from `mm_create` and hasn't been destroyed; JS is single
/// threaded, so no other reference to it exists during the call.
unsafe fn conv<'a>(h: *mut Converter) -> Option<&'a mut Converter> {
    // SAFETY: per the function's contract.
    unsafe { h.as_mut() }
}

/// Marks `len` bytes JS wrote into `buf`'s spare capacity as part of it.
/// False if they don't fit, which JS can't do through the pointers it got.
///
/// # Safety
/// JS wrote `len` bytes from `buf.as_ptr() + buf.len()` on, through a
/// pointer this module returned for that capacity.
unsafe fn grow(buf: &mut Vec<u8>, len: usize) -> bool {
    if buf.capacity() - buf.len() < len {
        return false;
    }
    // SAFETY: within capacity, and the bytes are initialized: JS wrote them.
    unsafe { buf.set_len(buf.len() + len) };
    true
}

/// A converter for one `SourceBuffer`; `progressive` != 0 for a whole MP4
/// file rather than MSE segments.
#[no_mangle]
pub extern "C" fn mm_create(progressive: u32) -> *mut Converter {
    Box::into_raw(Box::new(Converter::new(progressive != 0)))
}

/// # Safety
/// `h` came from `mm_create` and isn't used again.
#[no_mangle]
pub unsafe extern "C" fn mm_destroy(h: *mut Converter) {
    if !h.is_null() {
        // SAFETY: undoes mm_create's Box::into_raw.
        drop(unsafe { Box::from_raw(h) });
    }
}

/// Starts an append or a drain: frames from earlier ones come out in
/// `held` from now on.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_begin(h: *mut Converter) {
    // SAFETY: forwarded contract.
    if let Some(c) = unsafe { conv(h) } {
        c.begin();
    }
}

/// Room for `len` bytes of input: where to write them before `mm_commit`.
/// Null if that's more input than a converter takes at once.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_reserve(h: *mut Converter, len: usize) -> *mut u8 {
    // SAFETY: forwarded contract.
    let Some(c) = (unsafe { conv(h) }) else {
        return std::ptr::null_mut();
    };
    // Past the limit, the next poll fails.
    c.input.room(len).map_or(std::ptr::null_mut(), |buf| buf.spare_capacity_mut().as_mut_ptr().cast())
}

/// Takes the `len` bytes written where `mm_reserve` said. Converting
/// happens in `mm_poll`.
///
/// # Safety
/// See `conv` and `grow`: `len` is at most what was reserved, and nothing
/// was called in between.
#[no_mangle]
pub unsafe extern "C" fn mm_commit(h: *mut Converter, len: usize) -> i32 {
    // SAFETY: forwarded contract.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    // SAFETY: forwarded contract.
    if !unsafe { grow(c.input.buffer(), len) } {
        return -1;
    }
    c.committed(len);
    0
}

/// Converts what's complete. 1: a job waits for video (see `mm_job_*`),
/// 0: everything so far is in the output.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_poll(h: *mut Converter) -> i32 {
    // SAFETY: forwarded contract.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    let r = c.poll().map(|p| i32::from(p == Poll::Job));
    status(c, r)
}

/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_job_len(h: *mut Converter) -> usize {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.and_then(|c| c.job()).map_or(0, |j| j.samples.len())
}

/// The job's samples, `mm_job_len` records of `JobSample`.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_job_samples(h: *mut Converter) -> *const JobSample {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.and_then(|c| c.job()).map_or(std::ptr::null(), |j| j.samples.as_ptr())
}

/// Where the job samples' offsets point into. Stays put until `mm_write`.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_job_data(h: *mut Converter) -> *const u8 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.and_then(|c| c.job()).map_or(std::ptr::null(), |j| j.data.as_ptr())
}

/// The decoder put out the frame with `timestamp`: 1 to encode it, 0 to
/// drop it.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_frame(h: *mut Converter, track: u32, timestamp: f64) -> u32 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(0, |c| u32::from(c.frame(track, timestamp)))
}

/// Room for an encoded chunk of `len` bytes, for `mm_chunk`.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_chunk_buffer(h: *mut Converter, len: usize) -> *mut u8 {
    // SAFETY: forwarded contract.
    let Some(c) = (unsafe { conv(h) }) else {
        return std::ptr::null_mut();
    };
    c.chunk_buffer.clear();
    if c.chunk_buffer.try_reserve(len).is_err() {
        return std::ptr::null_mut();
    }
    c.chunk_buffer.spare_capacity_mut().as_mut_ptr().cast()
}

/// The VP9 chunk of `len` bytes written to `mm_chunk_buffer`, for the frame
/// with `timestamp`, encoded at `width` × `height`.
///
/// # Safety
/// See `conv` and `grow`.
#[no_mangle]
pub unsafe extern "C" fn mm_chunk(
    h: *mut Converter,
    track: u32,
    timestamp: f64,
    key: u32,
    width: u32,
    height: u32,
    len: usize,
) -> i32 {
    // SAFETY: forwarded contract.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    // SAFETY: forwarded contract.
    if !unsafe { grow(&mut c.chunk_buffer, len) } {
        return -1;
    }
    let data = std::mem::take(&mut c.chunk_buffer);
    let size = (width.min(0xffff) as u16, height.min(0xffff) as u16);
    let r = c.chunk(track, timestamp, key != 0, size, data).map(|()| 0);
    status(c, r)
}

/// The worker flushed `track`'s decoder, and its chunks are all in.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_flushed(h: *mut Converter, track: u32) {
    // SAFETY: forwarded contract.
    if let Some(c) = unsafe { conv(h) } {
        c.flushed(track);
    }
}

/// The worker's codecs started over; frames in flight are lost.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_restart(h: *mut Converter) {
    // SAFETY: forwarded contract.
    if let Some(c) = unsafe { conv(h) } {
        c.restart();
    }
}

/// Ends the job, if any, and writes fragments with every chunk so far.
/// Poll again afterwards.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_write(h: *mut Converter) -> i32 {
    // SAFETY: forwarded contract.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    let r = c.write().map(|()| 0);
    status(c, r)
}

/// Drops partial input and decoder state after the page's `abort()`.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_reset(h: *mut Converter) {
    // SAFETY: forwarded contract.
    if let Some(c) = unsafe { conv(h) } {
        c.reset();
    }
}

/// 1 if nothing waits in the converter, so a fresh one primed with the
/// init would carry on the same.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_recyclable(h: *mut Converter) -> u32 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(0, |c| u32::from(c.recyclable()))
}

/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_output_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.output.as_ptr())
}

/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_output_len(h: *mut Converter) -> usize {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(0, |c| c.output.len())
}

/// Frames of earlier appends, for the page to append before the output.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_held_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.held.as_ptr())
}

/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_held_len(h: *mut Converter) -> usize {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(0, |c| c.held.len())
}

/// Empties the output and `held` once JS has copied them.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_output_clear(h: *mut Converter) {
    // SAFETY: forwarded contract.
    if let Some(c) = unsafe { conv(h) } {
        for buf in [&mut c.output, &mut c.held] {
            buf.clear();
            // A big append's output needn't stay allocated.
            if buf.capacity() > 16 << 20 {
                *buf = Vec::new();
            }
        }
    }
}

/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_error_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.error.as_ptr())
}

/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_error_len(h: *mut Converter) -> usize {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(0, |c| c.error.len())
}

/// The converted init's MIME type, empty before the first init.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_mime_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.mime.as_ptr())
}

/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_mime_len(h: *mut Converter) -> usize {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(0, |c| c.mime.len())
}

/// The last input init segment (ftyp and moov), to prime a new converter
/// with if this one's module instance is lost.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_init_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.init.as_ptr())
}

/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_init_len(h: *mut Converter) -> usize {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(0, |c| c.init.len())
}

/// Changes whenever a new init segment arrives.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_init_generation(h: *mut Converter) -> u32 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.map_or(0, |c| c.init_generation)
}
