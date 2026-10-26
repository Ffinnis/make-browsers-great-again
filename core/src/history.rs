use serde::{Deserialize, Serialize};

const MAX_ENTRIES: usize = 2000;
const DAY_MS: f64 = 86_400_000.0;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Visit {
    pub url: String,
    pub title: String,
    pub count: u32,
    pub last_ms: u64,
}

#[derive(Serialize, Deserialize, Default, Debug)]
pub struct History {
    pub visits: Vec<Visit>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Match {
    pub url: String,
    pub title: String,
    pub site_prefix: bool,
}

impl History {
    pub fn record(&mut self, url: &str, now: u64) {
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            return;
        }
        if let Some(v) = self.visits.iter_mut().find(|v| v.url == url) {
            v.count += 1;
            v.last_ms = now;
            return;
        }
        self.visits.push(Visit { url: url.to_string(), title: String::new(), count: 1, last_ms: now });
        if self.visits.len() > MAX_ENTRIES {
            if let Some(worst) = (0..self.visits.len())
                .min_by(|&a, &b| score(&self.visits[a], now).total_cmp(&score(&self.visits[b], now)))
            {
                self.visits.swap_remove(worst);
            }
        }
    }

    pub fn clear(&mut self) {
        self.visits.clear();
    }

    pub fn set_title(&mut self, url: &str, title: &str) {
        if let Some(v) = self.visits.iter_mut().find(|v| v.url == url) {
            v.title = title.to_string();
        }
    }

    pub fn recent(&self, limit: usize) -> Vec<Match> {
        let mut visits: Vec<&Visit> = self.visits.iter().collect();
        visits.sort_by(|a, b| b.last_ms.cmp(&a.last_ms));
        visits
            .into_iter()
            .take(limit)
            .map(|v| Match { url: v.url.clone(), title: v.title.clone(), site_prefix: false })
            .collect()
    }

    pub fn suggest(&self, query: &str, limit: usize, now: u64) -> Vec<Match> {
        let query = query.trim().to_lowercase();
        let words: Vec<&str> = query.split_whitespace().collect();
        if words.is_empty() {
            return Vec::new();
        }
        let mut ranked: Vec<(f64, Match)> = self
            .visits
            .iter()
            .filter_map(|v| {
                let address = strip_scheme(&v.url).to_lowercase();
                let title = v.title.to_lowercase();
                if !words.iter().all(|w| address.contains(w) || title.contains(w)) {
                    return None;
                }
                let site_prefix = address.starts_with(&query);
                let bonus = if site_prefix { 1000.0 } else { 0.0 };
                Some((score(v, now) + bonus, Match { url: v.url.clone(), title: v.title.clone(), site_prefix }))
            })
            .collect();
        ranked.sort_by(|a, b| b.0.total_cmp(&a.0));
        ranked.into_iter().map(|(_, m)| m).take(limit).collect()
    }
}

#[expect(clippy::cast_precision_loss, reason = "an age in milliseconds is far below 2^52")]
fn score(v: &Visit, now: u64) -> f64 {
    let days = now.saturating_sub(v.last_ms) as f64 / DAY_MS;
    (1.0 + f64::from(v.count)).ln() * 10.0 / (1.0 + days / 14.0)
}

fn strip_scheme(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    rest.strip_prefix("www.").unwrap_or(rest)
}
