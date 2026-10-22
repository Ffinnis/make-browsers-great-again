use super::*;
use serde_json::json;

const SESSION: &[u8] = include_bytes!("../../tests/fixtures/chromium-session");

fn tab(url: &str, title: &str) -> Item {
    Item::tab(url, title)
}

fn write(path: &Path, contents: impl AsRef<[u8]>) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, contents).unwrap();
}

#[expect(clippy::too_many_lines, reason = "one fixture that lays out a whole home folder")]
fn fixture_home(name: &str) -> PathBuf {
    let home = std::env::temp_dir().join(format!("mbga-import-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&home);
    let support = home.join("Library/Application Support");

    let sidebar = json!({"sidebar": {"containers": [
        {"global": {}},
        {
            "spaces": [
                "S1", {"id": "S1", "title": "Home", "profile": {"default": true},
                       "customInfo": {"iconType": {"emoji_v2": "🏠"}, "windowTheme": {"background": {"single": {"_0": {
                           "style": {"color": {"_0": {"color": {"red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1.0}}}}}}}}},
                       "newContainerIDs": [{"pinned": {}}, "P1", {"unpinned": {"_0": {"shared": {}}}}, "U1"]},
                "S2", {"id": "S2", "title": "Work",
                       "profile": {"custom": {"_0": {"directoryBasename": "Profile 1", "machineID": "x"}}},
                       "customInfo": {"iconType": {"emoji": 128188}},
                       "newContainerIDs": [{"pinned": {}}, "P2", {"unpinned": {}}, "U2"]},
                "S3", {"id": "S3", "title": "Research", "profile": {"default": true},
                       "newContainerIDs": [{"pinned": {}}, "P3", {"unpinned": {}}, "U3"]}
            ],
            "items": [
                "P1", {"id": "P1", "childrenIds": ["F1", "T1"], "data": {"itemContainer": {}}},
                "F1", {"id": "F1", "title": "News", "parentID": "P1", "childrenIds": ["T2", "SV"], "data": {"list": {}}},
                "T2", {"id": "T2", "title": null, "parentID": "F1", "childrenIds": [],
                       "data": {"tab": {"savedURL": "https://bbc.com/", "savedTitle": "BBC"}}},
                "SV", {"id": "SV", "parentID": "F1", "childrenIds": ["T3", "T4"], "data": {"splitView": {}}},
                "T3", {"id": "T3", "parentID": "SV", "data": {"tab": {"savedURL": "https://a.com/", "savedTitle": "A"}}},
                "T4", {"id": "T4", "parentID": "SV", "data": {"tab": {"savedURL": "https://b.com/", "savedTitle": "B"}}},
                "T1", {"id": "T1", "title": "Renamed", "parentID": "P1",
                       "data": {"tab": {"savedURL": "https://example.com/", "savedTitle": "Example"}}},
                "U1", {"id": "U1", "childrenIds": ["T5", "T6"]},
                "T5", {"id": "T5", "data": {"tab": {"savedURL": "https://news.ycombinator.com/", "savedTitle": "HN"}}},
                "T6", {"id": "T6", "data": {"tab": {"savedURL": "arc://settings", "savedTitle": "Settings"}}},
                "P2", {"id": "P2", "childrenIds": ["T7"]},
                "T7", {"id": "T7", "data": {"tab": {"savedURL": "https://github.com/", "savedTitle": "GitHub"}}},
                "U2", {"id": "U2", "childrenIds": []},
                "P3", {"id": "P3", "childrenIds": ["T10"]},
                "T10", {"id": "T10", "data": {"tab": {"savedURL": "https://arxiv.org/", "savedTitle": "arXiv"}}},
                "U3", {"id": "U3", "childrenIds": []},
                "TA1", {"id": "TA1", "childrenIds": ["T8"]},
                "T8", {"id": "T8", "data": {"tab": {"savedURL": "https://mail.google.com/", "savedTitle": "Gmail"}}},
                "TA2", {"id": "TA2", "childrenIds": ["T9"]},
                "T9", {"id": "T9", "data": {"tab": {"savedURL": "https://linear.app/", "savedTitle": "Linear"}}}
            ],
            "topAppsContainerIDs": [{"default": true}, "TA1",
                                    {"custom": {"_0": {"directoryBasename": "Profile 1"}}}, "TA2"]
        }
    ]}});
    write(&support.join("Arc/StorableSidebar.json"), sidebar.to_string());
    write(
        &support.join("Arc/User Data/Local State"),
        json!({"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 1": {"name": "Work"}}}})
            .to_string(),
    );

    let chrome = support.join("Google/Chrome");
    write(
        &chrome.join("Local State"),
        json!({"profile": {"info_cache": {"Default": {"name": "Person 1"}, "Profile 2": {"name": "Work"}}}})
            .to_string(),
    );
    write(
        &chrome.join("Default/Bookmarks"),
        json!({"roots": {
            "bookmark_bar": {"children": [
                {"type": "url", "name": "Docs", "url": "https://docs.rs/"},
                {"type": "folder", "name": "Dev", "children": [
                    {"type": "url", "name": "Rust", "url": "https://rust-lang.org/"},
                    {"type": "url", "name": "Settings", "url": "chrome://settings"}
                ]}
            ]},
            "other": {"children": []},
            "synced": {"children": [{"type": "url", "name": "Mobile", "url": "https://m.example.com/"}]}
        }})
        .to_string(),
    );
    write(&chrome.join("Default/Sessions/Session_13437039062408342"), SESSION);
    write(
        &chrome.join("Profile 2/Bookmarks"),
        json!({"roots": {"bookmark_bar": {"children": [
            {"type": "url", "name": "Jira", "url": "https://jira.example.com/"}
        ]}}})
        .to_string(),
    );

    write(&support.join("net.imput.helium/Local State"), "{}");
    write(
        &support.join("net.imput.helium/Default/Bookmarks"),
        json!({"roots": {"bookmark_bar": {"children": [
            {"type": "url", "name": "Helium", "url": "https://helium.computer/"}
        ]}}})
        .to_string(),
    );

    write(&support.join("Acme/Acme Browser/Local State"), "{}");
    write(
        &support.join("Acme/Acme Browser/Default/Bookmarks"),
        json!({"roots": {"other": {"children": [
            {"type": "url", "name": "Acme", "url": "https://acme.example/"}
        ]}}})
        .to_string(),
    );
    write(&support.join("Slack/Local State"), "{}");
    write(&support.join("MBGA/engine/Local State"), "{}");
    write(&support.join("MBGA/engine/Profile 1/History"), "");

    let firefox = support.join("Firefox");
    write(
        &firefox.join("profiles.ini"),
        "[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abc.default-release\n",
    );
    let places = firefox.join("Profiles/abc.default-release/places.sqlite");
    fs::create_dir_all(places.parent().unwrap()).unwrap();
    let db = Connection::open(&places).unwrap();
    db.execute_batch(
        "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
         CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER,
                                     position INTEGER, title TEXT, guid TEXT);
         INSERT INTO moz_places VALUES (1, 'https://mozilla.org/', 'Mozilla'), (2, 'https://mdn.dev/', 'MDN'),
                                       (3, 'place:sort=8', NULL);
         INSERT INTO moz_bookmarks VALUES
           (1, 2, NULL, 0, 0, '', 'root________'),
           (2, 2, NULL, 1, 0, 'menu', 'menu________'),
           (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____'),
           (4, 2, NULL, 1, 2, 'unfiled', 'unfiled_____'),
           (5, 2, NULL, 1, 3, 'mobile', 'mobile______'),
           (6, 1, 1, 3, 0, 'Mozilla', 'a'),
           (7, 2, NULL, 3, 1, 'Stuff', 'b'),
           (8, 1, 2, 7, 0, 'MDN docs', 'c'),
           (9, 1, 3, 7, 1, 'Most Visited', 'd'),
           (10, 3, NULL, 3, 2, NULL, 'e');",
    )
    .unwrap();
    drop(db);

    let mut leaf = plist::Dictionary::new();
    leaf.insert("WebBookmarkType".into(), "WebBookmarkTypeLeaf".into());
    leaf.insert("URLString".into(), "https://apple.com/".into());
    let mut uri = plist::Dictionary::new();
    uri.insert("title".into(), "Apple".into());
    leaf.insert("URIDictionary".into(), uri.into());
    let mut bar = plist::Dictionary::new();
    bar.insert("WebBookmarkType".into(), "WebBookmarkTypeList".into());
    bar.insert("Title".into(), "BookmarksBar".into());
    bar.insert("Children".into(), vec![plist::Value::from(leaf)].into());
    let mut reading = plist::Dictionary::new();
    reading.insert("WebBookmarkType".into(), "WebBookmarkTypeList".into());
    reading.insert("Title".into(), "com.apple.ReadingList".into());
    reading.insert("Children".into(), Vec::<plist::Value>::new().into());
    let mut root = plist::Dictionary::new();
    root.insert("Children".into(), vec![plist::Value::from(bar), plist::Value::from(reading)].into());
    let safari = home.join("Library/Safari/Bookmarks.plist");
    fs::create_dir_all(safari.parent().unwrap()).unwrap();
    plist::Value::from(root).to_file_binary(&safari).unwrap();

    home
}

fn exclude(home: &Path) -> PathBuf {
    home.join("Library/Application Support/MBGA")
}

#[test]
fn session_file_replays_to_open_tabs() {
    let tabs = snss::parse(SESSION).unwrap();
    let urls: Vec<&str> = tabs.iter().map(|t| t.url.as_str()).collect();
    assert_eq!(urls, ["https://example.org/", "https://www.wikipedia.org/"]);
    assert_eq!(tabs[1].title, "Wikipedia");
    assert!(tabs.iter().all(|t| !t.pinned));
    assert_eq!(snss::parse(b"not a session"), None);
}

#[test]
fn detects_browsers_and_skips_look_alikes() {
    let home = fixture_home("detect");
    let sources = detect(&home, &exclude(&home));
    let names: Vec<&str> = sources.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(names, ["Arc", "Chrome", "Helium", "Acme Browser", "Firefox", "Safari"]);
    let chrome = &sources[1];
    assert_eq!(chrome.kind, Kind::Chromium);
    assert_eq!(chrome.bundle_id.as_deref(), Some("com.google.Chrome"));
    let profiles: Vec<(&str, &str)> = chrome.profiles.iter().map(|p| (p.id.as_str(), p.name.as_str())).collect();
    assert_eq!(profiles, [("Default", "Chrome · Person 1"), ("Profile 2", "Chrome · Work")]);
    assert_eq!(sources[2].profiles[0].name, "Helium");
    let _ = fs::remove_dir_all(home);
}

#[test]
fn arc_sidebar_becomes_profiles_spaces_and_favorites() {
    let home = fixture_home("arc");
    let sources = detect(&home, &exclude(&home));
    let arc = &sources[0];
    assert_eq!(arc.profiles.len(), 2);

    let personal = &arc.profiles[0];
    assert_eq!((personal.id.as_str(), personal.name.as_str()), ("Default", "Personal"));
    assert_eq!(personal.favorites, [tab("https://mail.google.com/", "Gmail")]);
    let space = &personal.spaces[0];
    assert_eq!(space.name, "Home");
    assert_eq!(space.icon.as_deref(), Some("🏠"));
    assert_eq!(space.color, Some(0xFF8000));
    assert_eq!(
        space.pinned,
        [
            Item::folder(
                "News",
                vec![tab("https://bbc.com/", "BBC"), tab("https://a.com/", "A"), tab("https://b.com/", "B")],
                true
            ),
            tab("https://example.com/", "Renamed"),
        ]
    );
    assert_eq!(space.today, [tab("https://news.ycombinator.com/", "HN")]);

    let work = &arc.profiles[1];
    assert_eq!(work.name, "Work");
    assert_eq!(work.spaces[0].icon.as_deref(), Some("💼"));
    assert_eq!(work.spaces[0].pinned, [tab("https://github.com/", "GitHub")]);
    assert_eq!(work.favorites, [tab("https://linear.app/", "Linear")]);
    let _ = fs::remove_dir_all(home);
}

#[test]
fn chromium_bookmarks_and_open_tabs() {
    let home = fixture_home("chromium");
    let sources = detect(&home, &exclude(&home));
    let profile = &sources[1].profiles[0];
    let space = &profile.spaces[0];
    assert_eq!(space.name, "Chrome · Person 1");
    assert_eq!(
        space.pinned,
        [
            Item::folder(
                "Bookmarks Bar",
                vec![
                    tab("https://docs.rs/", "Docs"),
                    Item::folder("Dev", vec![tab("https://rust-lang.org/", "Rust")], false),
                ],
                false
            ),
            Item::folder("Mobile Bookmarks", vec![tab("https://m.example.com/", "Mobile")], false),
        ]
    );
    let today: Vec<&Item> = space.today.iter().collect();
    assert_eq!(today.len(), 2);
    let _ = fs::remove_dir_all(home);
}

#[test]
fn firefox_and_safari_bookmarks() {
    let home = fixture_home("ff");
    let sources = detect(&home, &exclude(&home));
    let firefox = sources.iter().find(|s| s.kind == Kind::Firefox).unwrap();
    assert_eq!(
        firefox.profiles[0].spaces[0].pinned,
        [Item::folder(
            "Bookmarks Toolbar",
            vec![
                tab("https://mozilla.org/", "Mozilla"),
                Item::folder("Stuff", vec![tab("https://mdn.dev/", "MDN docs")], false),
            ],
            false
        )]
    );
    let safari = sources.iter().find(|s| s.kind == Kind::Safari).unwrap();
    assert_eq!(
        safari.profiles[0].spaces[0].pinned,
        [Item::folder("Favorites Bar", vec![tab("https://apple.com/", "Apple")], false)]
    );
    let _ = fs::remove_dir_all(home);
}

#[test]
fn importing_into_a_fresh_state_replaces_the_empty_space() {
    let home = fixture_home("apply");
    let sources = detect(&home, &exclude(&home));
    let arc = &sources[0];
    let mut state = State::new_default();
    let chosen: Vec<(&Source, &ImportedProfile)> = arc.profiles.iter().map(|p| (arc, p)).collect();
    let (counts, made) = apply(&mut state, &chosen, 1);
    assert_eq!(counts, Counts { spaces: 3, pinned: 6, favorites: 2, today: 1 });

    let names: Vec<&str> = state.profiles.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, ["Personal", "Work"]);
    assert_eq!(made, state.profiles.iter().map(|p| p.id).collect::<Vec<_>>());
    let spaces: Vec<&str> = state.spaces.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(spaces, ["Home", "Work", "Research"]);
    assert_eq!(state.spaces[2].profile_id, state.profiles[0].id);
    assert_eq!(state.active_space, state.spaces[0].id);
    let home_space = &state.spaces[0];
    assert_eq!(home_space.profile_id, state.profiles[0].id);
    assert_eq!(home_space.today.len(), 1);
    let today = &state.tabs[&home_space.today[0]];
    assert_eq!(
        (today.url.as_str(), today.title.as_str(), today.pinned_url.as_ref()),
        ("https://news.ycombinator.com/", "HN", None)
    );
    let mut pinned = Vec::new();
    crate::model::collect_tabs(&home_space.pinned, &mut pinned);
    assert!(pinned.iter().all(|id| state.tabs[id].pinned_url.is_some() && !state.tabs[id].live));
    let fav = state.favorites[&state.profiles[0].id][0];
    assert_eq!(state.tabs[&fav].pinned_url.as_deref(), Some("https://mail.google.com/"));
    let _ = fs::remove_dir_all(home);
}

#[test]
fn importing_into_a_used_state_adds_alongside() {
    let home = fixture_home("apply-used");
    let sources = detect(&home, &exclude(&home));
    let arc = &sources[0];
    let mut state = State::new_default();
    let existing = state.spaces[0].id;
    state.open_tab(existing, "https://kept.example/", true, 1);
    apply(&mut state, &[(arc, &arc.profiles[0])], 2);
    let names: Vec<&str> = state.profiles.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, ["Personal", "Personal (Arc)"]);
    assert_eq!(state.spaces.len(), 3);
    assert_eq!(state.spaces[0].id, existing);
    assert_eq!(state.active_space, state.spaces[1].id);
    let _ = fs::remove_dir_all(home);
}

type CookieRow<'a> = (&'a str, &'a str, &'a str, &'a [u8], i64, &'a str);

fn chromium_cookies(path: &Path, version: u32, rows: &[CookieRow]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = Connection::open(path).unwrap();
    db.execute_batch(&format!(
        "CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
         INSERT INTO meta VALUES ('version', '{version}');
         CREATE TABLE cookies (creation_utc INTEGER, host_key TEXT, top_frame_site_key TEXT, name TEXT, value TEXT,
             encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER,
             last_access_utc INTEGER, has_expires INTEGER, is_persistent INTEGER, priority INTEGER, samesite INTEGER);"
    ))
    .unwrap();
    for (host, name, value, encrypted, expires, top_frame) in rows {
        db.execute(
            "INSERT INTO cookies VALUES (1, ?1, ?2, ?3, ?4, ?5, '/', ?6, 1, 1, 2, 1, ?7, 1, 0)",
            rusqlite::params![host, top_frame, name, value, encrypted, expires, i64::from(*expires != 0)],
        )
        .unwrap();
    }
}

#[test]
fn chromium_cookies_decrypt_with_the_keychain_password() {
    let home = fixture_home("cookies");
    let sources = detect(&home, &exclude(&home));
    let chrome = &sources[1];
    let future = 13_500_000_000_000_000;
    let encrypted = cookies::encrypt_for_test(b"peanuts", ".github.com", "secret-session");
    let foreign = cookies::encrypt_for_test(b"other", "x.com", "nope");
    chromium_cookies(
        &home.join("Library/Application Support/Google/Chrome/Default/Cookies"),
        24,
        &[
            (".github.com", "user_session", "", &encrypted, future, ""),
            ("example.com", "plain", "visible", b"", 0, ""),
            ("old.example", "expired", "x", b"", 13_000_000_000_000_000, ""),
            ("embed.example", "partitioned", "x", b"", future, "https://top.example"),
            ("x.com", "wrong_key", "", &foreign, future, ""),
        ],
    );
    let read = cookies::read(chrome, "Default", Some(b"peanuts"), 1_790_000_000_000).unwrap();
    let got: Vec<(&str, &str, &str, i64)> =
        read.iter().map(|c| (c.domain.as_str(), c.name.as_str(), c.value.as_str(), c.expires)).collect();
    assert_eq!(
        got,
        [(".github.com", "user_session", "secret-session", future), ("example.com", "plain", "visible", 0)]
    );
    assert!(read[0].secure && read[0].http_only && read[0].same_site == 0);
    assert_eq!(cookies::keychain_service(chrome).as_deref(), Some("Chrome Safe Storage"));
    assert_eq!(cookies::keychain_service(&sources[0]).as_deref(), Some("Arc Safe Storage"));
    assert!(cookies::read(chrome, "Default", None, 0).is_err());
    assert!(cookies::read(chrome, "Profile 2", Some(b"peanuts"), 0).is_err());
    let _ = fs::remove_dir_all(home);
}

#[test]
fn firefox_cookies_are_read_in_the_clear() {
    let home = fixture_home("ff-cookies");
    let sources = detect(&home, &exclude(&home));
    let firefox = sources.iter().find(|s| s.kind == Kind::Firefox).unwrap();
    let db =
        Connection::open(home.join("Library/Application Support/Firefox/Profiles/abc.default-release/cookies.sqlite"))
            .unwrap();
    db.execute_batch(
        "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT,
             value TEXT, host TEXT, path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER,
             isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER);
         INSERT INTO moz_cookies VALUES (1, '', 'sid', 'abc', '.mozilla.org', '/', 1900000000, 1, 1, 1, 0, 1);
         INSERT INTO moz_cookies VALUES (2, '', 'ms', 'def', 'mdn.dev', '/', 1900000000000, 1, 1, 0, 1, 0);
         INSERT INTO moz_cookies VALUES (3, '^userContextId=2', 'work', 'x', 'mdn.dev', '/', 1900000000, 1, 1, 0, 0, 0);
         INSERT INTO moz_cookies VALUES (4, '', 'gone', 'x', 'mdn.dev', '/', 1000000000, 1, 1, 0, 0, 0);",
    )
    .unwrap();
    let read = cookies::read(firefox, &firefox.profiles[0].id, None, 1_790_000_000_000).unwrap();
    let names: Vec<&str> = read.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["sid", "ms"]);
    assert_eq!(read[0].expires, read[1].expires);
    assert_eq!(read[0].expires, 11_644_473_600_000_000 + 1_900_000_000_000_000);
    assert_eq!((read[0].same_site, read[1].same_site), (1, -1));
    assert!(cookies::keychain_service(firefox).is_none());
    let _ = fs::remove_dir_all(home);
}

fn chromium_logins(path: &Path, rows: &[(&str, &str, &[u8], bool)]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = Connection::open(path).unwrap();
    db.execute_batch(
        "CREATE TABLE logins (origin_url TEXT, action_url TEXT, username_element TEXT, username_value TEXT,
             password_element TEXT, password_value BLOB, signon_realm TEXT, date_created INTEGER,
             blacklisted_by_user INTEGER, scheme INTEGER, date_last_used INTEGER, date_password_modified INTEGER);",
    )
    .unwrap();
    for (origin, username, password, never) in rows {
        db.execute(
            "INSERT INTO logins VALUES (?1, '', 'user', ?2, 'pass', ?3, ?1, 13300000000000000, ?4, 0,
                 13350000000000000, 13340000000000000)",
            rusqlite::params![origin, username, password, i64::from(*never)],
        )
        .unwrap();
    }
}

#[test]
fn chromium_passwords_decrypt_with_the_keychain_password() {
    let home = fixture_home("passwords");
    let sources = detect(&home, &exclude(&home));
    let chrome = &sources[1];
    let profile = home.join("Library/Application Support/Google/Chrome/Default");
    let secret = cookies::encrypt_value_for_test(b"peanuts", b"hunter2");
    let foreign = cookies::encrypt_value_for_test(b"other", b"nope");
    chromium_logins(
        &profile.join("Login Data"),
        &[
            ("https://github.com/login", "octocat", &secret, false),
            ("android://abc@com.example/", "app", &secret, false),
            ("https://ads.example/", "", b"", true),
            ("https://x.com/", "elon", &foreign, false),
        ],
    );
    let account = cookies::encrypt_value_for_test(b"peanuts", b"s3cret");
    chromium_logins(
        &profile.join("Login Data For Account"),
        &[("https://mail.google.com/", "me@gmail.com", &account, false)],
    );

    assert_eq!(passwords::count(chrome, "Default"), 3);
    let read = passwords::read(chrome, "Default", Some(b"peanuts")).unwrap();
    let got: Vec<(&str, &str, &str)> =
        read.logins.iter().map(|l| (l.url.as_str(), l.username.as_str(), l.password.as_str())).collect();
    assert_eq!(
        got,
        [("https://github.com/login", "octocat", "hunter2"), ("https://mail.google.com/", "me@gmail.com", "s3cret")]
    );
    assert_eq!(read.never, ["https://ads.example/"]);
    assert_eq!(read.unreadable, 1);
    assert_eq!(
        (read.logins[0].created_ms, read.logins[0].used_ms, read.logins[0].changed_ms),
        (1_655_526_400_000, 1_705_526_400_000, 1_695_526_400_000)
    );
    assert!(passwords::read(chrome, "Default", None).is_err());
    assert!(passwords::read(chrome, "Default", Some(b"wrong")).is_err());
    let _ = fs::remove_dir_all(home);
}

#[test]
fn firefox_passwords_decrypt_with_key4() {
    let home = fixture_home("ff-passwords");
    let sources = detect(&home, &exclude(&home));
    let firefox = sources.iter().find(|s| s.kind == Kind::Firefox).unwrap();
    let profile = home.join("Library/Application Support/Firefox/Profiles/abc.default-release");
    let global_salt = b"global salt bytes";
    let key = [0x42u8; 24];
    let pbe = |plain: &[u8], salt: &[u8]| passwords::test_support::pbes2(plain, global_salt, salt, &[9u8; 14]);
    let db = Connection::open(profile.join("key4.db")).unwrap();
    db.execute_batch(
        "CREATE TABLE metaData (id TEXT PRIMARY KEY, item1, item2);
                      CREATE TABLE nssPrivate (id INTEGER PRIMARY KEY, a11, a102);",
    )
    .unwrap();
    db.execute(
        "INSERT INTO metaData VALUES ('password', ?1, ?2)",
        rusqlite::params![global_salt.to_vec(), pbe(b"password-check", b"check salt")],
    )
    .unwrap();
    let mut key_id = vec![0xf8u8; 1];
    key_id.extend([0u8; 14]);
    key_id.push(1);
    db.execute("INSERT INTO nssPrivate VALUES (1, ?1, ?2)", rusqlite::params![pbe(&key, b"key salt"), key_id]).unwrap();
    drop(db);
    let field = |s: &str| passwords::test_support::login_field(&key, s);
    let logins = json!({"logins": [
        {"hostname": "https://mozilla.org", "httpRealm": null, "encryptedUsername": field("fox"),
         "encryptedPassword": field("firefox!"), "timeCreated": 1, "timeLastUsed": 2, "timePasswordChanged": 3},
        {"hostname": "https://intranet.example", "httpRealm": "Staff only", "encryptedUsername": field("a"),
         "encryptedPassword": field("b")},
    ]});
    write(&profile.join("logins.json"), logins.to_string());

    let id = &firefox.profiles[0].id;
    assert_eq!(passwords::count(firefox, id), 1);
    let read = passwords::read(firefox, id, None).unwrap();
    assert_eq!(
        read.logins,
        [passwords::ImportedLogin {
            url: "https://mozilla.org".into(),
            username: "fox".into(),
            password: "firefox!".into(),
            created_ms: 1,
            used_ms: 2,
            changed_ms: 3,
        }]
    );

    let db = Connection::open(profile.join("key4.db")).unwrap();
    db.execute(
        "UPDATE metaData SET item2 = ?1",
        rusqlite::params![passwords::test_support::pbes2(b"password-check", b"other salt", b"check salt", &[9u8; 14])],
    )
    .unwrap();
    drop(db);
    assert_eq!(passwords::read(firefox, id, None).unwrap_err(), passwords::FIREFOX_PRIMARY_PASSWORD);
    let _ = fs::remove_dir_all(home);
}

#[test]
fn password_files_are_read_by_their_column_names() {
    let safari = "Title,URL,Username,Password,Notes,OTPAuth\r\n\
                  GitHub,https://github.com/,octocat,\"pa,ss\"\"word\",,\r\n\
                  Note only,,,,\"multi\nline\",\r\n\
                  Bank,bank.example,me,1234,,\r\n";
    let read = passwords::read_csv(safari).unwrap();
    let got: Vec<(&str, &str, &str)> =
        read.logins.iter().map(|l| (l.url.as_str(), l.username.as_str(), l.password.as_str())).collect();
    assert_eq!(got, [("https://github.com/", "octocat", "pa,ss\"word"), ("https://bank.example", "me", "1234")]);

    let bitwarden =
        "\u{feff}folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n\
                     ,,login,Site,,,0,https://site.example/login,user@site, secret ,\n";
    let read = passwords::read_csv(bitwarden).unwrap();
    assert_eq!((read.logins[0].username.as_str(), read.logins[0].password.as_str()), ("user@site", " secret "));
    assert!(passwords::read_csv("name,notes\nx,y\n").is_err());
}
