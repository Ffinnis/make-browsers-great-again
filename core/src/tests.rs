use super::*;
use model::{resolve_input, Container, Pressure, State};

fn temp_dir(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("mbga-test-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir.to_string_lossy().into_owned()
}

fn home(s: &State) -> u64 {
    s.spaces[0].id
}

#[test]
fn default_state_has_one_space_and_profile() {
    let s = State::new_default();
    assert_eq!(s.spaces.len(), 1);
    assert_eq!(s.profiles.len(), 1);
    assert_eq!(s.active_space, home(&s));
}

#[test]
fn new_tabs_go_to_top_of_today_and_activate() {
    let mut s = State::new_default();
    let a = s.open_tab(home(&s), "https://a.com", true, 1).unwrap();
    let b = s.open_tab(home(&s), "https://b.com", true, 2).unwrap();
    assert_eq!(s.spaces[0].today, vec![b, a]);
    assert_eq!(s.visible_tab(), Some(b));
}

#[test]
fn closing_today_tab_selects_tab_below_then_above() {
    let mut s = State::new_default();
    let sp = home(&s);
    let a = s.open_tab(sp, "https://a.com", false, 1).unwrap();
    let b = s.open_tab(sp, "https://b.com", false, 2).unwrap();
    let c = s.open_tab(sp, "https://c.com", false, 3).unwrap();
    s.activate_tab(sp, b, 4);
    assert_eq!(s.close_tab(b, 5), (true, Some(a)));
    assert_eq!(s.close_tab(a, 6), (true, Some(c)));
    assert!(!s.tabs.contains_key(&a));
}

#[test]
fn closing_pinned_tab_sleeps_and_resets_url() {
    let mut s = State::new_default();
    let sp = home(&s);
    let t = s.open_tab(sp, "https://mail.com", true, 1).unwrap();
    s.move_item(t, Container::Pinned { space_id: sp, folder_id: None }, 0).unwrap();
    s.set_live(t, true, 0);
    s.update_tab(t, Some("https://mail.com/inbox/123"), None);
    assert!(!s.close_tab(t, 2).0);
    let tab = &s.tabs[&t];
    assert_eq!(tab.url, "https://mail.com");
    assert!(!tab.live);
    assert!(s.spaces[0].active_tab.is_none());
}

#[test]
fn favorites_are_shared_by_spaces_with_the_same_profile() {
    let mut s = State::new_default();
    let p = s.profiles[0].id;
    let work_profile = s.create_profile("Work");
    let sp2 = s.create_space("Side", "✨", 0, p);
    let sp3 = s.create_space("Work", "💼", 0, work_profile);
    let t = s.open_tab(home(&s), "https://x.com", false, 1).unwrap();
    s.move_item(t, Container::Favorites { profile_id: p }, 0).unwrap();
    assert_eq!(s.profile_of_tab(t), Some(p));
    assert!(s.favorites[&p].contains(&t));
    assert_eq!(s.space(sp2).unwrap().profile_id, p);
    assert_ne!(s.space(sp3).unwrap().profile_id, p);
}

#[test]
fn moving_tab_to_other_profile_requires_reload() {
    let mut s = State::new_default();
    let work = s.create_profile("Work");
    let sp2 = s.create_space("Work", "💼", 0, work);
    let t = s.open_tab(home(&s), "https://x.com", true, 1).unwrap();
    s.set_live(t, true, 0);
    let reload = s.move_item(t, Container::Today { space_id: sp2 }, 0).unwrap();
    assert_eq!(reload, vec![t]);
    assert!(!s.tabs[&t].live);
    assert!(s.spaces[0].active_tab.is_none());
}

#[test]
fn folders_nest_and_cannot_contain_themselves() {
    let mut s = State::new_default();
    let sp = home(&s);
    let outer = s.create_folder(sp, "Outer", None).unwrap();
    let inner = s.create_folder(sp, "Inner", Some(outer)).unwrap();
    let t = s.open_tab(sp, "https://x.com", false, 1).unwrap();
    s.move_item(t, Container::Pinned { space_id: sp, folder_id: Some(inner) }, 0).unwrap();
    assert_eq!(s.locate(t), Some(Container::Pinned { space_id: sp, folder_id: Some(inner) }));
    assert!(s.move_item(outer, Container::Pinned { space_id: sp, folder_id: Some(inner) }, 0).is_none());
    assert!(s.move_item(outer, Container::Today { space_id: sp }, 0).is_none());
    assert_eq!(s.delete_folder(outer), vec![t]);
    assert!(s.tabs.is_empty());
}

#[test]
fn reorder_within_list_uses_pre_removal_index() {
    let mut s = State::new_default();
    let sp = home(&s);
    let a = s.open_tab(sp, "a", false, 1).unwrap();
    let b = s.open_tab(sp, "b", false, 2).unwrap();
    let c = s.open_tab(sp, "c", false, 3).unwrap();
    s.move_item(c, Container::Today { space_id: sp }, 3).unwrap();
    assert_eq!(s.spaces[0].today, vec![b, a, c]);
    s.move_item(a, Container::Today { space_id: sp }, 0).unwrap();
    assert_eq!(s.spaces[0].today, vec![a, b, c]);
}

#[test]
fn sleeps_idle_and_excess_tabs_but_never_visible_or_audible() {
    let mut s = State::new_default();
    let sp = home(&s);
    s.policy.max_live_tabs = 2;
    s.policy.sleep_after_secs = 60;
    let mut ids = Vec::new();
    for i in 0..5 {
        let id = s.open_tab(sp, &format!("https://{i}.com"), true, 1_000 + i).unwrap();
        s.set_live(id, true, 0);
        ids.push(id);
    }
    s.set_audible(ids[0], true);
    let sleepers = s.collect_sleepers(2_000, Pressure::Normal);
    assert_eq!(sleepers, vec![ids[1], ids[2]]);
    let sleepers = s.collect_sleepers(1_000 + 61_000 + 10, Pressure::Normal);
    assert_eq!(sleepers, vec![ids[3]]);
    assert!(s.tabs[&ids[4]].live);
    assert!(s.tabs[&ids[0]].live);
}

#[test]
fn sleeping_can_be_turned_off_but_memory_pressure_still_sleeps() {
    let mut s = State::new_default();
    let sp = home(&s);
    s.policy.sleep_after_secs = 0;
    s.policy.max_live_tabs = 0;
    let mut ids = Vec::new();
    for i in 0..40 {
        let id = s.open_tab(sp, &format!("https://{i}.com"), true, i).unwrap();
        s.set_live(id, true, 0);
        ids.push(id);
    }
    assert!(s.collect_sleepers(u64::MAX / 2, Pressure::Normal).is_empty());
    assert_eq!(s.collect_sleepers(100, Pressure::Warning).len(), 39 - 12);
    assert_eq!(s.collect_sleepers(100, Pressure::Critical).len(), 12);
}

#[test]
fn critical_pressure_sleeps_everything_hidden() {
    let mut s = State::new_default();
    let sp = home(&s);
    let a = s.open_tab(sp, "a", true, 1).unwrap();
    let b = s.open_tab(sp, "b", true, 2).unwrap();
    s.set_live(a, true, 0);
    s.set_live(b, true, 0);
    assert_eq!(s.collect_sleepers(3, Pressure::Critical), vec![a]);
}

#[test]
fn switching_profile_of_space_sleeps_its_live_tabs() {
    let mut s = State::new_default();
    let sp = home(&s);
    let work = s.create_profile("Work");
    let a = s.open_tab(sp, "a", true, 1).unwrap();
    s.set_live(a, true, 0);
    assert_eq!(s.set_space_profile(sp, work), vec![a]);
    assert_eq!(s.profile_of_tab(a), Some(work));
    assert!(s.delete_profile(work).is_none());
}

#[test]
fn omnibox_input_resolution() {
    let t = "https://s.test/?q=%s";
    assert_eq!(resolve_input("example.com", t), "https://example.com");
    assert_eq!(resolve_input("example.com/a?b=c", t), "https://example.com/a?b=c");
    assert_eq!(resolve_input("localhost:3000", t), "http://localhost:3000");
    assert_eq!(resolve_input("192.168.1.1", t), "http://192.168.1.1");
    assert_eq!(resolve_input("http://x", t), "http://x");
    assert_eq!(resolve_input("about:blank", t), "about:blank");
    assert_eq!(resolve_input("rust lifetimes", t), "https://s.test/?q=rust+lifetimes");
    assert_eq!(resolve_input("c++", t), "https://s.test/?q=c%2B%2B");
    assert_eq!(resolve_input("file.txt", t), "https://file.txt");
    assert_eq!(resolve_input("version1.2", t), "https://s.test/?q=version1.2");
}

#[test]
fn persists_and_reloads_through_ffi() {
    let dir = temp_dir("persist");
    let core = BrowserCore::new(dir.clone());
    let snap = core.snapshot();
    let sp = snap.active_space;
    let t = core.open_tab(sp, "https://keep.me".into(), true).unwrap();
    core.update_tab(t, None, Some("Keep".into()));
    let f = core.create_folder(sp, "Docs".into(), None).unwrap();
    core.move_item(t, DropTarget::Pinned { space_id: sp, folder_id: Some(f) }, 0).unwrap();
    core.set_live(t, true);
    assert!(core.persist());
    drop(core);

    let core = BrowserCore::new(dir.clone());
    let snap = core.snapshot();
    let space = &snap.spaces[0];
    assert_eq!(space.pinned.len(), 2);
    assert_eq!(space.pinned[0].folder_name.as_deref(), Some("Docs"));
    let row = &space.pinned[1];
    assert_eq!(row.depth, 1);
    assert_eq!(row.parent_id, Some(f));
    let tab = row.tab.as_ref().unwrap();
    assert_eq!(tab.title, "Keep");
    assert_eq!(tab.pinned_url.as_deref(), Some("https://keep.me"));
    assert!(!tab.live, "tabs always start asleep");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn corrupt_state_is_backed_up() {
    let dir = temp_dir("corrupt");
    fs::create_dir_all(&dir).unwrap();
    fs::write(Path::new(&dir).join(STATE_FILE), b"{not json").unwrap();
    let core = BrowserCore::new(dir.clone());
    assert_eq!(core.snapshot().spaces.len(), 1);
    let backups = fs::read_dir(&dir)
        .unwrap()
        .filter(|e| e.as_ref().unwrap().file_name().to_string_lossy().contains("corrupt"))
        .count();
    assert_eq!(backups, 1);
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn profile_dirs_are_direct_children_of_engine_root() {
    let dir = temp_dir("profiles");
    let core = BrowserCore::new(dir.clone());
    let profile = core.snapshot().profiles[0].id;
    let path = PathBuf::from(core.profile_dir(profile));
    assert_eq!(path.parent().unwrap(), Path::new(&core.engine_root_dir()));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn freezes_only_idle_hidden_today_tabs() {
    let mut s = State::new_default();
    let sp = home(&s);
    s.policy.freeze_after_secs = 60;
    let pinned = s.open_tab(sp, "https://mail.example", true, 0).unwrap();
    s.move_item(pinned, Container::Pinned { space_id: sp, folder_id: None }, 0).unwrap();
    let old = s.open_tab(sp, "https://a.example", true, 1_000).unwrap();
    let audible = s.open_tab(sp, "https://music.example", true, 2_000).unwrap();
    let visible = s.open_tab(sp, "https://b.example", true, 3_000).unwrap();
    for id in [pinned, old, audible, visible] {
        s.set_live(id, true, 0);
    }
    s.set_audible(audible, true);
    assert!(s.collect_freezers(30_000).is_empty());
    assert_eq!(s.collect_freezers(70_000), vec![old]);
    assert!(s.collect_freezers(80_000).is_empty(), "already frozen");
    assert!(s.thaw(old));
    assert!(!s.thaw(old));
    s.collect_freezers(90_000);
    s.set_live(old, false, 0);
    s.set_live(old, true, 0);
    assert!(!s.tabs[&old].frozen);
    let _ = visible;
}

#[test]
fn old_state_files_get_default_policy_fields() {
    let json = r#"{"sleep_after_secs": 30, "max_live_tabs": 2}"#;
    let p: model::Policy = serde_json::from_str(json).unwrap();
    assert_eq!(p.sleep_after_secs, 30);
    assert_eq!(p.freeze_after_secs, model::Policy::default().freeze_after_secs);
    assert!(!p.strict_site_isolation);
}

#[test]
fn states_with_the_first_sleep_defaults_get_the_current_ones() {
    let json = r#"{"sleep_after_secs": 600, "max_live_tabs": 8, "freeze_after_secs": 60, "archive_after_hours": 12}"#;
    let mut p: model::Policy = serde_json::from_str(json).unwrap();
    p.upgrade_first_defaults();
    let current = model::Policy::default();
    assert_eq!(
        (p.sleep_after_secs, p.max_live_tabs, p.freeze_after_secs),
        (current.sleep_after_secs, current.max_live_tabs, current.freeze_after_secs)
    );
    assert_eq!(p.archive_after_hours, 12, "other choices are kept");
    let mut chosen: model::Policy = serde_json::from_str(r#"{"sleep_after_secs": 900, "max_live_tabs": 8}"#).unwrap();
    chosen.upgrade_first_defaults();
    assert_eq!(chosen.sleep_after_secs, 900);
}

#[test]
fn each_spaces_current_tab_and_freshly_loaded_tabs_stay_awake() {
    let mut s = State::new_default();
    let home = home(&s);
    let front = s.open_tab(home, "https://front.com", true, 0).unwrap();
    s.set_live(front, true, 0);
    let other = s.create_space("Other", "", 0, s.spaces[0].profile_id);
    let shown = s.open_tab(other, "https://shown.com", true, 0).unwrap();
    s.set_live(shown, true, 0);
    s.set_active_space(other, 0);
    let hour = 3_600_000;
    let later = 10 * hour;
    assert!(s.collect_sleepers(later, model::Pressure::Normal).is_empty());
    let warmed = s.open_tab(home, "https://warmed.com", false, 0).unwrap();
    s.set_live(warmed, true, later);
    assert!(s.collect_sleepers(later + hour, model::Pressure::Normal).is_empty());
    assert_eq!(s.collect_sleepers(later + 3 * hour, model::Pressure::Normal), vec![warmed]);
    assert_eq!(s.collect_sleepers(later + 3 * hour, model::Pressure::Critical), vec![front]);
}

#[test]
fn engine_paths_are_resolved_through_symlinks() {
    let real = temp_dir("real");
    let link = temp_dir("link");
    fs::create_dir_all(&real).unwrap();
    let _ = fs::remove_file(&link);
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let core = BrowserCore::new(link.clone());
    let root = PathBuf::from(core.engine_root_dir());
    assert_eq!(root, fs::canonicalize(&real).unwrap().join("engine"));
    let _ = fs::remove_file(&link);
    let _ = fs::remove_dir_all(real);
}

#[test]
fn only_new_state_needs_onboarding() {
    assert!(!State::new_default().onboarded);
    let mut v = serde_json::to_value(State::new_default()).unwrap();
    v.as_object_mut().unwrap().remove("onboarded");
    let old: State = serde_json::from_value(v).unwrap();
    assert!(old.onboarded);
}

#[test]
fn kept_awake_sites_never_sleep_or_freeze() {
    let mut s = State::new_default();
    let sp = home(&s);
    let mail = s.open_tab(sp, "https://Mail.example.com/inbox", false, 1).unwrap();
    let news = s.open_tab(sp, "https://news.example.com", false, 1).unwrap();
    let visible = s.open_tab(sp, "https://other.example.com", true, 1).unwrap();
    for id in [mail, news, visible] {
        s.set_live(id, true, 0);
    }
    s.set_keep_awake("https://www.mail.example.com/settings", true);
    assert!(s.keeps_awake("https://mail.example.com:443/x"));
    assert_eq!(s.collect_freezers(10_000_000), vec![news]);
    assert_eq!(s.collect_sleepers(10_000_000, Pressure::Critical), vec![news]);
    s.set_keep_awake("https://mail.example.com", false);
    assert!(s.keep_awake.is_empty());
}

#[test]
fn sites_kept_awake_in_settings_cover_their_subdomains() {
    let mut s = State::new_default();
    s.set_keep_awake_sites(&[
        " Slack.com ".into(),
        "https://www.mail.google.com/inbox".into(),
        String::new(),
        "slack.com".into(),
    ]);
    assert_eq!(s.keep_awake, vec!["slack.com", "mail.google.com"]);
    assert!(s.keeps_awake("https://app.slack.com/client"));
    assert!(s.keeps_awake("https://mail.google.com/"));
    assert!(!s.keeps_awake("https://notslack.com"));
    assert!(!s.keeps_awake("https://docs.google.com"));
    let sp = home(&s);
    let chat = s.open_tab(sp, "https://app.slack.com", false, 0).unwrap();
    let news = s.open_tab(sp, "https://news.example.com", false, 0).unwrap();
    s.open_tab(sp, "https://other.example.com", true, 0).unwrap();
    for id in [chat, news] {
        s.set_live(id, true, 0);
    }
    assert_eq!(s.collect_freezers(10_000_000), vec![news]);
    s.set_keep_awake("https://app.slack.com", false);
    assert_eq!(s.keep_awake, vec!["mail.google.com"]);
}

#[test]
fn tabs_kept_always_awake_never_sleep_freeze_or_archive() {
    let hour = 3_600_000;
    let mut s = State::new_default();
    let sp = home(&s);
    let kept = s.open_tab(sp, "https://news.example.com/a", false, 0).unwrap();
    let other = s.open_tab(sp, "https://news.example.com/b", false, 0).unwrap();
    let visible = s.open_tab(sp, "https://other.example.com", true, 0).unwrap();
    for id in [kept, other, visible] {
        s.set_live(id, true, 0);
    }
    s.set_always_awake(kept, true);
    assert_eq!(s.always_awake_tabs(), vec![kept]);
    assert_eq!(s.collect_freezers(30 * hour), vec![other]);
    assert_eq!(s.idle_today(sp, 24, 30 * hour), vec![other]);
    assert_eq!(s.collect_sleepers(30 * hour, Pressure::Critical), vec![other]);
    let saved: State = serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
    assert!(saved.tabs[&kept].always_awake, "the choice is saved");
    s.set_always_awake(kept, false);
    assert_eq!(s.collect_sleepers(30 * hour, Pressure::Critical), vec![kept]);
}

#[test]
fn site_of_strips_www_port_and_user() {
    assert_eq!(model::site_of("https://user:pw@WWW.Example.com:8080/a?b"), "example.com");
    assert_eq!(model::site_of("about:blank"), "");
}

#[test]
fn history_ranks_sites_starting_with_the_query_first() {
    use history::History;
    let day = 86_400_000;
    let mut h = History::default();
    for _ in 0..30 {
        h.record("https://news.example.com/github-trends", 10 * day);
    }
    h.record("https://github.com/rust-lang/rust", 40 * day);
    h.record("about:blank", 40 * day);
    h.set_title("https://github.com/rust-lang/rust", "rust-lang/rust");
    let found = h.suggest("git", 5, 40 * day);
    assert_eq!(found[0].url, "https://github.com/rust-lang/rust");
    assert!(found[0].site_prefix);
    assert_eq!(found.len(), 2);
    assert!(h.suggest("rust lang", 5, 40 * day).iter().any(|m| m.title == "rust-lang/rust"));
    assert!(h.suggest("blank", 5, 40 * day).is_empty());
}

#[test]
fn frequent_visits_last_month_beat_one_visit_today() {
    use history::History;
    let day = 86_400_000;
    let mut h = History::default();
    for i in 0..30 {
        h.record("https://daily.example.com/", i * day);
    }
    h.record("https://once.example.com/", 60 * day);
    let found = h.suggest("example", 2, 60 * day);
    assert_eq!(found[0].url, "https://daily.example.com/");
}

#[test]
fn navigations_are_recorded_in_history_and_persisted() {
    let dir = temp_dir("history");
    let core = BrowserCore::new(dir.clone());
    let space = core.snapshot().spaces[0].id;
    let tab = core.open_tab(space, "https://a.example.com/".into(), true).unwrap();
    core.update_tab(tab, Some("https://b.example.com/page".into()), None);
    core.update_tab(tab, None, Some("Page B".into()));
    assert!(core.persist());
    let reopened = BrowserCore::new(dir.clone());
    let found = reopened.suggest_history("b.ex".into(), 5);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].title, "Page B");
    assert_eq!(reopened.suggest_history("a.example".into(), 5).len(), 1);
    reopened.clear_history();
    assert!(reopened.suggest_history("b.ex".into(), 5).is_empty());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn closing_clearing_and_deleting_folders_can_be_undone() {
    let mut s = State::new_default();
    let sp = home(&s);
    let a = s.open_tab(sp, "https://a.com", false, 1).unwrap();
    let b = s.open_tab(sp, "https://b.com", false, 2).unwrap();
    let c = s.open_tab(sp, "https://c.com", false, 3).unwrap();
    s.close_tab(b, 4);
    assert_eq!(s.reopen_last(), Some((sp, vec![b])));
    assert_eq!(s.spaces[0].today, vec![c, b, a]);

    s.clear_today(sp);
    assert!(s.spaces[0].today.is_empty());
    assert_eq!(s.closed_tabs().map(|t| t.id).collect::<Vec<_>>(), vec![c, b, a]);
    assert_eq!(s.reopen_last(), Some((sp, vec![c, b, a])));
    assert_eq!(s.spaces[0].today, vec![c, b, a]);
    assert!(!s.tabs[&a].live);

    let folder = s.create_folder(sp, "F", None).unwrap();
    s.move_item(a, Container::Pinned { space_id: sp, folder_id: Some(folder) }, 0);
    s.delete_folder(folder);
    assert!(!s.tabs.contains_key(&a));
    assert_eq!(s.reopen_last(), Some((sp, vec![a])));
    assert_eq!(s.locate(a), Some(Container::Pinned { space_id: sp, folder_id: Some(folder) }));
    assert!(s.reopen_last().is_none());
}

#[test]
fn one_closed_tab_can_be_reopened_from_a_cleared_list() {
    let mut s = State::new_default();
    let sp = home(&s);
    let a = s.open_tab(sp, "https://a.com", false, 1).unwrap();
    let b = s.open_tab(sp, "https://b.com", false, 2).unwrap();
    s.clear_today(sp);
    assert_eq!(s.reopen_tab(a), Some(sp));
    assert_eq!(s.spaces[0].today, vec![a]);
    assert_eq!(s.closed_tabs().map(|t| t.id).collect::<Vec<_>>(), vec![b]);
    assert_eq!(s.reopen_last(), Some((sp, vec![b])));
    assert_eq!(s.spaces[0].today, vec![b, a]);
}

#[test]
fn only_so_many_closes_are_remembered() {
    let mut s = State::new_default();
    let sp = home(&s);
    for i in 0..(model::MAX_CLOSED as u64 + 5) {
        let t = s.open_tab(sp, "https://a.com", false, i).unwrap();
        s.close_tab(t, i);
    }
    assert_eq!(s.closed.len(), model::MAX_CLOSED);
}

#[test]
fn idle_today_tabs_are_archived_by_policy_and_restorable() {
    let hour = 3_600_000;
    let mut s = State::new_default();
    let sp = home(&s);
    let old = s.open_tab(sp, "https://old.com", false, 0).unwrap();
    let kept = s.open_tab(sp, "https://mail.example.com", false, 0).unwrap();
    let fresh = s.open_tab(sp, "https://fresh.com", false, 30 * hour).unwrap();
    s.set_keep_awake("https://mail.example.com", true);
    assert_eq!(s.idle_today(sp, 24, 30 * hour), vec![old]);
    assert!(s.archive_by_policy(30 * hour).is_empty(), "off by default");
    s.policy.archive_after_hours = 24;
    assert_eq!(s.archive_by_policy(30 * hour), vec![old]);
    assert_eq!(s.spaces[0].today, vec![fresh, kept]);
    assert_eq!(s.reopen_last(), Some((sp, vec![old])));
    assert_eq!(s.spaces[0].today, vec![fresh, kept, old]);
}

#[test]
fn blocker_cancels_matching_requests_except_on_allowed_sites() {
    let mut b = blocker::Blocker::from_rules(
        "||ads.example.net^\n||tracker.example.org^$third-party\nnews.example.com##.ad-slot\n",
    );
    let page = "https://news.example.com/story";
    assert!(b.should_block("https://ads.example.net/banner.js", page, "script"));
    assert!(b.should_block("https://tracker.example.org/p.gif", page, "image"));
    assert!(!b.should_block("https://cdn.example.com/app.js", page, "script"));
    assert!(b.page_script(page).contains(".ad-slot{display:none!important}"));
    b.allowed.insert("news.example.com".into());
    assert!(!b.should_block("https://ads.example.net/banner.js", page, "script"));
    assert!(b.page_script(page).is_empty());
    b.allowed.clear();
    b.enabled = false;
    assert!(!b.should_block("https://ads.example.net/banner.js", page, "script"));
}

#[test]
fn blocker_compiles_lists_once_and_loads_the_cache() {
    let dir = PathBuf::from(temp_dir("filters"));
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join(blocker::LISTS[0].0), "||ads.example.net^\n").unwrap();
    let mut first = blocker::Blocker::new(true, []);
    assert!(!first.load_cached(&dir), "nothing compiled yet");
    assert!(first.load(&dir));
    assert!(dir.join("engine.dat").exists());
    let mut cached = blocker::Blocker::new(true, []);
    assert!(cached.load_cached(&dir));
    assert!(cached.should_block("https://ads.example.net/x.js", "https://a.com/", "script"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn video_conversion_is_on_until_turned_off() {
    let dir = temp_dir("convert-video");
    let core = BrowserCore::new(dir.clone());
    assert!(core.snapshot().convert_video);
    core.set_convert_video(false);
    assert!(core.persist());
    assert!(!BrowserCore::new(dir.clone()).snapshot().convert_video);
    let mut saved = serde_json::to_value(State::new_default()).unwrap();
    saved.as_object_mut().unwrap().remove("convert_video").unwrap();
    let state: State = serde_json::from_value(saved).unwrap();
    assert!(state.convert_video);
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn ad_settings_survive_a_restart() {
    let dir = temp_dir("ads");
    let core = BrowserCore::new(dir.clone());
    assert!(core.snapshot().block_ads);
    core.set_ads_allowed("https://www.example.com/a".into(), true);
    core.set_block_ads(false);
    assert!(core.persist());
    let reopened = BrowserCore::new(dir.clone());
    assert!(!reopened.snapshot().block_ads);
    fs::create_dir_all(reopened.filter_dir()).unwrap();
    fs::write(Path::new(&reopened.filter_dir()).join(blocker::LISTS[0].0), "||ads.example.net^\n").unwrap();
    assert!(!reopened.load_filters());
    reopened.set_block_ads(true);
    assert!(reopened.load_filters());
    assert!(reopened.should_block("https://ads.example.net/a.js".into(), "https://b.com/".into(), "script".into()));
    let space = reopened.snapshot().spaces[0].id;
    let tab = reopened.open_tab(space, "https://example.com/b".into(), false).unwrap();
    assert!(reopened.tab(tab).unwrap().ads_allowed);
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn tabs_in_little_windows_stay_awake_and_the_main_window_moves_on() {
    let mut s = State::new_default();
    let sp = home(&s);
    let a = s.open_tab(sp, "https://a.com", false, 1).unwrap();
    let b = s.open_tab(sp, "https://b.com", true, 2).unwrap();
    for id in [a, b] {
        s.set_live(id, true, 0);
    }
    assert_eq!(s.step_away(b, 3), Some(a));
    assert_eq!(s.visible_tab(), Some(a));
    s.shown_elsewhere.push(b);
    assert!(s.collect_sleepers(10_000_000, Pressure::Critical).is_empty());
    assert!(s.collect_freezers(10_000_000).is_empty());
    assert_eq!(s.step_away(b, 4), None, "b is no longer the visible tab");
}

#[test]
fn generic_hiding_rules_follow_the_names_a_page_reports() {
    let b = blocker::Blocker::from_rules("##.generic-ad\n###top-banner\n@@||quiet.example^$generichide\n");
    let page = "https://news.example.com/";
    assert!(b.page_script(page).contains("__mbga_cosmetic"), "the collector runs");
    assert!(!b.page_script(page).contains("'\n'"));
    let reply = b.cosmetic_reply(page, r#"{"c":["generic-ad","story"],"i":["top-banner"]}"#);
    assert!(reply.contains(".generic-ad{display:none!important}"));
    assert!(reply.contains("#top-banner{display:none!important}"));
    assert!(b.cosmetic_reply(page, r#"{"c":["story"],"i":[]}"#).is_empty());
    assert!(b.cosmetic_reply(page, "not json").is_empty());
    assert!(!b.page_script("https://quiet.example/").contains("__mbga_cosmetic"));
    assert!(b.cosmetic_reply("https://quiet.example/", r#"{"c":["generic-ad"]}"#).is_empty());
}

#[test]
fn scriptlets_and_user_rules_come_from_the_filter_directory() {
    let dir = PathBuf::from(temp_dir("scriptlets"));
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join(blocker::SCRIPTLETS.0),
        "/// set-constant.js\n/// alias set.js\n(function() {\nwindow['{{1}}'] = '{{2}}' === 'true';\n})();\n\n",
    )
    .unwrap();
    fs::write(dir.join(blocker::USER_RULES), "news.example.com##+js(set, mbgaFlag, true)\n||ads.example.net^\n")
        .unwrap();
    let mut b = blocker::Blocker::new(true, []);
    assert!(b.load(&dir), "user rules alone are enough");
    let script = b.page_script("https://news.example.com/");
    assert!(script.contains("mbgaFlag"), "{script}");
    assert!(b.should_block("https://ads.example.net/a.js", "https://news.example.com/", "script"));
    assert!(!b.page_script("https://other.example.com/").contains("mbgaFlag"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn a_space_with_tabs_but_none_selected_gets_its_most_recent_tab() {
    let mut s = State::new_default();
    let sp = home(&s);
    let pinned = s.open_tab(sp, "https://pinned.com", false, 5).unwrap();
    s.move_item(pinned, Container::Pinned { space_id: sp, folder_id: None }, 0);
    let older = s.open_tab(sp, "https://older.com", false, 1).unwrap();
    let newer = s.open_tab(sp, "https://newer.com", false, 3).unwrap();
    let _ = (older, newer);
    s.spaces[0].active_tab = None;
    assert_eq!(s.select_default_tab(sp, 10), Some(pinned), "most recently used");
    assert_eq!(s.select_default_tab(sp, 11), None, "already has one");
    let mut t = State::new_default();
    let sp = home(&t);
    let first = t.open_tab(sp, "https://a.com", false, 1).unwrap();
    let second = t.open_tab(sp, "https://b.com", false, 1).unwrap();
    let _ = first;
    t.spaces[0].active_tab = None;
    assert_eq!(t.select_default_tab(sp, 2), Some(second));
    let mut e = State::new_default();
    let sp = home(&e);
    let fav = e.open_tab(sp, "https://fav.com", false, 1).unwrap();
    let profile = e.spaces[0].profile_id;
    e.move_item(fav, Container::Favorites { profile_id: profile }, 0);
    e.spaces[0].active_tab = None;
    assert_eq!(e.select_default_tab(sp, 2), None);
}

#[test]
fn passwords_stay_sealed_until_unlocked_with_the_right_key() {
    let dir = temp_dir("passwords");
    let core = BrowserCore::new(dir.clone());
    let profile = core.snapshot().profiles[0].id;
    assert_eq!(core.save_login(profile, "https://github.com/login".into(), "octocat".into(), "hunter2".into()), None);
    assert!(core.unlock_passwords(vec![7; 32]));
    let id = core.save_login(profile, "https://github.com/login".into(), "octocat".into(), "hunter2".into()).unwrap();
    assert!(core.persist());
    let raw = fs::read_to_string(Path::new(&dir).join("passwords.json")).unwrap();
    assert!(raw.contains("octocat") && !raw.contains("hunter2"));

    let core = BrowserCore::new(dir.clone());
    assert_eq!(core.saved_logins(profile)[0].site, "github.com");
    assert_eq!(core.login_password(id), None);
    assert!(!core.unlock_passwords(vec![8; 32]));
    assert!(core.unlock_passwords(vec![7; 32]));
    assert_eq!(core.login_password(id).as_deref(), Some("hunter2"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn logins_are_offered_on_their_site_and_saving_is_asked_once() {
    let dir = temp_dir("password-offers");
    let core = BrowserCore::new(dir.clone());
    let profile = core.snapshot().profiles[0].id;
    let other = core.create_profile("Work".into());
    core.unlock_passwords(vec![1; 32]);
    let page = || "https://accounts.example.co.uk/signin?next=/".to_string();
    assert_eq!(core.password_offer(profile, page(), "me".into(), "pw".into()), PasswordOffer::Save);
    let id = core.save_login(profile, page(), "me".into(), "pw".into()).unwrap();
    assert_eq!(core.password_offer(profile, page(), "me".into(), "pw".into()), PasswordOffer::Nothing);
    assert_eq!(core.password_offer(profile, page(), "me".into(), "new".into()), PasswordOffer::Update { login_id: id });
    assert_eq!(core.password_offer(profile, page(), "you".into(), "pw2".into()), PasswordOffer::Save);

    core.save_login(profile, "https://www.example.co.uk/".into(), "www".into(), "x".into());
    let names =
        |url: &str, p: u64| core.logins_for_page(p, url.into()).into_iter().map(|l| l.username).collect::<Vec<_>>();
    assert_eq!(names("https://accounts.example.co.uk/", profile), ["me", "www"]);
    assert_eq!(names("https://shop.example.co.uk/", profile).len(), 2);
    assert!(names("https://other.co.uk/", profile).is_empty());
    assert!(names("http://accounts.example.co.uk/", profile).is_empty());
    assert!(names("https://accounts.example.co.uk/", other).is_empty());

    core.never_save_passwords(profile, "https://ads.example/x".into());
    assert_eq!(
        core.password_offer(profile, "https://ads.example/".into(), "a".into(), "b".into()),
        PasswordOffer::Nothing
    );
    assert_eq!(core.never_saved_sites(profile), ["https://ads.example"]);
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn imported_passwords_merge_by_site_and_username() {
    use import::passwords::ImportedLogin;
    let dir = temp_dir("password-merge");
    let core = BrowserCore::new(dir.clone());
    let profile = core.snapshot().profiles[0].id;
    core.unlock_passwords(vec![3; 32]);
    let kept = core.save_login(profile, "https://a.example/".into(), "me".into(), "mine".into()).unwrap();
    let login = |url: &str, user: &str, pw: &str, changed: u64| ImportedLogin {
        url: url.into(),
        username: user.into(),
        password: pw.into(),
        created_ms: 1,
        used_ms: 0,
        changed_ms: changed,
    };
    let read = import::passwords::Read {
        logins: vec![
            login("https://a.example/login", "me", "older", 5),
            login("https://b.example/", "you", "b", 5),
            login("https://b.example/", "you", "b-newer", 9),
            login("ftp://c.example/", "x", "y", 5),
        ],
        never: vec!["https://ads.example/".into()],
        unreadable: 2,
    };
    let outcome = core.merge_logins(read, profile);
    assert_eq!((outcome.added, outcome.updated, outcome.kept, outcome.unreadable), (1, 1, 1, 2));
    assert_eq!(core.login_password(kept).as_deref(), Some("mine"));
    let b = core.logins_for_page(profile, "https://b.example/".into());
    assert_eq!(core.login_password(b[0].id).as_deref(), Some("b-newer"));
    assert_eq!(core.never_saved_sites(profile), ["https://ads.example"]);
    let _ = fs::remove_dir_all(dir);
}
