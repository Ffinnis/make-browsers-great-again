//! MBGA browser core. Owns all browser state and the tab sleep policy; the
//! native shell only renders snapshots and forwards engine events.

uniffi::setup_scaffolding!();

pub mod blocker;
pub mod crypto;
pub mod history;
pub mod import;
pub mod model;
pub mod passwords;

use model::{Container, Id, Node, Pressure, State, Tab};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

// ------------------------------------------------------------------ records

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TabInfo {
    pub id: u64,
    pub url: String,
    pub title: String,
    pub favicon_path: Option<String>,
    pub pinned_url: Option<String>,
    pub live: bool,
    pub audible: bool,
    pub frozen: bool,
    /// The tab's site is exempt from sleeping and freezing.
    pub keep_awake: bool,
    /// The person chose to keep this one tab loaded (see `set_always_awake`).
    pub always_awake: bool,
    /// Ads and trackers are allowed on the tab's site.
    pub ads_allowed: bool,
}

/// One visible row of a space's pinned tree. Folders and tabs are flattened
/// depth-first; children of collapsed folders are omitted.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PinnedRow {
    pub id: u64,
    pub depth: u32,
    pub parent_id: Option<u64>,
    /// Position within the parent folder (or the pinned root).
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
    /// Something closed this session can be reopened.
    pub can_reopen: bool,
    pub block_ads: bool,
    /// H.264 and AAC video plays by converting it; new pages only.
    pub convert_video: bool,
    /// Today tabs untouched this long are archived; 0 is off.
    pub archive_after_hours: u32,
    pub cleanup_answered: bool,
    /// Sites whose tabs are never put to sleep or frozen, with their
    /// subdomains.
    pub keep_awake_sites: Vec<String>,
}

/// A page from history for the command bar.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct HistoryItem {
    pub url: String,
    pub title: String,
    /// The query is the start of the page's site ("git" for github.com).
    pub site_prefix: bool,
}

/// Tabs brought back by undoing a close, and the space they are in.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ReopenOutcome {
    pub space_id: u64,
    pub tabs: Vec<u64>,
}

/// A filter list for the shell to download into `filter_dir`.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct FilterList {
    pub file_name: String,
    pub url: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct CloseOutcome {
    /// False for pinned tabs and favorites, which stay in the sidebar asleep.
    pub removed: bool,
    /// Tab to show next, if the closed tab was on screen.
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

/// A profile of another browser and what importing it would bring.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportProfileInfo {
    pub id: String,
    pub name: String,
    pub spaces: u32,
    pub pinned: u32,
    pub favorites: u32,
    pub today: u32,
    /// Saved passwords; Safari's can't be counted.
    pub passwords: u32,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportSourceInfo {
    pub id: String,
    pub name: String,
    pub kind: BrowserKind,
    /// For showing the browser's app icon.
    pub bundle_id: Option<String>,
    pub profiles: Vec<ImportProfileInfo>,
    /// Why the browser's data could not be read.
    pub error: Option<String>,
    /// The keychain item with the password its cookies are encrypted with
    /// (Chromium-based browsers).
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
    /// The MBGA profile each imported profile became.
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

/// A cookie of another browser, for the engine to set.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportedCookie {
    /// ".example.com" covers subdomains; "example.com" is that host alone.
    pub domain: String,
    pub name: String,
    pub value: String,
    pub path: String,
    pub secure: bool,
    pub http_only: bool,
    /// Microseconds since 1601; 0 for a session cookie.
    pub expires: i64,
    pub created: i64,
    pub last_used: i64,
    /// -1 unspecified, 0 none, 1 lax, 2 strict.
    pub same_site: i32,
    /// 0 low, 1 medium, 2 high.
    pub priority: i32,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct CookieRead {
    pub cookies: Vec<ImportedCookie>,
    /// Why they couldn't be read.
    pub error: Option<String>,
}

/// A saved password, without the password.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SavedLogin {
    pub id: u64,
    pub profile_id: u64,
    /// "<https://example.com">: where it was saved.
    pub origin: String,
    /// "example.com", as shown to people.
    pub site: String,
    pub username: String,
    pub created_ms: u64,
    pub used_ms: u64,
    pub changed_ms: u64,
}

/// What to ask once a sign-in form was sent.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum PasswordOffer {
    /// Saved already, never saved on the site, or the passwords are locked.
    Nothing,
    Save,
    /// The saved login with that username has another password now.
    Update {
        login_id: u64,
    },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PasswordImportOutcome {
    pub added: u32,
    /// Saved logins whose password the import changed.
    pub updated: u32,
    /// Saved already, or older than the one MBGA has.
    pub kept: u32,
    /// Passwords that couldn't be decrypted.
    pub unreadable: u32,
    /// Why nothing could be imported.
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

// --------------------------------------------------------------------- core

struct Inner {
    state: State,
    dirty: bool,
    history: history::History,
    history_dirty: bool,
    revision: u64,
    data_dir: PathBuf,
    /// Browsers found by the last `detect_browsers`, ready to import.
    detected: Vec<import::Source>,
    passwords: passwords::Store,
    passwords_dirty: bool,
    /// None until the shell unlocks the passwords.
    password_key: Option<passwords::Key>,
}

#[derive(uniffi::Object)]
pub struct BrowserCore {
    inner: Mutex<Inner>,
    /// Consulted for every network request, on the engine's network thread.
    blocker: RwLock<blocker::Blocker>,
}

/// A length as the u32 that crosses to Swift, saturating instead of wrapping.
pub(crate) fn to_u32(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).ok().and_then(|d| u64::try_from(d.as_millis()).ok()).unwrap_or(0)
}

const STATE_FILE: &str = "state.json";
const HISTORY_FILE: &str = "history.json";
const PASSWORDS_FILE: &str = "passwords.json";

fn load_history(dir: &Path) -> history::History {
    fs::read(dir.join(HISTORY_FILE)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn load_passwords(dir: &Path) -> passwords::Store {
    fs::read(dir.join(PASSWORDS_FILE)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

/// Writes `value` as JSON next to its final path, then renames it into place.
fn write_atomic(dir: &Path, name: &str, value: &impl serde::Serialize) -> bool {
    let Ok(json) = serde_json::to_vec(value) else {
        return false;
    };
    let tmp = dir.join(format!("{name}.tmp"));
    fs::write(&tmp, json).is_ok() && private(&tmp, name) && fs::rename(&tmp, dir.join(name)).is_ok()
}

/// Only the person may read the passwords file, sealed as they are.
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
            // Keep the unreadable file for inspection instead of losing it.
            let backup = dir.join(format!("{STATE_FILE}.corrupt-{}", now_ms()));
            let _ = fs::rename(&path, backup);
            State::new_default()
        }
    }
}

/// The engine only accepts profile directories that are direct children of
/// its root directory.
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

    /// Runs a mutation and marks the state changed.
    fn mutate<R>(&self, f: impl FnOnce(&mut State, u64) -> R) -> R {
        let mut inner = self.lock();
        let r = f(&mut inner.state, now_ms());
        inner.dirty = true;
        inner.revision += 1;
        r
    }
}

#[uniffi::export]
impl BrowserCore {
    /// Loads state from `data_dir` (created if missing) or starts fresh.
    #[uniffi::constructor]
    pub fn new(data_dir: String) -> Arc<Self> {
        let data_dir = PathBuf::from(data_dir);
        let _ = fs::create_dir_all(&data_dir);
        // The engine rejects profile directories reached through a symlink
        // (e.g. /tmp -> /private/tmp) and silently falls back to in-memory
        // storage, so always hand it the resolved path.
        let data_dir = fs::canonicalize(&data_dir).unwrap_or(data_dir);
        let mut state = load_state(&data_dir);
        let history = load_history(&data_dir);
        let mut passwords = load_passwords(&data_dir);
        passwords.keep_profiles(&state.profiles.iter().map(|p| p.id).collect::<Vec<_>>());
        let blocker = blocker::Blocker::new(state.block_ads, state.ads_allowed.iter().cloned());
        // The engine is not running yet, so deleted profiles' storage is free.
        for id in std::mem::take(&mut state.doomed_profiles) {
            let _ = fs::remove_dir_all(profile_dir_in(&data_dir, id));
        }
        Arc::new(BrowserCore {
            inner: Mutex::new(Inner {
                state,
                dirty: true,
                history,
                history_dirty: false,
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
                }
            })
            .collect();
        let profiles = s
            .profiles
            .iter()
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
        }
    }

    pub fn tab(&self, id: u64) -> Option<TabInfo> {
        let inner = self.lock();
        inner.state.tabs.get(&id).map(|t| tab_info(&inner.state, t))
    }

    pub fn visible_tab(&self) -> Option<u64> {
        self.lock().state.visible_tab()
    }

    // ---------------------------------------------------------- engine paths

    /// Root directory for engine data; every profile directory lives inside.
    pub fn engine_root_dir(&self) -> String {
        self.lock().data_dir.join("engine").to_string_lossy().into_owned()
    }

    pub fn profile_dir(&self, profile_id: u64) -> String {
        profile_dir_in(&self.lock().data_dir, profile_id).to_string_lossy().into_owned()
    }

    pub fn profile_of_tab(&self, tab_id: u64) -> Option<u64> {
        self.lock().state.profile_of_tab(tab_id)
    }

    // -------------------------------------------------------------- profiles

    pub fn create_profile(&self, name: String) -> u64 {
        self.mutate(|s, _| s.create_profile(&name))
    }

    pub fn rename_profile(&self, id: u64, name: String) {
        self.mutate(|s, _| s.rename_profile(id, &name));
    }

    /// Returns the closed favorites, or None if it is the last profile or a
    /// space still uses it.
    pub fn delete_profile(&self, id: u64) -> Option<Vec<u64>> {
        let closed = self.mutate(|s, _| s.delete_profile(id))?;
        let mut inner = self.lock();
        let profiles: Vec<Id> = inner.state.profiles.iter().map(|p| p.id).collect();
        inner.passwords.keep_profiles(&profiles);
        inner.passwords_dirty = true;
        Some(closed)
    }

    // ---------------------------------------------------------------- spaces

    pub fn create_space(&self, name: String, icon: String, color: u32, profile_id: u64) -> u64 {
        self.mutate(|s, _| s.create_space(&name, &icon, color, profile_id))
    }

    pub fn update_space(&self, id: u64, name: String, icon: String, color: u32) {
        self.mutate(|s, _| s.update_space(id, &name, &icon, color));
    }

    /// Returns the live tabs that must be reloaded under the new profile.
    pub fn set_space_profile(&self, id: u64, profile_id: u64) -> Vec<u64> {
        self.mutate(|s, _| s.set_space_profile(id, profile_id))
    }

    /// Returns the closed tabs, or None if this is the last space.
    pub fn delete_space(&self, id: u64) -> Option<Vec<u64>> {
        self.mutate(|s, _| s.delete_space(id))
    }

    pub fn move_space(&self, id: u64, index: u32) {
        self.mutate(|s, _| s.move_space(id, index as usize));
    }

    pub fn set_active_space(&self, id: u64) {
        self.mutate(|s, now| s.set_active_space(id, now));
    }

    // ------------------------------------------------------------------ tabs

    pub fn open_tab(&self, space_id: u64, url: String, activate: bool) -> Option<u64> {
        let id = self.mutate(|s, now| s.open_tab(space_id, &url, activate, now))?;
        // The engine reports the first page's address unchanged, so the
        // visit is counted here.
        let mut inner = self.lock();
        inner.history.record(&url, now_ms());
        inner.history_dirty = true;
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
        // Engines repeat the same title/URL often; skip no-op updates.
        let changed = url.as_ref().is_some_and(|u| *u != t.url) || title.as_ref().is_some_and(|x| *x != t.title);
        if changed {
            let url_changed = url.as_ref().is_some_and(|u| *u != t.url);
            inner.state.update_tab(id, url.as_deref(), title.as_deref());
            inner.dirty = true;
            inner.revision += 1;
            // Every navigation the engine reports is a visit; the title
            // follows a moment later and belongs to the tab's current page.
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

    /// Pages from history matching `query`, best first.
    pub fn suggest_history(&self, query: String, limit: u32) -> Vec<HistoryItem> {
        self.lock()
            .history
            .suggest(&query, limit as usize, now_ms())
            .into_iter()
            .map(|m| HistoryItem { url: m.url, title: m.title, site_prefix: m.site_prefix })
            .collect()
    }

    pub fn clear_history(&self) {
        let mut inner = self.lock();
        inner.history.clear();
        inner.history_dirty = true;
    }

    pub fn close_tab(&self, id: u64) -> CloseOutcome {
        let (removed, next_tab) = self.mutate(|s, now| s.close_tab(id, now));
        CloseOutcome { removed, next_tab }
    }

    pub fn clear_today(&self, space_id: u64) -> Vec<u64> {
        self.mutate(|s, _| s.clear_today(space_id))
    }

    /// Undoes the most recent close, clear, tidy-up or folder deletion.
    pub fn undo_close(&self) -> Option<ReopenOutcome> {
        self.mutate(|s, _| s.reopen_last()).map(|(space_id, tabs)| ReopenOutcome { space_id, tabs })
    }

    /// Reopens one closed tab at the top of Today. Returns its space.
    pub fn reopen_tab(&self, id: u64) -> Option<u64> {
        self.mutate(|s, _| s.reopen_tab(id))
    }

    /// Marks a tab as on screen in a window of its own, or back.
    pub fn set_shown_elsewhere(&self, id: u64, shown: bool) {
        self.mutate(|s, _| {
            s.shown_elsewhere.retain(|t| *t != id);
            if shown {
                s.shown_elsewhere.push(id);
            }
        });
    }

    /// Selects a tab in a space with tabs but none selected. Returns it if
    /// one was chosen.
    pub fn select_default_tab(&self, space_id: u64) -> Option<u64> {
        let mut inner = self.lock();
        let chosen = inner.state.select_default_tab(space_id, now_ms());
        if chosen.is_some() {
            inner.dirty = true;
            inner.revision += 1;
        }
        chosen
    }

    /// Selects another tab in the main window if `id` was on screen there.
    pub fn step_away(&self, id: u64) -> Option<u64> {
        self.mutate(|s, now| s.step_away(id, now))
    }

    /// Tabs closed this session, most recent first.
    pub fn closed_tabs(&self, limit: u32) -> Vec<TabInfo> {
        let inner = self.lock();
        let s = &inner.state;
        s.closed_tabs().take(limit as usize).map(|t| tab_info(s, t)).collect()
    }

    // --------------------------------------------------------------- tidying

    /// How many Today tabs of a space nobody has looked at for `hours`.
    pub fn idle_today_count(&self, space_id: u64, hours: u32) -> u32 {
        to_u32(self.lock().state.idle_today(space_id, hours, now_ms()).len())
    }

    /// Archives a space's Today tabs untouched for `hours`, as one undoable
    /// step. Returns them; the shell must destroy their web views.
    pub fn archive_idle(&self, space_id: u64, hours: u32) -> Vec<u64> {
        self.mutate(|s, now| s.archive_idle(space_id, hours, now))
    }

    /// Applies the archive policy. Cheap when there is nothing to archive.
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

    /// Remembers that the person answered the offer to tidy up.
    pub fn answer_cleanup(&self) {
        self.mutate(|s, _| s.cleanup_answered = true);
    }

    /// Stores a favicon (PNG) for the tab's host and attaches it to the tab.
    pub fn set_favicon(&self, tab_id: u64, png: Vec<u8>) {
        let mut inner = self.lock();
        let Some(tab) = inner.state.tabs.get(&tab_id) else {
            return;
        };
        let dir = inner.data_dir.join("favicons");
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

    // --------------------------------------------------------------- folders

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

    // ----------------------------------------------------------- drag & drop

    /// Moves a tab or folder; `index` is in pre-removal coordinates.
    /// Returns tabs that must be reloaded because their profile changed, or
    /// None if the move is not allowed.
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

    // ------------------------------------------------------------- lifecycle

    pub fn set_live(&self, id: u64, live: bool) {
        self.mutate(|s, now| s.set_live(id, live, now));
    }

    pub fn set_audible(&self, id: u64, audible: bool) {
        self.mutate(|s, _| s.set_audible(id, audible));
    }

    /// Exempts the site of `url` from sleeping and freezing, or stops doing so.
    pub fn set_keep_awake(&self, url: String, keep: bool) {
        self.mutate(|s, _| s.set_keep_awake(&url, keep));
    }

    /// Replaces the sites kept awake: domains or addresses, each covering
    /// its subdomains.
    pub fn set_keep_awake_sites(&self, sites: Vec<String>) {
        self.mutate(|s, _| s.set_keep_awake_sites(&sites));
    }

    /// Keeps one tab loaded whatever the sleep policy: never put to sleep,
    /// frozen or archived, and loaded at launch. Or lets it sleep again.
    pub fn set_always_awake(&self, id: u64, awake: bool) {
        self.mutate(|s, _| s.set_always_awake(id, awake));
    }

    /// Tabs kept always awake, which the shell loads at launch.
    pub fn always_awake_tabs(&self) -> Vec<u64> {
        self.lock().state.always_awake_tabs()
    }

    // ------------------------------------------------------------ blocking

    /// Where the shell downloads filter lists.
    pub fn filter_dir(&self) -> String {
        self.lock().data_dir.join("filters").to_string_lossy().into_owned()
    }

    /// Filter lists and the scriptlets they use, for the shell to download.
    pub fn filter_lists(&self) -> Vec<FilterList> {
        blocker::LISTS
            .iter()
            .chain([&blocker::SCRIPTLETS])
            .map(|(file_name, url)| FilterList { file_name: file_name.to_string(), url: url.to_string() })
            .collect()
    }

    /// The person's own rules file, created with a short guide if missing.
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

    /// Loads the blocking engine from the downloaded lists (compiling and
    /// caching it if they changed). Slow the first time; call it off the
    /// main thread. False if blocking is off or no list has been downloaded
    /// yet; with blocking off the engine stays out of memory.
    pub fn load_filters(&self) -> bool {
        self.load_filters_from_disk(true)
    }

    /// Loads the engine only from an up-to-date compiled cache, which takes
    /// tens of milliseconds: call it before the first page loads.
    pub fn load_cached_filters(&self) -> bool {
        self.load_filters_from_disk(false)
    }

    /// Whether the engine should cancel a request for `url` made by the
    /// page at `page`. `kind` is "script", "image", "subdocument" and so on.
    pub fn should_block(&self, url: String, page: String, kind: String) -> bool {
        self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).should_block(&url, &page, &kind)
    }

    /// The script to run in `page` as it starts loading: hiding rules,
    /// scriptlets and the class/id collector. "" when blocking is off.
    /// Whether `page` gets scriptlets, which must run before its own
    /// scripts: only then does a new tab wait for them before loading.
    pub fn needs_early_script(&self, page: String) -> bool {
        self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).needs_early_script(&page)
    }

    pub fn page_script(&self, page: String) -> String {
        self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).page_script(&page)
    }

    /// A script adding the generic hiding rules for the class and id names
    /// a page reported, or "".
    pub fn cosmetic_reply(&self, page: String, report: String) -> String {
        self.blocker.read().unwrap_or_else(std::sync::PoisonError::into_inner).cosmetic_reply(&page, &report)
    }

    /// Turning blocking off frees the engine; after turning it on, call
    /// `load_filters` (off the main thread) to load it again.
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
        // Freed outside the lock, which requests wait on.
        drop(old);
    }

    /// Turns blocking off for the site of `url`, or back on.
    pub fn set_ads_allowed(&self, url: String, allowed: bool) {
        let sites = self.mutate(|s, _| {
            s.set_ads_allowed(&url, allowed);
            s.ads_allowed.clone()
        });
        self.blocker.write().unwrap_or_else(std::sync::PoisonError::into_inner).allowed = sites.into_iter().collect();
    }

    /// How long a background tab stays loaded while idle, and how many
    /// stay loaded at most. 0 turns either off; memory pressure still puts
    /// tabs to sleep.
    pub fn set_policy(&self, sleep_after_secs: u64, max_live_tabs: u32) {
        self.mutate(|s, _| {
            s.policy.sleep_after_secs = if sleep_after_secs == 0 { 0 } else { sleep_after_secs.max(30) };
            s.policy.max_live_tabs = max_live_tabs;
        });
    }

    /// Chooses tabs to put to sleep, marks them asleep and returns them. The
    /// shell must destroy their web views.
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

    /// Freezes idle hidden Today tabs (see `State::collect_freezers`).
    /// The shell must freeze their web views.
    pub fn collect_freezers(&self) -> Vec<u64> {
        let mut inner = self.lock();
        let frozen = inner.state.collect_freezers(now_ms());
        if !frozen.is_empty() {
            inner.revision += 1;
        }
        frozen
    }

    /// Returns true if the tab was frozen; the shell must resume its web view.
    pub fn thaw(&self, id: u64) -> bool {
        let mut inner = self.lock();
        let thawed = inner.state.thaw(id);
        if thawed {
            inner.revision += 1;
        }
        thawed
    }

    // ------------------------------------------------------- process model

    pub fn set_strict_site_isolation(&self, strict: bool) {
        self.mutate(|s, _| s.policy.strict_site_isolation = strict);
    }

    /// Origins that keep a dedicated renderer when strict isolation is off.
    pub fn isolated_origins(&self) -> Vec<String> {
        model::ALWAYS_ISOLATED_ORIGINS.iter().map(ToString::to_string).collect()
    }

    // ------------------------------------------------------------- video

    /// Whether pages play H.264 and AAC by converting them. The engine
    /// applies it to pages loaded afterwards.
    pub fn set_convert_video(&self, enabled: bool) {
        self.mutate(|s, _| s.convert_video = enabled);
    }

    // ---------------------------------------------------------------- misc

    pub fn resolve_input(&self, text: String) -> String {
        let inner = self.lock();
        model::resolve_input(&text, &inner.state.search_template)
    }

    /// A web search for `text`, even if it looks like an address.
    pub fn search_url(&self, text: String) -> String {
        let inner = self.lock();
        model::search_url(&text, &inner.state.search_template)
    }

    /// True until the first-launch onboarding has been completed or skipped.
    pub fn needs_onboarding(&self) -> bool {
        !self.lock().state.onboarded
    }

    pub fn finish_onboarding(&self) {
        self.mutate(|s, _| s.onboarded = true);
    }

    /// Finds other browsers' tabs and bookmarks under `home`. Reads every
    /// profile it finds, so call it off the main thread.
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

    /// The unexpired cookies of a profile found by `detect_browsers`;
    /// Chromium-based browsers need the password from their keychain item.
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

    /// Imports the chosen profiles of browsers found by `detect_browsers`.
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

    // ------------------------------------------------------------ passwords

    /// Unlocks saved passwords with the 32-byte secret the shell keeps in the
    /// keychain (the first secret ever given becomes the key). False if the
    /// passwords were sealed with another.
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

    /// Every login saved in a profile, by site, then username.
    pub fn saved_logins(&self, profile_id: u64) -> Vec<SavedLogin> {
        let inner = self.lock();
        let mut logins: Vec<SavedLogin> =
            inner.passwords.logins.iter().filter(|l| l.profile == profile_id).map(saved_login).collect();
        logins.sort_by(|a, b| a.site.cmp(&b.site).then_with(|| a.username.cmp(&b.username)));
        logins
    }

    /// Logins of a profile to offer on the page at `url`, best first.
    pub fn logins_for_page(&self, profile_id: u64, url: String) -> Vec<SavedLogin> {
        self.lock().passwords.matching(profile_id, &url).into_iter().map(saved_login).collect()
    }

    /// A saved password, or None while the passwords are locked.
    pub fn login_password(&self, id: u64) -> Option<String> {
        let inner = self.lock();
        let key = inner.password_key.as_ref()?;
        inner.passwords.logins.iter().find(|l| l.id == id).and_then(|l| key.open(&l.password))
    }

    /// Whether to offer saving a password sent from a page.
    pub fn password_offer(&self, profile_id: u64, url: String, username: String, password: String) -> PasswordOffer {
        let inner = self.lock();
        let Some(key) = inner.password_key.as_ref() else { return PasswordOffer::Nothing };
        match inner.passwords.offer(key, profile_id, &url, &username, &password) {
            passwords::Offer::Nothing => PasswordOffer::Nothing,
            passwords::Offer::Save => PasswordOffer::Save,
            passwords::Offer::Update(login_id) => PasswordOffer::Update { login_id },
        }
    }

    /// Saves a login for the page at `url`, replacing the password of the one
    /// with that username. None while locked.
    pub fn save_login(&self, profile_id: u64, url: String, username: String, password: String) -> Option<u64> {
        let mut inner = self.lock();
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

    /// Never offers to save passwords on the site of `url` again.
    pub fn never_save_passwords(&self, profile_id: u64, url: String) {
        let mut inner = self.lock();
        inner.passwords.never_save(profile_id, &url);
        inner.passwords_dirty = true;
    }

    /// Origins a profile never saves passwords on.
    pub fn never_saved_sites(&self, profile_id: u64) -> Vec<String> {
        let inner = self.lock();
        inner.passwords.never.iter().filter(|(p, _)| *p == profile_id).map(|(_, o)| o.clone()).collect()
    }

    pub fn allow_saving_passwords(&self, profile_id: u64, origin: String) {
        let mut inner = self.lock();
        inner.passwords.never.retain(|(p, o)| !(*p == profile_id && *o == origin));
        inner.passwords_dirty = true;
    }

    /// Imports the passwords of a profile found by `detect_browsers` into
    /// MBGA's profile `into`. Chromium-based browsers need the password from
    /// their keychain item. Call it off the main thread, once unlocked.
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

    /// Imports passwords exported to a CSV file (by the Passwords app, other
    /// browsers or password managers) into MBGA's profile `into`.
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

    /// Writes state and history to disk if they changed. Atomic: write +
    /// rename.
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
        if inner.dirty {
            if write_atomic(&inner.data_dir, STATE_FILE, &inner.state) {
                inner.dirty = false;
            } else {
                ok = false;
            }
        }
        ok
    }
}

impl BrowserCore {
    /// Builds a new engine (compiling the lists if allowed and needed) and
    /// swaps it in. Nothing loads while blocking is off.
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
        // Requests wait on the lock: free the old engine after releasing it.
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
