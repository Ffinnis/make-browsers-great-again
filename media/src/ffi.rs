#![allow(unsafe_code, clippy::missing_safety_doc)]

use crate::conv::{Converter, HeldGroup, JobSample, Poll};

fn status(c: &mut Converter, r: crate::bytes::Result<i32>) -> i32 {
    r.unwrap_or_else(|e| {
        c.fail(&e);
        -1
    })
}

unsafe fn conv<'a>(h: *mut Converter) -> Option<&'a mut Converter> {
    // SAFETY: `h` came from `mm_create` and JS hasn't destroyed it; JS is single
    // threaded, so no other reference to it exists during the call.
    unsafe { h.as_mut() }
}

unsafe fn grow(buf: &mut Vec<u8>, len: usize) -> bool {
    if buf.capacity() - buf.len() < len {
        return false;
    }
    // SAFETY: within capacity, and the bytes are initialized: JS wrote them
    // through a pointer this module returned for that capacity.
    unsafe { buf.set_len(buf.len() + len) };
    true
}

#[no_mangle]
pub extern "C" fn mm_create(progressive: u32) -> *mut Converter {
    Box::into_raw(Box::new(Converter::new(progressive != 0)))
}

#[no_mangle]
pub unsafe extern "C" fn mm_destroy(h: *mut Converter) {
    if !h.is_null() {
        // SAFETY: undoes mm_create's Box::into_raw, and JS doesn't use `h` again.
        drop(unsafe { Box::from_raw(h) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn mm_begin(h: *mut Converter, seq: f64) {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    if let Some(c) = unsafe { conv(h) } {
        c.begin(seq);
    }
}

#[no_mangle]
pub unsafe extern "C" fn mm_reserve(h: *mut Converter, len: usize) -> *mut u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return std::ptr::null_mut();
    };
    c.input.room(len).map_or(std::ptr::null_mut(), |buf| buf.spare_capacity_mut().as_mut_ptr().cast())
}

#[no_mangle]
pub unsafe extern "C" fn mm_commit(h: *mut Converter, len: usize) -> i32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    // SAFETY: JS wrote at most the `len` bytes reserved, with no call in between.
    if !unsafe { grow(c.input.buffer(), len) } {
        return -1;
    }
    c.committed(len);
    0
}

#[no_mangle]
pub unsafe extern "C" fn mm_poll(h: *mut Converter) -> i32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    let r = c.poll().map(|p| i32::from(p == Poll::Job));
    status(c, r)
}

#[no_mangle]
pub unsafe extern "C" fn mm_job_len(h: *mut Converter) -> usize {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.job()).map_or(0, |j| j.samples.len())
}

#[no_mangle]
pub unsafe extern "C" fn mm_job_samples(h: *mut Converter) -> *const JobSample {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.job()).map_or(std::ptr::null(), |j| j.samples.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_job_data(h: *mut Converter) -> *const u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.job()).map_or(std::ptr::null(), |j| j.data.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_frame(
    h: *mut Converter,
    track: u32,
    timestamp: f64,
    skip: u32,
    width: u32,
    height: u32,
) -> u32 {
    let visible = (width.min(0xffff) as u16, height.min(0xffff) as u16);
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.frame(track, timestamp, skip != 0, visible))
}

#[no_mangle]
pub unsafe extern "C" fn mm_chunk_buffer(h: *mut Converter, len: usize) -> *mut u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return std::ptr::null_mut();
    };
    c.chunk_buffer.clear();
    if c.chunk_buffer.try_reserve(len).is_err() {
        return std::ptr::null_mut();
    }
    c.chunk_buffer.spare_capacity_mut().as_mut_ptr().cast()
}

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
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    // SAFETY: JS wrote at most the `len` bytes reserved, with no call in between.
    if !unsafe { grow(&mut c.chunk_buffer, len) } {
        return -1;
    }
    let data = std::mem::take(&mut c.chunk_buffer);
    let size = (width.min(0xffff) as u16, height.min(0xffff) as u16);
    let r = c.chunk(track, timestamp, key != 0, size, data).map(|()| 0);
    status(c, r)
}

#[no_mangle]
pub unsafe extern "C" fn mm_flushed(h: *mut Converter, track: u32) {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    if let Some(c) = unsafe { conv(h) } {
        c.flushed(track);
    }
}

#[no_mangle]
pub unsafe extern "C" fn mm_restart(h: *mut Converter) {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    if let Some(c) = unsafe { conv(h) } {
        c.restart();
    }
}

#[no_mangle]
pub unsafe extern "C" fn mm_write(h: *mut Converter) -> i32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    let r = c.write().map(|()| 0);
    status(c, r)
}

#[no_mangle]
pub unsafe extern "C" fn mm_reset(h: *mut Converter) {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    if let Some(c) = unsafe { conv(h) } {
        c.reset();
    }
}

#[no_mangle]
pub unsafe extern "C" fn mm_recyclable(h: *mut Converter) -> u32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| u32::from(c.recyclable()))
}

#[no_mangle]
pub unsafe extern "C" fn mm_save_state(h: *mut Converter) -> usize {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| {
        c.save_state();
        c.state.len()
    })
}

#[no_mangle]
pub unsafe extern "C" fn mm_state_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.state.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_state_buffer(h: *mut Converter, len: usize) -> *mut u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return std::ptr::null_mut();
    };
    c.state.clear();
    if c.state.try_reserve(len).is_err() {
        return std::ptr::null_mut();
    }
    c.state.spare_capacity_mut().as_mut_ptr().cast()
}

#[no_mangle]
pub unsafe extern "C" fn mm_load_state(h: *mut Converter, len: usize) -> i32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return -1;
    };
    // SAFETY: JS wrote at most the `len` bytes reserved, with no call in between.
    if !unsafe { grow(&mut c.state, len) } {
        return -1;
    }
    let state = std::mem::take(&mut c.state);
    let r = c.load_state(&state).map(|()| 0);
    status(c, r)
}

#[no_mangle]
pub unsafe extern "C" fn mm_output_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.output.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_output_len(h: *mut Converter) -> usize {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.output.len())
}

#[no_mangle]
pub unsafe extern "C" fn mm_held_count(h: *mut Converter) -> usize {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.held_groups.len())
}

#[no_mangle]
pub unsafe extern "C" fn mm_held_groups(h: *mut Converter) -> *const HeldGroup {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.held_groups.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_held_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.held.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_held_len(h: *mut Converter) -> usize {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.held.len())
}

#[no_mangle]
pub unsafe extern "C" fn mm_output_clear(h: *mut Converter) {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    if let Some(c) = unsafe { conv(h) } {
        c.clear_output();
    }
}

#[no_mangle]
pub unsafe extern "C" fn mm_output_discard(h: *mut Converter) {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    if let Some(c) = unsafe { conv(h) } {
        c.discard_output();
    }
}

#[no_mangle]
pub unsafe extern "C" fn mm_start(h: *mut Converter, seconds: f64) {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    if let Some(c) = unsafe { conv(h) } {
        c.set_start(seconds);
    }
}

#[no_mangle]
pub unsafe extern "C" fn mm_offset(h: *mut Converter, offset: f64) -> u32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    let Some(c) = (unsafe { conv(h) }) else {
        return 0;
    };
    if !(0.0..9_007_199_254_740_992.0).contains(&offset) {
        return 0;
    }
    u32::from(c.offset(offset as u64))
}

#[no_mangle]
pub unsafe extern "C" fn mm_need(h: *mut Converter) -> f64 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.need).map_or(-1.0, |n| n as f64)
}

#[no_mangle]
pub unsafe extern "C" fn mm_output_start(h: *mut Converter) -> f64 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.output_range).map_or(f64::NAN, |r| r.0)
}

#[no_mangle]
pub unsafe extern "C" fn mm_output_end(h: *mut Converter) -> f64 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.output_range).map_or(f64::NAN, |r| r.1)
}

#[no_mangle]
pub unsafe extern "C" fn mm_inits(h: *mut Converter) -> u32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.inits_out)
}

#[no_mangle]
pub unsafe extern "C" fn mm_natural_width(h: *mut Converter) -> u32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.natural_out).map_or(0, |n| n.width)
}

#[no_mangle]
pub unsafe extern "C" fn mm_natural_height(h: *mut Converter) -> u32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.natural_out).map_or(0, |n| n.height)
}

#[no_mangle]
pub unsafe extern "C" fn mm_natural_at(h: *mut Converter) -> f64 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.natural_out).and_then(|n| n.at).unwrap_or(f64::NAN)
}

#[no_mangle]
pub unsafe extern "C" fn mm_natural_seq(h: *mut Converter) -> f64 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.and_then(|c| c.natural_out).map_or(f64::NAN, |n| n.seq)
}

#[no_mangle]
pub unsafe extern "C" fn mm_error_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.error.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_error_len(h: *mut Converter) -> usize {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.error.len())
}

#[no_mangle]
pub unsafe extern "C" fn mm_mime_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.mime.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_mime_len(h: *mut Converter) -> usize {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.mime.len())
}

#[no_mangle]
pub unsafe extern "C" fn mm_init_ptr(h: *mut Converter) -> *const u8 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(std::ptr::null(), |c| c.init.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn mm_init_len(h: *mut Converter) -> usize {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.init.len())
}

#[no_mangle]
pub unsafe extern "C" fn mm_init_generation(h: *mut Converter) -> u32 {
    // SAFETY: JS passes the live handle `mm_create` gave it.
    unsafe { conv(h) }.map_or(0, |c| c.init_generation)
}
