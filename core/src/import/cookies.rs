use super::{firefox, Kind, Source};
use crate::crypto::{self, Cipher, Hash};
use rusqlite::Connection;
use std::path::{Path, PathBuf};

const UNIX_EPOCH_US: i64 = 11_644_473_600_000_000;

#[derive(Debug, Clone, PartialEq)]
pub struct Cookie {
    pub domain: String,
    pub name: String,
    pub value: String,
    pub path: String,
    pub secure: bool,
    pub http_only: bool,
    pub expires: i64,
    pub created: i64,
    pub last_used: i64,
    pub same_site: i32,
    pub priority: i32,
}

pub fn keychain_service(source: &Source) -> Option<String> {
    let name = match source.kind {
        Kind::Arc => "Arc",
        Kind::Chromium if source.name.starts_with("Chrome") => "Chrome",
        Kind::Chromium if source.name == "Edge" => "Microsoft Edge",
        Kind::Chromium if source.name == "Yandex Browser" => "Yandex",
        Kind::Chromium => &source.name,
        Kind::Firefox | Kind::Safari => return None,
    };
    Some(format!("{name} Safe Storage"))
}

pub fn database(source: &Source, profile_id: &str) -> Option<PathBuf> {
    let data_dir = Path::new(&source.id);
    let candidates = match source.kind {
        Kind::Arc | Kind::Chromium => {
            let profile = if source.kind == Kind::Arc { data_dir.join("User Data") } else { data_dir.to_path_buf() }
                .join(profile_id);
            vec![profile.join("Cookies"), profile.join("Network/Cookies")]
        }
        Kind::Firefox => vec![firefox::profile_path(data_dir, profile_id).join("cookies.sqlite")],
        Kind::Safari => Vec::new(),
    };
    candidates.into_iter().find(|p| p.exists())
}

pub fn read(source: &Source, profile_id: &str, password: Option<&[u8]>, now_ms: u64) -> Result<Vec<Cookie>, String> {
    if source.kind == Kind::Safari {
        return Err("Safari's cookies can't be imported.".into());
    }
    let db = database(source, profile_id).ok_or("It has no cookies.")?;
    let now = UNIX_EPOCH_US + now_ms.cast_signed() * 1000;
    let cookies = if source.kind == Kind::Firefox {
        super::read_copy(&db, read_firefox)?
    } else {
        let password = password.ok_or("Its keychain password is needed.")?;
        let key = derive_key(password).ok_or("Can't derive its cookie key.")?;
        super::read_copy(&db, |db| read_chromium(db, &key))?
    };
    Ok(cookies.into_iter().filter(|c| c.expires == 0 || c.expires > now).collect())
}

fn read_chromium(db: &Connection, key: &[u8]) -> rusqlite::Result<Vec<Cookie>> {
    let version: i64 = db
        .query_row("SELECT value FROM meta WHERE key = 'version'", [], |r| r.get::<_, String>(0))
        .map(|v| v.parse().unwrap_or(0))
        .unwrap_or(0);
    let columns = columns(db, "cookies")?;
    let has = |c: &str| columns.iter().any(|n| n == c);
    let secure = if has("is_secure") { "is_secure" } else { "secure" };
    let http_only = if has("is_httponly") { "is_httponly" } else { "httponly" };
    let persistent = if has("is_persistent") { "is_persistent" } else { "persistent" };
    let same_site = if has("samesite") { "samesite" } else { "-1" };
    let priority = if has("priority") { "priority" } else { "1" };
    let partitioned = if has("top_frame_site_key") { "top_frame_site_key = ''" } else { "1" };
    let sql = format!(
        "SELECT host_key, name, value, encrypted_value, path, {secure}, {http_only}, expires_utc, {persistent},
                creation_utc, last_access_utc, {same_site}, {priority}
         FROM cookies WHERE {partitioned}"
    );
    let mut stmt = db.prepare(&sql)?;
    let rows = stmt.query_map([], |r| {
        let domain: String = r.get(0)?;
        let plain: String = r.get(2)?;
        let encrypted: Vec<u8> = r.get(3)?;
        let value = if !plain.is_empty() || encrypted.is_empty() {
            Some(plain)
        } else {
            decrypt(key, &encrypted, version >= 24)
        };
        Ok(value.map(|value| Cookie {
            domain,
            name: r.get(1).unwrap_or_default(),
            value,
            path: r.get(4).unwrap_or_default(),
            secure: r.get::<_, i64>(5).unwrap_or(0) != 0,
            http_only: r.get::<_, i64>(6).unwrap_or(0) != 0,
            expires: if r.get::<_, i64>(8).unwrap_or(1) != 0 { r.get(7).unwrap_or(0) } else { 0 },
            created: r.get(9).unwrap_or(0),
            last_used: r.get(10).unwrap_or(0),
            same_site: r.get(11).unwrap_or(-1),
            priority: r.get(12).unwrap_or(1),
        }))
    })?;
    Ok(rows.filter_map(|r| r.ok().flatten()).map(sane).collect())
}

fn read_firefox(db: &Connection) -> rusqlite::Result<Vec<Cookie>> {
    let columns = columns(db, "moz_cookies")?;
    let same_site = if columns.iter().any(|c| c == "sameSite") { "sameSite" } else { "256" };
    let sql = format!(
        "SELECT host, name, value, path, isSecure, isHttpOnly, expiry, creationTime, lastAccessed, {same_site}
         FROM moz_cookies WHERE originAttributes = ''"
    );
    let mut stmt = db.prepare(&sql)?;
    let rows = stmt.query_map([], |r| {
        let expiry: i64 = r.get(6)?;
        let expires_ms = if expiry > 100_000_000_000 { expiry } else { expiry.saturating_mul(1000) };
        Ok(Cookie {
            domain: r.get(0)?,
            name: r.get(1)?,
            value: r.get(2)?,
            path: r.get(3)?,
            secure: r.get::<_, i64>(4)? != 0,
            http_only: r.get::<_, i64>(5)? != 0,
            expires: UNIX_EPOCH_US + expires_ms.saturating_mul(1000),
            created: UNIX_EPOCH_US + r.get::<_, i64>(7)?,
            last_used: UNIX_EPOCH_US + r.get::<_, i64>(8)?,
            same_site: match r.get::<_, i64>(9)? {
                0 => 0,
                1 => 1,
                2 => 2,
                _ => -1,
            },
            priority: 1,
        })
    })?;
    Ok(rows.filter_map(Result::ok).map(sane).collect())
}

fn sane(mut cookie: Cookie) -> Cookie {
    if cookie.same_site == 0 && !cookie.secure {
        cookie.same_site = -1;
    }
    cookie
}

pub(super) fn columns(db: &Connection, table: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = db.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = stmt.query_map([], |r| r.get::<_, String>(1))?.filter_map(Result::ok).collect();
    Ok(names)
}

fn decrypt(key: &[u8], encrypted: &[u8], hashed_domain: bool) -> Option<String> {
    let mut plain = decrypt_value(key, encrypted)?;
    if hashed_domain {
        if plain.len() < 32 {
            return None;
        }
        plain.drain(..32);
    }
    String::from_utf8(plain).ok()
}

pub(super) fn derive_key(password: &[u8]) -> Option<Vec<u8>> {
    crypto::pbkdf2(Hash::Sha1, password, b"saltysalt", 1003, 16)
}

const IV: [u8; 16] = [b' '; 16];

pub(super) fn decrypt_value(key: &[u8], encrypted: &[u8]) -> Option<Vec<u8>> {
    let data = encrypted.strip_prefix(b"v10")?;
    crypto::cbc(false, Cipher::Aes, key, &IV, data)
}

#[cfg(test)]
pub(super) fn encrypt_value_for_test(password: &[u8], plain: &[u8]) -> Vec<u8> {
    let key = derive_key(password).unwrap();
    let mut out = b"v10".to_vec();
    out.extend(crypto::cbc(true, Cipher::Aes, &key, &IV, plain).unwrap());
    out
}

#[cfg(test)]
pub(super) fn encrypt_for_test(password: &[u8], domain: &str, value: &str) -> Vec<u8> {
    let mut plain = crypto::digest(Hash::Sha256, domain.as_bytes());
    plain.extend_from_slice(value.as_bytes());
    encrypt_value_for_test(password, &plain)
}
