use crate::model::{collect_tabs, Id, Profile, Space, State};
use crate::{fnv1a, BrowserCore};
use std::borrow::Cow;
use std::fs;
use std::path::{Path, PathBuf};

pub const PRIVATE_NAME: &str = "Private";
pub const PRIVATE_ICON: &str = "🕶️";
pub const PRIVATE_COLOR: u32 = 0x3F3F46;

pub(crate) fn favicon_dir(data_dir: &Path) -> PathBuf {
    std::env::temp_dir().join(format!("MBGA-private-{:016x}", fnv1a(&data_dir.to_string_lossy())))
}

impl State {
    pub fn is_ephemeral_space(&self, id: Id) -> bool {
        self.space(id).is_some_and(|s| s.ephemeral)
    }

    pub fn is_ephemeral_profile(&self, id: Id) -> bool {
        self.profiles.iter().any(|p| p.id == id && p.ephemeral)
    }

    pub fn is_ephemeral_tab(&self, id: Id) -> bool {
        self.profile_of_tab(id).is_some_and(|p| self.is_ephemeral_profile(p))
    }

    pub fn has_ephemeral(&self) -> bool {
        self.profiles.iter().any(|p| p.ephemeral)
    }

    pub fn open_private_space(&mut self) -> Id {
        let profile_id = self.alloc();
        self.profiles.push(Profile { id: profile_id, name: PRIVATE_NAME.into(), ephemeral: true });
        self.favorites.insert(profile_id, Vec::new());
        let id = self.alloc();
        self.spaces.push(Space {
            id,
            name: PRIVATE_NAME.into(),
            icon: PRIVATE_ICON.into(),
            color: PRIVATE_COLOR,
            profile_id,
            pinned: Vec::new(),
            today: Vec::new(),
            active_tab: None,
            ephemeral: true,
        });
        id
    }

    pub fn close_private_space(&mut self, id: Id) -> Option<Vec<Id>> {
        let index = self.spaces.iter().position(|s| s.id == id && s.ephemeral)?;
        let space = self.spaces.remove(index);
        let mut closed = space.today.clone();
        collect_tabs(&space.pinned, &mut closed);
        if !self.spaces.iter().any(|s| s.profile_id == space.profile_id) {
            self.profiles.retain(|p| p.id != space.profile_id);
            closed.extend(self.favorites.remove(&space.profile_id).unwrap_or_default());
        }
        for tab in &closed {
            self.tabs.remove(tab);
        }
        self.shown_elsewhere.retain(|t| !closed.contains(t));
        self.closed.retain(|c| c.space_id != id);
        if self.active_space == id {
            self.active_space = self.lasting_space();
        }
        Some(closed)
    }

    fn lasting_space(&self) -> Id {
        self.normal_space
            .filter(|s| self.space(*s).is_some_and(|s| !s.ephemeral))
            .or_else(|| self.spaces.iter().find(|s| !s.ephemeral).map(|s| s.id))
            .unwrap_or(self.active_space)
    }

    pub fn persisted(&self) -> Cow<'_, State> {
        if !self.has_ephemeral() {
            return Cow::Borrowed(self);
        }
        let mut kept = State { closed: Vec::new(), shown_elsewhere: Vec::new(), ..self.clone() };
        let mut gone = Vec::new();
        for space in kept.spaces.iter().filter(|s| s.ephemeral) {
            gone.extend(space.today.iter().copied());
            collect_tabs(&space.pinned, &mut gone);
        }
        for profile in self.profiles.iter().filter(|p| p.ephemeral) {
            gone.extend(kept.favorites.remove(&profile.id).unwrap_or_default());
        }
        for tab in &gone {
            kept.tabs.remove(tab);
        }
        kept.spaces.retain(|s| !s.ephemeral);
        kept.profiles.retain(|p| !p.ephemeral);
        if self.is_ephemeral_space(self.active_space) {
            kept.active_space = self.lasting_space();
        }
        Cow::Owned(kept)
    }
}

#[uniffi::export]
impl BrowserCore {
    pub fn open_private_space(&self) -> u64 {
        self.mutate(|s, _| s.open_private_space())
    }

    pub fn close_private_space(&self, id: u64) -> Vec<u64> {
        let closed = self.mutate(|s, _| s.close_private_space(id)).unwrap_or_default();
        let mut inner = self.lock();
        if !inner.state.has_ephemeral() {
            inner.downloads.forget_ephemeral();
            let _ = fs::remove_dir_all(favicon_dir(&inner.data_dir));
        }
        closed
    }

    pub fn is_private_tab(&self, id: u64) -> bool {
        self.lock().state.is_ephemeral_tab(id)
    }
}
