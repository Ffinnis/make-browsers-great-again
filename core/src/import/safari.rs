use super::{ImportedProfile, ImportedSpace, Item};
use plist::Value;
use std::path::Path;

pub const NEEDS_ACCESS: &str = "MBGA needs Full Disk Access to read Safari's bookmarks.";

pub fn load(path: &Path) -> Result<ImportedProfile, String> {
    let root = Value::from_file(path).map_err(|e| {
        if e.as_io().is_some_and(|io| io.kind() == std::io::ErrorKind::PermissionDenied) {
            NEEDS_ACCESS.to_string()
        } else {
            format!("Can't read Safari's bookmarks: {e}")
        }
    })?;
    let mut pinned = Vec::new();
    for list in children(&root) {
        let title = list.as_dictionary().and_then(|d| d.get("Title")).and_then(Value::as_string).unwrap_or("");
        let name = match title {
            "BookmarksBar" => "Favorites Bar",
            "BookmarksMenu" => "Bookmarks Menu",
            "com.apple.ReadingList" => "Reading List",
            other => other,
        };
        let items = items(list);
        if !items.is_empty() {
            pinned.push(Item::folder(if name.is_empty() { "Bookmarks" } else { name }, items, false));
        }
    }
    Ok(ImportedProfile {
        id: "Safari".into(),
        name: "Safari".into(),
        favorites: Vec::new(),
        spaces: vec![ImportedSpace {
            position: 0,
            name: "Safari".into(),
            icon: None,
            color: None,
            pinned,
            today: Vec::new(),
        }],
    })
}

fn children(node: &Value) -> impl Iterator<Item = &Value> {
    node.as_dictionary().and_then(|d| d.get("Children")).and_then(Value::as_array).into_iter().flatten()
}

fn items(list: &Value) -> Vec<Item> {
    children(list)
        .filter_map(|node| {
            let d = node.as_dictionary()?;
            match d.get("WebBookmarkType")?.as_string()? {
                "WebBookmarkTypeLeaf" => {
                    let url = d.get("URLString")?.as_string()?;
                    let title = d
                        .get("URIDictionary")
                        .and_then(Value::as_dictionary)
                        .and_then(|u| u.get("title"))
                        .and_then(Value::as_string)
                        .unwrap_or("");
                    super::importable(url).then(|| Item::tab(url, title))
                }
                "WebBookmarkTypeList" => {
                    let title = d.get("Title").and_then(Value::as_string).unwrap_or("Folder");
                    Some(Item::folder(title, items(node), false))
                }
                _ => None,
            }
        })
        .collect()
}
