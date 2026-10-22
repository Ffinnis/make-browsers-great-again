use super::{ImportedProfile, ImportedSpace, Item};
use rusqlite::Connection;
use std::fs;
use std::path::{Path, PathBuf};

pub fn profiles(data_dir: &Path) -> Vec<(String, String)> {
    let Ok(ini) = fs::read_to_string(data_dir.join("profiles.ini")) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut section: Option<(String, String)> = None;
    let flush = |section: &mut Option<(String, String)>, out: &mut Vec<(String, String)>| {
        if let Some((name, path)) = section.take() {
            if !path.is_empty() && profile_path(data_dir, &path).join("places.sqlite").exists() {
                out.push((path, name));
            }
        }
    };
    for line in ini.lines().map(str::trim) {
        if line.starts_with('[') {
            flush(&mut section, &mut out);
            if line.starts_with("[Profile") {
                section = Some((String::new(), String::new()));
            }
        } else if let (Some(s), Some((key, value))) = (section.as_mut(), line.split_once('=')) {
            match key {
                "Name" => s.0 = value.to_string(),
                "Path" => s.1 = value.to_string(),
                _ => {}
            }
        }
    }
    flush(&mut section, &mut out);
    out
}

pub fn profile_path(data_dir: &Path, path: &str) -> PathBuf {
    let p = Path::new(path);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        data_dir.join(p)
    }
}

pub fn load(data_dir: &Path, path: &str, name: &str, space_name: &str) -> Result<ImportedProfile, String> {
    let dir = profile_path(data_dir, path);
    let result =
        super::read_copy(&dir.join("places.sqlite"), read_bookmarks).map_err(|e| format!("Can't read bookmarks: {e}"));
    let pinned = result?;
    Ok(ImportedProfile {
        id: path.to_string(),
        name: name.to_string(),
        favorites: Vec::new(),
        spaces: vec![ImportedSpace {
            position: 0,
            name: space_name.to_string(),
            icon: None,
            color: None,
            pinned,
            today: Vec::new(),
        }],
    })
}

struct Row {
    id: i64,
    parent: i64,
    kind: i64,
    title: String,
    url: Option<String>,
}

fn read_bookmarks(db: &Connection) -> rusqlite::Result<Vec<Item>> {
    let mut stmt = db.prepare(
        "SELECT b.id, b.parent, b.type, COALESCE(b.title, ''), p.url
         FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
         ORDER BY b.parent, b.position",
    )?;
    let rows: Vec<Row> = stmt
        .query_map([], |r| {
            Ok(Row { id: r.get(0)?, parent: r.get(1)?, kind: r.get(2)?, title: r.get(3)?, url: r.get(4)? })
        })?
        .collect::<Result<_, _>>()?;
    let root_id = |guid: &str| -> Option<i64> {
        db.query_row("SELECT id FROM moz_bookmarks WHERE guid = ?1", [guid], |r| r.get(0)).ok()
    };
    let mut out = Vec::new();
    for (guid, name) in [
        ("toolbar_____", "Bookmarks Toolbar"),
        ("menu________", "Bookmarks Menu"),
        ("unfiled_____", "Other Bookmarks"),
        ("mobile______", "Mobile Bookmarks"),
    ] {
        if let Some(id) = root_id(guid) {
            let children = tree(&rows, id);
            if !children.is_empty() {
                out.push(Item::folder(name, children, false));
            }
        }
    }
    Ok(out)
}

fn tree(rows: &[Row], parent: i64) -> Vec<Item> {
    rows.iter()
        .filter(|r| r.parent == parent)
        .filter_map(|r| match r.kind {
            1 => {
                let url = r.url.as_deref()?;
                super::importable(url).then(|| Item::tab(url, &r.title))
            }
            2 => Some(Item::folder(if r.title.is_empty() { "Folder" } else { &r.title }, tree(rows, r.id), false)),
            _ => None,
        })
        .collect()
}
