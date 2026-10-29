uniffi::setup_scaffolding!();

pub mod blocker;
pub mod crypto;
pub mod downloads;
pub mod ephemeral;
pub mod history;
pub mod import;
pub mod model;
pub mod page;
pub mod passwords;

use model::{Container, Id, Node, Pressure, State, Tab};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TabInfo {
    pub id: u64,
    pub url: String,
    pub title: String,
    pub favicon_path: Option<String>,
    pub pinned_url: Option<String>,
    pub live: bool,
    pub audible: bool,
    pub muted: bool,
    pub frozen: bool,
    pub keep_awake: bool,
    pub always_awake: bool,
    pub ads_allowed: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PinnedRow {
    pub id: u64,
    pub depth: u32,
    pub parent_id: Option<u64>,
    pub index: u32,
    pub tab: Option<TabInfo>,
    pub folder_name: Option<String>,
    pub expanded: bool,
    pub child_count: u32,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SpaceInfo {
    pub id: u64,
    pub name: String,
    pub icon: String,
    pub color: u32,
    pub profile_id: u64,
    pub favorites: Vec<TabInfo>,
    pub pinned: Vec<PinnedRow>,
    pub today: Vec<TabInfo>,
    pub active_tab: Option<u64>,
    pub ephemeral: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ProfileInfo {
    pub id: u64,
    pub name: String,
    pub space_count: u32,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub revision: u64,
    pub active_space: u64,
    pub spaces: Vec<SpaceInfo>,
    pub profiles: Vec<ProfileInfo>,
    pub sleep_after_secs: u64,
    pub max_live_tabs: u32,
    pub strict_site_isolation: bool,
    pub can_reopen: bool,
    pub block_ads: bool,
    pub convert_video: bool,
    pub archive_after_hours: u32,
    pub cleanup_answered: bool,
    pub keep_awake_sites: Vec<String>,
    pub memory_limit_mb: u32,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HistoryItem {
    pub url: String,
    pub title: String,
    pub site_prefix: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RestoredNav {
    pub back: bool,
    pub forward: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ReopenOutcome {
    pub space_id: u64,
    pub tabs: Vec<u64>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct FilterList {
    pub file_name: String,
    pub url: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct CloseOutcome {
    pub removed: bool,
    pub next_tab: Option<u64>,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemoryPressure {
    Normal,
    Warning,
    Critical,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum DropTarget {
    Favorites { profile_id: u64 },
    Pinned { space_id: u64, folder_id: Option<u64> },
    Today { space_id: u64 },
}

impl From<DropTarget> for Container {
    fn from(t: DropTarget) -> Container {
        match t {
            DropTarget::Favorites { profile_id } => Container::Favorites { profile_id },
            DropTarget::Pinned { space_id, folder_id } => Container::Pinned { space_id, folder_id },
            DropTarget::Today { space_id } => Container::Today { space_id },
        }
    }
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum BrowserKind {
    Arc,
    Chromium,
    Firefox,
    Safari,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportProfileInfo {
    pub id: String,
    pub name: String,
    pub spaces: u32,
    pub pinned: u32,
    pub favorites: u32,
    pub today: u32,
    pub passwords: u32,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportSourceInfo {
    pub id: String,
    pub name: String,
    pub kind: BrowserKind,
    pub bundle_id: Option<String>,
    pub profiles: Vec<ImportProfileInfo>,
    pub error: Option<String>,
    pub keychain_service: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportChoice {
    pub source_id: String,
    pub profile_ids: Vec<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportSummary {
    pub spaces: u32,
    pub pinned: u32,
    pub favorites: u32,
    pub today: u32,
    pub profiles: Vec<ImportedProfileLink>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportedProfileLink {
    pub source_id: String,
    pub profile_id: String,
    pub into: u64,
}

fn import_counts(c: import::Counts, profiles: Vec<ImportedProfileLink>) -> ImportSummary {
    ImportSummary { spaces: c.spaces, pinned: c.pinned, favorites: c.favorites, today: c.today, profiles }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportedCookie {
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

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct CookieRead {
    pub cookies: Vec<ImportedCookie>,
    pub error: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SavedLogin {
    pub id: u64,
    pub profile_id: u64,
    pub origin: String,
    pub site: String,
    pub username: String,
    pub created_ms: u64,
    pub used_ms: u64,
    pub changed_ms: u64,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PasswordOffer {
    Nothing,
    Save,
    Update { login_id: u64 },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PasswordImportOutcome {
    pub added: u32,
    pub updated: u32,
    pub kept: u32,
    pub unreadable: u32,
    pub error: Option<String>,
}

impl PasswordImportOutcome {
    fn failed(error: impl Into<String>) -> PasswordImportOutcome {
        PasswordImportOutcome { added: 0, updated: 0, kept: 0, unreadable: 0, error: Some(error.into()) }
    }
}

fn saved_login(l: &passwords::Login) -> SavedLogin {
    SavedLogin {
        id: l.id,
        profile_id: l.profile,
        origin: l.origin.clone(),
        site: model::site_of(&l.origin),
        username: l.username.clone(),
        created_ms: l.created_ms,
        used_ms: l.used_ms,
        changed_ms: l.changed_ms,
    }
}

struct Inner {
    state: State,
    dirty: bool,
    history: history::History,
    history_dirty: bool,
    downloads: downloads::Downloads,
    downloads_dirty: bool,
    revision: u64,
    data_dir: PathBuf,
    detected: Vec<import::Source>,
    passwords: passwords::Store,
    passwords_dirty: bool,
    password_key: Option<passwords::Key>,
}

#[derive(uniffi::Object)]
pub struct BrowserCore {
    inner: Mutex<Inner>,
    blocker: RwLock<blocker::Blocker>,
}

pub(crate) fn to_u32(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).ok().and_then(|d| u64::try_from(d.as_millis()).ok()).unwrap_or(0)
}

const STATE_FILE: &str = "state.json";
const HISTORY_FILE: &str = "history.json";
const DOWNLOADS_FILE: &str = "downloads.json";
const PASSWORDS_FILE: &str = "passwords.json";

fn load_history(dir: &Path) -> history::History {
    fs::read(dir.join(HISTORY_FILE)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn load_downloads(dir: &Path) -> downloads::Downloads {
    fs::read(dir.join(DOWNLOADS_FILE)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn load_passwords(dir: &Path) -> passwords::Store {
    fs::read(dir.join(PASSWORDS_FILE)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn write_atomic(dir: &Path, name: &str, value: &impl serde::Serialize) -> bool {
    let Ok(json) = serde_json::to_vec(value) else {
        return false;
    };
    let tmp = dir.join(format!("{name}.tmp"));
    fs::write(&tmp, json).is_ok() && private(&tmp, name) && fs::rename(&tmp, dir.join(name)).is_ok()
}

fn private(path: &Path, name: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    name != PASSWORDS_FILE || fs::set_permissions(path, fs::Permissions::from_mode(0o600)).is_ok()
}

fn load_state(dir: &Path) -> State {
    let path = dir.join(STATE_FILE);
    let Ok(bytes) = fs::read(&path) else {
        return State::new_default();
    };
    match serde_json::from_slice::<State>(&bytes) {
        Ok(mut s) if !s.spaces.is_empty() && !s.profiles.is_empty() => {
            s.policy.upgrade_first_defaults();
            s
        }
        _ => {
            let backup = dir.join(format!("{STATE_FILE}.corrupt-{}", now_ms()));
            let _ = fs::rename(&path, backup);
            State::new_default()
        }
    }
}

fn profile_dir_in(data_dir: &Path, profile_id: Id) -> PathBuf {
    data_dir.join("engine").join(format!("Profile {profile_id}"))
}

fn tab_info(s: &State, t: &Tab) -> TabInfo {
    TabInfo {
        id: t.id,
        url: t.url.clone(),
        title: t.title.clone(),
        favicon_path: t.favicon.clone(),
        pinned_url: t.pinned_url.clone(),
        live: t.live,
        audible: t.audible,
        muted: t.muted,
        frozen: t.frozen,
        keep_awake: s.keeps_awake(&t.url),
        always_awake: t.always_awake,
        ads_allowed: s.allows_ads(&t.url),
    }
}

fn flatten(state: &State, nodes: &[Node], depth: u32, parent: Option<Id>, out: &mut Vec<PinnedRow>) {
    for (index, node) in nodes.iter().enumerate() {
        match node {
            Node::Tab { id } => {
                if let Some(t) = state.tabs.get(id) {
                    out.push(PinnedRow {
                        id: *id,
                        depth,
                        parent_id: parent,
                        index: to_u32(index),
                        tab: Some(tab_info(state, t)),
                        folder_name: None,
                        expanded: false,
                        child_count: 0,
                    });
                }
            }
            Node::Folder { id, name, expanded, children } => {
                out.push(PinnedRow {
                    id: *id,
                    depth,
                    parent_id: parent,
                    index: to_u32(index),
                    tab: None,
                    folder_name: Some(name.clone()),
                    expanded: *expanded,
                    child_count: to_u32(children.len()),
                });
                if *expanded {
                    flatten(state, children, depth + 1, Some(*id), out);
                }
            }
        }
    }
}

fn fnv1a(s: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

fn host_of(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    rest.split(['/', '?', '#']).next().unwrap_or(rest)
}

impl BrowserCore {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn mutate<R>(&self, f: impl FnOnce(&mut State, u64) -> R) -> R {
        let mut inner = self.lock();
        let r = f(&mut inner.state, now_ms());
        inner.dirty = true;
        inner.revision += 1;
        r
    }

    fn page_of<R>(&self, id: u64, f: impl FnOnce(&mut page::PageState) -> R) -> Option<R> {
        self.mutate(|s, _| s.tabs.get_mut(&id).map(|t| f(&mut t.page)))
    }
}

#[uniffi::export]
impl BrowserCore {
    #[uniffi::constructor]
    pub fn new(data_dir: String) -> Arc<Self> {
        let data_dir = PathBuf::from(data_dir);
        let _ = fs::create_dir_all(&data_dir);
        let data_dir = fs::canonicalize(&data_dir).unwrap_or(data_dir);
        let mut state = load_state(&data_dir);
        let history = load_history(&data_dir);
        let mut downloads = load_downloads(&data_dir);
        let downloads_dirty = downloads.interrupt();
        let mut passwords = load_passwords(&data_dir);
        passwords.keep_profiles(&state.profiles.iter().map(|p| p.id).collect::<Vec<_>>());
        let blocker = blocker::Blocker::new(state.block_ads, state.ads_allowed.iter().cloned());
        for id in std::mem::take(&mut state.doomed_profiles) {
            let _ = fs::remove_dir_all(profile_dir_in(&data_dir, id));
        }
        let _ = fs::remove_dir_all(ephemeral::favicon_dir(&data_dir));
        Arc::new(BrowserCore {
            inner: Mutex::new(Inner {
                state,
                dirty: true,
                history,
                history_dirty: false,
                downloads,
                downloads_dirty,
                revision: 1,
                data_dir,
                detected: Vec::new(),
                passwords,
                passwords_dirty: false,
                password_key: None,
            }),
            blocker: RwLock::new(blocker),
        })
    }

    pub fn revision(&self) -> u64 {
        self.lock().revision
    }

    pub fn snapshot(&self) -> Snapshot {
        let inner = self.lock();
        let s = &inner.state;
        let spaces = s
            .spaces
            .iter()
            .map(|space| {
                let mut pinned = Vec::new();
                flatten(s, &space.pinned, 0, None, &mut pinned);
                SpaceInfo {
                    id: space.id,
                    name: space.name.clone(),
                    icon: space.icon.clone(),
                    color: space.color,
                    profile_id: space.profile_id,
                    favorites: s
                        .favorites
                        .get(&space.profile_id)
                        .into_iter()
                        .flatten()
                        .filter_map(|id| s.tabs.get(id).map(|t| tab_info(s, t)))
                        .collect(),
                    pinned,
                    today: space.today.iter().filter_map(|id| s.tabs.get(id).map(|t| tab_info(s, t))).collect(),
                    active_tab: space.active_tab,
                    ephemeral: space.ephemeral,
                }
            })
            .collect();
        let profiles = s
            .profiles
            .iter()
            .filter(|p| !p.ephemeral)
            .map(|p| ProfileInfo {
                id: p.id,
                name: p.name.clone(),
                space_count: to_u32(s.spaces.iter().filter(|sp| sp.profile_id == p.id).count()),
            })
            .collect();
        Snapshot {
            revision: inner.revision,
            active_space: s.active_space,
            spaces,
            profiles,
            sleep_after_secs: s.policy.sleep_after_secs,
            max_live_tabs: s.policy.max_live_tabs,
            strict_site_isolation: s.policy.strict_site_isolation,
            can_reopen: !s.closed.is_empty(),
            block_ads: s.block_ads,
            convert_video: s.convert_video,
            archive_after_hours: s.policy.archive_after_hours,
            cleanup_answered: s.cleanup_answered,
            keep_awake_sites: s.keep_awake.clone(),
            memory_limit_mb: s.policy.memory_limit_mb,
        }
    }

    pub fn tab(&self, id: u64) -> Option<TabInfo> {
        let inner = self.lock();
        inner.state.tabs.get(&id).map(|t| tab_info(&inner.state, t))
    }

    pub fn visible_tab(&self) -> Option<u64> {
        self.lock().state.visible_tab()
    }

    pub fn engine_root_dir(&self) -> String {
        self.lock().data_dir.join("engine").to_string_lossy().into_owned()
    }

    pub fn profile_dir(&self, profile_id: u64) -> String {
        let inner = self.lock();
        if inner.state.is_ephemeral_profile(profile_id) {
            return format!("private-{profile_id}");
        }
        profile_dir_in(&inner.data_dir, profile_id).to_string_lossy().into_owned()
    }

    pub fn profile_of_tab(&self, tab_id: u64) -> Option<u64> {
        self.lock().state.profile_of_tab(tab_id)
    }

    pub fn create_profile(&self, name: String) -> u64 {
        self.mutate(|s, _| s.create_profile(&name))
    }

    pub fn rename_profile(&self, id: u64, name: String) {
        self.mutate(|s, _| s.rename_profile(id, &name));
    }

    pub fn delete_profile(&self, id: u64) -> Option<Vec<u64>> {
        let closed = self.mutate(|s, _| s.delete_profile(id))?;
        let mut inner = self.lock();
        let profiles: Vec<Id> = inner.state.profiles.iter().map(|p| p.id).collect();
        inner.passwords.keep_profiles(&profiles);
        inner.passwords_dirty = true;
        Some(closed)
    }

    pub fn create_space(&self, name: String, icon: String, color: u32, profile_id: u64) -> u64 {
        self.mutate(|s, _| s.create_space(&name, &icon, color, profile_id))
    }

    pub fn update_space(&self, id: u64, name: String, icon: String, color: u32) {
        self.mutate(|s, _| s.update_space(id, &name, &icon, color));
    }

    pub fn set_space_profile(&self, id: u64, profile_id: u64) -> Vec<u64> {
        self.mutate(|s, _| s.set_space_profile(id, profile_id))
    }

    pub fn delete_space(&self, id: u64) -> Option<Vec<u64>> {
        self.mutate(|s, _| s.delete_space(id))
    }

    pub fn move_space(&self, id: u64, index: u32) {
        self.mutate(|s, _| s.move_space(id, index as usize));
    }

    pub fn set_active_space(&self, id: u64) {
        self.mutate(|s, now| s.set_active_space(id, now));
    }

    pub fn open_tab(&self, space_id: u64, url: String, activate: bool) -> Option<u64> {
        let id = self.mutate(|s, now| s.open_tab(space_id, &url, activate, now))?;
        let mut inner = self.lock();
        if !inner.state.is_ephemeral_tab(id) {
            inner.history.record(&url, now_ms());
            inner.history_dirty = true;
        }
        Some(id)
    }

    pub fn activate_tab(&self, space_id: u64, tab_id: u64) {
        self.mutate(|s, now| s.activate_tab(space_id, tab_id, now));
    }

    pub fn update_tab(&self, id: u64, url: Option<String>, title: Option<String>) {
        let mut inner = self.lock();
        let Some(t) = inner.state.tabs.get(&id) else {
            return;
        };
        let changed = url.as_ref().is_some_and(|u| *u != t.url) || title.as_ref().is_some_and(|x| *x != t.title);
        if changed {
            let url_changed = url.as_ref().is_some_and(|u| *u != t.url);
            inner.state.update_tab(id, url.as_deref(), title.as_deref());
            inner.dirty = true;
            inner.revision += 1;
            if inner.state.is_ephemeral_tab(id) {
                return;
            }
            let page = inner.state.tabs[&id].url.clone();
            if url_changed {
                inner.history.record(&page, now_ms());
            }
            if let Some(title) = title.filter(|t| !t.is_empty()) {
                inner.history.set_title(&page, &title);
            }
            inner.history_dirty = true;
        }
    }

    pub fn suggest_history(&self, query: String, limit: u32) -> Vec<HistoryItem> {
        self.lock()
            .history
            .suggest(&query, limit as usize, now_ms())
            .into_iter()
            .map(|m| HistoryItem { url: m.url, title: m.title, site_prefix: m.site_prefix })
            .collect()
    }

    pub fn recent_history(&self, limit: u32) -> Vec<HistoryItem> {
        self.lock()
            .history
            .recent(limit as usize)
            .into_iter()
            .map(|m| HistoryItem { url: m.url, title: m.title, site_prefix: m.site_prefix })
            .collect()
    }

    pub fn clear_history(&self) {
        let mut inner = self.lock();
        inner.history.clear();
        inner.history_dirty = true;
    }

    pub fn downloads(&self) -> Vec<downloads::Download> {
        self.lock().downloads.items().to_vec()
    }

    pub fn start_download(&self, url: String, path: String, ephemeral: bool) -> u64 {
        let mut inner = self.lock();
        inner.downloads_dirty = true;
        inner.downloads.start(&url, &path, ephemeral, now_ms())
    }

    pub fn update_download(&self, id: u64, path: String, received: u64, total: u64, state: downloads::DownloadState) {
        let mut inner = self.lock();
        if inner.downloads.update(id, &path, received, total, state) {
            inner.downloads_dirty = true;
        }
    }

    pub fn remove_download(&self, id: u64) {
        let mut inner = self.lock();
        if inner.downloads.remove(id) {
            inner.downloads_dirty = true;
        }
    }

    pub fn clear_downloads(&self) {
        let mut inner = self.lock();
        if inner.downloads.clear() {
            inner.downloads_dirty = true;
        }
    }

    pub fn close_tab(&self, id: u64) -> CloseOutcome {
        let (removed, next_tab) = self.mutate(|s, now| s.close_tab(id, now));
        CloseOutcome { removed, next_tab }
    }

    pub fn clear_today(&self, space_id: u64) -> Vec<u64> {
        self.mutate(|s, _| s.clear_today(space_id))
    }

    pub fn undo_close(&self, private_space: Option<u64>) -> Option<ReopenOutcome> {
        self.mutate(|s, _| s.reopen_last(private_space)).map(|(space_id, tabs)| ReopenOutcome { space_id, tabs })
    }

    pub fn reopen_tab(&self, id: u64) -> Option<u64> {
        self.mutate(|s, _| s.reopen_tab(id))
    }

    pub fn set_shown_elsewhere(&self, id: u64, shown: bool) {
        self.mutate(|s, _| {
            s.shown_elsewhere.retain(|t| *t != id);
            if shown {
                s.shown_elsewhere.push(id);
            }
        });
    }

    pub fn select_default_tab(&self, space_id: u64) -> Option<u64> {
        let mut inner = self.lock();
        let chosen = inner.state.select_default_tab(space_id, now_ms());
        if chosen.is_some() {
            inner.dirty = true;
            inner.revision += 1;
        }
        chosen
    }

    pub fn step_away(&self, id: u64) -> Option<u64> {
        self.mutate(|s, now| s.step_away(id, now))
    }

    pub fn closed_tabs(&self, limit: u32, private_space: Option<u64>) -> Vec<TabInfo> {
        let inner = self.lock();
        let s = &inner.state;
        s.closed_tabs(private_space).take(limit as usize).map(|t| tab_info(s, t)).collect()
    }

    pub fn idle_today_count(&self, space_id: u64, hours: u32) -> u32 {
        to_u32(self.lock().state.idle_today(space_id, hours, now_ms()).len())
    }

    pub fn archive_idle(&self, space_id: u64, hours: u32) -> Vec<u64> {
        self.mutate(|s, now| s.archive_idle(space_id, hours, now))
    }

    pub fn archive_by_policy(&self) -> Vec<u64> {
        let mut inner = self.lock();
        let archived = inner.state.archive_by_policy(now_ms());
        if !archived.is_empty() {
            inner.dirty = true;
            inner.revision += 1;
        }
        archived
    }

    pub fn set_archive_after_hours(&self, hours: u32) {
        self.mutate(|s, _| s.policy.archive_after_hours = hours);
    }

    pub fn answer_cleanup(&self) {
        self.mutate(|s, _| s.cleanup_answered = true);
    }

    pub fn set_favicon(&self, tab_id: u64, png: Vec<u8>) {
        let mut inner = self.lock();
        let Some(tab) = inner.state.tabs.get(&tab_id) else {
            return;
        };
        let dir = if inner.state.is_ephemeral_tab(tab_id) {
            ephemeral::favicon_dir(&inner.data_dir)
        } else {
            inner.data_dir.join("favicons")
        };
        let path = dir.join(format!("{:016x}.png", fnv1a(host_of(&tab.url))));
        let unchanged = fs::metadata(&path).is_ok_and(|m| m.len() == png.len() as u64);
        if !unchanged {
            let _ = fs::create_dir_all(&dir);
            if fs::write(&path, &png).is_err() {
                return;
            }
        }
        let path = path.to_string_lossy().into_owned();
        if tab.favicon.as_deref() != Some(path.as_str()) || !unchanged {
            inner.state.set_favicon_path(tab_id, &path);
            inner.dirty = true;
            inner.revision += 1;
        }
    }

    pub fn create_folder(&self, space_id: u64, name: String, parent: Option<u64>) -> Option<u64> {
        self.mutate(|s, _| s.create_folder(space_id, &name, parent))
    }

    pub fn rename_folder(&self, id: u64, name: String) {
        self.mutate(|s, _| s.rename_folder(id, &name));
    }

    pub fn set_folder_expanded(&self, id: u64, expanded: bool) {
        self.mutate(|s, _| s.set_folder_expanded(id, expanded));
    }

    pub fn delete_folder(&self, id: u64) -> Vec<u64> {
        self.mutate(|s, _| s.delete_folder(id))
    }

    pub fn move_item(&self, id: u64, target: DropTarget, index: u32) -> Option<Vec<u64>> {
        self.mutate(|s, _| s.move_item(id, target.into(), index as usize))
    }

    pub fn pin_tab(&self, id: u64) -> Option<Vec<u64>> {
        let space = self.space_of(id)?;
        self.move_item(id, DropTarget::Pinned { space_id: space, folder_id: None }, u32::MAX)
    }

    pub fn unpin_tab(&self, id: u64) -> Option<Vec<u64>> {
        let space = self.space_of(id)?;
        self.move_item(id, DropTarget::Today { space_id: space }, 0)
    }

    pub fn add_favorite(&self, id: u64) -> Option<Vec<u64>> {
        let profile_id = self.profile_of_tab(id)?;
        self.move_item(id, DropTarget::Favorites { profile_id }, u32::MAX)
    }

    pub fn set_live(&self, id: u64, live: bool) {
        self.mutate(|s, now| s.set_live(id, live, now));
    }

    pub fn view_created(&self, id: u64) {
        self.page_of(id, page::PageState::view_created);
    }

    pub fn record_navigation(&self, id: u64, url: String, back: Vec<String>, forward: Vec<String>) {
        self.page_of(id, |p| p.record(&url, back, forward));
    }

    pub fn restored_nav(&self, id: u64) -> RestoredNav {
        let inner = self.lock();
        inner.state.tabs.get(&id).map_or(RestoredNav { back: false, forward: false }, |t| RestoredNav {
            back: t.page.can_restore_back(),
            forward: t.page.can_restore_forward(),
        })
    }

    pub fn pop_restored_back(&self, id: u64, current: String) -> Option<String> {
        self.page_of(id, |p| p.pop_older(&current)).flatten()
    }

    pub fn pop_restored_forward(&self, id: u64) -> Option<String> {
        self.page_of(id, page::PageState::pop_newer).flatten()
    }

    pub fn set_page_report(&self, id: u64, scroll_y: f64, editing: bool) {
        self.page_of(id, |p| {
            p.scroll_y = scroll_y;
            p.editing = editing;
        });
    }

    pub fn take_restored_scroll(&self, id: u64) -> Option<f64> {
        self.page_of(id, page::PageState::take_scroll).flatten()
    }

    pub fn duplicate_tab(&self, id: u64, space_id: u64) -> Option<u64> {
        let tab = self.lock().state.tabs.get(&id).cloned()?;
        let copy = self.open_tab(space_id, tab.url, true)?;
        self.page_of(copy, |p| *p = tab.page.copied());
        Some(copy)
    }

    pub fn set_muted(&self, id: u64, muted: bool) {
        self.mutate(|s, _| s.set_muted(id, muted));
    }

    pub fn set_audible(&self, id: u64, audible: bool) {
        self.mutate(|s, _| s.set_audible(id, audible));
    }

    pub fn set_keep_awake(&self, url: String, keep: bool) {
        self.mutate(|s, _| s.set_keep_awake(&url, keep));
    }

    pub fn set_keep_awake_sites(&self, sites: Vec<String>) {
        self.mutate(|s, _| s.set_keep_awake_sites(&sites));
    }

    pub fn set_always_awake(&self, id: u64, awake: bool) {
        self.mutate(|s, _| s.set_always_awake(id, awake));
    }

    pub fn always_awake_tabs(&self) -> Vec<u64> {
        self.lock().state.always_awake_tabs()
    }

    pub fn filter_dir(&self) -> String {
        self.lock().data_dir.join("filters").to_string_lossy().into_owned()
    }

    pub fn filter_lists(&self) -> Vec<FilterList> {
        blocker::LISTS
            .iter()
            .chain([&blocker::SCRIPTLETS])
            .map(|(file_name, url)| FilterList { file_name: file_name.to_string(), url: url.to_string() })
            .collect()
    }

    pub fn user_filters_path(&self) -> String {
        let dir = PathBuf::from(self.filter_dir());
        let path = dir.join(blocker::USER_RULES);
        if !path.exists() {
            let _ = fs::create_dir_all(&dir);
            let _ = fs::write(
                &path,
                "! My filters, in Adblock Plus / uBlock Origin syntax. Examples:\n\
                 !   ||ads.example.com^           block a domain\n\
                 !   example.com##.promo          hide elements on a site\n\
                 !   @@||example.com^$document    turn blocking off for a site\n\
                 ! Choose Reload Filters in the command bar after editing.\n",
            );
        }
        path.to_string_lossy().into_owned()
    }

    pub fn load_filters(&self) -> bool {
        self.load_filters_from_disk(true)
    }

    pub fn load_cached_filters(&self) -> bool {
        self.load_filters_from_disk(false)
    }

    pub fn should_block(&self, url: String, page: String, kind: String) -> bool {
        self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).should_block(&url, &page, &kind)
    }

    pub fn needs_early_script(&self, page: String) -> bool {
        self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).needs_early_script(&page)
    }

    pub fn page_script(&self, page: String) -> String {
        self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).page_script(&page)
    }

    pub fn cosmetic_reply(&self, page: String, report: String) -> String {
        self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).cosmetic_reply(&page, &report)
    }

    pub fn set_block_ads(&self, enabled: bool) {
        self.mutate(|s, _| s.block_ads = enabled);
        let old = {
            let mut blocker = self.blocker.write().unwrap_or_else(std::sync::PoisonError::into_inner);
            blocker.enabled = enabled;
            if enabled {
                None
            } else {
                blocker.unload()
            }
        };
        drop(old);
    }

    pub fn set_ads_allowed(&self, url: String, allowed: bool) {
        let sites = self.mutate(|s, _| {
            s.set_ads_allowed(&url, allowed);
            s.ads_allowed.clone()
        });
        self.blocker.write().unwrap_or_else(std::sync::PoisonError::into_inner).allowed = sites.into_iter().collect();
    }

    pub fn set_policy(&self, sleep_after_secs: u64, max_live_tabs: u32) {
        self.mutate(|s, _| {
            s.policy.sleep_after_secs = if sleep_after_secs == 0 { 0 } else { sleep_after_secs.max(30) };
            s.policy.max_live_tabs = max_live_tabs;
        });
    }

    pub fn collect_sleepers(&self, pressure: MemoryPressure) -> Vec<u64> {
        let pressure = match pressure {
            MemoryPressure::Normal => Pressure::Normal,
            MemoryPressure::Warning => Pressure::Warning,
            MemoryPressure::Critical => Pressure::Critical,
        };
        let mut inner = self.lock();
        let sleepers = inner.state.collect_sleepers(now_ms(), pressure);
        if !sleepers.is_empty() {
            inner.revision += 1;
        }
        sleepers
    }

    pub fn set_memory_limit(&self, megabytes: u32) {
        self.mutate(|s, _| s.policy.memory_limit_mb = megabytes);
    }

    pub fn set_agent_space(&self, space_id: Option<u64>) {
        self.lock().state.agent_space = space_id;
    }

    pub fn note_agent_use(&self, id: u64) {
        let mut inner = self.lock();
        inner.state.note_use(id, now_ms());
    }

    pub fn set_notifies_or_calls(&self, id: u64, notifies_or_calls: bool) {
        self.lock().state.set_notifies_or_calls(id, notifies_or_calls);
    }

    pub fn collect_over_limit(&self, count: u32) -> Vec<u64> {
        let mut inner = self.lock();
        let sleepers = inner.state.collect_over_limit(count as usize);
        if !sleepers.is_empty() {
            inner.revision += 1;
        }
        sleepers
    }

    pub fn collect_freezers(&self) -> Vec<u64> {
        let mut inner = self.lock();
        let frozen = inner.state.collect_freezers(now_ms());
        if !frozen.is_empty() {
            inner.revision += 1;
        }
        frozen
    }

    pub fn thaw(&self, id: u64) -> bool {
        let mut inner = self.lock();
        let thawed = inner.state.thaw(id);
        if thawed {
            inner.revision += 1;
        }
        thawed
    }

    pub fn set_strict_site_isolation(&self, strict: bool) {
        self.mutate(|s, _| s.policy.strict_site_isolation = strict);
    }

    pub fn isolated_origins(&self) -> Vec<String> {
        model::ALWAYS_ISOLATED_ORIGINS.iter().map(ToString::to_string).collect()
    }

    pub fn set_convert_video(&self, enabled: bool) {
        self.mutate(|s, _| s.convert_video = enabled);
    }

    pub fn resolve_input(&self, text: String) -> String {
        let inner = self.lock();
        model::resolve_input(&text, &inner.state.search_template)
    }

    pub fn search_url(&self, text: String) -> String {
        let inner = self.lock();
        model::search_url(&text, &inner.state.search_template)
    }

    pub fn needs_onboarding(&self) -> bool {
        !self.lock().state.onboarded
    }

    pub fn finish_onboarding(&self) {
        self.mutate(|s, _| s.onboarded = true);
    }

    pub fn detect_browsers(&self, home: String) -> Vec<ImportSourceInfo> {
        let exclude = self.lock().data_dir.clone();
        let sources = import::detect(Path::new(&home), &exclude);
        let infos = sources
            .iter()
            .map(|s| ImportSourceInfo {
                id: s.id.clone(),
                name: s.name.clone(),
                kind: match s.kind {
                    import::Kind::Arc => BrowserKind::Arc,
                    import::Kind::Chromium => BrowserKind::Chromium,
                    import::Kind::Firefox => BrowserKind::Firefox,
                    import::Kind::Safari => BrowserKind::Safari,
                },
                bundle_id: s.bundle_id.clone(),
                profiles: s
                    .profiles
                    .iter()
                    .map(|p| {
                        let c = import::count(p);
                        ImportProfileInfo {
                            id: p.id.clone(),
                            name: p.name.clone(),
                            spaces: c.spaces,
                            pinned: c.pinned,
                            favorites: c.favorites,
                            today: c.today,
                            passwords: import::passwords::count(s, &p.id),
                        }
                    })
                    .collect(),
                error: s.error.clone(),
                keychain_service: import::cookies::keychain_service(s),
            })
            .collect();
        self.lock().detected = sources;
        infos
    }

    pub fn read_browser_cookies(&self, source_id: String, profile_id: String, password: Option<Vec<u8>>) -> CookieRead {
        let source = self.lock().detected.iter().find(|s| s.id == source_id).cloned();
        let Some(source) = source else {
            return CookieRead { cookies: Vec::new(), error: Some("That browser is no longer there.".into()) };
        };
        match import::cookies::read(&source, &profile_id, password.as_deref(), now_ms()) {
            Ok(cookies) => CookieRead {
                cookies: cookies
                    .into_iter()
                    .map(|c| ImportedCookie {
                        domain: c.domain,
                        name: c.name,
                        value: c.value,
                        path: c.path,
                        secure: c.secure,
                        http_only: c.http_only,
                        expires: c.expires,
                        created: c.created,
                        last_used: c.last_used,
                        same_site: c.same_site,
                        priority: c.priority,
                    })
                    .collect(),
                error: None,
            },
            Err(error) => CookieRead { cookies: Vec::new(), error: Some(error) },
        }
    }

    pub fn import_browsers(&self, choices: Vec<ImportChoice>) -> ImportSummary {
        let detected = self.lock().detected.clone();
        let chosen: Vec<(&import::Source, &import::ImportedProfile)> = detected
            .iter()
            .flat_map(|s| {
                let choice = choices.iter().find(|c| c.source_id == s.id);
                s.profiles
                    .iter()
                    .filter(move |p| choice.is_some_and(|c| c.profile_ids.contains(&p.id)))
                    .map(move |p| (s, p))
            })
            .collect();
        if chosen.is_empty() {
            return import_counts(import::Counts::default(), Vec::new());
        }
        let (counts, made) = self.mutate(|state, now| import::apply(state, &chosen, now));
        let links = chosen
            .iter()
            .zip(made)
            .map(|((source, profile), into)| ImportedProfileLink {
                source_id: source.id.clone(),
                profile_id: profile.id.clone(),
                into,
            })
            .collect();
        import_counts(counts, links)
    }

    pub fn unlock_passwords(&self, secret: Vec<u8>) -> bool {
        let Some(key) = passwords::Key::new(&secret) else { return false };
        let mut inner = self.lock();
        let first = inner.passwords.check.is_none();
        if !inner.passwords.verify(&key) {
            return false;
        }
        inner.passwords_dirty |= first;
        inner.password_key = Some(key);
        true
    }

    pub fn passwords_unlocked(&self) -> bool {
        self.lock().password_key.is_some()
    }

    pub fn saved_logins(&self, profile_id: u64) -> Vec<SavedLogin> {
        let inner = self.lock();
        let mut logins: Vec<SavedLogin> =
            inner.passwords.logins.iter().filter(|l| l.profile == profile_id).map(saved_login).collect();
        logins.sort_by(|a, b| a.site.cmp(&b.site).then_with(|| a.username.cmp(&b.username)));
        logins
    }

    pub fn logins_for_page(&self, profile_id: u64, url: String) -> Vec<SavedLogin> {
        self.lock().passwords.matching(profile_id, &url).into_iter().map(saved_login).collect()
    }

    pub fn login_password(&self, id: u64) -> Option<String> {
        let inner = self.lock();
        let key = inner.password_key.as_ref()?;
        inner.passwords.logins.iter().find(|l| l.id == id).and_then(|l| key.open(&l.password))
    }

    pub fn password_offer(&self, profile_id: u64, url: String, username: String, password: String) -> PasswordOffer {
        let inner = self.lock();
        let Some(key) = inner.password_key.as_ref().filter(|_| !inner.state.is_ephemeral_profile(profile_id)) else {
            return PasswordOffer::Nothing;
        };
        match inner.passwords.offer(key, profile_id, &url, &username, &password) {
            passwords::Offer::Nothing => PasswordOffer::Nothing,
            passwords::Offer::Save => PasswordOffer::Save,
            passwords::Offer::Update(login_id) => PasswordOffer::Update { login_id },
        }
    }

    pub fn save_login(&self, profile_id: u64, url: String, username: String, password: String) -> Option<u64> {
        let mut inner = self.lock();
        if inner.state.is_ephemeral_profile(profile_id) {
            return None;
        }
        let key = inner.password_key.clone()?;
        let id = inner.passwords.save(&key, profile_id, &url, &username, &password, now_ms())?;
        inner.passwords_dirty = true;
        Some(id)
    }

    pub fn mark_login_used(&self, id: u64) {
        let mut inner = self.lock();
        inner.passwords.mark_used(id, now_ms());
        inner.passwords_dirty = true;
    }

    pub fn delete_login(&self, id: u64) {
        let mut inner = self.lock();
        if inner.passwords.delete(id) {
            inner.passwords_dirty = true;
        }
    }

    pub fn never_save_passwords(&self, profile_id: u64, url: String) {
        let mut inner = self.lock();
        if inner.state.is_ephemeral_profile(profile_id) {
            return;
        }
        inner.passwords.never_save(profile_id, &url);
        inner.passwords_dirty = true;
    }

    pub fn never_saved_sites(&self, profile_id: u64) -> Vec<String> {
        let inner = self.lock();
        inner.passwords.never.iter().filter(|(p, _)| *p == profile_id).map(|(_, o)| o.clone()).collect()
    }

    pub fn allow_saving_passwords(&self, profile_id: u64, origin: String) {
        let mut inner = self.lock();
        inner.passwords.never.retain(|(p, o)| !(*p == profile_id && *o == origin));
        inner.passwords_dirty = true;
    }

    pub fn import_browser_passwords(
        &self,
        source_id: String,
        profile_id: String,
        password: Option<Vec<u8>>,
        into: u64,
    ) -> PasswordImportOutcome {
        let source = self.lock().detected.iter().find(|s| s.id == source_id).cloned();
        let Some(source) = source else { return PasswordImportOutcome::failed("That browser is no longer there.") };
        match import::passwords::read(&source, &profile_id, password.as_deref()) {
            Ok(read) => self.merge_logins(read, into),
            Err(error) => PasswordImportOutcome::failed(error),
        }
    }

    pub fn import_password_file(&self, path: String, into: u64) -> PasswordImportOutcome {
        let text = match fs::read(&path) {
            Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            Err(e) => return PasswordImportOutcome::failed(format!("Can't read the file: {e}")),
        };
        match import::passwords::read_csv(&text) {
            Ok(read) => self.merge_logins(read, into),
            Err(error) => PasswordImportOutcome::failed(error),
        }
    }

    pub fn persist(&self) -> bool {
        let mut inner = self.lock();
        let mut ok = true;
        if inner.passwords_dirty {
            if write_atomic(&inner.data_dir, PASSWORDS_FILE, &inner.passwords) {
                inner.passwords_dirty = false;
            } else {
                ok = false;
            }
        }
        if inner.history_dirty {
            if write_atomic(&inner.data_dir, HISTORY_FILE, &inner.history) {
                inner.history_dirty = false;
            } else {
                ok = false;
            }
        }
        if inner.downloads_dirty {
            if write_atomic(&inner.data_dir, DOWNLOADS_FILE, &inner.downloads) {
                inner.downloads_dirty = false;
            } else {
                ok = false;
            }
        }
        if inner.dirty {
            if write_atomic(&inner.data_dir, STATE_FILE, &*inner.state.persisted()) {
                inner.dirty = false;
            } else {
                ok = false;
            }
        }
        ok
    }
}

impl BrowserCore {
    fn load_filters_from_disk(&self, compile: bool) -> bool {
        if !self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).enabled {
            return false;
        }
        let dir = PathBuf::from(self.filter_dir());
        let mut fresh = blocker::Blocker::default();
        let loaded = if compile { fresh.load(&dir) } else { fresh.load_cached(&dir) };
        if !loaded {
            return false;
        }
        let mut blocker = self.blocker.write().unwrap_or_else(std::sync::PoisonError::into_inner);
        fresh.enabled = blocker.enabled;
        fresh.allowed = std::mem::take(&mut blocker.allowed);
        let old = std::mem::replace(&mut *blocker, fresh);
        drop(blocker);
        drop(old);
        true
    }

    fn merge_logins(&self, read: import::passwords::Read, into: u64) -> PasswordImportOutcome {
        let mut inner = self.lock();
        let Some(key) = inner.password_key.clone() else {
            return PasswordImportOutcome::failed("Passwords are locked.");
        };
        let merged = inner.passwords.merge(&key, into, &read.logins, &read.never, now_ms());
        inner.passwords_dirty = true;
        PasswordImportOutcome {
            added: merged.added,
            updated: merged.updated,
            kept: merged.kept,
            unreadable: read.unreadable,
            error: None,
        }
    }

    fn space_of(&self, tab_id: u64) -> Option<u64> {
        let inner = self.lock();
        match inner.state.locate(tab_id)? {
            Container::Pinned { space_id, .. } | Container::Today { space_id } => Some(space_id),
            Container::Favorites { .. } => Some(inner.state.active_space),
        }
    }
}

#[cfg(test)]
mod tests;
