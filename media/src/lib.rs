//! Converts the H.264 and AAC that pages hand to Media Source Extensions
//! into VP9 and FLAC, which the engine can play. Built to WebAssembly and run
//! in a worker; see README.md.

mod audio;
mod avc;
mod bytes;
pub mod conv;
mod ffi;
mod flac;
mod frag;
mod init;
mod progressive;

pub use bytes::Error;
pub use conv::{Converter, Job, JobSample, Poll, DECODE_ONLY, KEY, UNHELD};
