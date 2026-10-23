import AppKit

enum SettingsPane: Int, CaseIterable {
    case general, privacy, passwords, developer, agents

    var title: String {
        switch self {
        case .general: "General"
        case .privacy: "Privacy"
        case .passwords: "Passwords"
        case .developer: "Developer"
        case .agents: "Agents"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .passwords: "key"
        case .developer: "hammer"
        case .agents: "sparkles"
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = SettingsTabsController()

    init(store: BrowserStore) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        for pane in SettingsPane.allCases {
            let controller = SettingsPaneController(pane: pane, store: store)
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.fitWindow(animated: false)
        window.center()
        window.setFrameAutosaveName("Settings")
        if ProcessInfo.processInfo.environment["MBGA_DEBUG_SETTINGS_CYCLE"] != nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let tabs = self?.tabs else { return }
                    tabs.selectedTabViewItemIndex = (tabs.selectedTabViewItemIndex + 1) % tabs.tabViewItems.count
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ pane: SettingsPane?) {
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class SettingsTabsController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow(animated: true)
    }

    func fitWindow(animated: Bool) {
        guard let window = view.window ?? viewIfLoaded?.window,
              let pane = tabViewItems[safe: selectedTabViewItemIndex]?.viewController as? SettingsPaneController
        else { return }
        let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.contentSize))
        var frame = window.frame
        frame.origin.y += frame.height - content.height
        frame.size = content.size
        guard frame != window.frame else { return }
        guard animated, window.isVisible, !Motion.reduced else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2 * Motion.slow
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            window.animator().setFrame(frame, display: true)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor
private final class SettingsPaneController: NSViewController {
    private let pane: SettingsPane
    private let store: BrowserStore
    private var refreshers: [() -> Void] = []
    private(set) var contentSize = NSSize(width: 564, height: 300)

    init(pane: SettingsPane, store: BrowserStore) {
        self.pane = pane
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = pane.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let rows: [[NSView]] = switch pane {
        case .general: generalRows()
        case .privacy: privacyRows()
        case .passwords: passwordRows()
        case .developer: developerRows()
        case .agents: agentRows()
        }
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.column(at: 1).width = 340
        grid.rowAlignment = .firstBaseline
        for (i, row) in rows.enumerated() where row.last?.identifier == Self.captionID {
            grid.row(at: i).topPadding = -4
        }
        let view = NSView()
        view.addSubview(grid)
        let bottom = grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24)
        bottom.priority = .defaultLow
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            bottom,
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        self.view = view
        refresh()
        contentSize = view.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: UserDefaults.didChangeNotification, object: nil)
        store.observe(self) { [weak self] change in
            if case .snapshot = change { self?.refresh() }
            if case .layout = change { self?.refresh() }
            if case .update = change { self?.refresh() }
        }
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    @objc private func refresh() {
        for refresher in refreshers { refresher() }
    }

    private func generalRows() -> [[NSView]] {
        let layout = popUp(SidebarLayout.allCases.map(\.title)) { [store] i in store.setLayout(SidebarLayout.allCases[i]) }
        refreshers.append { [store] in layout.selectItem(at: SidebarLayout.allCases.firstIndex(of: store.layout) ?? 0) }

        let colour = popUp(TintStyle.allCases.map(\.title)) { i in
            UserDefaults.standard.set(TintStyle.allCases[i].rawValue, forKey: TintStyle.defaultsKey)
        }
        refreshers.append { colour.selectItem(at: TintStyle.allCases.firstIndex(of: TintStyle.saved) ?? 0) }
        let matchPage = checkbox("Take the colour of the page in front") { on in
            UserDefaults.standard.set(on, forKey: TintStyle.matchPageKey)
        }
        refreshers.append { matchPage.state = UserDefaults.standard.bool(forKey: TintStyle.matchPageKey) ? .on : .off }

        let intervals: [(String, UInt32)] = [("Never", 0), ("After 12 Hours", 12), ("After a Day", 24), ("After a Week", 168)]
        let archive = popUp(intervals.map(\.0)) { [store] i in store.setArchiveAfterHours(intervals[i].1) }
        refreshers.append { [store] in
            archive.selectItem(at: intervals.firstIndex { $0.1 == store.archiveAfterHours } ?? 0)
        }

        let delays: [(String, UInt64)] = [
            ("After 5 Minutes", 300), ("After 15 Minutes", 900), ("After 30 Minutes", 1800), ("After an Hour", 3600),
            ("After 2 Hours", 7200), ("After 6 Hours", 21600), ("After 12 Hours", 43200), ("Never", 0),
        ]
        let sleep = popUp(delays.map(\.0)) { [store] i in
            if i < delays.count { store.setSleepPolicy(afterSecs: delays[i].1) }
        }
        let limits: [(String, UInt32)] = [("8 Tabs", 8), ("16 Tabs", 16), ("24 Tabs", 24), ("50 Tabs", 50), ("No Limit", 0)]
        let limit = popUp(limits.map(\.0)) { [store] i in
            if i < limits.count { store.setSleepPolicy(maxLiveTabs: limits[i].1) }
        }
        refreshers.append { [store] in
            Self.select(sleep, store.sleepAfterSecs, in: delays) { "After \(Duration.seconds(Int64(clamping: $0)).formatted(.units(width: .wide)))" }
            Self.select(limit, store.maxLiveTabs, in: limits) { "\($0) Tabs" }
        }

        let awake = sitesField(placeholder: "mail.google.com, slack.com") { [store] sites in store.setKeepAwakeSites(sites) }
        refreshers.append { [store] in
            if awake.currentEditor() == nil { awake.stringValue = store.keepAwakeSites.joined(separator: ", ") }
        }

        return [
            [label("Sidebar:"), layout],
            [label("Sidebar colour:"), colour],
            [NSGridCell.emptyContentView, matchPage],
            [label("Archive Today tabs:"), archive],
            [NSGridCell.emptyContentView, caption("Tabs in Today you haven't used for this long move to the archive. Pinned tabs and favourites stay.")],
            [label("Put tabs to sleep:"), sleep],
            [NSGridCell.emptyContentView, caption("A tab in the background you haven't used for this long is unloaded, and reloads when you select it. The tab you're on, tabs playing sound and tabs kept awake stay loaded.")],
            [label("Keep loaded at most:"), limit],
            [NSGridCell.emptyContentView, caption("Beyond this many, the tabs you used longest ago go to sleep first. When your Mac runs low on memory, tabs go to sleep sooner whatever you choose.")],
            [label("Keep awake:"), awake],
            [NSGridCell.emptyContentView, caption("Tabs of these sites, with their subdomains, are never put to sleep, frozen or archived, so mail and chat keep notifying you. Separate them with commas.")],
        ] + videoRows() + updateRows()
    }

    private func videoRows() -> [[NSView]] {
        let convert = checkbox("Play H.264 video by converting it") { [store] on in store.setConvertsVideo(on) }
        refreshers.append { [store] in convert.state = store.convertsVideo ? .on : .off }
        let about = "Sites like X, Reddit and Twitch send video in a format the engine can't play. "
            + "MBGA converts it as it plays, which uses more battery. Applies to pages you load afterwards."
        return [[label("Video:"), convert], [NSGridCell.emptyContentView, caption(about)]]
    }

    private func updateRows() -> [[NSView]] {
        let updater = Updater.shared
        let automatic = checkbox("Keep MBGA up to date") { on in updater.automatic = on }
        let check = NSButton.push("Check Now") { updater.check(userInitiated: true) }
        let status = caption("")
        refreshers.append {
            automatic.state = updater.automatic ? .on : .off
            automatic.isEnabled = updater.available
            if let version = updater.readyVersion {
                check.title = "Restart to Update"
                check.onAction { updater.restartToUpdate() }
                status.stringValue = "MBGA \(version) is ready. It installs when you restart or quit MBGA."
            } else {
                check.title = "Check Now"
                check.onAction { updater.check(userInitiated: true) }
                status.stringValue = updater.statusText
            }
            check.isEnabled = updater.available && updater.state != .checking && !updater.isDownloading
        }

        return [
            [label("Updates:"), automatic],
            [NSGridCell.emptyContentView, check],
            [NSGridCell.emptyContentView, status],
        ]
    }

    private func privacyRows() -> [[NSView]] {
        let blockAds = checkbox("Block ads and trackers") { [store] on in store.setBlockAds(on) }
        refreshers.append { [store] in blockAds.state = store.blockAds ? .on : .off }
        let filters = NSButton.push("Edit My Filters…") { [store] in
            NSWorkspace.shared.open(URL(fileURLWithPath: store.core.userFiltersPath()))
        }
        let extensions = NSButton.push("Manage Extensions…") { [store] in store.showExtensions() }
        let isolation = checkbox("Strict site isolation") { [store] on in store.setStrictSiteIsolation(on) }
        refreshers.append { [store] in isolation.state = store.strictSiteIsolation ? .on : .off }
        return [
            [label("Ad blocking:"), blockAds],
            [NSGridCell.emptyContentView, filters],
            [label("Extensions:"), extensions],
            [NSGridCell.emptyContentView, caption("Add extensions from the Chrome Web Store and manage them in Chrome's own window. Each profile has its own; they run in all of its spaces.")],
            [label("Processes:"), isolation],
            [NSGridCell.emptyContentView, caption("Every site gets its own process, as in desktop Chrome: the strongest protection against one site reading another's data, for about 30% more memory. Takes effect at next launch.")],
        ] + signInRows()
    }

    private func signInRows() -> [[NSView]] {
        let from = NSPopUpButton(frame: .zero, pullsDown: false)
        from.addItem(withTitle: "Looking for browsers…")
        from.isEnabled = false
        let into = NSPopUpButton(frame: .zero, pullsDown: false)
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var choices: [(ImportSourceInfo, ImportProfileInfo)] = []
        let fillProfiles = { [store] in
            let profiles = store.snapshot.profiles
            let current = into.selectedItem?.tag
            into.removeAllItems()
            for profile in profiles {
                into.addItem(withTitle: profile.name)
                into.lastItem?.tag = Int(profile.id)
            }
            if let current { into.selectItem(withTag: current) }
        }
        let matchProfile = { [store] in
            guard let (source, profile) = choices[safe: from.indexOfSelectedItem] else { return }
            let id = SignIns.likelyProfile(for: profile, of: source, among: store.snapshot.profiles)?.id
                ?? store.activeSpace.profileId
            into.selectItem(withTag: Int(id))
        }
        fillProfiles()
        refreshers.append(fillProfiles)
        from.onAction(matchProfile)
        let bring = NSButton.push("Bring Sign-ins") {}
        bring.isEnabled = false
        bring.onAction { [store, weak bring] in
            guard let (source, profile) = choices[safe: from.indexOfSelectedItem], let target = into.selectedItem else { return }
            bring?.isEnabled = false
            status.stringValue = "Bringing…"
            Task {
                let outcome = await SignIns.bring(from: source, profileID: profile.id, into: UInt64(target.tag), store: store)
                let text = SignIns.describe(outcome, from: source.name)
                status.stringValue = text
                status.toolTip = text
                bring?.isEnabled = true
            }
        }
        let core = store.core
        let home = ProcessInfo.processInfo.environment["MBGA_IMPORT_HOME"] ?? NSHomeDirectory()
        Task { [weak self] in
            let sources = await Task.detached { core.detectBrowsers(home: home) }.value
            guard self != nil else { return }
            choices = sources.filter(SignIns.available).flatMap { s in s.profiles.map { (s, $0) } }
            from.removeAllItems()
            from.addItems(withTitles: choices.map { SignIns.title($1, of: $0) })
            from.isEnabled = !choices.isEmpty
            bring.isEnabled = !choices.isEmpty
            if choices.isEmpty { from.addItem(withTitle: "No other browsers found") }
            matchProfile()
        }
        let action = NSStackView(views: [bring, status])
        action.spacing = 10
        return [
            [label("Sign-ins from:"), from],
            [label("Into profile:"), into],
            [NSGridCell.emptyContentView, action],
            [NSGridCell.emptyContentView, caption("Brings the browser's cookies, so sites it's signed in to know you here too. Sign-ins you already have in MBGA stay. macOS asks before MBGA can read the browser's key in your keychain; reload open pages afterwards.")],
        ]
    }

    private func passwordRows() -> [[NSView]] {
        let core = store.core
        let profile = NSPopUpButton(frame: .zero, pullsDown: false)
        let list = PasswordListView(width: 340)
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.preferredMaxLayoutWidth = 340
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let say = { (text: String) in
            status.stringValue = text
            status.toolTip = text
        }
        let profileID = { [store] in profile.selectedItem.map { UInt64($0.tag) } ?? store.activeSpace.profileId }
        let reload = { list.logins = core.savedLogins(profileId: profileID()) }
        let fillProfiles = { [store] in
            let current = profile.selectedItem?.tag ?? Int(store.activeSpace.profileId)
            profile.removeAllItems()
            for info in store.snapshot.profiles {
                profile.addItem(withTitle: info.name)
                profile.lastItem?.tag = Int(info.id)
            }
            profile.selectItem(withTag: current)
            reload()
        }
        refreshers.append(fillProfiles)
        profile.onAction(reload)

        let copy = NSButton.push("Copy Password") {}
        let show = NSButton.push("Show Password") {}
        let delete = NSButton.push("Delete") {}
        list.onSelect = {
            for button in [copy, show, delete] { button.isEnabled = list.selected != nil }
        }
        list.onSelect?()
        let reveal = { [weak self] (login: SavedLogin, copying: Bool) in
            _ = Task {
                let reason = "\(copying ? "copy" : "show") the password for \(login.site)"
                guard await PasswordKey.confirmOwner(reason) else { return }
                guard await PasswordKey.unlock(core), let password = core.loginPassword(id: login.id) else {
                    return say("Couldn't unlock your passwords.")
                }
                if copying {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                    NSPasteboard.general.setString("", forType: .init("org.nspasteboard.ConcealedType"))
                    return say("Copied the password for \(login.username.isEmpty ? login.site : login.username).")
                }
                let alert = NSAlert()
                alert.messageText = login.site
                alert.informativeText = login.username.isEmpty ? "No username" : login.username
                let field = NSTextField(labelWithString: password)
                field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
                field.isSelectable = true
                alert.accessoryView = field
                alert.addButton(withTitle: "Done")
                guard let window = self?.view.window else { return }
                await alert.beginSheetModal(for: window)
            }
        }
        copy.onAction { if let login = list.selected { reveal(login, true) } }
        show.onAction { if let login = list.selected { reveal(login, false) } }
        delete.onAction { [weak self] in
            guard let login = list.selected, let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.messageText = "Delete the password for \(login.username.isEmpty ? login.site : login.username)?"
            alert.informativeText = "MBGA won't fill it in on \(login.site) any more."
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                core.deleteLogin(id: login.id)
                _ = core.persist()
                reload()
            }
        }
        let actions = NSStackView(views: [copy, show, delete])
        actions.spacing = 8

        let offer = checkbox("Offer to save passwords") { on in
            UserDefaults.standard.set(on, forKey: PasswordSettings.offersToSaveKey)
        }
        refreshers.append { offer.state = PasswordSettings.offersToSave ? .on : .off }

        let from = NSPopUpButton(frame: .zero, pullsDown: false)
        from.addItem(withTitle: "Looking for browsers…")
        from.isEnabled = false
        var choices: [(ImportSourceInfo, ImportProfileInfo)] = []
        let bring = NSButton.push("Import Passwords") {}
        bring.isEnabled = false
        bring.onAction { [store, weak bring] in
            guard let (source, browserProfile) = choices[safe: from.indexOfSelectedItem] else { return }
            bring?.isEnabled = false
            say("Importing…")
            Task {
                let outcome = await PasswordImport.bring(from: source, profileID: browserProfile.id, into: profileID(), store: store)
                _ = core.persist()
                say(PasswordImport.describe(outcome, from: source.name))
                reload()
                bring?.isEnabled = true
            }
        }
        let file = NSButton.push("Import a File…") { [store, weak self] in
            Task {
                guard let outcome = await PasswordImport.bringFile(into: profileID(), store: store, window: self?.view.window)
                else { return }
                say(PasswordImport.describe(outcome, from: "the file"))
                reload()
            }
        }
        let home = ProcessInfo.processInfo.environment["MBGA_IMPORT_HOME"] ?? NSHomeDirectory()
        Task { [weak self] in
            let sources = await Task.detached { core.detectBrowsers(home: home) }.value
            guard self != nil else { return }
            choices = sources.filter(PasswordImport.available).flatMap { s in
                s.profiles.filter { $0.passwords > 0 }.map { (s, $0) }
            }
            from.removeAllItems()
            for (source, browserProfile) in choices {
                let count = browserProfile.passwords
                from.addItem(withTitle: "\(SignIns.title(browserProfile, of: source)) (\(count.formatted()) password\(count == 1 ? "" : "s"))")
            }
            from.isEnabled = !choices.isEmpty
            bring.isEnabled = !choices.isEmpty
            if choices.isEmpty { from.addItem(withTitle: "No browsers with saved passwords") }
        }
        let importing = NSStackView(views: [bring, file])
        importing.spacing = 8

        return [
            [label("Profile:"), profile],
            [label("Passwords:"), list],
            [NSGridCell.emptyContentView, actions],
            [NSGridCell.emptyContentView, caption("MBGA offers these on their sites' sign-in pages and fills in the one you pick. Showing or copying a password asks for your Mac's password or Touch ID first.")],
            [label("Saving:"), offer],
            [label("Import from:"), from],
            [NSGridCell.emptyContentView, importing],
            [NSGridCell.emptyContentView, status],
            [NSGridCell.emptyContentView, caption("Passwords go into the profile above. macOS asks before MBGA can read a Chromium browser's key in your keychain. For Safari, choose File ▸ Export All Passwords in the Passwords app and import that file; other browsers and password managers export such files too.")],
        ]
    }

    private func developerRows() -> [[NSView]] {
        let enabled = NSSwitch()
        enabled.controlSize = .small
        enabled.onAction { [weak enabled] in
            UserDefaults.standard.set(enabled?.state == .on, forKey: DeveloperSettings.enabledKey)
        }
        let everywhere = popUp(["Local sites", "Every site"]) { i in
            UserDefaults.standard.set(i == 1, forKey: DeveloperSettings.everywhereKey)
        }
        let collapses = popUp(["Stays open", "Shrinks to the page's status", "Shrinks to a small handle"]) { i in
            UserDefaults.standard.set(i > 0, forKey: DeveloperSettings.collapsesKey)
            UserDefaults.standard.set(i == 2, forKey: DeveloperSettings.minimizedKey)
        }
        let anchors = DevToolbarAnchor.allCases
        let position = NSSegmentedControl(labels: ["Left", "Centre", "Right"], trackingMode: .selectOne, target: nil, action: nil)
        position.onAction { [weak position] in
            guard let position else { return }
            UserDefaults.standard.set(anchors[position.selectedSegment].rawValue, forKey: DeveloperSettings.anchorKey)
        }
        let devTools = popUp(["MBGA's sidebar", "Chrome DevTools beside the page", "Chrome DevTools in a window"]) { [store] i in
            UserDefaults.standard.set(i > 0, forKey: DeveloperSettings.chromeDevToolsKey)
            if i > 0 { UserDefaults.standard.set(i == 2, forKey: DeveloperSettings.devToolsInWindowKey) }
            store.devToolsChoiceChanged()
        }
        refreshers.append {
            devTools.selectItem(at: !DeveloperSettings.usesChromeDevTools ? 0 : DeveloperSettings.docksDevTools ? 1 : 2)
        }
        let dependents: [NSControl] = [everywhere, collapses, position]
        refreshers.append {
            let on = DeveloperSettings.enabled
            enabled.state = on ? .on : .off
            everywhere.selectItem(at: DeveloperSettings.everywhere ? 1 : 0)
            collapses.selectItem(at: !DeveloperSettings.collapses ? 0 : DeveloperSettings.minimized ? 2 : 1)
            position.selectedSegment = anchors.firstIndex(of: DeveloperSettings.anchor) ?? 1
            for control in dependents { control.isEnabled = on }
        }
        return [
            [label("Developer Mode:"), enabled],
            [NSGridCell.emptyContentView, caption("A toolbar floats over the top of the page: how it loaded, console errors, reload without the cache, element picking, dark mode and device previews, full-page screenshots and a QR code for your phone. The Develop menu appears too.")],
            [label("Show the toolbar on:"), everywhere],
            [NSGridCell.emptyContentView, caption("Local sites are localhost, .local and .test names, addresses on your network, and files. ⇧⌘D shows or hides it on any tab.")],
            [label("Toolbar:"), collapses],
            [label("Position:"), position],
            [NSGridCell.emptyContentView, caption("You can also drag the toolbar along the top of the page.")],
            [label("Developer tools:"), devTools],
            [NSGridCell.emptyContentView, caption("MBGA's sidebar sits right of the page with Elements, Console, Network, Sources, Application and Performance, following whichever tab you're on. Chrome's DevTools stay in its ⋯ menu. ⌥⌘I opens and closes them; drag the edge to resize.")],
        ]
    }

    private func agentRows() -> [[NSView]] {
        let enabled = NSSwitch()
        enabled.controlSize = .small
        enabled.onAction { [weak enabled] in
            UserDefaults.standard.set(enabled?.state == .on, forKey: AgentSettings.enabledKey)
        }
        let status = caption("")
        let install = NSButton.push("Install the mbga Command") {
            if let error = AgentSettings.installCommand() {
                status.stringValue = "Couldn't install it: \(error)"
            } else {
                status.stringValue = Self.installedNote
            }
        }
        let link = AgentSettings.commandLink.path
        let taught = caption("")
        let claude = NSButton.push("Add to Claude Code") {
            if let error = AgentSettings.installClaudeSkill() {
                taught.stringValue = "Couldn't add it: \(error)"
            } else {
                taught.stringValue = Self.skillNote
            }
        }
        let copy = NSButton.push("Copy Instructions") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AgentSettings.instructions, forType: .string)
            taught.stringValue = "Copied. Paste them into your agent's AGENTS.md or CLAUDE.md."
        }
        let teach = NSStackView(views: [claude, copy])
        teach.spacing = 8
        refreshers.append {
            enabled.state = AgentSettings.enabled ? .on : .off
            if taught.stringValue.isEmpty || taught.stringValue == Self.skillNote {
                taught.stringValue = FileManager.default.fileExists(atPath: AgentSettings.claudeSkill.path) ? Self.skillNote
                    : "Agents use mbga straight from their terminal. Claude Code learns it from a skill; other agents, from a few lines in their AGENTS.md."
            }
            if status.stringValue.isEmpty || status.stringValue == Self.installedNote {
                status.stringValue = FileManager.default.fileExists(atPath: link) ? Self.installedNote
                    : "Puts mbga in ~/.local/bin, so any terminal or agent can run it."
            }
        }
        let workspace = popUp(["In a space of their own", "In the space you're in"]) { [store] i in
            store.setAgentPreferences { $0.ownSpace = i == 0 }
        }
        let profile = NSPopUpButton(frame: .zero, pullsDown: false)
        profile.onAction { [store, weak profile] in
            guard let item = profile?.selectedItem else { return }
            store.setAgentPreferences {
                if item.tag == -1 {
                    $0.separateProfile = true
                } else {
                    $0.separateProfile = false
                    $0.profileID = UInt64(item.tag)
                }
            }
        }
        let blocked = sitesField(placeholder: "bank.com, mail.google.com") { [store] sites in
            store.setAgentPreferences { $0.blockedSites = sites }
        }
        refreshers.append { [store] in
            let preferences = store.agentPreferences
            workspace.selectItem(at: preferences.ownSpace ? 0 : 1)
            profile.removeAllItems()
            let mainProfile = store.snapshot.spaces.first?.profileId
            for info in store.snapshot.profiles where info.id != preferences.separateProfileID {
                profile.addItem(withTitle: info.name)
                profile.lastItem?.tag = Int(info.id)
            }
            profile.menu?.addItem(.separator())
            profile.addItem(withTitle: "A separate profile")
            profile.lastItem?.tag = -1
            let chosen = preferences.separateProfile ? -1 : Int(preferences.profileID ?? mainProfile ?? 0)
            profile.selectItem(withTag: chosen)
            profile.isEnabled = preferences.ownSpace
            if blocked.currentEditor() == nil { blocked.stringValue = preferences.blockedSites.joined(separator: ", ") }
        }
        return [
            [label("Agent access:"), enabled],
            [NSGridCell.emptyContentView, caption("Agents on this Mac (Claude Code and other coding agents, your scripts) can open tabs, read pages, click and type, with the mbga command in their terminal. They see pages as short outlines rather than screenshots, so it costs them few tokens. Only apps running as you can connect, and the page glows while an agent acts on it.")],
            [label("Agents work:"), workspace],
            [label("Signed in as:"), profile],
            [NSGridCell.emptyContentView, caption("In their own space, agents' tabs stay out of your sidebar and off your screen, so you both use MBGA at once; switch to the Agents space to watch them. Your profile shares your sign-ins; a separate one starts signed out, with its own cookies.")],
            [label("Keep agents off:"), blocked],
            [NSGridCell.emptyContentView, caption("Sites agents can't read, use or open, with their subdomains. Separate them with commas.")],
            [label("Command:"), install],
            [NSGridCell.emptyContentView, status],
            [label("Teach agents:"), teach],
            [NSGridCell.emptyContentView, taught],
        ]
    }

    private static let skillNote = "Claude Code has the mbga skill (~/.claude/skills/mbga-browser) and uses the browser when a task needs it."
    private static let installedNote = "Installed at ~/.local/bin/mbga. Run \"mbga help\" in a terminal to try it."

    private static let captionID = NSUserInterfaceItemIdentifier("caption")

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 340
        label.identifier = Self.captionID
        return label
    }

    private func checkbox(_ title: String, _ action: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.onAction { [weak button] in action(button?.state == .on) }
        return button
    }

    private static func select<T: Equatable>(_ button: NSPopUpButton, _ value: T, in choices: [(String, T)],
                                             title: (T) -> String) {
        if let i = choices.firstIndex(where: { $0.1 == value }) {
            while button.numberOfItems > choices.count { button.removeItem(at: choices.count) }
            button.selectItem(at: i)
        } else {
            let name = title(value)
            if button.numberOfItems == choices.count { button.addItem(withTitle: name) } else { button.lastItem?.title = name }
            button.selectItem(at: choices.count)
        }
    }

    private func sitesField(placeholder: String, _ action: @escaping ([String]) -> Void) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        field.onAction { [weak field] in
            let sites = (field?.stringValue ?? "").components(separatedBy: CharacterSet(charactersIn: ", \n"))
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            action(sites)
        }
        return field
    }

    private func popUp(_ titles: [String], _ action: @escaping (Int) -> Void) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.onAction { [weak button] in action(button?.indexOfSelectedItem ?? 0) }
        return button
    }
}
