//! The C ABI worker.js calls. This is the only module with `unsafe`: it
//! turns the handles and buffers JS passes back into Rust references.
//!
//! JS owns nothing here. It copies input into a buffer from `mm_alloc`,
//! passes it in and frees it; it reads results straight out of memory
//! through the pointer and length getters, and must copy them before the
//! next call into the module, which may move them. A handle is a pointer to
//! a boxed `Converter`, valid from `mm_create` until `mm_destroy`.
//!
//! Status codes: 0 done, 1 a job waits (`mm_poll` only), -1 failed, with
//! the reason in `mm_error_*`.
#![allow(unsafe_code)]

use std::slice;

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

/// # Safety
/// `ptr` and `len` describe a buffer from `mm_alloc`, or `len` is 0.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: per the function's contract.
    unsafe { slice::from_raw_parts(ptr, len) }
}

#[no_mangle]
pub extern "C" fn mm_alloc(len: usize) -> *mut u8 {
    let mut v = Vec::<u8>::with_capacity(len.max(1));
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    ptr
}

/// # Safety
/// `ptr` came from `mm_alloc(len)`.
#[no_mangle]
pub unsafe extern "C" fn mm_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        // SAFETY: rebuilds the Vec mm_alloc leaked, with its capacity.
        drop(unsafe { Vec::from_raw_parts(ptr, 0, len.max(1)) });
    }
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

/// Appends input bytes. Converting happens in `mm_poll`.
///
/// # Safety
/// See `conv` and `bytes`.
#[no_mangle]
pub unsafe extern "C" fn mm_push(h: *mut Converter, ptr: *const u8, len: usize) -> i32 {
    // SAFETY: forwarded contract.
    let (Some(c), data) = (unsafe { conv(h) }, unsafe { bytes(ptr, len) }) else {
        return -1;
    };
    c.push(data);
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

/// Where the job samples' offsets point into.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_job_data(h: *mut Converter) -> *const u8 {
    // SAFETY: forwarded contract.
    unsafe { conv(h) }.and_then(|c| c.job()).map_or(std::ptr::null(), |j| j.data.as_ptr())
}

/// An encoded VP9 chunk for the job, with the timestamp of its frame.
///
/// # Safety
/// See `conv` and `bytes`.
#[no_mangle]
pub unsafe extern "C" fn mm_chunk(
    h: *mut Converter,
    track: u32,
    timestamp: f64,
    key: u32,
    ptr: *const u8,
    len: usize,
) -> i32 {
    // SAFETY: forwarded contract.
    let (Some(c), data) = (unsafe { conv(h) }, unsafe { bytes(ptr, len) }) else {
        return -1;
    };
    let r = c.chunk(track, timestamp, key != 0, data).map(|()| 0);
    status(c, r)
}

/// Ends the job and writes its fragment. Poll again afterwards.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_finish(h: *mut Converter) -> i32 {
    // SAFETY: forwarded contract.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    let r = c.finish().map(|()| 0);
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

/// Empties the output once JS has copied it.
///
/// # Safety
/// See `conv`.
#[no_mangle]
pub unsafe extern "C" fn mm_output_clear(h: *mut Converter) {
    // SAFETY: forwarded contract.
    if let Some(c) = unsafe { conv(h) } {
        c.output.clear();
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
