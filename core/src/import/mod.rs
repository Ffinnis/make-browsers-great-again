mod arc;
mod chromium;
pub mod cookies;
mod firefox;
pub mod passwords;
mod safari;
pub mod snss;

use crate::model::{Id, Node, State, Tab, SPACE_COLORS};
use rusqlite::{Connection, OpenFlags};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    Tab { url: String, title: String },
    Folder { name: String, children: Vec<Item>, expanded: bool },
}

impl Item {
    fn tab(url: &str, title: &str) -> Item {
        Item::Tab { url: url.to_string(), title: title.to_string() }
    }

    fn folder(name: &str, children: Vec<Item>, expanded: bool) -> Item {
        Item::Folder { name: name.to_string(), children, expanded }
    }
}

#[derive(Debug, Clone)]
pub struct ImportedSpace {
    pub position: usize,
    pub name: String,
    pub icon: Option<String>,
    pub color: Option<u32>,
    pub pinned: Vec<Item>,
    pub today: Vec<Item>,
}

#[derive(Debug, Clone)]
pub struct ImportedProfile {
    pub id: String,
    pub name: String,
    pub spaces: Vec<ImportedSpace>,
    pub favorites: Vec<Item>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Arc,
    Chromium,
    Firefox,
    Safari,
}

#[derive(Debug, Clone)]
pub struct Source {
    pub id: String,
    pub name: String,
    pub kind: Kind,
    pub bundle_id: Option<String>,
    pub icon: &'static str,
    pub profiles: Vec<ImportedProfile>,
    pub error: Option<String>,
}

fn importable(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://") || url.starts_with("file://")
}

const CHROMIUM_BROWSERS: &[(&str, &str, &str, &str)] = &[
    ("Google/Chrome", "Chrome", "com.google.Chrome", "🌐"),
    ("Google/Chrome Beta", "Chrome Beta", "com.google.Chrome.beta", "🌐"),
    ("Google/Chrome Dev", "Chrome Dev", "com.google.Chrome.dev", "🌐"),
    ("Google/Chrome Canary", "Chrome Canary", "com.google.Chrome.canary", "🌐"),
    ("net.imput.helium", "Helium", "net.imput.helium", "🎈"),
    ("Chromium", "Chromium", "org.chromium.Chromium", "🔵"),
    ("BraveSoftware/Brave-Browser", "Brave", "com.brave.Browser", "🦁"),
    ("Microsoft Edge", "Edge", "com.microsoft.edgemac", "🌊"),
    ("Vivaldi", "Vivaldi", "com.vivaldi.Vivaldi", "🎻"),
    ("com.operasoftware.Opera", "Opera", "com.operasoftware.Opera", "⭕"),
    ("Dia/User Data", "Dia", "company.thebrowser.dia", "💬"),
    ("Comet", "Comet", "ai.perplexity.comet", "☄️"),
    ("Thorium", "Thorium", "org.chromium.Thorium", "⚛️"),
    ("Yandex/YandexBrowser", "Yandex Browser", "ru.yandex.desktop.yandex-browser", "🔴"),
];

const FIREFOX_BROWSERS: &[(&str, &str, &str, &str)] = &[
    ("Firefox", "Firefox", "org.mozilla.firefox", "🦊"),
    ("zen", "Zen", "app.zen-browser.zen", "🧘"),
    ("librewolf", "LibreWolf", "io.gitlab.librewolf-community", "🐺"),
    ("Waterfox", "Waterfox", "net.waterfox.waterfox", "💧"),
];

const ARC_DIR: &str = "Arc";

pub fn detect(home: &Path, exclude: &Path) -> Vec<Source> {
    let support = home.join("Library/Application Support");
    let mut sources = Vec::new();
    detect_arc(&support, &mut sources);
    detect_chromium(&support, exclude, &mut sources);
    detect_firefox(&support, &mut sources);
    detect_safari(home, &mut sources);

    sources.retain(|s| {
        s.error.is_some()
            || s.profiles.iter().any(|p| {
                count(p).total() > 0 || cookies::database(s, &p.id).is_some() || passwords::count(s, &p.id) > 0
            })
    });
    sources
}

fn detect_arc(support: &Path, sources: &mut Vec<Source>) {
    let arc = support.join(ARC_DIR);
    if arc.join(arc::SIDEBAR_FILE).exists() {
        let (profiles, error) = match arc::load(&arc) {
            Ok(p) => (p, None),
            Err(e) => (Vec::new(), Some(e)),
        };
        sources.push(Source {
            id: arc.to_string_lossy().into_owned(),
            name: "Arc".into(),
            kind: Kind::Arc,
            bundle_id: Some("company.thebrowser.Browser".into()),
            icon: "🌈",
            profiles,
            error,
        });
    }
}

fn detect_chromium(support: &Path, exclude: &Path, sources: &mut Vec<Source>) {
    let arc = support.join(ARC_DIR);
    let mut chromium_dirs: Vec<(PathBuf, String, Option<String>, &'static str)> = CHROMIUM_BROWSERS
        .iter()
        .map(|(dir, name, bundle, icon)| (support.join(dir), name.to_string(), Some(bundle.to_string()), *icon))
        .collect();
    for dir in subdirs(support).into_iter().flat_map(|d| {
        let nested = subdirs(&d);
        std::iter::once(d).chain(nested)
    }) {
        let known = chromium_dirs.iter().any(|(d, ..)| *d == dir)
            || dir == arc.join("User Data")
            || dir.starts_with(exclude)
            || exclude.starts_with(&dir);
        if !known && dir.join("Local State").exists() {
            chromium_dirs.push((dir.clone(), display_name(support, &dir), None, "🌐"));
        }
    }
    for (dir, name, bundle_id, icon) in chromium_dirs {
        let profiles = chromium::profiles(&dir);
        if profiles.is_empty() {
            continue;
        }
        let single = profiles.len() == 1;
        let profiles = profiles
            .iter()
            .map(|(id, profile)| {
                let label = if single { name.clone() } else { format!("{name} · {profile}") };
                chromium::load(&dir, id, &label, &label)
            })
            .collect();
        sources.push(Source {
            id: dir.to_string_lossy().into_owned(),
            name,
            kind: Kind::Chromium,
            bundle_id,
            icon,
            profiles,
            error: None,
        });
    }
}

fn detect_firefox(support: &Path, sources: &mut Vec<Source>) {
    let mut firefox_dirs: Vec<(PathBuf, String, Option<String>, &'static str)> = FIREFOX_BROWSERS
        .iter()
        .map(|(dir, name, bundle, icon)| (support.join(dir), name.to_string(), Some(bundle.to_string()), *icon))
        .collect();
    for dir in subdirs(support) {
        if !firefox_dirs.iter().any(|(d, ..)| *d == dir) && dir.join("profiles.ini").exists() {
            firefox_dirs.push((dir.clone(), display_name(support, &dir), None, "🦊"));
        }
    }
    for (dir, name, bundle_id, icon) in firefox_dirs {
        let profiles = firefox::profiles(&dir);
        if profiles.is_empty() {
            continue;
        }
        let single = profiles.len() == 1;
        let mut loaded = Vec::new();
        let mut error = None;
        for (path, profile) in &profiles {
            let label = if single { name.clone() } else { format!("{name} · {profile}") };
            match firefox::load(&dir, path, &label, &label) {
                Ok(p) => loaded.push(p),
                Err(e) => error = Some(e),
            }
        }
        sources.push(Source {
            id: dir.to_string_lossy().into_owned(),
            name,
            kind: Kind::Firefox,
            bundle_id,
            icon,
            error: if loaded.is_empty() { error } else { None },
            profiles: loaded,
        });
    }
}

fn detect_safari(home: &Path, sources: &mut Vec<Source>) {
    let safari = home.join("Library/Safari/Bookmarks.plist");
    if Path::new("/Applications/Safari.app").exists() || safari.exists() {
        let (profiles, error) = match safari::load(&safari) {
            Ok(p) => (vec![p], None),
            Err(e) => (Vec::new(), Some(e)),
        };
        if !profiles.is_empty() || error.as_deref() == Some(safari::NEEDS_ACCESS) {
            sources.push(Source {
                id: safari.to_string_lossy().into_owned(),
                name: "Safari".into(),
                kind: Kind::Safari,
                bundle_id: Some("com.apple.Safari".into()),
                icon: "🧭",
                profiles,
                error,
            });
        }
    }
}

fn read_copy<T>(path: &Path, read: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, String> {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let tmp = std::env::temp_dir().join(format!(
        "mbga-import-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let copy = tmp.join("db.sqlite");
    let result = (|| {
        fs::copy(path, &copy).map_err(|e| e.to_string())?;
        let mut wal = path.as_os_str().to_owned();
        wal.push("-wal");
        let _ = fs::copy(wal, tmp.join("db.sqlite-wal"));
        let db = Connection::open_with_flags(&copy, OpenFlags::SQLITE_OPEN_READ_WRITE).map_err(|e| e.to_string())?;
        read(&db).map_err(|e| e.to_string())
    })();
    let _ = fs::remove_dir_all(&tmp);
    result
}

fn subdirs(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .collect();
    out.sort();
    out
}

fn display_name(support: &Path, dir: &Path) -> String {
    let rel = dir.strip_prefix(support).unwrap_or(dir);
    let last = rel.iter().rfind(|c| *c != "User Data").map(|c| c.to_string_lossy().into_owned());
    let last = last.unwrap_or_else(|| "Browser".into());
    let base = if last.matches('.').count() >= 2 { last.rsplit('.').next().unwrap_or(&last).to_string() } else { last };
    let mut chars = base.chars();
    chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or(base)
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Counts {
    pub spaces: u32,
    pub pinned: u32,
    pub favorites: u32,
    pub today: u32,
}

impl Counts {
    pub fn total(&self) -> u32 {
        self.pinned + self.favorites + self.today
    }
}

fn tabs_in(items: &[Item]) -> u32 {
    items
        .iter()
        .map(|i| match i {
            Item::Tab { .. } => 1,
            Item::Folder { children, .. } => tabs_in(children),
        })
        .sum()
}

pub fn count(p: &ImportedProfile) -> Counts {
    Counts {
        spaces: crate::to_u32(p.spaces.len()),
        pinned: p.spaces.iter().map(|s| tabs_in(&s.pinned)).sum(),
        favorites: tabs_in(&p.favorites),
        today: p.spaces.iter().map(|s| tabs_in(&s.today)).sum(),
    }
}

pub fn apply(state: &mut State, sources: &[(&Source, &ImportedProfile)], now: u64) -> (Counts, Vec<Id>) {
    let pristine = state.profiles.len() == 1 && state.spaces.len() == 1 && state.tabs.is_empty();
    let old_space = state.spaces[0].id;
    let old_profile = state.profiles[0].id;
    let mut counts = Counts::default();
    let mut first_space = None;
    let mut made = Vec::new();

    let mut spaces: Vec<(usize, usize, Id, &Source, &ImportedSpace)> = Vec::new();
    for (source, profile) in sources {
        let taken = |state: &State, name: &str| {
            state.profiles.iter().any(|p| p.name == name && !(pristine && p.id == old_profile))
        };
        let mut name = profile.name.clone();
        if taken(state, &name) {
            name = format!("{name} ({})", source.name);
        }
        let profile_id = state.create_profile(&name);
        made.push(profile_id);
        for fav in flatten(&profile.favorites) {
            let id = new_tab(state, fav, true, now);
            state.favorites.entry(profile_id).or_default().push(id);
            counts.favorites += 1;
        }
        let rank = sources.iter().position(|(s, _)| s.id == source.id).unwrap_or(0);
        for space in &profile.spaces {
            spaces.push((rank, space.position, profile_id, source, space));
        }
    }
    spaces.sort_by_key(|&(rank, position, ..)| (rank, position));
    for (_, _, profile_id, source, space) in spaces {
        let color = space.color.unwrap_or(SPACE_COLORS[state.spaces.len() % SPACE_COLORS.len()]);
        let icon = space.icon.clone().unwrap_or_else(|| source.icon.to_string());
        let space_id = state.create_space(&space.name, &icon, color, profile_id);
        first_space.get_or_insert(space_id);
        let pinned = nodes(state, &space.pinned, now);
        counts.pinned += tabs_in(&space.pinned);
        let today: Vec<Id> = flatten(&space.today).into_iter().map(|t| new_tab(state, t, false, now)).collect();
        counts.today += crate::to_u32(today.len());
        let s = state.spaces.iter_mut().find(|s| s.id == space_id).expect("space just created");
        s.pinned = pinned;
        s.today = today;
        counts.spaces += 1;
    }

    if let Some(first) = first_space {
        if pristine {
            state.delete_space(old_space);
            state.delete_profile(old_profile);
        }
        state.set_active_space(first, now);
    }
    (counts, made)
}

fn flatten(items: &[Item]) -> Vec<&Item> {
    items
        .iter()
        .flat_map(|i| match i {
            Item::Folder { children, .. } => flatten(children),
            tab @ Item::Tab { .. } => vec![tab],
        })
        .collect()
}

fn new_tab(state: &mut State, item: &Item, pinned: bool, now: u64) -> Id {
    let Item::Tab { url, title } = item else { unreachable!("only tabs are flattened") };
    let id = state.alloc();
    state.tabs.insert(
        id,
        Tab {
            id,
            url: url.clone(),
            title: title.clone(),
            favicon: None,
            pinned_url: pinned.then(|| url.clone()),
            last_active_ms: now,
            always_awake: false,
            live: false,
            audible: false,
            frozen: false,
            woke_ms: 0,
        },
    );
    id
}

fn nodes(state: &mut State, items: &[Item], now: u64) -> Vec<Node> {
    items
        .iter()
        .map(|item| match item {
            Item::Tab { .. } => Node::Tab { id: new_tab(state, item, true, now) },
            Item::Folder { name, children, expanded } => {
                let id = state.alloc();
                Node::Folder { id, name: name.clone(), expanded: *expanded, children: nodes(state, children, now) }
            }
        })
        .collect()
}

#[cfg(test)]
mod tests;
