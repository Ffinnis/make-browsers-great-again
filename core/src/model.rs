//! Browser state: profiles, spaces, favorites, pinned trees and today tabs.
//!
//! Everything here is plain data plus the operations the shell performs on it.
//! The FFI layer in `lib.rs` wraps a `State` in a mutex and exposes it to Swift.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

pub type Id = u64;

pub const STATE_VERSION: u32 = 1;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Profile {
    pub id: Id,
    pub name: String,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Tab {
    pub id: Id,
    pub url: String,
    pub title: String,
    #[serde(default)]
    pub favicon: Option<String>,
    /// The URL a pinned tab or favorite returns to when it is closed.
    #[serde(default)]
    pub pinned_url: Option<String>,
    #[serde(default)]
    pub last_active_ms: u64,
    /// The person chose to keep this tab loaded: it is never put to sleep,
    /// frozen or archived, and loads at launch.
    #[serde(default)]
    pub always_awake: bool,
    /// A web view currently exists for this tab. Never persisted: every tab
    /// starts asleep and is loaded on first activation.
    #[serde(skip)]
    pub live: bool,
    #[serde(skip)]
    pub audible: bool,
    #[serde(skip)]
    pub frozen: bool,
    /// When its web view was last made. A tab loaded ahead of being shown
    /// (warmed) isn't put back to sleep or frozen as idle right away.
    #[serde(skip)]
    pub woke_ms: u64,
}

impl Tab {
    /// When it was last shown or loaded, whichever is later.
    fn last_used_ms(&self) -> u64 {
        self.last_active_ms.max(self.woke_ms)
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Node {
    Tab { id: Id },
    Folder { id: Id, name: String, expanded: bool, children: Vec<Node> },
}

impl Node {
    pub fn id(&self) -> Id {
        match self {
            Node::Tab { id } | Node::Folder { id, .. } => *id,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Space {
    pub id: Id,
    pub name: String,
    pub icon: String,
    /// 0xRRGGBB.
    pub color: u32,
    pub profile_id: Id,
    pub pinned: Vec<Node>,
    /// Newest first, like Arc.
    pub today: Vec<Id>,
    pub active_tab: Option<Id>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(default)]
pub struct Policy {
    /// Background tabs idle for longer than this are put to sleep. 0 never
    /// puts them to sleep for being idle (memory pressure still does).
    pub sleep_after_secs: u64,
    /// Upper bound on simultaneously loaded tabs (the visible tab excluded).
    /// 0 is no limit (memory pressure still applies one).
    pub max_live_tabs: u32,
    /// Hidden Today tabs idle for longer than this are frozen: they keep
    /// their state but run no JavaScript until shown again.
    pub freeze_after_secs: u64,
    /// One renderer process per site, as in desktop Chrome. Off by default:
    /// sites share a few processes and only sign-in pages and sites that ask
    /// for it (COOP) get their own, as in Chrome on Android. Applies at launch.
    pub strict_site_isolation: bool,
    /// Today tabs untouched for this long are archived (closed, and
    /// restorable for the session). 0 turns it off, the default until the
    /// person chooses otherwise.
    pub archive_after_hours: u32,
}

impl Default for Policy {
    fn default() -> Self {
        // Tabs stay loaded for hours, as in Edge (2 h) and Chrome, rather
        // than reloading whenever you come back after a short break; memory
        // pressure still puts them to sleep sooner.
        Policy {
            sleep_after_secs: 2 * 60 * 60,
            max_live_tabs: 24,
            freeze_after_secs: 5 * 60,
            strict_site_isolation: false,
            archive_after_hours: 0,
        }
    }
}

impl Policy {
    /// States saved with the first defaults (10 minutes, 8 tabs, frozen
    /// after a minute) get the current ones. Nothing let people choose
    /// those values.
    pub fn upgrade_first_defaults(&mut self) {
        if (self.sleep_after_secs, self.max_live_tabs, self.freeze_after_secs) == (600, 8, 60) {
            let current = Policy::default();
            self.sleep_after_secs = current.sleep_after_secs;
            self.max_live_tabs = current.max_live_tabs;
            self.freeze_after_secs = current.freeze_after_secs;
        }
    }
}

/// Sign-in origins that keep a dedicated process when strict site isolation
/// is off, so credentials never share a process with other sites.
pub const ALWAYS_ISOLATED_ORIGINS: [&str; 8] = [
    "https://accounts.google.com",
    "https://login.microsoftonline.com",
    "https://login.live.com",
    "https://appleid.apple.com",
    "https://idmsa.apple.com",
    "https://www.facebook.com",
    "https://github.com",
    "https://www.paypal.com",
];

/// Something closed that can be brought back: a Today tab, a cleared Today
/// list or a deleted folder. Kept for the session only.
#[derive(Clone, Debug)]
pub struct Closed {
    pub space_id: Id,
    pub kind: ClosedKind,
    /// The closed tabs, in sidebar order.
    pub tabs: Vec<Tab>,
}

#[derive(Clone, Debug)]
pub enum ClosedKind {
    /// Today tabs, with the position each had.
    Today { indices: Vec<usize> },
    /// A pinned folder with its contents, and where it was.
    Folder { node: Node, parent: Option<Id>, index: usize },
}

/// Most closing actions that can be undone.
pub const MAX_CLOSED: usize = 25;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pressure {
    Normal,
    Warning,
    Critical,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Section {
    Favorites,
    Pinned,
    Today,
}

/// Where a tab or folder lives. Favorites belong to a profile and are shared
/// by every space using it; pinned and today tabs belong to one space.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Container {
    Favorites { profile_id: Id },
    Pinned { space_id: Id, folder_id: Option<Id> },
    Today { space_id: Id },
}

#[derive(Serialize, Deserialize, Debug)]
pub struct State {
    pub version: u32,
    pub next_id: Id,
    pub profiles: Vec<Profile>,
    /// Keyed by profile id.
    pub favorites: HashMap<Id, Vec<Id>>,
    pub spaces: Vec<Space>,
    pub tabs: HashMap<Id, Tab>,
    pub active_space: Id,
    #[serde(default)]
    pub policy: Policy,
    #[serde(default = "default_search_template")]
    pub search_template: String,
    /// Profiles deleted while their storage may still be in use. Their
    /// directories are removed on the next launch, before the engine starts.
    #[serde(default)]
    pub doomed_profiles: Vec<Id>,
    /// False until the first-launch onboarding has been shown. State files
    /// from before onboarding existed count as onboarded.
    #[serde(default = "default_onboarded")]
    pub onboarded: bool,
    /// Sites (see `site_of`) whose tabs are never put to sleep or frozen,
    /// such as mail or chat that must keep delivering notifications.
    #[serde(default)]
    pub keep_awake: Vec<String>,
    /// The person has answered the offer to tidy up old Today tabs.
    #[serde(default)]
    pub cleanup_answered: bool,
    /// Block ads and trackers.
    #[serde(default = "default_block_ads")]
    pub block_ads: bool,
    /// Sites (see `site_of`) where ads and trackers are allowed.
    #[serde(default)]
    pub ads_allowed: Vec<String>,
    /// Play H.264 and AAC video, which the engine can't decode, by
    /// converting it in the page.
    #[serde(default = "default_convert_video")]
    pub convert_video: bool,
    /// Closed tabs and folders that can be reopened, newest last.
    #[serde(skip)]
    pub closed: Vec<Closed>,
    /// Tabs on screen outside the main window (little windows). Like the
    /// visible tab, they are never put to sleep or frozen.
    #[serde(skip)]
    pub shown_elsewhere: Vec<Id>,
}

fn default_search_template() -> String {
    "https://www.google.com/search?q=%s".into()
}

fn default_onboarded() -> bool {
    true
}

fn default_block_ads() -> bool {
    true
}

fn default_convert_video() -> bool {
    true
}

pub const SPACE_COLORS: [u32; 8] = [0x8B5CF6, 0x3B82F6, 0x10B981, 0xF59E0B, 0xEF4444, 0xEC4899, 0x14B8A6, 0x6366F1];

impl State {
    pub fn new_default() -> State {
        let mut s = State {
            version: STATE_VERSION,
            next_id: 1,
            profiles: Vec::new(),
            favorites: HashMap::new(),
            spaces: Vec::new(),
            tabs: HashMap::new(),
            active_space: 0,
            policy: Policy::default(),
            search_template: default_search_template(),
            doomed_profiles: Vec::new(),
            onboarded: false,
            keep_awake: Vec::new(),
            cleanup_answered: false,
            block_ads: true,
            ads_allowed: Vec::new(),
            convert_video: true,
            closed: Vec::new(),
            shown_elsewhere: Vec::new(),
        };
        let profile = s.create_profile("Personal");
        let space = s.create_space("Home", "🏠", SPACE_COLORS[0], profile);
        s.active_space = space;
        s
    }

    pub(crate) fn alloc(&mut self) -> Id {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    // ---------------------------------------------------------------- lookups

    pub fn space(&self, id: Id) -> Option<&Space> {
        self.spaces.iter().find(|s| s.id == id)
    }

    fn space_mut(&mut self, id: Id) -> Option<&mut Space> {
        self.spaces.iter_mut().find(|s| s.id == id)
    }

    pub fn locate(&self, id: Id) -> Option<Container> {
        for (profile_id, favs) in &self.favorites {
            if favs.contains(&id) {
                return Some(Container::Favorites { profile_id: *profile_id });
            }
        }
        for space in &self.spaces {
            if space.today.contains(&id) {
                return Some(Container::Today { space_id: space.id });
            }
            if let Some(folder_id) = find_parent(&space.pinned, id, None) {
                return Some(Container::Pinned { space_id: space.id, folder_id });
            }
        }
        None
    }

    /// The profile whose storage a tab must be loaded with.
    pub fn profile_of_tab(&self, id: Id) -> Option<Id> {
        match self.locate(id)? {
            Container::Favorites { profile_id } => Some(profile_id),
            Container::Pinned { space_id, .. } | Container::Today { space_id } => {
                self.space(space_id).map(|s| s.profile_id)
            }
        }
    }

    /// The tab currently on screen.
    pub fn visible_tab(&self) -> Option<Id> {
        self.space(self.active_space).and_then(|s| s.active_tab)
    }

    // --------------------------------------------------------------- profiles

    pub fn create_profile(&mut self, name: &str) -> Id {
        let id = self.alloc();
        self.profiles.push(Profile { id, name: name.to_string() });
        self.favorites.insert(id, Vec::new());
        id
    }

    pub fn rename_profile(&mut self, id: Id, name: &str) {
        if let Some(p) = self.profiles.iter_mut().find(|p| p.id == id) {
            p.name = name.to_string();
        }
    }

    /// Deletes a profile no space uses any more. Returns the favorites that
    /// were closed with it.
    pub fn delete_profile(&mut self, id: Id) -> Option<Vec<Id>> {
        if self.profiles.len() <= 1 || self.spaces.iter().any(|s| s.profile_id == id) {
            return None;
        }
        self.profiles.retain(|p| p.id != id);
        let closed = self.favorites.remove(&id).unwrap_or_default();
        for tab in &closed {
            self.tabs.remove(tab);
        }
        self.doomed_profiles.push(id);
        Some(closed)
    }

    // ----------------------------------------------------------------- spaces

    pub fn create_space(&mut self, name: &str, icon: &str, color: u32, profile_id: Id) -> Id {
        let profile_id =
            if self.profiles.iter().any(|p| p.id == profile_id) { profile_id } else { self.profiles[0].id };
        let id = self.alloc();
        self.spaces.push(Space {
            id,
            name: name.to_string(),
            icon: icon.to_string(),
            color,
            profile_id,
            pinned: Vec::new(),
            today: Vec::new(),
            active_tab: None,
        });
        id
    }

    pub fn update_space(&mut self, id: Id, name: &str, icon: &str, color: u32) {
        if let Some(s) = self.space_mut(id) {
            s.name = name.to_string();
            s.icon = icon.to_string();
            s.color = color;
        }
    }

    /// Switches the storage a space uses. Its tabs must be reloaded with the
    /// new profile, so they are put to sleep and returned.
    pub fn set_space_profile(&mut self, id: Id, profile_id: Id) -> Vec<Id> {
        if !self.profiles.iter().any(|p| p.id == profile_id) {
            return Vec::new();
        }
        let Some(space) = self.space_mut(id) else {
            return Vec::new();
        };
        if space.profile_id == profile_id {
            return Vec::new();
        }
        space.profile_id = profile_id;
        // Favorites belong to the old profile and disappear from this space.
        if let Some(active) = space.active_tab {
            if !space.today.contains(&active) && find_parent(&space.pinned, active, None).is_none() {
                space.active_tab = None;
            }
        }
        let mut ids = space.today.clone();
        collect_tabs(&space.pinned, &mut ids);
        ids.retain(|id| self.tabs.get(id).is_some_and(|t| t.live));
        for id in &ids {
            if let Some(t) = self.tabs.get_mut(id) {
                t.live = false;
            }
        }
        ids
    }

    /// Deletes a space and every tab it owns. Returns the closed tabs.
    pub fn delete_space(&mut self, id: Id) -> Option<Vec<Id>> {
        if self.spaces.len() <= 1 {
            return None;
        }
        let index = self.spaces.iter().position(|s| s.id == id)?;
        let space = self.spaces.remove(index);
        let mut closed = space.today.clone();
        collect_tabs(&space.pinned, &mut closed);
        for tab in &closed {
            self.tabs.remove(tab);
        }
        if self.active_space == id {
            self.active_space = self.spaces[index.min(self.spaces.len() - 1)].id;
        }
        Some(closed)
    }

    pub fn move_space(&mut self, id: Id, index: usize) {
        if let Some(from) = self.spaces.iter().position(|s| s.id == id) {
            let space = self.spaces.remove(from);
            let index = index.min(self.spaces.len());
            self.spaces.insert(index, space);
        }
    }

    pub fn set_active_space(&mut self, id: Id, now: u64) {
        if self.active_space == id || self.space(id).is_none() {
            return;
        }
        self.touch_visible(now);
        self.active_space = id;
        self.touch_visible(now);
    }

    fn touch_visible(&mut self, now: u64) {
        if let Some(tab) = self.visible_tab().and_then(|id| self.tabs.get_mut(&id)) {
            tab.last_active_ms = now;
        }
    }

    // ------------------------------------------------------------------- tabs

    pub fn open_tab(&mut self, space_id: Id, url: &str, activate: bool, now: u64) -> Option<Id> {
        self.space(space_id)?;
        let id = self.alloc();
        self.tabs.insert(
            id,
            Tab {
                id,
                url: url.to_string(),
                title: String::new(),
                favicon: None,
                pinned_url: None,
                last_active_ms: now,
                always_awake: false,
                live: false,
                audible: false,
                frozen: false,
                woke_ms: 0,
            },
        );
        self.space_mut(space_id).expect("space checked above").today.insert(0, id);
        if activate {
            self.activate_tab(space_id, id, now);
        }
        Some(id)
    }

    /// Makes `tab_id` the selected tab of `space_id`. Favorites are shared, so
    /// the space has to be passed explicitly.
    pub fn activate_tab(&mut self, space_id: Id, tab_id: Id, now: u64) {
        if !self.tabs.contains_key(&tab_id) || self.space(space_id).is_none() {
            return;
        }
        if space_id == self.active_space {
            self.touch_visible(now);
        }
        self.space_mut(space_id).expect("space checked above").active_tab = Some(tab_id);
        if let Some(t) = self.tabs.get_mut(&tab_id) {
            t.last_active_ms = now;
        }
    }

    pub fn update_tab(&mut self, id: Id, url: Option<&str>, title: Option<&str>) {
        if let Some(t) = self.tabs.get_mut(&id) {
            if let Some(url) = url {
                t.url = url.to_string();
            }
            if let Some(title) = title {
                t.title = title.to_string();
            }
        }
    }

    /// Closes a tab the way Arc does: today tabs are removed, pinned tabs and
    /// favorites are put to sleep and reset to their pinned URL.
    /// Returns (tab was removed, tab to select next in the visible space).
    pub fn close_tab(&mut self, id: Id, now: u64) -> (bool, Option<Id>) {
        let Some(container) = self.locate(id) else {
            return (false, None);
        };
        let next = self.next_after_close(id, container, now);
        let removed = if let Container::Today { space_id } = container {
            let today = &mut self.space_mut(space_id).expect("space checked above").today;
            let index = today.iter().position(|t| *t == id).unwrap_or(0);
            today.retain(|t| *t != id);
            if let Some(tab) = self.tabs.remove(&id) {
                self.remember(Closed { space_id, kind: ClosedKind::Today { indices: vec![index] }, tabs: vec![tab] });
            }
            true
        } else {
            if let Some(t) = self.tabs.get_mut(&id) {
                t.live = false;
                t.audible = false;
                if let Some(home) = t.pinned_url.clone() {
                    t.url = home;
                }
            }
            false
        };
        let mut next_visible = None;
        for space in &mut self.spaces {
            if space.active_tab == Some(id) {
                space.active_tab = if space.id == self.active_space { next } else { None };
                if space.id == self.active_space {
                    next_visible = next;
                }
            }
        }
        if let Some(n) = next_visible.and_then(|n| self.tabs.get_mut(&n)) {
            n.last_active_ms = now;
        }
        (removed, next_visible)
    }

    /// Arc moves to the tab below a closed today tab, then the one above;
    /// for pinned tabs it returns to the most recently used tab.
    fn next_after_close(&self, id: Id, container: Container, _now: u64) -> Option<Id> {
        let space = self.space(self.active_space)?;
        if space.active_tab != Some(id) {
            return None;
        }
        if let Container::Today { space_id } = container {
            if space_id == space.id {
                let i = space.today.iter().position(|t| *t == id)?;
                if let Some(next) = space.today.get(i + 1).or_else(|| i.checked_sub(1).and_then(|p| space.today.get(p)))
                {
                    return Some(*next);
                }
            }
        }
        let mut candidates = space.today.clone();
        collect_tabs(&space.pinned, &mut candidates);
        if let Some(favs) = self.favorites.get(&space.profile_id) {
            candidates.extend(favs);
        }
        candidates
            .into_iter()
            .filter(|t| *t != id)
            .filter_map(|t| self.tabs.get(&t))
            .max_by_key(|t| (t.live, t.last_active_ms))
            .map(|t| t.id)
    }

    /// Archives every today tab of a space ("Clear" in Arc).
    pub fn clear_today(&mut self, space_id: Id) -> Vec<Id> {
        let Some(space) = self.space_mut(space_id) else {
            return Vec::new();
        };
        let closed = std::mem::take(&mut space.today);
        if space.active_tab.is_some_and(|t| closed.contains(&t)) {
            space.active_tab = None;
        }
        let tabs: Vec<Tab> = closed.iter().filter_map(|id| self.tabs.remove(id)).collect();
        if !tabs.is_empty() {
            let indices = (0..tabs.len()).collect();
            self.remember(Closed { space_id, kind: ClosedKind::Today { indices }, tabs });
        }
        closed
    }

    pub fn set_favicon_path(&mut self, id: Id, path: &str) {
        if let Some(t) = self.tabs.get_mut(&id) {
            t.favicon = Some(path.to_string());
        }
    }

    // ---------------------------------------------------------------- folders

    pub fn create_folder(&mut self, space_id: Id, name: &str, parent: Option<Id>) -> Option<Id> {
        self.space(space_id)?;
        let id = self.alloc();
        let folder = Node::Folder { id, name: name.to_string(), expanded: true, children: Vec::new() };
        let space = self.space_mut(space_id).expect("space checked above");
        let list = match parent {
            Some(pid) => folder_children_mut(&mut space.pinned, pid)?,
            None => &mut space.pinned,
        };
        list.insert(0, folder);
        Some(id)
    }

    pub fn rename_folder(&mut self, id: Id, name: &str) {
        for space in &mut self.spaces {
            if let Some(Node::Folder { name: n, .. }) = find_node_mut(&mut space.pinned, id) {
                *n = name.to_string();
                return;
            }
        }
    }

    pub fn set_folder_expanded(&mut self, id: Id, value: bool) {
        for space in &mut self.spaces {
            if let Some(Node::Folder { expanded, .. }) = find_node_mut(&mut space.pinned, id) {
                *expanded = value;
                return;
            }
        }
    }

    /// Deletes a folder together with its contents. Returns the closed tabs.
    pub fn delete_folder(&mut self, id: Id) -> Vec<Id> {
        let mut closed = Vec::new();
        let mut removed = None;
        for space in &mut self.spaces {
            if let Some((node, index, parent)) = detach(&mut space.pinned, id, None) {
                collect_tabs(std::slice::from_ref(&node), &mut closed);
                if space.active_tab.is_some_and(|t| closed.contains(&t)) {
                    space.active_tab = None;
                }
                removed = Some((space.id, node, index, parent));
                break;
            }
        }
        let tabs: Vec<Tab> = closed.iter().filter_map(|t| self.tabs.remove(t)).collect();
        if let Some((space_id, node, index, parent)) = removed {
            self.remember(Closed { space_id, kind: ClosedKind::Folder { node, parent, index }, tabs });
        }
        closed
    }

    // ------------------------------------------------------------ reopening

    fn remember(&mut self, closed: Closed) {
        self.closed.push(closed);
        if self.closed.len() > MAX_CLOSED {
            self.closed.remove(0);
        }
    }

    /// Closed tabs that can be reopened, most recently closed first.
    pub fn closed_tabs(&self) -> impl Iterator<Item = &Tab> {
        self.closed.iter().rev().flat_map(|c| c.tabs.iter())
    }

    /// Undoes the most recent close, clear or folder deletion. Returns the
    /// space and the tabs brought back, asleep.
    pub fn reopen_last(&mut self) -> Option<(Id, Vec<Id>)> {
        let closed = self.closed.pop()?;
        let space_id = if self.space(closed.space_id).is_some() { closed.space_id } else { self.active_space };
        let ids: Vec<Id> = closed.tabs.iter().map(|t| t.id).collect();
        for mut tab in closed.tabs {
            tab.live = false;
            tab.audible = false;
            tab.frozen = false;
            self.tabs.insert(tab.id, tab);
        }
        let space = self.space_mut(space_id)?;
        match closed.kind {
            ClosedKind::Today { indices } => {
                let mut placed: Vec<(usize, Id)> = indices.into_iter().zip(ids.iter().copied()).collect();
                placed.sort_unstable();
                for (index, id) in placed {
                    space.today.insert(index.min(space.today.len()), id);
                }
            }
            ClosedKind::Folder { node, parent, index } => {
                let list = match parent.and_then(|p| folder_children_mut(&mut space.pinned, p)) {
                    Some(children) => children,
                    None => &mut space.pinned,
                };
                list.insert(index.min(list.len()), node);
            }
        }
        Some((space_id, ids))
    }

    /// Reopens one closed tab at the top of its space's Today list.
    /// Returns its space.
    pub fn reopen_tab(&mut self, id: Id) -> Option<Id> {
        let entry = self.closed.iter().position(|c| c.tabs.iter().any(|t| t.id == id))?;
        let closed = &mut self.closed[entry];
        let i = closed.tabs.iter().position(|t| t.id == id)?;
        let mut tab = closed.tabs.remove(i);
        let space_id = closed.space_id;
        match &mut closed.kind {
            ClosedKind::Today { indices } => {
                indices.remove(i);
            }
            ClosedKind::Folder { node, .. } => {
                if let Node::Folder { children, .. } = node {
                    detach(children, id, None);
                }
            }
        }
        if closed.tabs.is_empty() {
            self.closed.remove(entry);
        }
        let space_id = if self.space(space_id).is_some() { space_id } else { self.active_space };
        tab.live = false;
        tab.audible = false;
        tab.frozen = false;
        tab.pinned_url = None;
        self.tabs.insert(id, tab);
        self.space_mut(space_id)?.today.insert(0, id);
        Some(space_id)
    }

    /// Selects a tab in a space that has tabs but none selected (after an
    /// import, say): the most recently used, ties going to sidebar order
    /// (Today, then pinned). Favorites are shared between spaces, so a space
    /// with only those stays empty. Returns the tab if one was chosen.
    pub fn select_default_tab(&mut self, space_id: Id, now: u64) -> Option<Id> {
        let space = self.space(space_id)?;
        if space.active_tab.is_some_and(|t| self.tabs.contains_key(&t)) {
            return None;
        }
        let mut candidates = space.today.clone();
        collect_tabs(&space.pinned, &mut candidates);
        let mut best: Option<&Tab> = None;
        for tab in candidates.iter().filter_map(|id| self.tabs.get(id)) {
            if best.is_none_or(|b| tab.last_active_ms > b.last_active_ms) {
                best = Some(tab);
            }
        }
        let id = best?.id;
        self.activate_tab(space_id, id, now);
        Some(id)
    }

    /// Moves the main window off `id` (popped out into its own window) to
    /// the tab Arc would show after closing it. Returns that tab.
    pub fn step_away(&mut self, id: Id, now: u64) -> Option<Id> {
        let container = self.locate(id)?;
        let space = self.space(self.active_space)?;
        if space.active_tab != Some(id) {
            return None;
        }
        let next = self.next_after_close(id, container, now);
        self.space_mut(self.active_space)?.active_tab = next;
        if let Some(t) = next.and_then(|n| self.tabs.get_mut(&n)) {
            t.last_active_ms = now;
        }
        next
    }

    // -------------------------------------------------------------- tidying

    /// Today tabs of a space untouched for at least `hours`, except the
    /// visible tab, tabs playing sound and sites kept awake.
    pub fn idle_today(&self, space_id: Id, hours: u32, now: u64) -> Vec<Id> {
        let visible = self.visible_tab();
        let after_ms = u64::from(hours) * 3_600_000;
        let Some(space) = self.space(space_id) else { return Vec::new() };
        space
            .today
            .iter()
            .copied()
            .filter(|id| Some(*id) != visible)
            .filter(|id| {
                self.tabs.get(id).is_some_and(|t| {
                    !t.audible && !self.stays_awake(t) && now.saturating_sub(t.last_active_ms) >= after_ms
                })
            })
            .collect()
    }

    /// Archives idle Today tabs of a space as one undoable step. Returns them.
    pub fn archive_idle(&mut self, space_id: Id, hours: u32, now: u64) -> Vec<Id> {
        let idle = self.idle_today(space_id, hours, now);
        if idle.is_empty() {
            return idle;
        }
        let space = self.space_mut(space_id).expect("space checked above");
        let mut indices = Vec::new();
        for (i, id) in space.today.iter().enumerate() {
            if idle.contains(id) {
                indices.push(i);
            }
        }
        space.today.retain(|id| !idle.contains(id));
        if space.active_tab.is_some_and(|t| idle.contains(&t)) {
            space.active_tab = None;
        }
        let tabs: Vec<Tab> = idle.iter().filter_map(|id| self.tabs.remove(id)).collect();
        self.remember(Closed { space_id, kind: ClosedKind::Today { indices }, tabs });
        idle
    }

    /// Applies the archive policy to every space. Returns the archived tabs.
    pub fn archive_by_policy(&mut self, now: u64) -> Vec<Id> {
        let hours = self.policy.archive_after_hours;
        if hours == 0 {
            return Vec::new();
        }
        let spaces: Vec<Id> = self.spaces.iter().map(|s| s.id).collect();
        spaces.into_iter().flat_map(|s| self.archive_idle(s, hours, now)).collect()
    }

    // ------------------------------------------------------------ drag & drop

    /// Moves a tab or folder. `index` is the drop position in the target list
    /// as seen before the item was removed (what list drop delegates report).
    /// Returns the tabs that must be reloaded because they changed profile.
    pub fn move_item(&mut self, id: Id, target: Container, index: usize) -> Option<Vec<Id>> {
        let source = self.locate(id)?;
        let is_folder = !self.tabs.contains_key(&id);
        if is_folder && !matches!(target, Container::Pinned { .. }) {
            return None;
        }
        let source_profile = self.container_profile(source)?;
        let target_profile = self.container_profile(target)?;
        if let Container::Pinned { space_id, folder_id: Some(folder) } = target {
            // The target folder must exist and must not be inside the item.
            let space = self.space(space_id)?;
            let moved = find_node(&space.pinned, id);
            find_node(&space.pinned, folder)?;
            if folder == id || moved.is_some_and(|m| find_node(std::slice::from_ref(m), folder).is_some()) {
                return None;
            }
        }

        let (node, old_index) = self.detach_from(id, source)?;
        let index = if source == target && old_index < index { index - 1 } else { index };

        let mut moved_tabs = Vec::new();
        collect_tabs(std::slice::from_ref(&node), &mut moved_tabs);
        for t in &moved_tabs {
            if let Some(tab) = self.tabs.get_mut(t) {
                match target {
                    Container::Today { .. } => tab.pinned_url = None,
                    _ => {
                        if tab.pinned_url.is_none() {
                            tab.pinned_url = Some(tab.url.clone());
                        }
                    }
                }
            }
        }

        match target {
            Container::Favorites { profile_id } => {
                let favs = self.favorites.entry(profile_id).or_default();
                favs.insert(index.min(favs.len()), id);
            }
            Container::Today { space_id } => {
                let today = &mut self.space_mut(space_id).expect("space checked above").today;
                today.insert(index.min(today.len()), id);
            }
            Container::Pinned { space_id, folder_id } => {
                let space = self.space_mut(space_id).expect("space checked above");
                let list = match folder_id {
                    Some(f) => folder_children_mut(&mut space.pinned, f).expect("folder checked above"),
                    None => &mut space.pinned,
                };
                list.insert(index.min(list.len()), node);
            }
        }

        // A tab leaving a space must not stay selected there.
        let target_space = match target {
            Container::Pinned { space_id, .. } | Container::Today { space_id } => Some(space_id),
            Container::Favorites { .. } => None,
        };
        for space in &mut self.spaces {
            let owned_here = Some(space.id) == target_space
                || matches!(target, Container::Favorites { profile_id } if profile_id == space.profile_id);
            if !owned_here && space.active_tab.is_some_and(|t| moved_tabs.contains(&t)) {
                space.active_tab = None;
            }
        }

        if source_profile == target_profile {
            return Some(Vec::new());
        }
        let mut reload = Vec::new();
        for t in moved_tabs {
            if let Some(tab) = self.tabs.get_mut(&t) {
                if tab.live {
                    tab.live = false;
                    reload.push(t);
                }
            }
        }
        Some(reload)
    }

    fn container_profile(&self, c: Container) -> Option<Id> {
        match c {
            Container::Favorites { profile_id } => {
                self.profiles.iter().any(|p| p.id == profile_id).then_some(profile_id)
            }
            Container::Pinned { space_id, .. } | Container::Today { space_id } => {
                self.space(space_id).map(|s| s.profile_id)
            }
        }
    }

    fn detach_from(&mut self, id: Id, c: Container) -> Option<(Node, usize)> {
        match c {
            Container::Favorites { profile_id } => {
                let favs = self.favorites.get_mut(&profile_id)?;
                let i = favs.iter().position(|t| *t == id)?;
                favs.remove(i);
                Some((Node::Tab { id }, i))
            }
            Container::Today { space_id } => {
                let today = &mut self.space_mut(space_id)?.today;
                let i = today.iter().position(|t| *t == id)?;
                today.remove(i);
                Some((Node::Tab { id }, i))
            }
            Container::Pinned { space_id, .. } => {
                let space = self.space_mut(space_id)?;
                detach(&mut space.pinned, id, None).map(|(n, i, _)| (n, i))
            }
        }
    }

    // -------------------------------------------------------------- lifecycle

    pub fn set_live(&mut self, id: Id, live: bool, now: u64) {
        if let Some(t) = self.tabs.get_mut(&id) {
            // A new or destroyed web view is never frozen.
            t.live = live;
            t.frozen = false;
            if live {
                t.woke_ms = now;
            } else {
                t.audible = false;
            }
        }
    }

    /// Picks hidden Today tabs to freeze, marks them frozen and returns them.
    /// Pinned tabs and favorites are usually web apps (mail, chat) that must
    /// keep running to deliver notifications, so they are never frozen.
    pub fn collect_freezers(&mut self, now: u64) -> Vec<Id> {
        let visible = self.visible_tab();
        let after_ms = self.policy.freeze_after_secs * 1000;
        let today: Vec<Id> = self.spaces.iter().flat_map(|s| s.today.iter().copied()).collect();
        let keep_awake = &self.keep_awake;
        let elsewhere = &self.shown_elsewhere;
        let mut frozen = Vec::new();
        for id in today {
            let Some(t) = self.tabs.get_mut(&id) else { continue };
            if t.live
                && !t.frozen
                && !t.audible
                && !t.always_awake
                && !covers(keep_awake, &site_of(&t.url))
                && !elsewhere.contains(&id)
                && Some(id) != visible
                && now.saturating_sub(t.last_used_ms()) >= after_ms
            {
                t.frozen = true;
                frozen.push(id);
            }
        }
        frozen
    }

    /// Marks a tab as running again. Returns true if it was frozen.
    pub fn thaw(&mut self, id: Id) -> bool {
        match self.tabs.get_mut(&id) {
            Some(t) if t.frozen => {
                t.frozen = false;
                true
            }
            _ => false,
        }
    }

    pub fn set_audible(&mut self, id: Id, audible: bool) {
        if let Some(t) = self.tabs.get_mut(&id) {
            t.audible = audible;
        }
    }

    pub fn allows_ads(&self, url: &str) -> bool {
        self.ads_allowed.contains(&site_of(url))
    }

    /// Turns ad blocking off for the site of `url`, or back on.
    pub fn set_ads_allowed(&mut self, url: &str, allowed: bool) {
        let site = site_of(url);
        if site.is_empty() {
            return;
        }
        self.ads_allowed.retain(|s| *s != site);
        if allowed {
            self.ads_allowed.push(site);
        }
    }

    pub fn keeps_awake(&self, url: &str) -> bool {
        covers(&self.keep_awake, &site_of(url))
    }

    /// The tab, or its site, is exempt from sleeping, freezing and archiving.
    pub fn stays_awake(&self, t: &Tab) -> bool {
        t.always_awake || self.keeps_awake(&t.url)
    }

    /// Keeps one tab loaded whatever the policy, or lets it sleep again.
    pub fn set_always_awake(&mut self, id: Id, awake: bool) {
        if let Some(t) = self.tabs.get_mut(&id) {
            t.always_awake = awake;
        }
    }

    /// Tabs the person chose to keep loaded, for the shell to load at launch.
    pub fn always_awake_tabs(&self) -> Vec<Id> {
        let mut ids: Vec<Id> =
            self.tabs.values().filter(|t| t.always_awake && !t.url.is_empty()).map(|t| t.id).collect();
        ids.sort_unstable();
        ids
    }

    /// Exempts the site of `url` from sleeping and freezing, or stops doing so.
    pub fn set_keep_awake(&mut self, url: &str, keep: bool) {
        let site = site_of(url);
        if site.is_empty() {
            return;
        }
        if keep {
            if !covers(&self.keep_awake, &site) {
                self.keep_awake.push(site);
            }
        } else {
            // Including a parent domain that covers it.
            self.keep_awake.retain(|s| !covers(std::slice::from_ref(s), &site));
        }
    }

    /// Replaces the sites kept awake, as typed in Settings: bare domains
    /// ("slack.com") or addresses, each also covering its subdomains.
    pub fn set_keep_awake_sites(&mut self, sites: &[String]) {
        let mut kept: Vec<String> = Vec::new();
        for entry in sites {
            let entry = entry.trim();
            let site = if entry.contains("://") { site_of(entry) } else { site_of(&format!("https://{entry}")) };
            if !site.is_empty() && !kept.contains(&site) {
                kept.push(site);
            }
        }
        self.keep_awake = kept;
    }

    /// Picks the tabs to put to sleep, marks them asleep and returns them.
    /// The visible tab and tabs playing audio are never chosen.
    pub fn collect_sleepers(&mut self, now: u64, pressure: Pressure) -> Vec<Id> {
        let visible = self.visible_tab();
        let after_ms = match self.policy.sleep_after_secs {
            0 => u64::MAX,
            secs => secs.saturating_mul(1000),
        };
        let limit = match self.policy.max_live_tabs {
            0 => usize::MAX,
            max => max as usize,
        };
        let (timeout_ms, max_live) = match pressure {
            Pressure::Normal => (after_ms, limit),
            // Without a limit of their own, tabs beyond the default count.
            Pressure::Warning => (after_ms / 4, (limit.min(Policy::default().max_live_tabs as usize) / 2).max(1)),
            Pressure::Critical => (0, 0),
        };
        // Each space's current tab stays loaded unless memory is critical,
        // so switching spaces shows it at once.
        let fronts: HashSet<Id> = match pressure {
            Pressure::Critical => HashSet::new(),
            _ => self.spaces.iter().filter_map(|s| s.active_tab).collect(),
        };
        let mut live: Vec<&Tab> = self
            .tabs
            .values()
            .filter(|t| {
                t.live && Some(t.id) != visible && !self.shown_elsewhere.contains(&t.id) && !fronts.contains(&t.id)
            })
            .collect();
        live.sort_by_key(|t| (t.last_used_ms(), t.id));

        let mut sleepers = Vec::new();
        let mut remaining = live.len();
        for t in live {
            if t.audible || self.stays_awake(t) {
                continue;
            }
            let idle = now.saturating_sub(t.last_used_ms()) >= timeout_ms;
            if idle || remaining > max_live {
                sleepers.push(t.id);
                remaining -= 1;
            }
        }
        for id in &sleepers {
            if let Some(tab) = self.tabs.get_mut(id) {
                tab.live = false;
            }
        }
        sleepers
    }
}

// ------------------------------------------------------------- tree helpers

/// Returns `Some(parent folder)` if `id` is in the tree.
#[expect(clippy::option_option, reason = "None: not in the tree; Some(None): at the top level")]
fn find_parent(nodes: &[Node], id: Id, parent: Option<Id>) -> Option<Option<Id>> {
    for n in nodes {
        if n.id() == id {
            return Some(parent);
        }
        if let Node::Folder { id: fid, children, .. } = n {
            if let Some(p) = find_parent(children, id, Some(*fid)) {
                return Some(p);
            }
        }
    }
    None
}

fn find_node(nodes: &[Node], id: Id) -> Option<&Node> {
    for n in nodes {
        if n.id() == id {
            return Some(n);
        }
        if let Node::Folder { children, .. } = n {
            if let Some(found) = find_node(children, id) {
                return Some(found);
            }
        }
    }
    None
}

fn find_node_mut(nodes: &mut [Node], id: Id) -> Option<&mut Node> {
    for n in nodes {
        if n.id() == id {
            return Some(n);
        }
        if let Node::Folder { children, .. } = n {
            if let Some(found) = find_node_mut(children, id) {
                return Some(found);
            }
        }
    }
    None
}

fn folder_children_mut(nodes: &mut [Node], id: Id) -> Option<&mut Vec<Node>> {
    match find_node_mut(nodes, id)? {
        Node::Folder { children, .. } => Some(children),
        Node::Tab { .. } => None,
    }
}

/// Removes `id` from the tree. Returns the node, its index and its parent.
fn detach(nodes: &mut Vec<Node>, id: Id, parent: Option<Id>) -> Option<(Node, usize, Option<Id>)> {
    if let Some(i) = nodes.iter().position(|n| n.id() == id) {
        return Some((nodes.remove(i), i, parent));
    }
    for n in nodes.iter_mut() {
        if let Node::Folder { id: fid, children, .. } = n {
            let fid = *fid;
            if let Some(found) = detach(children, id, Some(fid)) {
                return Some(found);
            }
        }
    }
    None
}

pub fn collect_tabs(nodes: &[Node], out: &mut Vec<Id>) {
    for n in nodes {
        match n {
            Node::Tab { id } => out.push(*id),
            Node::Folder { children, .. } => collect_tabs(children, out),
        }
    }
}

// --------------------------------------------------------------- omnibox

/// Turns omnibox text into a URL: URLs and hostnames load directly,
/// everything else is searched.
/// The site a URL belongs to, as shown to people: the lowercase host
/// without "www.", user info or port ("mail.google.com"). Empty for URLs
/// without a host, such as about:blank.
/// `site` is one of `sites` or a subdomain of one.
pub fn covers(sites: &[String], site: &str) -> bool {
    !site.is_empty()
        && sites.iter().any(|s| site == s || site.strip_suffix(s.as_str()).is_some_and(|sub| sub.ends_with('.')))
}

pub fn site_of(url: &str) -> String {
    let Some((_, rest)) = url.split_once("://") else {
        return String::new();
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let host = host.split(':').next().unwrap_or(host).to_ascii_lowercase();
    host.strip_prefix("www.").map(str::to_string).unwrap_or(host)
}

pub fn resolve_input(text: &str, search_template: &str) -> String {
    let text = text.trim();
    if text.is_empty() {
        return String::new();
    }
    let has_scheme = text.split_once(':').is_some_and(|(scheme, rest)| {
        !scheme.is_empty()
            && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
            && scheme.starts_with(|c: char| c.is_ascii_alphabetic())
            && (rest.starts_with("//") || matches!(scheme, "about" | "data" | "mailto" | "javascript" | "view-source"))
    });
    if has_scheme {
        return text.to_string();
    }
    if !text.contains(char::is_whitespace) {
        let host = text.split(['/', '?', '#']).next().unwrap_or("");
        let host_no_port =
            host.rsplit_once(':').map_or(
                host,
                |(h, port)| {
                    if port.chars().all(|c| c.is_ascii_digit()) {
                        h
                    } else {
                        host
                    }
                },
            );
        let looks_like_host = host_no_port == "localhost"
            || host_no_port.parse::<std::net::Ipv4Addr>().is_ok()
            || (host_no_port.contains('.')
                && !host_no_port.starts_with('.')
                && !host_no_port.ends_with('.')
                && host_no_port
                    .rsplit('.')
                    .next()
                    .is_some_and(|tld| tld.len() >= 2 && tld.chars().all(char::is_alphabetic)));
        if looks_like_host {
            let scheme = if host_no_port == "localhost" || host_no_port.parse::<std::net::Ipv4Addr>().is_ok() {
                "http"
            } else {
                "https"
            };
            return format!("{scheme}://{text}");
        }
    }
    search_url(text, search_template)
}

/// A web search for `text`, whatever it looks like.
pub fn search_url(text: &str, search_template: &str) -> String {
    search_template.replace("%s", &percent_encode(text.trim()))
}

fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            b' ' => out.push('+'),
            _ => {
                let _ = write!(out, "%{b:02X}");
            }
        }
    }
    out
}
