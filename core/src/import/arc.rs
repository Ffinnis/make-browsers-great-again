use super::{ImportedProfile, ImportedSpace, Item};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

pub const SIDEBAR_FILE: &str = "StorableSidebar.json";

pub fn load(arc_dir: &Path) -> Result<Vec<ImportedProfile>, String> {
    let bytes = fs::read(arc_dir.join(SIDEBAR_FILE)).map_err(|e| format!("Can't read Arc's sidebar: {e}"))?;
    let root: Value = serde_json::from_slice(&bytes).map_err(|_| "Arc's sidebar file is not valid JSON".to_string())?;
    let container = root["sidebar"]["containers"]
        .as_array()
        .and_then(|c| c.iter().find(|c| c.get("spaces").is_some() && c.get("items").is_some()))
        .ok_or("Arc's sidebar file has no spaces")?;

    let items: HashMap<&str, &Value> =
        objects(&container["items"]).filter_map(|item| Some((item["id"].as_str()?, item))).collect();
    let names = profile_names(&arc_dir.join("User Data"));
    let mut profiles: Vec<ImportedProfile> = Vec::new();
    let profile = |dir: String, profiles: &mut Vec<ImportedProfile>| -> usize {
        if let Some(i) = profiles.iter().position(|p| p.id == dir) {
            return i;
        }
        let name = names.get(&dir).cloned().unwrap_or_else(|| {
            if dir == "Default" {
                "Personal".to_string()
            } else {
                dir.clone()
            }
        });
        profiles.push(ImportedProfile { id: dir, name, spaces: Vec::new(), favorites: Vec::new() });
        profiles.len() - 1
    };

    for (position, space) in objects(&container["spaces"]).enumerate() {
        let ids = if space["newContainerIDs"].is_array() { &space["newContainerIDs"] } else { &space["containerIDs"] };
        let pinned_id = container_id(ids, "pinned");
        let today_id = container_id(ids, "unpinned");
        let imported = ImportedSpace {
            position,
            name: space["title"].as_str().filter(|t| !t.is_empty()).unwrap_or("Space").to_string(),
            icon: icon(&space["customInfo"]),
            color: color(&space["customInfo"]["windowTheme"]),
            pinned: pinned_id.map(|id| children(&items, id)).unwrap_or_default(),
            today: today_id.map(|id| children(&items, id)).unwrap_or_default(),
        };
        let i = profile(profile_dir(&space["profile"]), &mut profiles);
        profiles[i].spaces.push(imported);
    }

    if let Some(list) = container["topAppsContainerIDs"].as_array() {
        for pair in list.windows(2) {
            if let (Some(key), Some(id)) = (pair[0].as_object(), pair[1].as_str()) {
                let i = profile(profile_dir(&Value::Object(key.clone())), &mut profiles);
                let favorites = children(&items, id);
                profiles[i].favorites.extend(flatten_tabs(favorites));
            }
        }
    }
    profiles.retain(|p| !p.spaces.is_empty() || !p.favorites.is_empty());
    Ok(profiles)
}

fn objects(list: &Value) -> impl Iterator<Item = &Value> {
    list.as_array().into_iter().flatten().filter(|v| v.is_object())
}

fn container_id<'a>(ids: &'a Value, kind: &str) -> Option<&'a str> {
    let list = ids.as_array()?;
    list.windows(2).find(|pair| pair[0].get(kind).is_some()).and_then(|pair| pair[1].as_str())
}

fn profile_dir(profile: &Value) -> String {
    profile["custom"]["_0"]["directoryBasename"].as_str().unwrap_or("Default").to_string()
}

fn profile_names(user_data: &Path) -> HashMap<String, String> {
    fs::read(user_data.join("Local State"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v["profile"]["info_cache"].as_object().cloned())
        .map(|cache| {
            cache.into_iter().filter_map(|(dir, info)| Some((dir, info["name"].as_str()?.to_string()))).collect()
        })
        .unwrap_or_default()
}

fn children(items: &HashMap<&str, &Value>, parent: &str) -> Vec<Item> {
    let Some(ids) = items.get(parent).and_then(|p| p["childrenIds"].as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for id in ids.iter().filter_map(Value::as_str) {
        let Some(item) = items.get(id) else { continue };
        let title = item["title"].as_str().unwrap_or("");
        if let Some(tab) = item["data"].get("tab") {
            let Some(url) = tab["savedURL"].as_str() else { continue };
            if super::importable(url) {
                let title = if title.is_empty() { tab["savedTitle"].as_str().unwrap_or("") } else { title };
                out.push(Item::tab(url, title));
            }
        } else if item["data"].get("splitView").is_some() {
            out.extend(children(items, id));
        } else {
            let nested = children(items, id);
            if !nested.is_empty() {
                out.push(Item::folder(if title.is_empty() { "Folder" } else { title }, nested, true));
            }
        }
    }
    out
}

fn flatten_tabs(items: Vec<Item>) -> Vec<Item> {
    items
        .into_iter()
        .flat_map(|item| match item {
            Item::Folder { children, .. } => flatten_tabs(children),
            tab @ Item::Tab { .. } => vec![tab],
        })
        .collect()
}

fn icon(info: &Value) -> Option<String> {
    let icon = &info["iconType"];
    icon["emoji_v2"]
        .as_str()
        .map(str::to_string)
        .or_else(|| {
            icon["emoji"].as_u64().and_then(|c| u32::try_from(c).ok()).and_then(char::from_u32).map(String::from)
        })
        .filter(|s| !s.is_empty())
}

fn color(theme: &Value) -> Option<u32> {
    match theme {
        Value::Object(map) => {
            if let (Some(r), Some(g), Some(b)) = (
                map.get("red").and_then(Value::as_f64),
                map.get("green").and_then(Value::as_f64),
                map.get("blue").and_then(Value::as_f64),
            ) {
                #[expect(clippy::cast_possible_truncation, clippy::cast_sign_loss, reason = "clamped to 0...255")]
                let c = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u32;
                return Some(c(r) << 16 | c(g) << 8 | c(b));
            }
            map.values().find_map(color)
        }
        Value::Array(list) => list.iter().find_map(color),
        _ => None,
    }
}
