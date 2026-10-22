use std::collections::{BTreeMap, HashMap};

const SET_TAB_WINDOW: u8 = 0;
const SET_TAB_INDEX_IN_WINDOW: u8 = 2;
const NAVIGATION_PRUNED_FROM_BACK: u8 = 5;
const UPDATE_TAB_NAVIGATION: u8 = 6;
const SET_SELECTED_NAVIGATION_INDEX: u8 = 7;
const SET_WINDOW_TYPE: u8 = 9;
const NAVIGATION_PRUNED_FROM_FRONT: u8 = 11;
const SET_PINNED_STATE: u8 = 12;
const TAB_CLOSED: u8 = 16;
const WINDOW_CLOSED: u8 = 17;

const WINDOW_TYPE_NORMAL: i32 = 0;

#[derive(Debug, Clone, PartialEq)]
pub struct SessionTab {
    pub url: String,
    pub title: String,
    pub pinned: bool,
}

#[derive(Default)]
struct TabState {
    window: i32,
    index: i32,
    pinned: bool,
    selected: Option<i32>,
    navigations: BTreeMap<i32, (String, String)>,
}

fn i32_at(b: &[u8], at: usize) -> Option<i32> {
    Some(i32::from_le_bytes(b.get(at..at + 4)?.try_into().ok()?))
}

fn parse_navigation(p: &[u8]) -> Option<(i32, i32, String, String)> {
    let tab = i32_at(p, 4)?;
    let index = i32_at(p, 8)?;
    let url_len = usize::try_from(i32_at(p, 12)?).ok()?;
    let url = String::from_utf8_lossy(p.get(16..16 + url_len)?).into_owned();
    let at = 16 + url_len.next_multiple_of(4);
    let title_len = usize::try_from(i32_at(p, at)?).ok()?;
    let units: Vec<u16> =
        p.get(at + 4..at + 4 + title_len * 2)?.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
    Some((tab, index, url, String::from_utf16_lossy(&units)))
}

pub fn parse(data: &[u8]) -> Option<Vec<SessionTab>> {
    if data.get(..4)? != b"SNSS" {
        return None;
    }
    let mut tabs: HashMap<i32, TabState> = HashMap::new();
    let mut window_types: HashMap<i32, i32> = HashMap::new();
    let mut window_order: Vec<i32> = Vec::new();
    let mut closed_windows: Vec<i32> = Vec::new();

    let mut at = 8;
    while let Some(size) = data.get(at..at + 2) {
        let size = u16::from_le_bytes([size[0], size[1]]) as usize;
        at += 2;
        let Some(record) = data.get(at..at + size) else { break };
        at += size;
        let Some((&id, p)) = record.split_first() else { continue };
        match id {
            SET_TAB_WINDOW => {
                if let (Some(window), Some(tab)) = (i32_at(p, 0), i32_at(p, 4)) {
                    tabs.entry(tab).or_default().window = window;
                    if !window_order.contains(&window) {
                        window_order.push(window);
                    }
                }
            }
            SET_TAB_INDEX_IN_WINDOW => {
                if let (Some(tab), Some(index)) = (i32_at(p, 0), i32_at(p, 4)) {
                    tabs.entry(tab).or_default().index = index;
                }
            }
            UPDATE_TAB_NAVIGATION => {
                if let Some((tab, index, url, title)) = parse_navigation(p) {
                    tabs.entry(tab).or_default().navigations.insert(index, (url, title));
                }
            }
            SET_SELECTED_NAVIGATION_INDEX => {
                if let (Some(tab), Some(index)) = (i32_at(p, 0), i32_at(p, 4)) {
                    tabs.entry(tab).or_default().selected = Some(index);
                }
            }
            NAVIGATION_PRUNED_FROM_BACK => {
                if let (Some(tab), Some(index)) = (i32_at(p, 0), i32_at(p, 4)) {
                    if let Some(t) = tabs.get_mut(&tab) {
                        t.navigations.retain(|&i, _| i < index);
                    }
                }
            }
            NAVIGATION_PRUNED_FROM_FRONT => {
                if let (Some(tab), Some(count)) = (i32_at(p, 0), i32_at(p, 4)) {
                    if let Some(t) = tabs.get_mut(&tab) {
                        t.navigations = std::mem::take(&mut t.navigations)
                            .into_iter()
                            .filter(|&(i, _)| i >= count)
                            .map(|(i, v)| (i - count, v))
                            .collect();
                        t.selected = t.selected.map(|s| (s - count).max(0));
                    }
                }
            }
            SET_WINDOW_TYPE => {
                if let (Some(window), Some(kind)) = (i32_at(p, 0), i32_at(p, 4)) {
                    window_types.insert(window, kind);
                }
            }
            SET_PINNED_STATE => {
                if let (Some(tab), Some(&pinned)) = (i32_at(p, 0), p.get(4)) {
                    tabs.entry(tab).or_default().pinned = pinned != 0;
                }
            }
            TAB_CLOSED => {
                if let Some(tab) = i32_at(p, 0) {
                    tabs.remove(&tab);
                }
            }
            WINDOW_CLOSED => {
                if let Some(window) = i32_at(p, 0) {
                    closed_windows.push(window);
                }
            }
            _ => {}
        }
    }

    let mut open: Vec<(usize, i32, SessionTab)> = Vec::new();
    for t in tabs.into_values() {
        let normal = window_types.get(&t.window).is_none_or(|&k| k == WINDOW_TYPE_NORMAL);
        if !normal || closed_windows.contains(&t.window) {
            continue;
        }
        let current = t.selected.and_then(|s| t.navigations.get(&s)).or_else(|| t.navigations.values().next_back());
        let Some((url, title)) = current else { continue };
        let window_rank = window_order.iter().position(|&w| w == t.window).unwrap_or(usize::MAX);
        open.push((window_rank, t.index, SessionTab { url: url.clone(), title: title.clone(), pinned: t.pinned }));
    }
    open.sort_by_key(|(window, index, _)| (*window, *index));
    Some(open.into_iter().map(|(_, _, tab)| tab).collect())
}
