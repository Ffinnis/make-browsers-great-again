use super::{snss, ImportedProfile, ImportedSpace, Item};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

pub fn profiles(data_dir: &Path) -> Vec<(String, String)> {
    let mut out = Vec::new();
    if let Some(cache) = fs::read(data_dir.join("Local State"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v["profile"]["info_cache"].as_object().cloned())
    {
        for (dir, info) in cache {
            if is_browser_profile(&data_dir.join(&dir)) {
                let name = info["name"].as_str().unwrap_or(&dir).to_string();
                out.push((dir, name));
            }
        }
    }
    if out.is_empty() && is_browser_profile(&data_dir.join("Default")) {
        out.push(("Default".into(), "Default".into()));
    }
    out.sort_by_key(|(dir, _)| dir.strip_prefix("Profile ").and_then(|n| n.parse::<u32>().ok()).map_or(0, |n| n + 1));
    out
}

fn is_browser_profile(dir: &Path) -> bool {
    ["Bookmarks", "History", "Sessions", "Current Session"].iter().any(|f| dir.join(f).exists())
}

pub fn load(data_dir: &Path, dir: &str, name: &str, space_name: &str) -> ImportedProfile {
    let profile = data_dir.join(dir);
    let tabs =
        newest_session(&profile).and_then(|p| fs::read(p).ok()).and_then(|b| snss::parse(&b)).unwrap_or_default();
    let mut pinned: Vec<Item> =
        tabs.iter().filter(|t| t.pinned && super::importable(&t.url)).map(|t| Item::tab(&t.url, &t.title)).collect();
    let today =
        tabs.iter().filter(|t| !t.pinned && super::importable(&t.url)).map(|t| Item::tab(&t.url, &t.title)).collect();
    if let Some(roots) = fs::read(profile.join("Bookmarks"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .map(|v| v["roots"].clone())
    {
        for (key, folder) in
            [("bookmark_bar", "Bookmarks Bar"), ("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")]
        {
            let children = bookmark_items(&roots[key]["children"]);
            if !children.is_empty() {
                pinned.push(Item::folder(folder, children, false));
            }
        }
    }
    ImportedProfile {
        id: dir.to_string(),
        name: name.to_string(),
        favorites: Vec::new(),
        spaces: vec![ImportedSpace {
            position: 0,
            name: space_name.to_string(),
            icon: None,
            color: None,
            pinned,
            today,
        }],
    }
}

fn bookmark_items(children: &Value) -> Vec<Item> {
    children
        .as_array()
        .map(|nodes| {
            nodes
                .iter()
                .filter_map(|n| match n["type"].as_str() {
                    Some("url") => {
                        let url = n["url"].as_str()?;
                        super::importable(url).then(|| Item::tab(url, n["name"].as_str().unwrap_or("")))
                    }
                    Some("folder") => Some(Item::folder(
                        n["name"].as_str().unwrap_or("Folder"),
                        bookmark_items(&n["children"]),
                        false,
                    )),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

fn newest_session(profile: &Path) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = fs::read_dir(profile.join("Sessions"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("Session_")))
        .collect();
    candidates.push(profile.join("Current Session"));
    candidates
        .into_iter()
        .filter_map(|p| Some((fs::metadata(&p).ok()?.modified().ok()?, p)))
        .max_by_key(|(modified, _)| *modified)
        .map(|(_, p)| p)
}
