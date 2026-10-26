use serde::{Deserialize, Serialize};

const MAX_ENTRIES: usize = 25;

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct PageState {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub back: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub forward: Vec<String>,
    #[serde(default)]
    pub scroll_y: f64,
    #[serde(skip)]
    pub editing: bool,
    #[serde(skip)]
    older: Vec<String>,
    #[serde(skip)]
    newer: Vec<String>,
    #[serde(skip)]
    restoring: bool,
    #[serde(skip)]
    scroll_pending: bool,
    #[serde(skip)]
    last_url: String,
}

impl PageState {
    pub fn view_created(&mut self) {
        self.older.clone_from(&self.back);
        self.newer.clone_from(&self.forward);
        self.restoring = false;
        self.scroll_pending = self.scroll_y > 0.0;
        self.last_url.clear();
    }

    pub fn record(&mut self, url: &str, live_back: Vec<String>, live_forward: Vec<String>) {
        let moved = !self.last_url.is_empty() && self.last_url != url;
        if moved && live_forward.is_empty() && !self.restoring {
            self.newer.clear();
        }
        self.restoring = false;
        url.clone_into(&mut self.last_url);
        let mut back = self.older.clone();
        back.extend(live_back);
        let excess = back.len().saturating_sub(MAX_ENTRIES);
        back.drain(..excess);
        let mut forward = live_forward;
        forward.extend(self.newer.iter().cloned());
        forward.truncate(MAX_ENTRIES);
        self.back = back;
        self.forward = forward;
    }

    pub fn can_restore_back(&self) -> bool {
        !self.older.is_empty()
    }

    pub fn can_restore_forward(&self) -> bool {
        !self.newer.is_empty()
    }

    pub fn pop_older(&mut self, current: &str) -> Option<String> {
        let url = self.older.pop()?;
        self.newer.insert(0, current.to_string());
        self.restoring = true;
        Some(url)
    }

    pub fn pop_newer(&mut self) -> Option<String> {
        if self.newer.is_empty() {
            return None;
        }
        self.restoring = true;
        Some(self.newer.remove(0))
    }

    pub fn take_scroll(&mut self) -> Option<f64> {
        if !self.scroll_pending {
            return None;
        }
        self.scroll_pending = false;
        Some(self.scroll_y)
    }

    #[must_use]
    pub fn copied(&self) -> Self {
        Self { back: self.back.clone(), forward: self.forward.clone(), scroll_y: self.scroll_y, ..Self::default() }
    }
}
