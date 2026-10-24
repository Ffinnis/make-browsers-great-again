use serde::{Deserialize, Serialize};

const MAX_ENTRIES: usize = 100;

#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum DownloadState {
    Running,
    Paused,
    Done,
    Failed,
    Canceled,
}

impl DownloadState {
    pub fn is_active(self) -> bool {
        matches!(self, DownloadState::Running | DownloadState::Paused)
    }
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Download {
    pub id: u64,
    pub url: String,
    pub path: String,
    pub received: u64,
    pub total: u64,
    pub state: DownloadState,
    pub started_ms: u64,
}

#[derive(Serialize, Deserialize, Default, Debug)]
pub struct Downloads {
    next_id: u64,
    items: Vec<Download>,
}

impl Downloads {
    pub fn items(&self) -> &[Download] {
        &self.items
    }

    pub fn start(&mut self, url: &str, path: &str, now: u64) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        self.items.insert(
            0,
            Download {
                id,
                url: url.to_string(),
                path: path.to_string(),
                received: 0,
                total: 0,
                state: DownloadState::Running,
                started_ms: now,
            },
        );
        self.trim();
        id
    }

    fn trim(&mut self) {
        while self.items.len() > MAX_ENTRIES {
            let Some(oldest) = self.items.iter().rposition(|d| !d.state.is_active()) else {
                break;
            };
            self.items.remove(oldest);
        }
    }

    pub fn update(&mut self, id: u64, path: &str, received: u64, total: u64, state: DownloadState) -> bool {
        let Some(d) = self.items.iter_mut().find(|d| d.id == id) else {
            return false;
        };
        if !d.state.is_active() {
            return false;
        }
        let lasting = d.state != state || (!path.is_empty() && d.path != path);
        if !path.is_empty() {
            d.path = path.to_string();
        }
        d.received = received;
        d.total = if state == DownloadState::Done && total == 0 { received } else { total };
        d.state = state;
        if !state.is_active() {
            self.trim();
        }
        lasting
    }

    pub fn remove(&mut self, id: u64) -> bool {
        let before = self.items.len();
        self.items.retain(|d| d.id != id || d.state.is_active());
        self.items.len() != before
    }

    pub fn clear(&mut self) -> bool {
        let before = self.items.len();
        self.items.retain(|d| d.state.is_active());
        self.items.len() != before
    }

    pub fn interrupt(&mut self) -> bool {
        let mut changed = false;
        for d in self.items.iter_mut().filter(|d| d.state.is_active()) {
            d.state = DownloadState::Failed;
            changed = true;
        }
        changed
    }
}
