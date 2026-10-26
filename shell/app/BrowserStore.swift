import AppKit

struct NavState: Equatable {
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
}

enum SidebarLayout: String, CaseIterable {
    case full, compact, focus

    var title: String {
        switch self {
        case .full: "Sidebar"
        case .compact: "Compact"
        case .focus: "Focus"
        }
    }

    static let defaultsKey = "sidebarLayout"
    static let debugCycling = ["MBGA_DEBUG_LAYOUTS", "MBGA_DEBUG_PEEK", "MBGA_DEBUG_LAYOUT"].contains {
        ProcessInfo.processInfo.environment[$0]?.isEmpty == false
    }

    static var saved: Self {
        if let raw = ProcessInfo.processInfo.environment["MBGA_DEBUG_LAYOUT"], let layout = Self(rawValue: raw) {
            return layout
        }
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: defaultsKey), let layout = Self(rawValue: raw) { return layout }
        return defaults.object(forKey: "sidebarVisible") as? Bool == false ? .focus : .full
    }
}

enum CommandBarMode: Equatable {
    case newTab
    case editCurrent
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var symbol = "checkmark"
    var undoable = false
}

extension NSPasteboard.PasteboardType {
    static let sidebarItem = NSPasteboard.PasteboardType("dev.mbga.browser.sidebar-item")
}

enum StoreChange {
    case snapshot, nav, layout, peek, commandBar, toast, media, cleanup, blocked
    case pageColors, dragOverPage, drag, renaming, spaceEditor, importSheet, chrome
    case developer
    case agent
    case inspector
    case elsewhere
    case extensions
    case update
}

struct NetworkEntry {
    let number: Int
    let requestID: String
    let method: String
    let url: String
    var type: String
    var status: Int?
    var mime = ""
    var size: Int?
    let started: Double
    var ended: Double?
    var failure: String?
}

struct ConsoleEntry {
    let level: Int
    let text: String
    let source: String
    let line: Int
}

@MainActor
final class BrowserStore: NSObject {
    let core: BrowserCore
    private(set) var snapshot: Snapshot {
        didSet {
            changed(.snapshot)
            ExtensionHost.shared?.setNeedsSync()
        }
    }
    private(set) var snapshotAnimation: Motion.Curve?
    private(set) var nav = NavState() {
        didSet { if nav != oldValue { changed(.nav) } }
    }
    var commandBar: CommandBarMode? {
        didSet {
            if commandBar != nil { releaseWebFocus() }
            if commandBar != oldValue { changed(.commandBar) }
        }
    }
    private(set) var layout = SidebarLayout.saved {
        didSet {
            if !SidebarLayout.debugCycling {
                UserDefaults.standard.set(layout.rawValue, forKey: SidebarLayout.defaultsKey)
            }
            if oldValue != .focus { layoutBeforeFocus = oldValue }
            sidebarPeek = false
            updateTrafficLights()
            changed(.layout)
        }
    }
    private var layoutBeforeFocus = SidebarLayout.full
    var sidebarPeek = false {
        didSet {
            guard sidebarPeek != oldValue else { return }
            updateTrafficLights()
            changed(.peek)
        }
    }
    var spaceEditor: SpaceEditorRequest? {
        didSet { changed(.spaceEditor) }
    }
    var importSheet: ImportRequest? {
        didSet {
            if importSheet != nil { releaseWebFocus() }
            changed(.importSheet)
        }
    }
    var renamingFolder: UInt64? {
        didSet {
            if renamingFolder != nil { releaseWebFocus() }
            if renamingFolder != oldValue { changed(.renaming) }
        }
    }
    private(set) var contentFullscreen = false {
        didSet { changed(.chrome) }
    }
    var windowRadius: CGFloat = 10 {
        didSet { changed(.chrome) }
    }
    private(set) var toast: Toast? {
        didSet { changed(.toast) }
    }
    private(set) var pausedMediaTab: UInt64? {
        didSet { changed(.media) }
    }
    private(set) var cleanupOffer: Int? {
        didSet { if cleanupOffer != oldValue { changed(.cleanup) } }
    }
    private(set) var visibleBlockedCount = 0 {
        didSet { if visibleBlockedCount != oldValue { changed(.blocked) } }
    }
    private var blockedCounts: [UInt64: Int] = [:]
    private var blockedCountTimer: Timer?
    private var devStates: [UInt64: DevTabState] = [:]
    private var devReports: [UInt64: DevPageReport] = [:]
    private var devToolbarOverrides: [UInt64: Bool] = [:]
    private(set) var inspectorOpen = InspectorSettings.debugPanel != nil
    var inspectorPanel = InspectorSettings.debugPanel ?? InspectorSettings.panel {
        didSet {
            if InspectorSettings.debugPanel == nil { UserDefaults.standard.set(inspectorPanel.rawValue, forKey: InspectorSettings.panelKey) }
            if inspectorPanel != oldValue { changed(.inspector) }
        }
    }
    private var inspectorSessions: [UInt64: InspectorSession] = [:]
    var openSettings: ((SettingsPane?) -> Void)?
    private(set) lazy var passwords = PasswordFiller(store: self)
    lazy var agentPreferences = AgentPreferences.load(from: dataDirectory)
    private var networkLogs: [UInt64: [NetworkEntry]] = [:]
    private var networkNumbers: [UInt64: Int] = [:]
    private var consoleLogs: [UInt64: [ConsoleEntry]] = [:]
    private(set) var agentActiveTabs: Set<UInt64> = []
    private var agentTimers: [UInt64: Timer] = [:]
    private(set) var pageColors: [String: RGB] = [:] {
        didSet { changed(.pageColors) }
    }
    private(set) var dragOverPage: UInt64? {
        didSet { if dragOverPage != oldValue { changed(.dragOverPage) } }
    }

    private struct Observer {
        weak var owner: AnyObject?
        let handle: @MainActor (StoreChange) -> Void
    }
    private var observers: [Observer] = []

    func observe(_ owner: AnyObject, _ handle: @escaping @MainActor (StoreChange) -> Void) {
        observers.append(Observer(owner: owner, handle: handle))
    }

    private func changed(_ change: StoreChange) {
        observers.removeAll { $0.owner == nil }
        for observer in observers where observer.owner != nil {
            observer.handle(change)
        }
    }

    var extensions: ExtensionHost { ExtensionHost.shared }
    weak var extensionButtons: ExtensionButtonsView?

    let pager = PagerModel()
    let webContainer = WebContainerView()
    weak var window: NSWindow?
    private(set) var draggingItem: UInt64? {
        didSet { if (draggingItem == nil) != (oldValue == nil) { changed(.drag) } }
    }

    var isDragging: Bool { draggingItem != nil }

    private(set) var views: [UInt64: MBWebView] = [:]
    private(set) var navStates: [UInt64: NavState] = [:]
    private var refreshPending = false
    private var persistTimer: Timer?
    private var toastTimer: Timer?
    private var littleWindows: [UInt64: LittleWindow] = [:]
    private var enteredFullscreenForContent = false
    private var lastVisibleTab: UInt64?
    private var shownSpace: UInt64?

    private static let open = NSHashTable<BrowserStore>.weakObjects()
    private(set) weak static var front: BrowserStore?
    var isFront: Bool { Self.front === self }
    private var ownSpace: UInt64
    private var ownTabs: [UInt64: UInt64?]
    private var coreSnapshot: Snapshot
    private var keptAwake: UInt64?
    private(set) var visibleTabElsewhere = false {
        didSet { if visibleTabElsewhere != oldValue { changed(.elsewhere) } }
    }
    private(set) var elsewhereImage: NSImage? {
        didSet { changed(.elsewhere) }
    }
    private var mirroredTab: UInt64?
    private var mirrorTimer: Timer?
    private var mirrorPending = false

    init(core: BrowserCore, newWindow: Bool = false) {
        self.core = core
        let snapshot = core.snapshot()
        coreSnapshot = snapshot
        ownSpace = snapshot.activeSpace
        ownTabs = Dictionary(uniqueKeysWithValues: snapshot.spaces.map { ($0.id, $0.activeTab) })
        if newWindow { ownTabs[snapshot.activeSpace] = .some(nil) }
        self.snapshot = snapshot
        super.init()
        self.snapshot = ownView(of: snapshot)
        Self.open.add(self)
        pager.pageCount = snapshot.spaces.count
        pager.setPosition(CGFloat(activeSpaceIndex), animated: false)
        pager.onSettle = { [weak self] index in
            guard let self, snapshot.spaces.indices.contains(index) else { return }
            activateSpace(snapshot.spaces[index].id)
        }
        pager.onSwipeTowards = { [weak self] index in
            guard let self, snapshot.spaces.indices.contains(index) else { return }
            warmSpace(snapshot.spaces[index].id)
        }
        webContainer.viewport = { [weak self] view in self?.devStates[view.tabID]?.viewport }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    var activeSpace: SpaceInfo {
        snapshot.spaces.first { $0.id == snapshot.activeSpace } ?? snapshot.spaces[0]
    }

    var activeSpaceIndex: Int {
        snapshot.spaces.firstIndex { $0.id == snapshot.activeSpace } ?? 0
    }

    var visibleTabID: UInt64? { activeSpace.activeTab }

    func isLoading(_ tab: UInt64) -> Bool { navStates[tab]?.isLoading ?? false }

    var visibleTab: TabInfo? { visibleTabID.flatMap { core.tab(id: $0) } }

    var orderedTabs: [TabInfo] {
        let space = activeSpace
        return space.favorites + space.pinned.compactMap(\.tab) + space.today
    }

    func isFavorite(_ id: UInt64, in space: SpaceInfo) -> Bool {
        space.favorites.contains { $0.id == id }
    }

    func isPinned(_ id: UInt64, in space: SpaceInfo) -> Bool {
        space.pinned.contains { $0.id == id }
    }

    private func space(owning tabID: UInt64) -> SpaceInfo? {
        snapshot.spaces.first { s in
            s.today.contains { $0.id == tabID } || s.pinned.contains { $0.id == tabID }
        }
    }

    func setNeedsRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh(animation: Motion.Curve? = nil) {
        refreshPending = false
        if core.revision() != snapshot.revision {
            noteCore(core.snapshot())
            applyChoices(animation: animation)
            schedulePersist()
            for store in Self.open.allObjects where store !== self { store.setNeedsRefresh() }
        }
        syncWebViews()
    }

    private func applyChoices(animation: Motion.Curve? = nil) {
        pager.pageCount = coreSnapshot.spaces.count
        snapshotAnimation = animation
        snapshot = ownView(of: coreSnapshot)
        snapshotAnimation = nil
        pager.show(activeSpaceIndex, animated: true)
    }

    private func syncWebViews() {
        let visible = visibleTabID
        if let id = visible, views[id] == nil, let tab = core.tab(id: id) {
            if let holder = Self.holder(of: id) {
                if isFront || !holder.isShowing(id) { adopt(id, from: holder) }
            } else {
                createView(for: tab)
            }
        }
        visibleTabElsewhere = visible.map { views[$0] == nil && Self.holder(of: $0) != nil } ?? false
        syncMirror()
        keepAwake(isFront || window?.isVisible != true ? nil : visible.flatMap { views[$0] != nil ? $0 : nil })
        if let id = visible, core.thaw(id: id) {
            views[id]?.setFrozen(false)
        }
        let switchedSpace = shownSpace != nil && shownSpace != snapshot.activeSpace
        shownSpace = snapshot.activeSpace
        webContainer.show(visible.flatMap { views[$0] }, crossfade: switchedSpace)
        nav = visible.flatMap { navStates[$0] } ?? NavState()
        publishBlockedCount()
        if lastVisibleTab != visible {
            if let previous = lastVisibleTab {
                views[previous]?.probeMedia()
                if devStates[previous]?.picking == true {
                    devStates[previous]?.picking = false
                    views[previous]?.setPicking(false)
                }
            }
            lastVisibleTab = visible
            passwords.hide()
            changed(.developer)
            changed(.agent)
            syncInspector()
        } else if inspectorOpen, let id = visible, views[id] != nil, inspectorSessions[id] == nil {
            syncInspector()
        }
    }

    private func createView(for tab: TabInfo) {
        guard Self.holder(of: tab.id) == nil, let profile = core.profileOfTab(tabId: tab.id) else { return }
        let url = tab.url.isEmpty ? "about:blank" : tab.url
        let view = MBWebView(url: url, profilePath: core.profileDir(profileId: profile), tabID: tab.id)
        view.delegate = self
        view.picksForInspector = !DeveloperSettings.usesChromeDevTools
        if let state = devStates[tab.id] { view.apply(state) }
        views[tab.id] = view
        webContainer.add(view)
        core.setLive(id: tab.id, live: true)
        setNeedsRefresh()
    }

    private func destroyView(_ id: UInt64) {
        for store in Self.open.allObjects { store.dropView(id) }
    }

    private func dropView(_ id: UInt64) {
        if let little = littleWindows.removeValue(forKey: id) {
            core.setShownElsewhere(id: id, shown: false)
            little.dismiss()
        }
        guard let view = views.removeValue(forKey: id) else { return }
        navStates[id] = nil
        blockedCounts[id] = nil
        devReports[id] = nil
        consoleLogs[id] = nil
        networkLogs[id] = nil
        inspectorSessions.removeValue(forKey: id)?.stop()
        passwords.forget(id)
        devStates[id]?.picking = false
        if pausedMediaTab == id { pausedMediaTab = nil }
        webContainer.stopDrawing(view)
        view.close()
    }

    private func destroyViews(_ ids: [UInt64]?) {
        ids?.forEach(destroyView)
    }

    private func releaseWebFocus() {
        window?.makeFirstResponder(nil)
    }

    private func focusVisibleContent() {
        if let id = visibleTabID { views[id]?.focusContent() }
    }

    private func schedulePersist() {
        guard persistTimer?.isValid != true else { return }
        let timer = Timer(timeInterval: 2, repeats: false) { [core] _ in _ = core.persist() }
        RunLoop.main.add(timer, forMode: .common)
        persistTimer = timer
    }

    func select(_ tabID: UInt64, in spaceID: UInt64? = nil) {
        if let little = littleWindows[tabID] {
            little.putBack()
            return
        }
        if let holder = Self.holder(of: tabID), holder !== self {
            if let little = holder.littleWindows[tabID] { return little.show() }
            adopt(tabID, from: holder)
        }
        choose(space: spaceID ?? activeSpace.id, tab: tabID)
        focusVisibleContent()
    }

    private func choose(space spaceID: UInt64, tab tabID: UInt64?) {
        ownSpace = spaceID
        if let tabID { ownTabs[spaceID] = .some(tabID) }
        if isFront {
            if spaceID != coreSnapshot.activeSpace { core.setActiveSpace(id: spaceID) }
            if let tabID { core.activateTab(spaceId: spaceID, tabId: tabID) }
        }
        refresh()
        if ownView(of: coreSnapshot) != snapshot {
            applyChoices()
            syncWebViews()
        }
    }

    func submit(_ input: String, mode: CommandBarMode) {
        open(core.resolveInput(text: input), mode: mode)
    }

    func search(_ query: String, mode: CommandBarMode) {
        open(core.searchUrl(text: query), mode: mode)
    }

    private func open(_ url: String, mode: CommandBarMode) {
        commandBar = nil
        guard !url.isEmpty else { return }
        if MBEngine.isExtensionsPage(url) {
            showExtensions(url: url)
            return
        }
        if mode == .editCurrent, let id = visibleTabID {
            core.updateTab(id: id, url: url, title: nil)
            views[id]?.loadURL(url)
        } else {
            _ = core.openTab(spaceId: activeSpace.id, url: url, activate: true)
        }
        refresh()
        focusVisibleContent()
    }

    func openFromSystem(_ url: String) {
        commandBar = nil
        if MBEngine.isExtensionsPage(url) {
            showExtensions(url: url)
            return
        }
        _ = core.openTab(spaceId: activeSpace.id, url: url, activate: true)
        refresh()
    }

    func close(_ tabID: UInt64) {
        _ = core.closeTab(id: tabID)
        destroyView(tabID)
        refresh()
    }

    func sleep(_ tabID: UInt64) {
        guard Self.holder(of: tabID) != nil else { return }
        destroyView(tabID)
        core.setLive(id: tabID, live: false)
        refresh()
    }

    func undoClose() {
        toast = nil
        guard let outcome = core.undoClose() else { return }
        refresh()
        if outcome.tabs.count == 1, let id = outcome.tabs.first { select(id, in: outcome.spaceId) }
    }

    func reopenClosedTab(_ id: UInt64) {
        guard let space = core.reopenTab(id: id) else { return }
        select(id, in: space)
    }

    var canReopen: Bool { snapshot.canReopen }

    func duplicate(_ tab: TabInfo, in space: SpaceInfo) {
        _ = core.openTab(spaceId: space.id, url: tab.url, activate: true)
        refresh()
    }

    func togglePin(_ tabID: UInt64, in space: SpaceInfo? = nil) {
        let space = space ?? activeSpace
        if isPinned(tabID, in: space) || isFavorite(tabID, in: space) {
            destroyViews(core.unpinTab(id: tabID))
        } else {
            destroyViews(core.pinTab(id: tabID))
        }
        refresh()
    }

    func togglePinVisibleTab() {
        if let id = visibleTabID { togglePin(id) }
    }

    func setKeepAwake(_ keep: Bool, for tab: TabInfo) {
        core.setKeepAwake(url: tab.url, keep: keep)
        refresh()
    }

    var sleepAfterSecs: UInt64 { snapshot.sleepAfterSecs }
    var maxLiveTabs: UInt32 { snapshot.maxLiveTabs }

    func setSleepPolicy(afterSecs: UInt64? = nil, maxLiveTabs: UInt32? = nil) {
        core.setPolicy(sleepAfterSecs: afterSecs ?? sleepAfterSecs, maxLiveTabs: maxLiveTabs ?? self.maxLiveTabs)
        refresh()
        sleepIdleTabs()
    }

    var keepAwakeSites: [String] { snapshot.keepAwakeSites }

    func setKeepAwakeSites(_ sites: [String]) {
        core.setKeepAwakeSites(sites: sites)
        refresh()
    }

    func setAlwaysAwake(_ awake: Bool, for tabID: UInt64) {
        core.setAlwaysAwake(id: tabID, awake: awake)
        if awake {
            if let holder = Self.holder(of: tabID) {
                if core.thaw(id: tabID) { holder.views[tabID]?.setFrozen(false) }
            } else {
                warmTab(tabID)
            }
        }
        refresh()
    }

    func wakeAlwaysAwakeTabs() {
        for (n, id) in core.alwaysAwakeTabs().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(n) * 0.5) { [weak self] in
                guard let self, Self.holder(of: id) == nil else { return }
                warmTab(id)
            }
        }
    }

    func addFavorite(_ tabID: UInt64) {
        destroyViews(core.addFavorite(id: tabID))
        refresh()
    }

    func move(_ id: UInt64, to target: DropTarget, index: Int) {
        destroyViews(core.moveItem(id: id, target: target, index: UInt32(clamping: index)))
        refresh()
    }

    func clearToday(_ spaceID: UInt64) {
        let closed = core.clearToday(spaceId: spaceID)
        destroyViews(closed)
        refresh(animation: Motion.settle)
        if !closed.isEmpty {
            showToast(Toast(message: closed.count == 1 ? "Archived 1 tab" : "Archived \(closed.count) tabs",
                            symbol: "archivebox", undoable: true))
        }
    }

    static let cleanupOfferHours: UInt32 = 12

    func updateCleanupOffer() {
        guard !snapshot.cleanupAnswered else {
            if cleanupOffer != nil { cleanupOffer = nil }
            return
        }
        let count = Int(core.idleTodayCount(spaceId: activeSpace.id, hours: Self.cleanupOfferHours))
        let offer = count >= 5 ? count : nil
        if offer != cleanupOffer { cleanupOffer = offer }
    }

    enum CleanupAnswer { case notNow, once, daily }

    func answerCleanup(_ answer: CleanupAnswer) {
        core.answerCleanup()
        cleanupOffer = nil
        if answer == .daily { core.setArchiveAfterHours(hours: 24) }
        if answer != .notNow {
            let archived = core.archiveIdle(spaceId: activeSpace.id, hours: Self.cleanupOfferHours)
            destroyViews(archived)
            refresh(animation: Motion.settle)
            showToast(Toast(message: "Archived \(archived.count) tabs", symbol: "archivebox", undoable: true))
        } else {
            refresh()
        }
    }

    var archiveAfterHours: UInt32 { snapshot.archiveAfterHours }

    func setArchiveAfterHours(_ hours: UInt32) {
        core.setArchiveAfterHours(hours: hours)
        if !snapshot.cleanupAnswered { core.answerCleanup() }
        refresh()
        updateCleanupOffer()
    }

    func showToast(_ toast: Toast, duration: TimeInterval = 4) {
        self.toast = toast
        toastTimer?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.toast?.id == toast.id else { return }
                self.toast = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        toastTimer = timer
    }

    func dismissToast() {
        toast = nil
    }

    func selectTab(at index: Int) {
        let tabs = orderedTabs
        let i = index == 8 ? tabs.count - 1 : index
        if tabs.indices.contains(i) { select(tabs[i].id) }
    }

    func selectAdjacentTab(_ offset: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == visibleTabID } ?? -1
        let next = (current + offset + tabs.count) % tabs.count
        select(tabs[next].id)
    }

    var visibleView: MBWebView? { visibleTabID.flatMap { views[$0] } }

    func goBack() { visibleView?.goBack() }
    func goForward() { visibleView?.goForward() }
    func reloadOrStop() {
        if nav.isLoading { visibleView?.stopLoading() } else { visibleView?.reload() }
    }
    func reload() { visibleView?.reload() }
    func zoomIn() { visibleView?.zoomIn() }
    func zoomOut() { visibleView?.zoomOut() }
    func resetZoom() { visibleView?.resetZoom() }
    func showDevTools() {
        guard DeveloperSettings.usesChromeDevTools else { return toggleInspector() }
        guard let view = visibleView else { return }
        if view.devToolsWindow != nil { view.closeDevTools() } else { view.showDevTools() }
    }

    func openDevTools() {
        guard DeveloperSettings.usesChromeDevTools else { return showInspector(.console) }
        visibleView?.showDevTools()
    }

    func openChromeDevTools() { visibleView?.showDevTools() }

    var visibleDevToolsOpen: Bool {
        DeveloperSettings.usesChromeDevTools ? visibleView?.devToolsWindow != nil : inspectorOpen
    }

    func devToolsChoiceChanged() {
        let shell = !DeveloperSettings.usesChromeDevTools
        for view in views.values { view.picksForInspector = shell }
        if !shell { closeInspector() }
        changed(.developer)
    }

    func toggleInspector() {
        if inspectorOpen { closeInspector() } else { showInspector(nil) }
    }

    func showInspector(_ panel: InspectorPanelKind?) {
        if let panel { inspectorPanel = panel }
        guard !inspectorOpen else { return }
        inspectorOpen = true
        syncInspector(force: true)
    }

    func closeInspector() {
        guard inspectorOpen else { return }
        inspectorOpen = false
        if visibleDevState.picking { togglePicking() }
        for session in inspectorSessions.values { session.stop() }
        inspectorSessions = [:]
        changed(.inspector)
        changed(.developer)
    }

    var inspectorSession: InspectorSession? {
        guard inspectorOpen, let id = visibleTabID else { return nil }
        return inspectorSessions[id]
    }

    private func syncInspector(force: Bool = false) {
        guard inspectorOpen else { return }
        if let id = visibleTabID, let view = views[id], inspectorSessions[id] == nil {
            let session = InspectorSession(view: view)
            session.showPanel = { [weak self] panel in self?.inspectorPanel = panel }
            session.openTab = { [weak self] url in
                guard let self else { return }
                _ = core.openTab(spaceId: space(owning: id)?.id ?? activeSpace.id, url: url, activate: false)
                refresh()
            }
            session.developerState = { [weak self] in self?.devStates[id] ?? DevTabState() }
            session.updateDeveloperState = { [weak self] change in
                guard let self, visibleTabID == id else { return }
                updateDev(change)
            }
            inspectorSessions[id] = session
        }
        changed(.inspector)
        if force { changed(.developer) }
    }

    func reloadIgnoringCache() { visibleView?.reloadIgnoringCache() }

    func copyVisibleURL() {
        if let url = visibleTab?.url { copyLink(url) }
    }

    func copyLink(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        showToast(Toast(message: "Link copied", symbol: "link"), duration: 1.6)
    }

    var mediaTab: (tab: TabInfo, space: SpaceInfo)? {
        var found: (TabInfo, SpaceInfo)?
        for space in snapshot.spaces {
            for tab in space.favorites + space.pinned.compactMap(\.tab) + space.today
                where tab.id != visibleTabID && tab.live && (tab.audible || tab.id == pausedMediaTab)
                && !Self.open.allObjects.contains(where: { $0.isShowing(tab.id) }) {
                if tab.id == pausedMediaTab { return (tab, space) }
                if found == nil { found = (tab, space) }
            }
        }
        return found
    }

    func toggleMedia(_ tabID: UInt64) {
        let pause = pausedMediaTab != tabID
        keeper(of: tabID).views[tabID]?.setMediaPaused(pause)
        pausedMediaTab = pause ? tabID : nil
    }

    func dismissMedia() {
        pausedMediaTab = nil
    }

    func activateSpace(_ id: UInt64) {
        guard id != snapshot.activeSpace else { return }
        if isFront { _ = core.selectDefaultTab(spaceId: id) }
        choose(space: id, tab: nil)
        updateCleanupOffer()
    }

    func warmTab(_ id: UInt64) {
        guard views[id] == nil, let tab = core.tab(id: id), !tab.url.isEmpty else { return }
        createView(for: tab)
    }

    func warmSpace(_ id: UInt64) {
        guard id != snapshot.activeSpace else { return }
        if let tab = core.selectDefaultTab(spaceId: id) ?? snapshot.spaces.first(where: { $0.id == id })?.activeTab {
            warmTab(tab)
        }
    }

    func warmOtherSpaces() {
        let current = activeSpaceIndex
        let others = snapshot.spaces.indices.filter { $0 != current }.sorted { abs($0 - current) < abs($1 - current) }
        for (n, index) in others.prefix(4).enumerated() {
            let id = snapshot.spaces[index].id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(n) * 0.8) { [weak self] in
                self?.warmSpace(id)
            }
        }
    }

    func showDefaultTab() {
        if core.selectDefaultTab(spaceId: activeSpace.id) != nil { refresh() }
    }

    func activateSpace(at index: Int) {
        if snapshot.spaces.indices.contains(index) { activateSpace(snapshot.spaces[index].id) }
    }

    func activateAdjacentSpace(_ offset: Int) {
        activateSpace(at: min(max(activeSpaceIndex + offset, 0), snapshot.spaces.count - 1))
    }

    func createSpace(name: String, icon: String, color: UInt32, profileID: UInt64) {
        let id = core.createSpace(name: name, icon: icon, color: color, profileId: profileID)
        choose(space: id, tab: nil)
    }

    func updateSpace(_ id: UInt64, name: String, icon: String, color: UInt32, profileID: UInt64) {
        core.updateSpace(id: id, name: name, icon: icon, color: color)
        destroyViews(core.setSpaceProfile(id: id, profileId: profileID))
        refresh()
    }

    func setProfile(_ profileID: UInt64, for spaceID: UInt64) {
        destroyViews(core.setSpaceProfile(id: spaceID, profileId: profileID))
        refresh()
    }

    func deleteSpace(_ id: UInt64) {
        destroyViews(core.deleteSpace(id: id))
        refresh()
        showDefaultTab()
    }

    func createProfile(_ name: String) -> UInt64 {
        let id = core.createProfile(name: name)
        refresh()
        return id
    }

    func renameProfile(_ id: UInt64, name: String) {
        core.renameProfile(id: id, name: name)
        refresh()
    }

    func deleteProfile(_ id: UInt64) {
        destroyViews(core.deleteProfile(id: id))
        refresh()
    }

    func newFolder(in spaceID: UInt64? = nil, parent: UInt64? = nil) {
        let spaceID = spaceID ?? activeSpace.id
        if let id = core.createFolder(spaceId: spaceID, name: "New Folder", parent: parent) {
            renamingFolder = id
        }
        refresh()
    }

    func renameFolder(_ id: UInt64, to name: String) {
        renamingFolder = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { core.renameFolder(id: id, name: trimmed) }
        refresh()
    }

    func setFolder(_ id: UInt64, expanded: Bool) {
        core.setFolderExpanded(id: id, expanded: expanded)
        refresh(animation: Motion.quick)
    }

    func deleteFolder(_ id: UInt64) {
        let name = activeSpace.pinned.first { $0.id == id }?.folderName
        destroyViews(core.deleteFolder(id: id))
        refresh()
        showToast(Toast(message: name.map { "Deleted “\($0)”" } ?? "Deleted folder", symbol: "trash", undoable: true))
    }

    func beginDrag(_ id: UInt64) {
        draggingItem = id
        MBEngine.setRejectsDrops(true)
    }

    func dragMoved(to point: NSPoint) {
        guard let id = draggingItem else { return }
        let overPage = core.tab(id: id) != nil && pageFrameOnScreen?.contains(point) == true
            && sidebarFrameOnScreen?.contains(point) != true
        dragOverPage = overPage ? id : nil
    }

    func endDrag(at point: NSPoint, accepted: Bool) {
        MBEngine.setRejectsDrops(false)
        let id = draggingItem
        draggingItem = nil
        let overPage = dragOverPage != nil
        dragOverPage = nil
        if let id, !accepted, overPage, core.tab(id: id) != nil {
            openInLittleWindow(id, near: point)
        }
    }

    func drop(_ id: UInt64, on target: DropTarget, index: Int) {
        move(id, to: target, index: index)
    }

    func dropURL(_ url: String, on target: DropTarget, index: Int) {
        guard let space = spaceID(of: target),
              let id = core.openTab(spaceId: space, url: url, activate: false)
        else { return }
        move(id, to: target, index: index)
    }

    private var pageFrameOnScreen: NSRect? {
        guard let window, webContainer.window === window else { return nil }
        return window.convertToScreen(webContainer.convert(webContainer.bounds, to: nil))
    }

    private var sidebarFrameOnScreen: NSRect? {
        guard let window, let sidebar = pager.sidebar, sidebar.window === window,
              !sidebar.isHiddenOrHasHiddenAncestor else { return nil }
        return window.convertToScreen(sidebar.convert(sidebar.bounds, to: nil))
    }

    func openInLittleWindow(_ tabID: UInt64, near point: NSPoint? = nil) {
        if let little = littleWindows[tabID] {
            little.show()
            return
        }
        guard let tab = core.tab(id: tabID) else { return }
        if views[tabID] == nil {
            if let holder = Self.holder(of: tabID) { adopt(tabID, from: holder) } else { createView(for: tab) }
        }
        guard let view = views[tabID] else { return }
        if core.thaw(id: tabID) { view.setFrozen(false) }
        core.setShownElsewhere(id: tabID, shown: true)
        _ = core.stepAway(id: tabID)
        let little = LittleWindow(tabID: tabID, view: view, store: self, near: point)
        littleWindows[tabID] = little
        refresh()
        little.show()
    }

    func isInLittleWindow(_ tabID: UInt64) -> Bool {
        littleWindows[tabID] != nil
    }

    func littleWindowClosed(_ tabID: UInt64, select: Bool) {
        guard littleWindows.removeValue(forKey: tabID) != nil else { return }
        core.setShownElsewhere(id: tabID, shown: false)
        if let view = views[tabID] { webContainer.add(view) }
        if select {
            self.select(tabID)
            window?.makeKeyAndOrderFront(nil)
        } else {
            refresh()
        }
    }

    private func spaceID(of target: DropTarget) -> UInt64? {
        switch target {
        case .pinned(let spaceId, _), .today(let spaceId): spaceId
        case .favorites: activeSpace.id
        }
    }

    func tintColors(matchPage: Bool, dark: Bool) -> [UInt32] {
        var colors = snapshot.spaces.map(\.color)
        guard matchPage, colors.indices.contains(activeSpaceIndex),
              let site = visibleTab?.site, let page = pageColors[site],
              dark ? page.luminance <= 0.7 : page.luminance >= 0.2
        else { return colors }
        colors[activeSpaceIndex] = page.hex
        return colors
    }

    var blockAds: Bool { snapshot.blockAds }

    func setBlockAds(_ enabled: Bool) {
        core.setBlockAds(enabled: enabled)
        refresh()
        guard enabled else {
            reload()
            return
        }
        let core = core
        Task {
            _ = await Task.detached(priority: .userInitiated) { core.loadFilters() }.value
            reload()
        }
    }

    func setAdsAllowed(_ allowed: Bool, for tab: TabInfo) {
        core.setAdsAllowed(url: tab.url, allowed: allowed)
        refresh()
        views[tab.id]?.reload()
    }

    func showExtensions(url: String = "") {
        MBEngine.showExtensions(forProfilePath: core.profileDir(profileId: activeSpace.profileId), url: url)
    }

    func runExtensionAction(_ key: ExtensionHost.Key, from anchor: NSView?) {
        guard let tab = visibleTabID, let popup = extensions.clickAction(key, tab: tab) else { return }
        guard let anchor = anchor ?? extensionButtons?.anchor(for: key.extensionID) ?? window?.contentView else { return }
        ExtensionPopup.show(url: popup, profilePath: key.profile, from: anchor, store: self)
    }

    var strictSiteIsolation: Bool { snapshot.strictSiteIsolation }

    func setStrictSiteIsolation(_ strict: Bool) {
        core.setStrictSiteIsolation(strict: strict)
        refresh()
    }

    func toggleSidebar() {
        setLayout(layout == .focus ? layoutBeforeFocus : .focus)
    }

    func setLayout(_ layout: SidebarLayout) {
        self.layout = layout
    }

    private var lightsOffset = CGSize.zero
    private var lightsNativeX: [NSWindow.ButtonType: CGFloat] = [:]
    private var lightsObservers: [NSObjectProtocol] = []
    private var placingLights = false
    static let trafficLightsCenterY: CGFloat = 21

    func offsetTrafficLights(_ offset: CGSize) {
        lightsOffset = offset
        placeTrafficLights()
    }

    private func placeTrafficLights() {
        guard let window, !placingLights else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { type in window.standardWindowButton(type).map { (type, $0) } }
        if lightsNativeX.isEmpty {
            for (type, button) in buttons { lightsNativeX[type] = button.frame.minX }
            for (_, button) in buttons {
                button.postsFrameChangedNotifications = true
                lightsObservers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: button, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.placingLights {
                            DispatchQueue.main.async { [weak self] in self?.placeTrafficLights() }
                        } else {
                            self.placeTrafficLights()
                        }
                    }
                })
            }
        }
        placingLights = true
        defer { placingLights = false }
        for (type, button) in buttons {
            guard let x = lightsNativeX[type], let container = button.superview else { continue }
            let top = container.isFlipped ? 0 : container.bounds.height
            let topInWindow = container.convert(NSPoint(x: 0, y: top), to: nil).y
            let inset = (window.contentView?.bounds.height ?? topInWindow) - topInWindow
            let centerFromTop = Self.trafficLightsCenterY + lightsOffset.height - inset
            let y = container.isFlipped ? centerFromTop - button.frame.height / 2
                : container.bounds.height - centerFromTop - button.frame.height / 2
            let origin = NSPoint(x: x + lightsOffset.width, y: y.rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    func updateTrafficLights() {
        let hidden = (layout == .focus && !sidebarPeek) || contentFullscreen
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window?.standardWindowButton($0) }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !contentFullscreen
        if !hidden {
            for button in buttons where button.isHidden {
                button.alphaValue = animate ? 0 : 1
                button.isHidden = false
            }
            placeTrafficLights()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.14 : 0
            for button in buttons { button.animator().alphaValue = hidden ? 0 : 1 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, hidden, (self.layout == .focus && !self.sidebarPeek)
                    || self.contentFullscreen else { return }
                for button in buttons { button.isHidden = true }
            }
        }
    }

    func sleepIdleTabs(pressure: MemoryPressure = .normal) {
        let archived = core.archiveByPolicy()
        destroyViews(archived)
        let sleepers = core.collectSleepers(pressure: pressure)
        sleepers.forEach(destroyView)
        let freezers = core.collectFreezers()
        for id in freezers { keeper(of: id).views[id]?.setFrozen(true) }
        if !archived.isEmpty || !sleepers.isEmpty || !freezers.isEmpty { setNeedsRefresh() }
        for store in Self.open.allObjects {
            for (id, view) in store.views where id != store.visibleTabID { view.probeMedia() }
        }
        updateCleanupOffer()
    }
}

extension BrowserStore {
    private func ownView(of core: Snapshot) -> Snapshot {
        var view = core
        if view.spaces.contains(where: { $0.id == ownSpace }) { view.activeSpace = ownSpace }
        for i in view.spaces.indices {
            guard let own = ownTabs[view.spaces[i].id] else { continue }
            view.spaces[i].activeTab = own.flatMap { id in Self.holds(view.spaces[i], id) ? id : nil }
        }
        return view
    }

    private static func holds(_ space: SpaceInfo, _ id: UInt64) -> Bool {
        space.favorites.contains { $0.id == id } || space.pinned.contains { $0.tab?.id == id }
            || space.today.contains { $0.id == id }
    }

    private func noteCore(_ next: Snapshot) {
        if isFront {
            if next.activeSpace != coreSnapshot.activeSpace { ownSpace = next.activeSpace }
            for space in next.spaces {
                let before = coreSnapshot.spaces.first { $0.id == space.id }
                if before == nil || before?.activeTab != space.activeTab { ownTabs[space.id] = .some(space.activeTab) }
            }
        }
        if !next.spaces.contains(where: { $0.id == ownSpace }) { ownSpace = next.activeSpace }
        coreSnapshot = next
    }

    func becomeFront() {
        guard !isFront else { return }
        Self.front = self
        let current = core.snapshot()
        if snapshot.activeSpace != current.activeSpace { core.setActiveSpace(id: snapshot.activeSpace) }
        for space in snapshot.spaces {
            if let tab = space.activeTab, current.spaces.first(where: { $0.id == space.id })?.activeTab != tab {
                core.activateTab(spaceId: space.id, tabId: tab)
            }
        }
        coreSnapshot = core.snapshot()
        refresh()
        Self.windowsChanged()
    }

    static func windowsChanged() {
        for store in open.allObjects { store.setNeedsRefresh() }
    }

    func windowClosed() {
        Self.open.remove(self)
        if isFront { Self.front = nil }
        keepAwake(nil)
        for id in Array(views.keys) {
            dropView(id)
            core.setLive(id: id, live: false)
        }
        Self.windowsChanged()
    }

    static var windows: [BrowserStore] { open.allObjects }

    static func extensionsChanged() {
        for store in open.allObjects { store.changed(.extensions) }
    }

    static func updateChanged() {
        for store in open.allObjects { store.changed(.update) }
    }

    fileprivate static func holder(of id: UInt64) -> BrowserStore? {
        open.allObjects.first { $0.views[id] != nil }
    }

    private func keeper(of id: UInt64) -> BrowserStore {
        Self.holder(of: id) ?? self
    }

    private func isShowing(_ id: UInt64) -> Bool {
        littleWindows[id] != nil || (visibleTabID == id && window?.isVisible == true)
    }

    private func syncMirror() {
        let id = visibleTabElsewhere && window?.isVisible == true ? visibleTabID : nil
        guard id != mirroredTab else { return }
        mirroredTab = id
        mirrorTimer?.invalidate()
        mirrorTimer = nil
        elsewhereImage = nil
        guard id != nil else { return }
        captureMirror()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureMirror() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mirrorTimer = timer
    }

    private func captureMirror() {
        guard let id = mirroredTab, !mirrorPending, window?.occlusionState.contains(.visible) == true,
              let view = Self.holder(of: id)?.views[id] else { return }
        mirrorPending = true
        let params = #"{"format":"jpeg","quality":85,"optimizeForSpeed":true}"#
        view.sendDevToolsCommand("Page.captureScreenshot", params: params) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mirrorPending = false
                guard self.mirroredTab == id, let data = result?.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let base64 = object["data"] as? String, let jpeg = Data(base64Encoded: base64),
                      let image = NSImage(data: jpeg) else { return }
                self.elsewhereImage = image
            }
        }
    }

    private struct LoadedTab {
        let view: MBWebView
        let nav: NavState?
        let dev: DevTabState?
        let report: DevPageReport?
        let blocked: Int?
        let console: [ConsoleEntry]?
        let network: [NetworkEntry]?
    }

    private func adopt(_ id: UInt64, from other: BrowserStore) {
        guard let tab = other.release(id) else { return }
        views[id] = tab.view
        navStates[id] = tab.nav
        devStates[id] = tab.dev
        devReports[id] = tab.report
        blockedCounts[id] = tab.blocked
        consoleLogs[id] = tab.console
        networkLogs[id] = tab.network
        tab.view.delegate = self
        webContainer.add(tab.view)
    }

    private func release(_ id: UInt64) -> LoadedTab? {
        guard littleWindows[id] == nil, let view = views.removeValue(forKey: id) else { return nil }
        let tab = LoadedTab(view: view, nav: navStates.removeValue(forKey: id), dev: devStates.removeValue(forKey: id),
                            report: devReports.removeValue(forKey: id), blocked: blockedCounts.removeValue(forKey: id),
                            console: consoleLogs.removeValue(forKey: id), network: networkLogs.removeValue(forKey: id))
        inspectorSessions.removeValue(forKey: id)?.stop()
        passwords.forget(id)
        if pausedMediaTab == id { pausedMediaTab = nil }
        setNeedsRefresh()
        return tab
    }

    private func keepAwake(_ id: UInt64?) {
        guard id != keptAwake else { return }
        if let old = keptAwake { core.setShownElsewhere(id: old, shown: false) }
        if let id { core.setShownElsewhere(id: id, shown: true) }
        keptAwake = id
        setNeedsRefresh()
    }
}

extension BrowserStore {
    var visibleDevState: DevTabState { visibleTabID.flatMap { devStates[$0] } ?? DevTabState() }
    var visibleDevReport: DevPageReport { visibleTabID.flatMap { devReports[$0] } ?? DevPageReport() }

    var developerToolbarShown: Bool {
        guard DeveloperSettings.enabled, !contentFullscreen, let tab = visibleTab, !tab.url.isEmpty else { return false }
        if let shown = devToolbarOverrides[tab.id] { return shown }
        return DeveloperSettings.everywhere ? DevSite.isSite(tab.url) : DevSite.isLocal(tab.url)
    }

    func toggleDeveloperToolbar() {
        guard let id = visibleTabID else { return }
        if !DeveloperSettings.enabled {
            devToolbarOverrides[id] = true
            UserDefaults.standard.set(true, forKey: DeveloperSettings.enabledKey)
        } else {
            devToolbarOverrides[id] = !developerToolbarShown
        }
        changed(.developer)
    }

    func updateDev(_ change: (inout DevTabState) -> Void) {
        guard let id = visibleTabID else { return }
        let old = devStates[id] ?? DevTabState()
        var state = old
        change(&state)
        guard state != old else { return }
        devStates[id] = state
        views[id]?.apply(state, from: old)
        if state.viewport != old.viewport { webContainer.viewportChanged() }
        changed(.developer)
    }

    func hardReload() { visibleView?.reloadIgnoringCache() }

    func togglePicking() {
        guard visibleView != nil else { return }
        updateDev { $0.picking.toggle() }
    }

    func setDevice(_ device: DevicePreset?) {
        updateDev {
            $0.device = device
            if device == nil { $0.landscape = false }
        }
    }

    func toggleScripts() {
        updateDev { $0.scriptsDisabled.toggle() }
        visibleView?.reload()
    }

    func clearSiteData() {
        guard let view = visibleView else { return }
        view.clearSiteDataAndReload()
        showToast(Toast(message: "Site data cleared", symbol: "trash"), duration: 1.6)
    }

    func loadInVisibleTab(_ url: String) {
        open(url, mode: .editCurrent)
    }

    func screenshotPage() {
        guard let view = visibleView, let tab = visibleTab else { return }
        view.captureFullPage { [weak self] png in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let png else {
                    self.showToast(Toast(message: "Couldn't take the screenshot", symbol: "exclamationmark.triangle"), duration: 2.5)
                    return
                }
                let debugDir = ProcessInfo.processInfo.environment["MBGA_DEBUG_SCREENSHOTS"]
                if debugDir == nil {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(png, forType: .png)
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let site = DevSite.label(tab.url).replacingOccurrences(of: ":", with: " ").replacingOccurrences(of: "/", with: " ")
                let name = "\(site) \(formatter.string(from: Date())).png"
                let downloads = debugDir.map { URL(fileURLWithPath: $0) }
                    ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                try? png.write(to: downloads.appendingPathComponent(name))
                self.showToast(Toast(message: "Screenshot copied and saved to Downloads", symbol: "camera.viewfinder"), duration: 2.5)
            }
        }
    }

    @objc private func defaultsChanged() {
        webContainer.placeCurrent()
        if !DeveloperSettings.enabled, !devStates.isEmpty {
            for (id, state) in devStates { views[id]?.apply(DevTabState(), from: state) }
            devStates = [:]
            webContainer.viewportChanged()
        }
        if !DeveloperSettings.enabled { devToolbarOverrides = [:] }
        changed(.developer)
    }

    private func updateDevReport(_ id: UInt64, _ change: (inout DevPageReport) -> Void) {
        var report = devReports[id] ?? DevPageReport()
        change(&report)
        guard report != devReports[id] else { return }
        devReports[id] = report
        if id == visibleTabID, DeveloperSettings.enabled { changed(.developer) }
    }
}

extension BrowserStore {
    func engineView(for id: UInt64) -> MBWebView? {
        if let holder = Self.holder(of: id) { return holder.views[id] }
        if let tab = core.tab(id: id), !tab.url.isEmpty { createView(for: tab) }
        return views[id]
    }

    func isLoaded(_ id: UInt64) -> Bool {
        let store = keeper(of: id)
        return store.views[id] != nil && store.navStates[id] != nil
    }

    func holdDrawing(_ id: UInt64) -> (started: Bool, release: () -> Void) {
        let store = keeper(of: id)
        guard id != store.visibleTabID, let view = store.views[id] else { return (false, {}) }
        return store.webContainer.holdDrawing(view, grace: 30)
    }

    func navState(of id: UInt64) -> NavState { keeper(of: id).navStates[id] ?? NavState() }

    func devReport(of id: UInt64) -> DevPageReport { keeper(of: id).devReports[id] ?? DevPageReport() }

    func consoleEntries(of id: UInt64) -> [ConsoleEntry] { keeper(of: id).consoleLogs[id] ?? [] }

    func networkEntries(of id: UInt64) -> [NetworkEntry] { keeper(of: id).networkLogs[id] ?? [] }

    func clearNetwork(of id: UInt64) { keeper(of: id).networkLogs[id] = nil }

    private func recordNetwork(_ tab: UInt64, _ method: String, _ request: String, _ params: [AnyHashable: Any]) {
        var log = networkLogs[tab] ?? []
        let index = log.lastIndex { $0.requestID == request }
        switch method {
        case "Network.requestWillBeSent":
            guard let info = params["request"] as? [String: Any], let url = info["url"] as? String,
                  !url.hasPrefix("data:") else { return }
            if params["type"] as? String == "Document", params["frameId"] as? String == params["loaderId"] as? String ?? "" { log.removeAll() }
            let number = (networkNumbers[tab] ?? 0) + 1
            networkNumbers[tab] = number
            log.append(NetworkEntry(number: number, requestID: request, method: info["method"] as? String ?? "GET", url: url,
                                    type: (params["type"] as? String ?? "Other").lowercased(),
                                    started: params["timestamp"] as? Double ?? 0))
            if log.count > 300 { log.removeFirst(log.count - 300) }
        case "Network.responseReceived":
            guard let index, let response = params["response"] as? [String: Any] else { return }
            log[index].status = response["status"] as? Int
            log[index].mime = response["mimeType"] as? String ?? ""
        case "Network.loadingFinished":
            guard let index else { return }
            log[index].size = params["encodedDataLength"] as? Int
            log[index].ended = params["timestamp"] as? Double
        case "Network.loadingFailed":
            guard let index else { return }
            log[index].failure = (params["canceled"] as? Bool == true) ? "canceled"
                : params["blockedReason"] as? String ?? params["errorText"] as? String ?? "failed"
            log[index].ended = params["timestamp"] as? Double
        default:
            return
        }
        networkLogs[tab] = log
    }

    func clearConsole(of id: UInt64) { keeper(of: id).consoleLogs[id] = nil }

    func spaceID(of tabID: UInt64) -> UInt64? {
        snapshot.spaces.first { space in
            (space.favorites + space.pinned.compactMap(\.tab) + space.today).contains { $0.id == tabID }
        }?.id
    }

    func openTabForAgent(_ url: String, focus: Bool) -> UInt64? {
        let space = agentSpaceID()
        let onScreen = focus && space == activeSpace.id
        guard !url.isEmpty, let id = core.openTab(spaceId: space, url: url, activate: onScreen && isFront) else { return nil }
        if focus, !onScreen || !isFront {
            select(id, in: space)
        } else {
            refresh()
        }
        if views[id] == nil, let tab = core.tab(id: id) { createView(for: tab) }
        views[id]?.recordsNetwork = true
        views[id]?.attachToFrames()
        return id
    }

    func agentSpaceID() -> UInt64 {
        var preferences = agentPreferences
        guard preferences.ownSpace else { return activeSpace.id }
        let profile = agentProfileID()
        if let id = preferences.spaceID, let space = snapshot.spaces.first(where: { $0.id == id }) {
            if space.profileId != profile {
                destroyViews(core.setSpaceProfile(id: id, profileId: profile))
                refresh()
            }
            return id
        }
        let id = core.createSpace(name: "Agents", icon: "✨", color: 0x8B5CF6, profileId: profile)
        preferences.spaceID = id
        agentPreferences = preferences
        agentPreferences.save(to: dataDirectory)
        refresh()
        return id
    }

    func agentProfileID() -> UInt64 {
        var preferences = agentPreferences
        let profiles = snapshot.profiles
        if preferences.separateProfile {
            if let id = preferences.separateProfileID, profiles.contains(where: { $0.id == id }) { return id }
            let id = core.createProfile(name: "Agents")
            preferences.separateProfileID = id
            agentPreferences = preferences
            agentPreferences.save(to: dataDirectory)
            refresh()
            return id
        }
        if let id = preferences.profileID, profiles.contains(where: { $0.id == id }) { return id }
        return snapshot.spaces.first?.profileId ?? profiles.first?.id ?? 0
    }

    func setAgentPreferences(_ change: (inout AgentPreferences) -> Void) {
        change(&agentPreferences)
        agentPreferences.save(to: dataDirectory)
        if agentPreferences.ownSpace, agentPreferences.spaceID != nil { _ = agentSpaceID() }
        changed(.agent)
    }

    func agentActed(on id: UInt64) {
        let wasActive = agentActiveTabs.contains(id)
        agentActiveTabs.insert(id)
        agentTimers[id]?.invalidate()
        let timer = Timer(timeInterval: 1.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.agentActiveTabs.remove(id)
                self.agentTimers[id] = nil
                if id == self.visibleTabID { self.changed(.agent) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        agentTimers[id] = timer
        if !wasActive, id == visibleTabID { changed(.agent) }
    }

    var agentActingOnVisibleTab: Bool { visibleTabID.map { agentActiveTabs.contains($0) } ?? false }
}

extension BrowserStore: MBWebViewDelegate {
    private func isCurrent(_ view: MBWebView) -> Bool {
        views[view.tabID] === view
    }

    nonisolated func webView(_ view: MBWebView, didChangeURL url: String) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            core.updateTab(id: view.tabID, url: url, title: nil)
            passwords.pageChanged(view, url: url)
            setNeedsRefresh()
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeTitle title: String) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            core.updateTab(id: view.tabID, url: nil, title: title)
            setNeedsRefresh()
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            if loading, navStates[view.tabID]?.isLoading != true { consoleLogs[view.tabID] = nil }
            let state = NavState(isLoading: loading, canGoBack: canGoBack, canGoForward: canGoForward)
            if navStates[view.tabID]?.isLoading != loading { extensions.setNeedsSync() }
            navStates[view.tabID] = state
            if view.tabID == visibleTabID { nav = state }
        }
    }

    nonisolated func webView(_ view: MBWebView, didReceiveFavicon png: Data) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            core.setFavicon(tabId: view.tabID, png: png)
            if let path = core.tab(id: view.tabID)?.faviconPath {
                FaviconCache.shared.invalidate(path)
            }
            setNeedsRefresh()
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeBusy busy: Bool) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            core.setAudible(id: view.tabID, audible: busy)
            setNeedsRefresh()
        }
    }

    nonisolated func webView(_ view: MBWebView, requestsNewTabWithURL url: String, foreground: Bool) {
        MainActor.assumeIsolated {
            if let origin = URL(string: url), origin.scheme == "chrome-extension",
               core.tab(id: view.tabID).flatMap({ URL(string: $0.url) })?.host != origin.host {
                return
            }
            let space = space(owning: view.tabID)?.id ?? activeSpace.id
            let id = core.openTab(spaceId: space, url: url, activate: foreground && isFront)
            if foreground, !isFront, let id {
                select(id, in: space)
            } else {
                refresh()
            }
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeFullscreen fullscreen: Bool) {
        MainActor.assumeIsolated {
            guard isCurrent(view), let window, view.window === window else { return }
            contentFullscreen = fullscreen
            let windowFullscreen = window.styleMask.contains(.fullScreen)
            if fullscreen, !windowFullscreen {
                enteredFullscreenForContent = true
                window.toggleFullScreen(nil)
            } else if !fullscreen, windowFullscreen, enteredFullscreenForContent {
                enteredFullscreenForContent = false
                window.toggleFullScreen(nil)
            }
            updateTrafficLights()
        }
    }

    func windowExitedFullscreen() {
        enteredFullscreenForContent = false
        if contentFullscreen { visibleView?.exitFullscreen() }
    }

    nonisolated func webView(_ view: MBWebView, opensExtensionsPage url: String, fromPage page: String) {
        MainActor.assumeIsolated {
            guard isCurrent(view), let profile = core.profileOfTab(tabId: view.tabID) else { return }
            MBEngine.showExtensions(forProfilePath: core.profileDir(profileId: profile), url: url)
            if page.isEmpty || page == "about:blank" {
                close(view.tabID)
            } else {
                core.updateTab(id: view.tabID, url: page, title: nil)
                setNeedsRefresh()
            }
        }
    }

    nonisolated func webView(_ view: MBWebView, contextMenuItemsFor context: [AnyHashable: Any]) -> [[AnyHashable: Any]] {
        MainActor.assumeIsolated {
            guard isCurrent(view), let profile = core.profileOfTab(tabId: view.tabID) else { return [] }
            let context = context as? [String: Any] ?? [:]
            return extensions.pageMenuItems(profile: extensions.profilePath(profile), context: context)
        }
    }

    nonisolated func webView(_ view: MBWebView, choseContextMenuItem itemID: String, context: [AnyHashable: Any]) {
        MainActor.assumeIsolated {
            guard isCurrent(view), let profile = core.profileOfTab(tabId: view.tabID) else { return }
            extensions.choosePageMenuItem(itemID, context: context as? [String: Any] ?? [:],
                                          profile: extensions.profilePath(profile), tab: view.tabID)
        }
    }

    nonisolated func webViewRendererDidTerminate(_ view: MBWebView) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            if view.tabID == visibleTabID {
                view.reload()
            } else {
                destroyView(view.tabID)
                core.setLive(id: view.tabID, live: false)
                setNeedsRefresh()
            }
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeThemeColor color: String) {
        MainActor.assumeIsolated {
            guard isCurrent(view), let site = core.tab(id: view.tabID)?.site else { return }
            let parsed = RGB(css: color)
            if pageColors[site] != parsed { pageColors[site] = parsed }
        }
    }

    nonisolated func webView(_ view: MBWebView, didChangeBlockedCount count: UInt) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            blockedCounts[view.tabID] = Int(count)
            guard view.tabID == visibleTabID else { return }
            if count == 0 {
                publishBlockedCount()
            } else if blockedCountTimer?.isValid != true {
                let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publishBlockedCount() }
                }
                RunLoop.main.add(timer, forMode: .common)
                blockedCountTimer = timer
            }
        }
    }

    private func publishBlockedCount() {
        visibleBlockedCount = visibleTabID.flatMap { blockedCounts[$0] } ?? 0
    }

    nonisolated func webView(_ view: MBWebView, didChangeConsoleErrors errors: UInt, warnings: UInt) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            updateDevReport(view.tabID) {
                $0.errors = Int(errors)
                $0.warnings = Int(warnings)
            }
        }
    }

    nonisolated func webView(_ view: MBWebView, didFinishLoadWithStatus status: Int32, duration: TimeInterval) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            updateDevReport(view.tabID) {
                $0.status = Int(status)
                $0.duration = duration
            }
            passwords.pageLoaded(view)
        }
    }

    nonisolated func webViewDidStopPicking(_ view: MBWebView) {
        MainActor.assumeIsolated {
            guard isCurrent(view), devStates[view.tabID]?.picking == true else { return }
            devStates[view.tabID]?.picking = false
            if view.tabID == visibleTabID { changed(.developer) }
        }
    }

    nonisolated func webView(_ view: MBWebView, didLogConsoleMessage message: String, level: Int, source: String, line: Int32) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            var log = consoleLogs[view.tabID] ?? []
            log.append(ConsoleEntry(level: level, text: message, source: source, line: Int(line)))
            if log.count > 200 { log.removeFirst(log.count - 200) }
            consoleLogs[view.tabID] = log
        }
    }

    nonisolated func webView(_ view: MBWebView, didObserveNetworkEvent method: String, params: [AnyHashable: Any]) {
        MainActor.assumeIsolated {
            guard isCurrent(view), let request = params["requestId"] as? String else { return }
            recordNetwork(view.tabID, method, request, params)
        }
    }

    nonisolated func webView(_ view: MBWebView, didReceiveDevToolsEvent method: String, params: [AnyHashable: Any]) {
        MainActor.assumeIsolated {
            guard isCurrent(view), let session = inspectorSessions[view.tabID] else { return }
            session.receive(method, params as? JSON ?? [:])
        }
    }

    nonisolated func webView(_ view: MBWebView, didPickNode backendNodeId: Int) {
        MainActor.assumeIsolated {
            guard let session = inspectorSession(showingFor: view) else { return }
            session.revealNode(backendNodeID: backendNodeId)
        }
    }

    nonisolated func webView(_ view: MBWebView, inspectsElementAt point: NSPoint) {
        MainActor.assumeIsolated {
            guard let session = inspectorSession(showingFor: view) else { return }
            session.inspect(at: point)
        }
    }

    private func inspectorSession(showingFor view: MBWebView) -> InspectorSession? {
        guard isCurrent(view), view.tabID == visibleTabID else { return nil }
        showInspector(.elements)
        return inspectorSessions[view.tabID]
    }

    nonisolated func webViewDidChangeDevTools(_ view: MBWebView) {
        MainActor.assumeIsolated {
            guard isCurrent(view), view.tabID == visibleTabID else { return }
            webContainer.placeCurrent()
            changed(.developer)
        }
    }

    nonisolated func webView(_ view: MBWebView, didReceiveFormMessage message: String, url: String) {
        MainActor.assumeIsolated {
            guard isCurrent(view) else { return }
            passwords.receive(message, url: url, from: view)
        }
    }

    nonisolated func webViewDidClose(_ view: MBWebView) {
        MainActor.assumeIsolated {
            view.removeFromSuperview()
            if !MBEngine.isQuitting, views[view.tabID] === view { sleep(view.tabID) }
        }
    }
}
