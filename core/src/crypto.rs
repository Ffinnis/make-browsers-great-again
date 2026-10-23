#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Hash {
    Sha1,
    Sha256,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Cipher {
    Aes,
    TripleDes,
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
mod sys {
    use super::{Cipher, Hash};
    use std::ffi::c_void;

    const PBKDF2: u32 = 2;
    const PKCS7: u32 = 1;

    extern "C" {
        fn CCKeyDerivationPBKDF(
            algorithm: u32,
            password: *const u8,
            password_len: usize,
            salt: *const u8,
            salt_len: usize,
            prf: u32,
            rounds: u32,
            derived: *mut u8,
            derived_len: usize,
        ) -> i32;
        fn CCCrypt(
            op: u32,
            alg: u32,
            options: u32,
            key: *const c_void,
            key_len: usize,
            iv: *const c_void,
            data_in: *const c_void,
            data_in_len: usize,
            data_out: *mut c_void,
            data_out_available: usize,
            data_out_moved: *mut usize,
        ) -> i32;
        fn CCHmac(alg: u32, key: *const c_void, key_len: usize, data: *const c_void, len: usize, mac: *mut u8);
        fn CC_SHA1(data: *const c_void, len: u32, md: *mut u8) -> *mut u8;
        fn CC_SHA256(data: *const c_void, len: u32, md: *mut u8) -> *mut u8;
        fn CCRandomGenerateBytes(bytes: *mut c_void, count: usize) -> i32;
    }

    pub fn pbkdf2(hash: Hash, password: &[u8], salt: &[u8], rounds: u32, out: &mut [u8]) -> bool {
        let prf = if hash == Hash::Sha1 { 1 } else { 3 };
        // SAFETY: each pointer comes with its slice's length, and `out` is
        // writable for `out.len()` bytes.
        let status = unsafe {
            CCKeyDerivationPBKDF(
                PBKDF2,
                password.as_ptr(),
                password.len(),
                salt.as_ptr(),
                salt.len(),
                prf,
                rounds,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        status == 0
    }

    pub fn cbc(encrypt: bool, cipher: Cipher, key: &[u8], iv: &[u8], data: &[u8]) -> Option<Vec<u8>> {
        let alg = if cipher == Cipher::Aes { 0 } else { 2 };
        let mut out = vec![0u8; data.len() + 16];
        let mut moved = 0usize;
        // SAFETY: each pointer comes with its slice's length; `out` has room
        // for the input plus a block of padding, which is all CBC can add.
        let status = unsafe {
            CCCrypt(
                u32::from(!encrypt),
                alg,
                PKCS7,
                key.as_ptr().cast(),
                key.len(),
                iv.as_ptr().cast(),
                data.as_ptr().cast(),
                data.len(),
                out.as_mut_ptr().cast(),
                out.len(),
                &raw mut moved,
            )
        };
        if status != 0 {
            return None;
        }
        out.truncate(moved);
        Some(out)
    }

    pub fn hmac(hash: Hash, key: &[u8], data: &[u8]) -> Vec<u8> {
        let (alg, len) = if hash == Hash::Sha1 { (0, 20) } else { (2, 32) };
        let mut mac = vec![0u8; len];
        // SAFETY: key and data come with their lengths, and `mac` has room for
        // the digest `alg` produces (20 bytes for SHA-1, 32 for SHA-256).
        unsafe { CCHmac(alg, key.as_ptr().cast(), key.len(), data.as_ptr().cast(), data.len(), mac.as_mut_ptr()) };
        mac
    }

    pub fn digest(hash: Hash, data: &[u8]) -> Vec<u8> {
        let mut md = vec![0u8; if hash == Hash::Sha1 { 20 } else { 32 }];
        let len = u32::try_from(data.len()).expect("CommonCrypto digests at most 4 GB in one call");
        // SAFETY: `md` is as long as the digest written, and `data`'s length is
        // passed with it.
        unsafe {
            if hash == Hash::Sha1 {
                CC_SHA1(data.as_ptr().cast(), len, md.as_mut_ptr());
            } else {
                CC_SHA256(data.as_ptr().cast(), len, md.as_mut_ptr());
            }
        }
        md
    }

    pub fn random(out: &mut [u8]) -> bool {
        // SAFETY: `out` is writable for `out.len()` bytes.
        unsafe { CCRandomGenerateBytes(out.as_mut_ptr().cast(), out.len()) == 0 }
    }
}

#[cfg(not(target_os = "macos"))]
mod sys {
    use super::{Cipher, Hash};

    pub fn pbkdf2(_: Hash, _: &[u8], _: &[u8], _: u32, _: &mut [u8]) -> bool {
        false
    }

    pub fn cbc(_: bool, _: Cipher, _: &[u8], _: &[u8], _: &[u8]) -> Option<Vec<u8>> {
        None
    }

    pub fn hmac(_: Hash, _: &[u8], _: &[u8]) -> Vec<u8> {
        Vec::new()
    }

    pub fn digest(_: Hash, _: &[u8]) -> Vec<u8> {
        Vec::new()
    }

    pub fn random(_: &mut [u8]) -> bool {
        false
    }
}

pub fn pbkdf2(hash: Hash, password: &[u8], salt: &[u8], rounds: u32, len: usize) -> Option<Vec<u8>> {
    let mut key = vec![0u8; len];
    sys::pbkdf2(hash, password, salt, rounds, &mut key).then_some(key)
}

pub fn cbc(encrypt: bool, cipher: Cipher, key: &[u8], iv: &[u8], data: &[u8]) -> Option<Vec<u8>> {
    sys::cbc(encrypt, cipher, key, iv, data)
}

pub fn hmac(hash: Hash, key: &[u8], data: &[u8]) -> Vec<u8> {
    sys::hmac(hash, key, data)
}

pub fn digest(hash: Hash, data: &[u8]) -> Vec<u8> {
    sys::digest(hash, data)
}

pub fn random(len: usize) -> Option<Vec<u8>> {
    let mut out = vec![0u8; len];
    sys::random(&mut out).then_some(out)
}

pub fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}
