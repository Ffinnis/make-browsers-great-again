import AppKit

enum ApplicationChange {
    case origin
    case domStorage(local: Bool)
    case serviceWorkers
    case databases
    case caches
}

@MainActor
final class ApplicationModel: InspectorModel {
    private weak var session: InspectorSession?
    let changed = Signal<ApplicationChange>()
    private(set) var origin = ""
    private(set) var frameID = ""
    private(set) var storageKey: String?
    private(set) var localItems: [[String]] = []
    private(set) var sessionItems: [[String]] = []
    private(set) var registrations: [String: JSON] = [:]
    private(set) var versions: [String: JSON] = [:]
    private(set) var workerErrors: [JSON] = []
    private(set) var databaseNames: [String] = []
    private(set) var databases: [String: JSON] = [:]
    private(set) var caches: [JSON] = []
    private(set) var forceUpdateOnReload = false

    init(session: InspectorSession) { self.session = session }

    func start() {
        guard let session else { return }
        session.on("DOMStorage.", self) { [weak self] method, params in self?.domStorageEvent(method, params) }
        session.on("ServiceWorker.", self) { [weak self] method, params in self?.serviceWorkerEvent(method, params) }
        session.navigated.observe(self) { [weak self] url in
            guard let self else { return }
            if Self.origin(of: url) != origin { reset() } else { refreshDOMStorage() }
        }
        session.call("DOMStorage.enable")
        session.call("ServiceWorker.enable")
        session.call("IndexedDB.enable")
        reset()
    }

    func stop() {
        guard let session else { return }
        session.call("DOMStorage.disable")
        session.call("ServiceWorker.disable")
        session.call("IndexedDB.disable")
        if forceUpdateOnReload { session.call("ServiceWorker.setForceUpdateOnPageLoad", ["forceUpdateOnPageLoad": false]) }
    }

    func reset() {
        localItems = []
        sessionItems = []
        databaseNames = []
        databases = [:]
        caches = []
        Task {
            guard let session else { return }
            if let tree = try? await session.send("Page.getFrameTree"), let frame = tree.obj("frameTree")?.obj("frame") {
                frameID = frame.str("id") ?? ""
                origin = frame.str("securityOrigin").flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
                    ?? Self.origin(of: frame.str("url") ?? "")
            } else {
                origin = Self.origin(of: session.url)
            }
            storageKey = nil
            changed.send(.origin)
            if !frameID.isEmpty, let key = try? await session.send("Storage.getStorageKeyForFrame", ["frameId": frameID], timeout: 2) {
                storageKey = key.str("storageKey")
            }
            refreshDOMStorage()
            refreshDatabases()
            refreshCaches()
        }
    }

    static func origin(of url: String) -> String {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme else { return "" }
        guard let host = parts.host, !host.isEmpty else { return scheme == "file" ? "file://" : "" }
        return "\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")
    }

    var host: String { URLComponents(string: origin)?.host ?? "" }

    var storageParams: JSON {
        if let storageKey { return ["storageKey": storageKey] }
        return ["securityOrigin": origin]
    }

    private func storageID(local: Bool) -> JSON {
        var id: JSON = ["isLocalStorage": local]
        if let storageKey { id["storageKey"] = storageKey } else { id["securityOrigin"] = origin }
        return id
    }

    private func isOurs(_ id: JSON?) -> Bool? {
        guard let id else { return nil }
        if let key = id.str("storageKey"), let storageKey, key != storageKey { return nil }
        if let origin = id.str("securityOrigin"), !origin.isEmpty, origin != self.origin { return nil }
        return id.bool("isLocalStorage")
    }

    func items(local: Bool) -> [[String]] { local ? localItems : sessionItems }

    func refreshDOMStorage() {
        guard !origin.isEmpty else { return }
        for local in [true, false] {
            session?.call("DOMStorage.getDOMStorageItems", ["storageId": storageID(local: local)]) { [weak self] result, _ in
                guard let self, let entries = result?["entries"] as? [[String]] else { return }
                if local { localItems = entries } else { sessionItems = entries }
                changed.send(.domStorage(local: local))
            }
        }
    }

    func setItem(local: Bool, key: String, value: String) {
        session?.call("DOMStorage.setDOMStorageItem", ["storageId": storageID(local: local), "key": key, "value": value]) { [weak self] _, _ in
            self?.refreshDOMStorage()
        }
    }

    func removeItem(local: Bool, key: String) {
        session?.call("DOMStorage.removeDOMStorageItem", ["storageId": storageID(local: local), "key": key]) { [weak self] _, _ in
            self?.refreshDOMStorage()
        }
    }

    func renameItem(local: Bool, from old: String, to new: String) {
        guard old != new, let value = items(local: local).first(where: { $0.first == old })?.last else { return }
        removeItem(local: local, key: old)
        setItem(local: local, key: new, value: value)
    }

    func clearItems(local: Bool) {
        session?.call("DOMStorage.clear", ["storageId": storageID(local: local)]) { [weak self] _, _ in
            self?.refreshDOMStorage()
        }
    }

    private func domStorageEvent(_ method: String, _ params: JSON) {
        guard let local = isOurs(params.obj("storageId")) else { return }
        var items = items(local: local)
        let key = params.str("key") ?? ""
        switch method {
        case "DOMStorage.domStorageItemAdded":
            items.removeAll { $0.first == key }
            items.append([key, params.str("newValue") ?? ""])
        case "DOMStorage.domStorageItemUpdated":
            if let i = items.firstIndex(where: { $0.first == key }) {
                items[i] = [key, params.str("newValue") ?? ""]
            } else {
                items.append([key, params.str("newValue") ?? ""])
            }
        case "DOMStorage.domStorageItemRemoved":
            items.removeAll { $0.first == key }
        case "DOMStorage.domStorageItemsCleared":
            items = []
        default:
            return
        }
        if local { localItems = items } else { sessionItems = items }
        changed.send(.domStorage(local: local))
    }

    private func serviceWorkerEvent(_ method: String, _ params: JSON) {
        switch method {
        case "ServiceWorker.workerRegistrationUpdated":
            for registration in params.list("registrations") {
                guard let id = registration.str("registrationId") else { continue }
                registrations[id] = registration.bool("isDeleted") ? nil : registration
            }
        case "ServiceWorker.workerVersionUpdated":
            for version in params.list("versions") {
                guard let id = version.str("versionId") else { continue }
                versions[id] = version.str("status") == "redundant" && version.str("runningStatus") == "stopped" ? nil : version
            }
        case "ServiceWorker.workerErrorReported":
            if let error = params.obj("errorMessage") { workerErrors.append(error) }
        default:
            return
        }
        changed.send(.serviceWorkers)
    }

    var siteRegistrations: [JSON] {
        registrations.values.filter { origin.isEmpty || ($0.str("scopeURL") ?? "").hasPrefix(origin) }
            .sorted { ($0.str("scopeURL") ?? "") < ($1.str("scopeURL") ?? "") }
    }

    func versions(of registration: String) -> [JSON] {
        versions.values.filter { $0.str("registrationId") == registration }
            .sorted { (Int($0.str("versionId") ?? "") ?? 0) > (Int($1.str("versionId") ?? "") ?? 0) }
    }

    func errors(of registration: String) -> [JSON] {
        workerErrors.filter { $0.str("registrationId") == registration }
    }

    func setForceUpdateOnReload(_ on: Bool) {
        forceUpdateOnReload = on
        session?.call("ServiceWorker.setForceUpdateOnPageLoad", ["forceUpdateOnPageLoad": on])
        changed.send(.serviceWorkers)
    }

    func refreshDatabases() {
        guard !origin.isEmpty, let session else { return }
        session.call("IndexedDB.requestDatabaseNames", storageParams) { [weak self] result, _ in
            guard let self else { return }
            databaseNames = (result?["databaseNames"] as? [String] ?? []).sorted()
            databases = databases.filter { self.databaseNames.contains($0.key) }
            changed.send(.databases)
            for name in databaseNames { refreshDatabase(name) }
        }
    }

    func refreshDatabase(_ name: String) {
        var params = storageParams
        params["databaseName"] = name
        session?.call("IndexedDB.requestDatabase", params) { [weak self] result, _ in
            guard let self, let database = result?.obj("databaseWithObjectStores") else { return }
            databases[name] = database
            changed.send(.databases)
        }
    }

    func deleteDatabase(_ name: String) {
        var params = storageParams
        params["databaseName"] = name
        session?.call("IndexedDB.deleteDatabase", params) { [weak self] _, _ in self?.refreshDatabases() }
    }

    func refreshCaches() {
        guard !origin.isEmpty else { return }
        session?.call("CacheStorage.requestCacheNames", storageParams) { [weak self] result, _ in
            guard let self else { return }
            caches = (result?.list("caches") ?? []).sorted { ($0.str("cacheName") ?? "") < ($1.str("cacheName") ?? "") }
            changed.send(.caches)
        }
    }

    func deleteCache(_ id: String) {
        session?.call("CacheStorage.deleteCache", ["cacheId": id]) { [weak self] _, _ in self?.refreshCaches() }
    }
}

private enum AppSection: Hashable {
    case manifest, serviceWorkers, storage, frames
    case localStorage, sessionStorage, cookies
    case indexedDB, database(String), objectStore(database: String, store: String)
    case cacheStorage, cache(id: String, name: String)

    var title: String {
        switch self {
        case .manifest: "Manifest"
        case .serviceWorkers: "Service workers"
        case .storage: "Storage"
        case .frames: "Frames"
        case .localStorage: "Local storage"
        case .sessionStorage: "Session storage"
        case .cookies: "Cookies"
        case .indexedDB: "IndexedDB"
        case .database(let name): name
        case .objectStore(_, let store): store
        case .cacheStorage: "Cache storage"
        case .cache(_, let name): name
        }
    }

    var symbol: String {
        switch self {
        case .manifest: "doc.text"
        case .serviceWorkers: "gearshape.2"
        case .storage: "internaldrive"
        case .frames: "square.on.square"
        case .localStorage, .sessionStorage: "tablecells"
        case .cookies: "circle.grid.2x2"
        case .indexedDB, .database: "cylinder.split.1x2"
        case .objectStore: "tablecells"
        case .cacheStorage, .cache: "archivebox"
        }
    }
}

private final class NavItem {
    let title: String
    let section: AppSection?
    var children: [NavItem]

    init(_ title: String, section: AppSection? = nil, children: [NavItem] = []) {
        self.title = title
        self.section = section
        self.children = children
    }
}

final class ApplicationPanel: InspectorPanelView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let navigator = InspectorOutlineView()
    private let navigatorScroll = NSScrollView()
    private let navigatorEdge = NSView()
    private let narrowBar = InspectorToolbar()
    private let picker = NSPopUpButton()
    private let detail = FlippedView()
    private let empty = InspectorEmptyView("Open a page to see its storage.")
    private var items: [NavItem] = []
    private var selected: AppSection = .storage
    private var shownView: AppSectionView?
    private var views: [AppSection: AppSectionView] = [:]
    private weak var observedModel: ApplicationModel?
    private var narrow = false

    private var model: ApplicationModel? { session.map { $0.model(ApplicationModel.self) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nav"))
        navigator.addTableColumn(column)
        navigator.outlineTableColumn = column
        navigator.headerView = nil
        navigator.style = .plain
        navigator.rowHeight = 22
        navigator.indentationPerLevel = 10
        navigator.backgroundColor = .clear
        navigator.focusRingType = .none
        navigator.floatsGroupRows = false
        navigator.dataSource = self
        navigator.delegate = self
        navigator.menuForRow = { [weak self] row in self?.navigatorMenu(row) }
        navigatorScroll.documentView = navigator
        navigatorScroll.hasVerticalScroller = true
        navigatorScroll.autohidesScrollers = true
        navigatorScroll.drawsBackground = false
        navigatorScroll.borderType = .noBorder
        navigatorEdge.wantsLayer = true
        addSubview(navigatorScroll)
        addSubview(navigatorEdge)
        picker.controlSize = .small
        picker.font = Theme.font(11)
        picker.isBordered = false
        picker.onAction { [weak self] in self?.pickerChanged() }
        narrowBar.add(picker, width: nil)
        addSubview(narrowBar)
        addSubview(detail)
        addSubview(empty)
        rebuildItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        navigatorEdge.layer?.backgroundColor = InspectorTheme.separator.cgColor
        layer?.backgroundColor = nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        narrow = bounds.width < 520
        navigatorScroll.isHidden = narrow
        navigatorEdge.isHidden = narrow
        narrowBar.isHidden = !narrow
        let navWidth: CGFloat = narrow ? 0 : min(170, (bounds.width * 0.3).rounded())
        navigatorScroll.frame = NSRect(x: 0, y: 0, width: navWidth, height: bounds.height)
        navigatorEdge.frame = NSRect(x: navWidth, y: 0, width: 1, height: bounds.height)
        narrowBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        let top: CGFloat = narrow ? InspectorToolbar.height : 0
        let left = narrow ? 0 : navWidth + 1
        detail.frame = NSRect(x: left, y: top, width: bounds.width - left, height: bounds.height - top)
        shownView?.frame = detail.bounds
        empty.frame = bounds
    }

    override func sessionChanged() {
        if let observedModel { observedModel.changed.stopObserving(self) }
        observedModel = nil
        for view in views.values { view.removeFromSuperview() }
        views = [:]
        shownView?.removeFromSuperview()
        shownView = nil
        empty.isHidden = session != nil
        guard isShown else { return }
        attach()
    }

    override func panelDidAppear() {
        if observedModel == nil { attach() }
    }

    override func focusFilter() { shownView?.focusFilter() }

    private func attach() {
        guard let session, let model else { return }
        observedModel = model
        model.changed.observe(self) { [weak self] change in self?.modelChanged(change) }
        rebuildItems()
        if shownView == nil { show(selected, session: session, model: model) }
    }

    private func modelChanged(_ change: ApplicationChange) {
        switch change {
        case .origin:
            rebuildItems()
            switch selected {
            case .database, .objectStore, .cache: select(.storage)
            default: shownView?.reload()
            }
        case .databases, .caches:
            rebuildItems()
        default:
            break
        }
        shownView?.modelChanged(change)
    }

    private func rebuildItems() {
        let model = observedModel
        let databases = (model?.databaseNames ?? []).map { name in
            NavItem(name, section: .database(name), children: ((model?.databases[name]?.list("objectStores")) ?? []).map {
                let store = $0.str("name") ?? ""
                return NavItem(store, section: .objectStore(database: name, store: store))
            })
        }
        let caches = (model?.caches ?? []).compactMap { cache -> NavItem? in
            guard let id = cache.str("cacheId"), let name = cache.str("cacheName") else { return nil }
            return NavItem(name, section: .cache(id: id, name: name))
        }
        items = [
            NavItem("Application", children: [AppSection.manifest, .serviceWorkers, .storage].map { NavItem($0.title, section: $0) }),
            NavItem("Storage", children: [
                NavItem(AppSection.localStorage.title, section: .localStorage),
                NavItem(AppSection.sessionStorage.title, section: .sessionStorage),
                NavItem(AppSection.indexedDB.title, section: .indexedDB, children: databases),
                NavItem(AppSection.cookies.title, section: .cookies),
                NavItem(AppSection.cacheStorage.title, section: .cacheStorage, children: caches),
            ]),
            NavItem("Frames", children: [NavItem("Frame tree", section: .frames)]),
        ]
        navigator.reloadData()
        for group in items { navigator.expandItem(group) }
        if !databases.isEmpty, let item = item(for: .indexedDB) { navigator.expandItem(item) }
        if !caches.isEmpty, let item = item(for: .cacheStorage) { navigator.expandItem(item) }
        if case .database = selected, let item = item(for: selected) { navigator.expandItem(item) }
        if case .objectStore(let database, _) = selected, let item = item(for: .database(database)) { navigator.expandItem(item) }
        if let item = item(for: selected) {
            let row = navigator.row(forItem: item)
            if row >= 0 { navigator.selectRowIndexes([row], byExtendingSelection: false) }
        }
        rebuildPicker()
    }

    private func item(for section: AppSection) -> NavItem? {
        func find(_ items: [NavItem]) -> NavItem? {
            for item in items {
                if item.section == section { return item }
                if let found = find(item.children) { return found }
            }
            return nil
        }
        return find(items)
    }

    private func rebuildPicker() {
        picker.removeAllItems()
        func add(_ items: [NavItem], depth: Int) {
            for item in items {
                if let section = item.section {
                    picker.addItem(withTitle: String(repeating: "    ", count: max(depth - 1, 0)) + item.title)
                    picker.lastItem?.representedObject = section as Any
                    if section == selected { picker.select(picker.lastItem) }
                } else if depth == 0 {
                    if picker.numberOfItems > 0 { picker.menu?.addItem(.separator()) }
                    let heading = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    heading.isEnabled = false
                    picker.menu?.addItem(heading)
                }
                add(item.children, depth: depth + 1)
            }
        }
        add(items, depth: 0)
    }

    private func pickerChanged() {
        if let section = picker.selectedItem?.representedObject as? AppSection { select(section) }
    }

    override func selectRow(_ row: Int) {
        let sections: [AppSection] = [.manifest, .serviceWorkers, .storage, .frames, .localStorage, .sessionStorage, .cookies,
                                      .indexedDB, .cacheStorage]
        if sections.indices.contains(row) { select(sections[row]) }
    }

    private func select(_ section: AppSection) {
        guard section != selected || shownView == nil else { return }
        selected = section
        if let item = item(for: section) {
            let row = navigator.row(forItem: item)
            if row >= 0, navigator.selectedRow != row { navigator.selectRowIndexes([row], byExtendingSelection: false) }
        }
        rebuildPicker()
        if let session, let model { show(section, session: session, model: model) }
    }

    private func show(_ section: AppSection, session: InspectorSession, model: ApplicationModel) {
        shownView?.removeFromSuperview()
        let view = views[section] ?? makeView(section, session: session, model: model)
        switch section {
        case .database, .objectStore, .cache: break
        default: views[section] = view
        }
        view.frame = detail.bounds
        view.autoresizingMask = [.width, .height]
        detail.addSubview(view)
        shownView = view
        view.reload()
    }

    private func makeView(_ section: AppSection, session: InspectorSession, model: ApplicationModel) -> AppSectionView {
        let view: AppSectionView = switch section {
        case .manifest: ManifestSection()
        case .serviceWorkers: ServiceWorkersSection()
        case .storage: StorageOverviewSection()
        case .frames: FramesSection()
        case .localStorage: DOMStorageSection(local: true)
        case .sessionStorage: DOMStorageSection(local: false)
        case .cookies: CookiesSection()
        case .indexedDB: DatabasesSection()
        case .database(let name): DatabaseSection(name: name)
        case .objectStore(let database, let store): ObjectStoreSection(database: database, store: store)
        case .cacheStorage: CachesSection()
        case .cache(let id, let name): CacheSection(id: id, name: name)
        }
        view.session = session
        view.model = model
        view.open = { [weak self] section in self?.select(section) }
        return view
    }

    private func navigatorMenu(_ row: Int) -> NSMenu? {
        guard let item = navigator.item(atRow: row) as? NavItem, let model else { return nil }
        let menu = NSMenu()
        switch item.section {
        case .database(let name):
            menu.add("Refresh Database") { model.refreshDatabase(name) }
            menu.add("Delete Database") { model.deleteDatabase(name) }
        case .indexedDB:
            menu.add("Refresh IndexedDB") { model.refreshDatabases() }
        case .cache(let id, _):
            menu.add("Delete Cache") { model.deleteCache(id) }
        case .cacheStorage:
            menu.add("Refresh Caches") { model.refreshCaches() }
        case .localStorage:
            menu.add("Clear Local Storage") { model.clearItems(local: true) }
        case .sessionStorage:
            menu.add("Clear Session Storage") { model.clearItems(local: false) }
        default:
            return nil
        }
        return menu
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? NavItem)?.children.count ?? items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? NavItem)?.children[index] ?? items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? NavItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? NavItem)?.section == nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? NavItem)?.section != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? NavItem)?.section != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NavItem else { return nil }
        guard let section = item.section else {
            return InspectorTable.cell(outlineView, "group", item.title.uppercased(), color: .tertiaryLabelColor,
                                       font: Theme.font(10, .semibold))
        }
        let identifier = NSUserInterfaceItemIdentifier("nav.item")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NavCell ?? NavCell(identifier: identifier)
        cell.configure(title: item.title, symbol: section.symbol)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { InspectorRowView() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = navigator.item(atRow: navigator.selectedRow) as? NavItem, let section = item.section else { return }
        select(section)
    }
}

private final class NavCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = Label.make("", size: 11.5)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, symbol: String) {
        label.stringValue = title
        icon.image = .symbol(symbol, size: 10.5)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: 0, width: 16, height: bounds.height)
        label.frame = NSRect(x: 19, y: (bounds.height - 16) / 2, width: max(bounds.width - 20, 0), height: 16)
    }
}

@MainActor
private class AppSectionView: FlippedView {
    weak var session: InspectorSession?
    weak var model: ApplicationModel?
    var open: ((AppSection) -> Void)?
    let toolbar = InspectorToolbar()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(toolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var contentFrame: NSRect {
        NSRect(x: 0, y: InspectorToolbar.height, width: bounds.width, height: max(bounds.height - InspectorToolbar.height, 0))
    }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
    }

    func reload() {}
    func modelChanged(_ change: ApplicationChange) {}
    func focusFilter() {}
}

private struct AppRow {
    let id: String
    var values: [String: String]
    var colors: [String: NSColor] = [:]
    var numbers: [String: Double] = [:]
    var payload: Any?
}

@MainActor
private final class AppTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = InspectorTableView()
    let scroll: NSScrollView
    var editable: Set<String> = []
    var mono: Set<String> = []
    var onSelect: ((AppRow?) -> Void)?
    var onEdit: ((AppRow, String, String) -> Void)?
    var onDelete: (([AppRow]) -> Void)?
    var menuForRows: (([AppRow]) -> NSMenu?)?
    var filter = "" {
        didSet { apply() }
    }
    private var rows: [AppRow] = []
    private(set) var shown: [AppRow] = []

    init(columns: [(id: String, title: String, width: CGFloat)], sortable: Bool = true, scrollsSideways: Bool = false) {
        scroll = InspectorTable.make(table, columns: columns)
        super.init()
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        if scrollsSideways {
            table.columnAutoresizingStyle = .noColumnAutoresizing
            scroll.hasHorizontalScroller = true
        }
        if sortable {
            for column in table.tableColumns {
                column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
            }
        }
        table.menuForRow = { [weak self] _ in
            guard let self else { return nil }
            return menuForRows?(selected)
        }
        table.onKey = { [weak self] event in
            guard let self, event.keyCode == 51 || event.keyCode == 117, !selected.isEmpty, let onDelete else { return false }
            onDelete(selected)
            return true
        }
    }

    var selected: [AppRow] { table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0] : nil } }

    func set(_ rows: [AppRow]) {
        let keep = Set(selected.map(\.id))
        self.rows = rows
        apply(keeping: keep)
    }

    private func apply(keeping keep: Set<String>? = nil) {
        let keep = keep ?? Set(selected.map(\.id))
        let needle = filter.lowercased()
        var list = needle.isEmpty ? rows : rows.filter { $0.values.values.contains { $0.lowercased().contains(needle) } }
        if let descriptor = table.sortDescriptors.first, let key = descriptor.key {
            list.sort { a, b in
                let order: Bool = if let x = a.numbers[key], let y = b.numbers[key] {
                    x < y
                } else {
                    (a.values[key] ?? "").localizedStandardCompare(b.values[key] ?? "") == .orderedAscending
                }
                return descriptor.ascending ? order : !order
            }
        }
        shown = list
        table.reloadData()
        let indexes = IndexSet(shown.indices.filter { keep.contains(shown[$0].id) })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        if indexes.isEmpty { onSelect?(nil) }
    }

    func edit(id: String, column: String) {
        guard let row = shown.firstIndex(where: { $0.id == id }),
              let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.editColumn(index, row: row, with: nil, select: true)
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow, column = table.clickedColumn
        guard row >= 0, column >= 0, editable.contains(table.tableColumns[column].identifier.rawValue) else { return }
        table.editColumn(column, row: row, with: nil, select: true)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, shown.indices.contains(row) else { return nil }
        let item = shown[row]
        let text = item.values[column] ?? ""
        let isEditable = editable.contains(column)
        let cell = InspectorTable.cell(tableView, column + (isEditable ? ".edit" : ""), text.clipped(1000).oneLine,
                                       color: item.colors[column] ?? .labelColor,
                                       font: mono.contains(column) ? InspectorTheme.mono() : InspectorTheme.font)
        guard isEditable, let field = cell.textField else { return cell }
        field.isEditable = true
        field.cell?.sendsActionOnEndEditing = true
        field.stringValue = text
        field.onAction { [weak self, weak field] in
            guard let self, let field, field.stringValue != text else { return }
            onEdit?(item, column, field.stringValue)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { InspectorRowView() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { apply() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let rows = selected
        onSelect?(rows.count == 1 ? rows[0] : nil)
    }
}

private final class ValuePreview: FlippedView {
    private let tree = ValueTreeView()
    private let code = CodeView()
    private let empty = InspectorEmptyView("Select a row to see its value.")
    private let line = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        code.wraps = true
        line.wantsLayer = true
        for view in [tree, code, empty, line] { addSubview(view) }
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        for view in [tree, code, empty] { view.frame = bounds }
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        line.layer?.backgroundColor = InspectorTheme.separator.cgColor
    }

    func show(_ text: String?) {
        guard let text else {
            tree.isHidden = true
            code.isHidden = true
            empty.isHidden = false
            return
        }
        empty.isHidden = true
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
            tree.showsNames = false
            tree.show([JSONValueNode(name: "", value: value)])
            tree.expandRoots()
            tree.isHidden = false
            code.isHidden = true
        } else {
            code.show(text, language: .plain)
            code.isHidden = false
            tree.isHidden = true
        }
    }

    func show(object: JSON, session: InspectorSession?) {
        empty.isHidden = true
        code.isHidden = true
        tree.isHidden = false
        tree.showsNames = false
        let node = RemoteValueNode(name: "", object: object, session: session)
        tree.show([node])
        tree.expandRoots()
    }
}

private class TableSection: AppSectionView {
    let list: AppTable
    let preview = ValuePreview()
    let filterField = InspectorFilterField(placeholder: "Filter")
    private(set) var split: InspectorSplitView!
    let status = Label.make("", size: 11, color: .secondaryLabelColor)

    init(columns: [(id: String, title: String, width: CGFloat)], key: String, scrollsSideways: Bool = false) {
        list = AppTable(columns: columns, scrollsSideways: scrollsSideways)
        super.init(frame: .zero)
        split = InspectorSplitView(list.scroll, preview, vertical: false, key: "application." + key, fraction: 0.62, minimum: 60)
        addSubview(split)
        filterField.onChange = { [weak self] text in self?.list.filter = text }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        split.frame = contentFrame
    }

    override func focusFilter() { window?.makeFirstResponder(filterField) }
}

private final class DOMStorageSection: TableSection {
    private let local: Bool

    init(local: Bool) {
        self.local = local
        super.init(columns: [("key", "Key", 140), ("value", "Value", 220)], key: "domstorage")
        list.editable = ["key", "value"]
        list.mono = ["key", "value"]
        list.onSelect = { [weak self] row in self?.preview.show(row?.values["value"]) }
        list.onEdit = { [weak self] row, column, text in
            guard let self, let model else { return }
            if column == "key" {
                model.renameItem(local: local, from: row.id, to: text)
            } else {
                model.setItem(local: local, key: row.id, value: text)
            }
        }
        list.onDelete = { [weak self] rows in self?.delete(rows) }
        list.menuForRows = { [weak self] rows in
            guard let self, !rows.isEmpty else { return nil }
            let menu = NSMenu()
            if rows.count == 1 {
                menu.add("Edit Key") { [weak self] in self?.list.edit(id: rows[0].id, column: "key") }
                menu.add("Edit Value") { [weak self] in self?.list.edit(id: rows[0].id, column: "value") }
                menu.add("Copy Value") { Format.copy(rows[0].values["value"] ?? "") }
                menu.addItem(.separator())
            }
            menu.add(rows.count == 1 ? "Delete" : "Delete \(rows.count) Items") { [weak self] in self?.delete(rows) }
            return menu
        }
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.reload() }, width: 24)
        toolbar.add(InspectorButton("plus", tip: "Add an item") { [weak self] in self?.add() }, width: 24)
        toolbar.add(InspectorButton("minus", tip: "Delete the selected items  ⌫") { [weak self] in
            guard let self else { return }
            delete(list.selected)
        }, width: 24)
        toolbar.add(InspectorButton("trash", tip: "Clear all") { [weak self] in
            guard let self else { return }
            model?.clearItems(local: local)
        }, width: 24)
        toolbar.addSeparator()
        toolbar.add(filterField, width: nil)
        toolbar.add(status, width: 70, trailing: true)
        status.alignment = .right
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func reload() {
        show()
        model?.refreshDOMStorage()
    }

    override func modelChanged(_ change: ApplicationChange) {
        if case .domStorage(let local) = change, local == self.local { show() }
    }

    private func show() {
        let items = model?.items(local: local) ?? []
        list.set(items.compactMap { pair in
            guard let key = pair.first else { return nil }
            return AppRow(id: key, values: ["key": key, "value": pair.count > 1 ? pair[1] : ""],
                          colors: ["key": InspectorTheme.property])
        })
        status.stringValue = "\(items.count) item\(items.count == 1 ? "" : "s")"
        if list.selected.count == 1 { preview.show(list.selected[0].values["value"]) }
    }

    private func delete(_ rows: [AppRow]) {
        for row in rows { model?.removeItem(local: local, key: row.id) }
    }

    private func add() {
        guard let model else { return }
        let keys = Set(model.items(local: local).compactMap(\.first))
        var key = "key", n = 1
        while keys.contains(key) {
            n += 1
            key = "key\(n)"
        }
        model.setItem(local: local, key: key, value: "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.list.filter = ""
            self?.list.edit(id: key, column: "key")
        }
    }
}

private final class CookiesSection: TableSection {
    private var cookies: [JSON] = []
    private let decode = InspectorButton("percent", tip: "Show the value URL-decoded")
    private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init() {
        super.init(columns: [
            ("name", "Name", 120), ("value", "Value", 180), ("domain", "Domain", 120), ("path", "Path", 50),
            ("expires", "Expires / Max-Age", 150), ("size", "Size", 40), ("httpOnly", "HttpOnly", 56),
            ("secure", "Secure", 48), ("sameSite", "SameSite", 60), ("partition", "Partition Key", 100),
            ("priority", "Priority", 56),
        ], key: "cookies", scrollsSideways: true)
        list.editable = ["name", "value", "domain", "path", "expires"]
        list.mono = ["value"]
        list.onSelect = { [weak self] _ in self?.updatePreview() }
        list.onEdit = { [weak self] row, column, text in self?.edit(row, column, text) }
        list.onDelete = { [weak self] rows in self?.delete(rows) }
        list.menuForRows = { [weak self] rows in
            guard let self, !rows.isEmpty else { return nil }
            let menu = NSMenu()
            if rows.count == 1 {
                menu.add("Edit Value") { [weak self] in self?.list.edit(id: rows[0].id, column: "value") }
                menu.add("Copy Value") { Format.copy(rows[0].values["value"] ?? "") }
                menu.add("Copy as Header") { Format.copy("\(rows[0].values["name"] ?? "")=\(rows[0].values["value"] ?? "")") }
                menu.addItem(.separator())
            }
            menu.add(rows.count == 1 ? "Delete" : "Delete \(rows.count) Cookies") { [weak self] in self?.delete(rows) }
            return menu
        }
        decode.action = { [weak self] in
            guard let self else { return }
            decode.isOn.toggle()
            updatePreview()
        }
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.reload() }, width: 24)
        toolbar.add(InspectorButton("plus", tip: "Add a cookie") { [weak self] in self?.add() }, width: 24)
        toolbar.add(InspectorButton("minus", tip: "Delete the selected cookies  ⌫") { [weak self] in
            guard let self else { return }
            delete(list.selected)
        }, width: 24)
        toolbar.add(InspectorButton("trash", tip: "Clear all of the site's cookies") { [weak self] in
            guard let self else { return }
            delete(list.shown)
        }, width: 24)
        toolbar.addSeparator()
        toolbar.add(filterField, width: nil)
        toolbar.add(decode, width: 24)
        toolbar.add(status, width: 70, trailing: true)
        status.alignment = .right
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func modelChanged(_ change: ApplicationChange) {
        if case .origin = change { reload() }
    }

    override func reload() {
        guard let session, let model else { return }
        let host = model.host
        session.call("Network.getAllCookies") { [weak self] result, _ in
            guard let self else { return }
            guard let all = result?.list("cookies") else {
                session.call("Network.getCookies", ["urls": [session.url]]) { [weak self] result, _ in
                    self?.show(result?.list("cookies") ?? [])
                }
                return
            }
            show(all.filter { cookie in
                let domain = (cookie.str("domain") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return !host.isEmpty && (host == domain || host.hasSuffix("." + domain))
            })
        }
    }

    private func show(_ cookies: [JSON]) {
        self.cookies = cookies
        list.set(cookies.map { cookie in
            let expires = cookie.num("expires") ?? -1
            let session = cookie.bool("session") || expires <= 0
            let partition: String = {
                if let key = cookie.obj("partitionKey") { return key.str("topLevelSite") ?? "" }
                return cookie.str("partitionKey") ?? ""
            }()
            return AppRow(id: Self.id(cookie), values: [
                "name": cookie.str("name") ?? "", "value": cookie.str("value") ?? "", "domain": cookie.str("domain") ?? "",
                "path": cookie.str("path") ?? "/",
                "expires": session ? "Session" : Self.dates.string(from: Date(timeIntervalSince1970: expires)),
                "size": "\(cookie.int("size") ?? 0)", "httpOnly": cookie.bool("httpOnly") ? "✓" : "",
                "secure": cookie.bool("secure") ? "✓" : "", "sameSite": cookie.str("sameSite") ?? "",
                "partition": partition, "priority": cookie.str("priority") ?? "Medium",
            ], colors: ["name": InspectorTheme.property], numbers: ["size": cookie.num("size") ?? 0, "expires": session ? .infinity : expires],
            payload: cookie)
        })
        status.stringValue = "\(cookies.count) cookie\(cookies.count == 1 ? "" : "s")"
        updatePreview()
    }

    private static func id(_ cookie: JSON) -> String {
        "\(cookie.str("name") ?? "")\n\(cookie.str("domain") ?? "")\n\(cookie.str("path") ?? "")"
    }

    private func updatePreview() {
        guard list.selected.count == 1, let value = list.selected[0].values["value"] else { return preview.show(nil) }
        preview.show(decode.isOn ? (value.removingPercentEncoding ?? value) : value)
    }

    private func set(_ cookie: JSON, _ changes: JSON, then done: @escaping @MainActor () -> Void) {
        guard let session else { return }
        let cookie = cookie.merging(changes) { $1 }
        var params: JSON = ["name": cookie.str("name") ?? "", "value": cookie.str("value") ?? "",
                            "path": cookie.str("path") ?? "/", "secure": cookie.bool("secure"),
                            "httpOnly": cookie.bool("httpOnly")]
        let domain = cookie.str("domain") ?? ""
        if domain.hasPrefix(".") {
            params["domain"] = domain
        } else {
            let scheme = cookie.bool("secure") ? "https" : (URLComponents(string: session.url)?.scheme ?? "http")
            params["url"] = "\(scheme)://\(domain)\(cookie.str("path") ?? "/")"
        }
        if let sameSite = cookie.str("sameSite") { params["sameSite"] = sameSite }
        if let priority = cookie.str("priority") { params["priority"] = priority }
        if let expires = cookie.num("expires"), expires > 0, !cookie.bool("session") { params["expires"] = expires }
        if let key = cookie["partitionKey"] { params["partitionKey"] = key }
        if let scheme = cookie.str("sourceScheme") { params["sourceScheme"] = scheme }
        session.call("Network.setCookie", params) { [weak self] _, error in
            if let error { self?.status.stringValue = error }
            done()
        }
    }

    private func edit(_ row: AppRow, _ column: String, _ text: String) {
        guard let cookie = row.payload as? JSON else { return }
        var changes: JSON = [:]
        switch column {
        case "value": changes["value"] = text
        case "path": changes["path"] = text.isEmpty ? "/" : text
        case "domain": changes["domain"] = text
        case "name": changes["name"] = text
        case "expires":
            if text.lowercased() == "session" || text.isEmpty {
                changes["expires"] = -1
                changes["session"] = true
            } else if let date = Self.dates.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                changes["expires"] = date.timeIntervalSince1970
                changes["session"] = false
            } else if let seconds = Double(text) {
                changes["expires"] = Date().timeIntervalSince1970 + seconds
                changes["session"] = false
            } else {
                return
            }
        default: return
        }
        if ["name", "domain", "path"].contains(column) {
            deleteCookie(cookie) { [weak self] in self?.set(cookie, changes) { self?.reload() } }
        } else {
            set(cookie, changes) { [weak self] in self?.reload() }
        }
    }

    private func deleteCookie(_ cookie: JSON, then done: @escaping @MainActor () -> Void) {
        var params: JSON = ["name": cookie.str("name") ?? "", "domain": cookie.str("domain") ?? "",
                            "path": cookie.str("path") ?? "/"]
        if let key = cookie["partitionKey"] { params["partitionKey"] = key }
        session?.call("Network.deleteCookies", params) { _, _ in done() }
    }

    private func delete(_ rows: [AppRow]) {
        let cookies = rows.compactMap { $0.payload as? JSON }
        guard !cookies.isEmpty else { return }
        var left = cookies.count
        for cookie in cookies {
            deleteCookie(cookie) { [weak self] in
                left -= 1
                if left == 0 { self?.reload() }
            }
        }
    }

    private func add() {
        guard let model else { return }
        let names = Set(cookies.compactMap { $0.str("name") })
        var name = "cookie", n = 1
        while names.contains(name) {
            n += 1
            name = "cookie\(n)"
        }
        let cookie: JSON = ["name": name, "value": "", "domain": model.host, "path": "/",
                            "secure": model.origin.hasPrefix("https"), "httpOnly": false, "session": true]
        set(cookie, [:]) { [weak self] in
            self?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.list.filter = ""
                self?.list.edit(id: Self.id(cookie), column: "value")
            }
        }
    }
}

private final class DatabasesSection: TableSection {
    init() {
        super.init(columns: [("name", "Database", 160), ("version", "Version", 60), ("stores", "Object stores", 200)], key: "databases")
        list.table.target = self
        list.table.doubleAction = #selector(openDatabase)
        list.menuForRows = { [weak self] rows in
            guard let self, let row = rows.first else { return nil }
            let menu = NSMenu()
            menu.add("Open") { [weak self] in self?.open?(.database(row.id)) }
            menu.add("Delete Database") { [weak self] in self?.model?.deleteDatabase(row.id) }
            return menu
        }
        list.onDelete = { [weak self] rows in for row in rows { self?.model?.deleteDatabase(row.id) } }
        split.setSecondCollapsed(true)
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.model?.refreshDatabases() }, width: 24)
        toolbar.addSeparator()
        toolbar.add(filterField, width: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func openDatabase() {
        let row = list.table.clickedRow
        guard list.shown.indices.contains(row) else { return }
        open?(.database(list.shown[row].id))
    }

    override func reload() { show() }

    override func modelChanged(_ change: ApplicationChange) {
        if case .databases = change { show() }
    }

    private func show() {
        guard let model else { return }
        list.set(model.databaseNames.map { name in
            let database = model.databases[name]
            let stores = database?.list("objectStores").compactMap { $0.str("name") } ?? []
            return AppRow(id: name, values: ["name": name, "version": database?.num("version").map { "\(Int($0))" } ?? "",
                                             "stores": stores.joined(separator: ", ")],
                          numbers: ["version": database?.num("version") ?? 0])
        })
    }
}

private final class DatabaseSection: AppSectionView {
    private let name: String
    private let tree = ValueTreeView()

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        addSubview(tree)
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in
            guard let self else { return }
            model?.refreshDatabase(name)
        }, width: 24)
        let delete = NSButton(title: "Delete Database", target: nil, action: nil)
        delete.controlSize = .small
        delete.bezelStyle = .push
        delete.font = Theme.font(11)
        delete.onAction { [weak self] in
            guard let self else { return }
            model?.deleteDatabase(name)
            open?(.indexedDB)
        }
        toolbar.add(delete, width: 110)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        tree.frame = contentFrame
    }

    override func reload() { show() }

    override func modelChanged(_ change: ApplicationChange) {
        if case .databases = change { show() }
    }

    private static func keyPath(_ path: JSON?) -> String {
        guard let path else { return "" }
        if let string = path.str("string") { return string }
        if let array = path["array"] as? [String] { return "[" + array.joined(separator: ", ") + "]" }
        return ""
    }

    private func show() {
        guard let database = model?.databases[name] else { return tree.show([]) }
        func text(_ value: String, _ color: NSColor = .labelColor) -> NSAttributedString {
            NSMutableAttributedString().add(value, color)
        }
        var nodes: [ValueNode] = [
            GroupNode(name: "Name", value: text(name, InspectorTheme.string)),
            GroupNode(name: "Version", value: text("\(Int(database.num("version") ?? 0))", InspectorTheme.number)),
        ]
        let stores = database.list("objectStores").map { store -> ValueNode in
            var children: [ValueNode] = [
                GroupNode(name: "Key path", value: text(Self.keyPath(store.obj("keyPath")), InspectorTheme.string)),
                GroupNode(name: "Auto-increment", value: text(store.bool("autoIncrement") ? "true" : "false", InspectorTheme.keyword)),
            ]
            for index in store.list("indexes") {
                children.append(GroupNode(name: "Index " + (index.str("name") ?? ""), value: text(
                    Self.keyPath(index.obj("keyPath")) + (index.bool("unique") ? " · unique" : "") + (index.bool("multiEntry") ? " · multi-entry" : ""),
                    .secondaryLabelColor
                )))
            }
            return GroupNode(name: store.str("name") ?? "", value: text("object store", .secondaryLabelColor), children: children)
        }
        nodes.append(GroupNode(name: "Object stores", value: text("\(stores.count)", InspectorTheme.number), children: stores))
        tree.show(nodes)
        tree.expandRoots()
    }
}

private final class ObjectStoreSection: TableSection {
    private let database: String
    private let store: String
    private let indexPicker = NSPopUpButton()
    private let more = NSButton(title: "Load More", target: nil, action: nil)
    private let startKey = InspectorFilterField(placeholder: "Start from key")
    private var entries: [JSON] = []
    private var hasMore = false
    private static let pageSize = 50

    init(database: String, store: String) {
        self.database = database
        self.store = store
        super.init(columns: [("n", "#", 34), ("key", "Key", 120), ("primary", "Primary key", 100), ("value", "Value", 260)],
                   key: "objectstore")
        list.mono = ["key", "primary", "value"]
        list.onSelect = { [weak self] row in
            guard let self else { return }
            if let entry = row?.payload as? JSON, let value = entry.obj("value") {
                preview.show(object: value, session: session)
            } else {
                preview.show(nil)
            }
        }
        list.onDelete = { [weak self] rows in self?.delete(rows) }
        list.menuForRows = { [weak self] rows in
            guard let self, !rows.isEmpty else { return nil }
            let menu = NSMenu()
            menu.add(rows.count == 1 ? "Delete Entry" : "Delete \(rows.count) Entries") { [weak self] in self?.delete(rows) }
            return menu
        }
        indexPicker.controlSize = .small
        indexPicker.font = Theme.font(11)
        indexPicker.onAction { [weak self] in self?.reload() }
        more.controlSize = .small
        more.bezelStyle = .push
        more.font = Theme.font(11)
        more.onAction { [weak self] in self?.load(append: true) }
        startKey.onChange = { [weak self] _ in self?.reload() }
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.reload() }, width: 24)
        toolbar.add(InspectorButton("minus", tip: "Delete the selected entries  ⌫") { [weak self] in
            guard let self else { return }
            delete(list.selected)
        }, width: 24)
        toolbar.add(InspectorButton("trash", tip: "Clear the object store") { [weak self] in self?.clearStore() }, width: 24)
        toolbar.addSeparator()
        toolbar.add(indexPicker, width: 110)
        toolbar.add(startKey, width: nil)
        toolbar.add(more, width: 80)
        toolbar.add(status, width: 64, trailing: true)
        status.alignment = .right
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var baseParams: JSON {
        var params = model?.storageParams ?? [:]
        params["databaseName"] = database
        params["objectStoreName"] = store
        return params
    }

    override func reload() {
        let chosen = indexPicker.titleOfSelectedItem
        indexPicker.removeAllItems()
        indexPicker.addItem(withTitle: "Object store")
        let storeInfo = model?.databases[database]?.list("objectStores").first { $0.str("name") == store }
        for index in storeInfo?.list("indexes") ?? [] { indexPicker.addItem(withTitle: index.str("name") ?? "") }
        if let chosen, indexPicker.item(withTitle: chosen) != nil { indexPicker.selectItem(withTitle: chosen) }
        list.table.tableColumns.first { $0.identifier.rawValue == "primary" }?.isHidden = indexPicker.indexOfSelectedItem <= 0
        load(append: false)
    }

    private static func key(_ text: String) -> JSON {
        if let number = Double(text) { return ["type": "number", "number": number] }
        return ["type": "string", "string": text]
    }

    private func load(append: Bool) {
        guard let session else { return }
        var params = baseParams
        params["indexName"] = indexPicker.indexOfSelectedItem > 0 ? (indexPicker.titleOfSelectedItem ?? "") : ""
        params["skipCount"] = append ? entries.count : 0
        params["pageSize"] = Self.pageSize
        let start = startKey.stringValue.trimmingCharacters(in: .whitespaces)
        if !start.isEmpty { params["keyRange"] = ["lower": Self.key(start), "lowerOpen": false, "upperOpen": true] }
        session.call("IndexedDB.requestData", params) { [weak self] result, error in
            guard let self else { return }
            if let error {
                status.stringValue = "Failed"
                status.toolTip = error
                return
            }
            let page = result?.list("objectStoreDataEntries") ?? []
            entries = append ? entries + page : page
            hasMore = result?.bool("hasMore") ?? false
            show()
        }
    }

    private func show() {
        list.set(entries.enumerated().map { i, entry in
            let key = entry.obj("key") ?? [:], primary = entry.obj("primaryKey") ?? [:], value = entry.obj("value") ?? [:]
            return AppRow(id: "\(i)", values: [
                "n": "\(i)", "key": RemoteValue.summary(key), "primary": RemoteValue.summary(primary),
                "value": RemoteValue.summary(value),
            ], colors: ["n": .tertiaryLabelColor, "key": RemoteValue.color(key), "primary": RemoteValue.color(primary)],
            numbers: ["n": Double(i)], payload: entry)
        })
        more.isEnabled = hasMore
        status.stringValue = "\(entries.count)\(hasMore ? "+" : "") entr\(entries.count == 1 ? "y" : "ies")"
    }

    private func protocolKey(_ object: JSON) async -> JSON? {
        switch object.str("type") {
        case "number": return object.num("value").map { ["type": "number", "number": $0] }
        case "string": return object.str("value").map { ["type": "string", "string": $0] }
        default:
            guard object.str("subtype") == "date", let id = object.str("objectId"), let session else { return nil }
            let result = try? await session.send("Runtime.callFunctionOn", ["objectId": id, "functionDeclaration": "function(){ return this.getTime() }",
                                                                            "returnByValue": true])
            return result?.obj("result")?.num("value").map { ["type": "date", "date": $0] }
        }
    }

    private func delete(_ rows: [AppRow]) {
        guard let session else { return }
        let entries = rows.compactMap { $0.payload as? JSON }
        Task {
            var failed = 0
            for entry in entries {
                guard let key = await protocolKey(entry.obj("primaryKey") ?? entry.obj("key") ?? [:]) else {
                    failed += 1
                    continue
                }
                var params = baseParams
                params["keyRange"] = ["lower": key, "upper": key, "lowerOpen": false, "upperOpen": false]
                _ = try? await session.send("IndexedDB.deleteObjectStoreEntries", params)
            }
            load(append: false)
            if failed > 0 { status.stringValue = "\(failed) not deleted" }
        }
    }

    private func clearStore() {
        session?.call("IndexedDB.clearObjectStore", baseParams) { [weak self] _, _ in self?.load(append: false) }
    }
}

private final class CachesSection: TableSection {
    init() {
        super.init(columns: [("name", "Cache", 200), ("origin", "Origin", 200)], key: "caches")
        split.setSecondCollapsed(true)
        list.table.target = self
        list.table.doubleAction = #selector(openCache)
        list.menuForRows = { [weak self] rows in
            guard let self, let row = rows.first, let cache = row.payload as? JSON else { return nil }
            let menu = NSMenu()
            menu.add("Open") { [weak self] in self?.open?(.cache(id: row.id, name: cache.str("cacheName") ?? "")) }
            menu.add("Delete Cache") { [weak self] in self?.model?.deleteCache(row.id) }
            return menu
        }
        list.onDelete = { [weak self] rows in for row in rows { self?.model?.deleteCache(row.id) } }
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.model?.refreshCaches() }, width: 24)
        toolbar.addSeparator()
        toolbar.add(filterField, width: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func openCache() {
        let row = list.table.clickedRow
        guard list.shown.indices.contains(row), let cache = list.shown[row].payload as? JSON else { return }
        open?(.cache(id: list.shown[row].id, name: cache.str("cacheName") ?? ""))
    }

    override func reload() { show() }

    override func modelChanged(_ change: ApplicationChange) {
        if case .caches = change { show() }
    }

    private func show() {
        list.set((model?.caches ?? []).compactMap { cache in
            guard let id = cache.str("cacheId") else { return nil }
            return AppRow(id: id, values: ["name": cache.str("cacheName") ?? "",
                                           "origin": cache.str("securityOrigin") ?? cache.str("storageKey") ?? ""], payload: cache)
        })
    }
}

private final class CacheSection: TableSection {
    private let id: String
    private let name: String
    private var entries: [JSON] = []
    private var returned = 0
    private let more = NSButton(title: "Load More", target: nil, action: nil)
    private let image = NSImageView()
    private let path = InspectorFilterField(placeholder: "Filter by path")
    private static let pageSize = 50

    init(id: String, name: String) {
        self.id = id
        self.name = name
        super.init(columns: [("n", "#", 30), ("url", "Name", 200), ("type", "Response type", 80),
                             ("contentType", "Content-Type", 110), ("length", "Content-Length", 80), ("time", "Time cached", 150)],
                   key: "cache", scrollsSideways: true)
        list.onSelect = { [weak self] row in self?.preview(row) }
        list.onDelete = { [weak self] rows in self?.delete(rows) }
        list.menuForRows = { [weak self] rows in
            guard let self, !rows.isEmpty else { return nil }
            let menu = NSMenu()
            if let entry = rows.first?.payload as? JSON { menu.add("Copy URL") { Format.copy(entry.str("requestURL") ?? "") } }
            menu.add(rows.count == 1 ? "Delete Entry" : "Delete \(rows.count) Entries") { [weak self] in self?.delete(rows) }
            return menu
        }
        image.imageScaling = .scaleProportionallyDown
        image.isHidden = true
        preview.addSubview(image)
        more.controlSize = .small
        more.bezelStyle = .push
        more.font = Theme.font(11)
        more.onAction { [weak self] in self?.load(append: true) }
        path.onChange = { [weak self] _ in self?.load(append: false) }
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.reload() }, width: 24)
        toolbar.add(InspectorButton("minus", tip: "Delete the selected entries  ⌫") { [weak self] in
            guard let self else { return }
            delete(list.selected)
        }, width: 24)
        toolbar.add(InspectorButton("trash", tip: "Delete this cache") { [weak self] in
            guard let self else { return }
            model?.deleteCache(id)
            open?(.cacheStorage)
        }, width: 24)
        toolbar.addSeparator()
        toolbar.add(path, width: nil)
        toolbar.add(more, width: 80)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        image.frame = preview.bounds.insetBy(dx: 12, dy: 12)
    }

    override func reload() { load(append: false) }

    private func load(append: Bool) {
        let params: JSON = ["cacheId": id, "skipCount": append ? entries.count : 0, "pageSize": Self.pageSize,
                            "pathFilter": path.stringValue]
        session?.call("CacheStorage.requestEntries", params) { [weak self] result, _ in
            guard let self else { return }
            let page = result?.list("cacheDataEntries") ?? []
            entries = append ? entries + page : page
            returned = result?.int("returnCount") ?? entries.count
            more.isEnabled = entries.count < returned
            show()
        }
    }

    private static func header(_ entry: JSON, _ name: String) -> String {
        entry.list("responseHeaders").first { $0.str("name")?.lowercased() == name }?.str("value") ?? ""
    }

    private func show() {
        let dates = DateFormatter()
        dates.dateStyle = .short
        dates.timeStyle = .medium
        list.set(entries.enumerated().map { i, entry in
            let url = entry.str("requestURL") ?? ""
            let time = entry.num("responseTime") ?? 0
            let length = Self.header(entry, "content-length")
            return AppRow(id: url, values: [
                "n": "\(i)", "url": URL(string: url).map { $0.path + ($0.query.map { "?" + $0 } ?? "") } ?? url,
                "type": entry.str("responseType") ?? "", "contentType": Self.header(entry, "content-type"),
                "length": length, "time": time > 0 ? dates.string(from: Date(timeIntervalSince1970: time)) : "",
            ], colors: ["n": .tertiaryLabelColor], numbers: ["n": Double(i), "length": Double(length) ?? 0, "time": time], payload: entry)
        })
    }

    private func preview(_ row: AppRow?) {
        image.isHidden = true
        guard let entry = row?.payload as? JSON, let session else { return preview.show(nil) }
        let headers = entry.list("requestHeaders").map { ["name": $0.str("name") ?? "", "value": $0.str("value") ?? ""] }
        session.call("CacheStorage.requestCachedResponse", ["cacheId": id, "requestURL": entry.str("requestURL") ?? "",
                                                            "requestHeaders": headers]) { [weak self] result, error in
            guard let self, list.selected.first?.id == row?.id else { return }
            let data = result?.obj("response")?.str("body").flatMap { Data(base64Encoded: $0) } ?? Data()
            let type = Self.header(entry, "content-type")
            if type.hasPrefix("image/"), let picture = NSImage(data: data) {
                preview.show("")
                image.image = picture
                image.isHidden = false
            } else if let text = String(data: data, encoding: .utf8) {
                preview.show(text)
            } else {
                preview.show(error ?? "Binary data, \(Format.bytes(Double(data.count)))")
            }
        }
    }

    private func delete(_ rows: [AppRow]) {
        guard let session else { return }
        Task {
            for row in rows { _ = try? await session.send("CacheStorage.deleteEntry", ["cacheId": id, "request": row.id]) }
            load(append: false)
        }
    }
}

private final class ManifestSection: AppSectionView {
    private let tree = ValueTreeView()
    private let empty = InspectorEmptyView("This page has no web app manifest.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(tree)
        addSubview(empty)
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.reload() }, width: 24)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        tree.frame = contentFrame
        empty.frame = contentFrame
    }

    override func modelChanged(_ change: ApplicationChange) {
        if case .origin = change { reload() }
    }

    override func reload() {
        session?.call("Page.getAppManifest") { [weak self] result, error in
            guard let self else { return }
            let url = result?.str("url") ?? ""
            let errors = result?.list("errors") ?? []
            let data = result?.str("data") ?? ""
            empty.isHidden = !url.isEmpty || !errors.isEmpty
            tree.isHidden = !empty.isHidden
            if let error { empty.text = error }
            var nodes: [ValueNode] = [GroupNode(name: "URL", value: NSMutableAttributedString().add(url, InspectorTheme.link))]
            if !errors.isEmpty {
                nodes.append(GroupNode(name: "Errors", value: NSMutableAttributedString().add("\(errors.count)", InspectorTheme.error),
                                       children: errors.map { error in
                                           GroupNode(name: error.bool("critical") ? "critical" : "warning", value: NSMutableAttributedString().add(
                                               (error.str("message") ?? "") + (error.int("line").map { " (line \($0 + 1))" } ?? ""), InspectorTheme.error
                                           ))
                                       }))
            }
            if let value = try? JSONSerialization.jsonObject(with: Data(data.utf8)) {
                let node = JSONValueNode(name: "Manifest", value: value)
                nodes.append(node)
            } else if !data.isEmpty {
                nodes.append(GroupNode(name: "Manifest", value: NSMutableAttributedString().add(data.clipped(500).oneLine, InspectorTheme.string)))
            }
            tree.show(nodes)
            tree.expandRoots()
        }
    }
}

private final class ServiceWorkersSection: AppSectionView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = InspectorTableView()
    private var scroll: NSScrollView!
    private let details = CodeView()
    private var split: InspectorSplitView!
    private let empty = InspectorEmptyView("No service workers for this site.")
    private let forceUpdate = NSButton(checkboxWithTitle: "Update on reload", target: nil, action: nil)
    private var registrations: [JSON] = []
    private var buttons: [InspectorButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll = InspectorTable.make(table, columns: [("scope", "Scope", 180), ("status", "Status", 130), ("script", "Script", 200)])
        table.dataSource = self
        table.delegate = self
        details.wraps = true
        split = InspectorSplitView(scroll, details, vertical: false, key: "application.workers", fraction: 0.45, minimum: 60)
        addSubview(split)
        addSubview(empty)
        forceUpdate.controlSize = .small
        forceUpdate.font = Theme.font(11)
        forceUpdate.onAction { [weak self] in
            guard let self else { return }
            model?.setForceUpdateOnReload(forceUpdate.state == .on)
        }
        let actions: [(String, String, (JSON, ApplicationModel?, InspectorSession) -> Void)] = [
            ("arrow.triangle.2.circlepath", "Update", { registration, _, session in
                session.call("ServiceWorker.updateRegistration", ["scopeURL": registration.str("scopeURL") ?? ""])
            }),
            ("play", "Start", { registration, _, session in
                session.call("ServiceWorker.startWorker", ["scopeURL": registration.str("scopeURL") ?? ""])
            }),
            ("stop", "Stop", { registration, model, session in
                for version in model?.versions(of: registration.str("registrationId") ?? "") ?? []
                    where version.str("runningStatus") == "running" || version.str("runningStatus") == "starting" {
                    session.call("ServiceWorker.stopWorker", ["versionId": version.str("versionId") ?? ""])
                }
            }),
            ("forward.end", "Skip waiting", { registration, _, session in
                session.call("ServiceWorker.skipWaiting", ["scopeURL": registration.str("scopeURL") ?? ""])
            }),
            ("xmark.circle", "Unregister", { registration, _, session in
                session.call("ServiceWorker.unregister", ["scopeURL": registration.str("scopeURL") ?? ""])
            }),
        ]
        for (symbol, tip, run) in actions {
            let button = InspectorButton(symbol, tip: tip) { [weak self] in
                guard let self, let session, let registration = selection else { return }
                run(registration, model, session)
            }
            buttons.append(button)
            toolbar.add(button, width: 24)
        }
        toolbar.addSeparator()
        toolbar.add(forceUpdate, width: 130)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        split.frame = contentFrame
        empty.frame = contentFrame
    }

    private var selection: JSON? { registrations.indices.contains(table.selectedRow) ? registrations[table.selectedRow] : nil }

    override func reload() { show() }

    override func modelChanged(_ change: ApplicationChange) {
        switch change {
        case .serviceWorkers, .origin: show()
        default: break
        }
    }

    private func show() {
        let id = selection?.str("registrationId")
        registrations = model?.siteRegistrations ?? []
        table.reloadData()
        if let row = registrations.firstIndex(where: { $0.str("registrationId") == id }) ?? (registrations.isEmpty ? nil : 0) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        empty.isHidden = !registrations.isEmpty
        split.isHidden = registrations.isEmpty
        forceUpdate.state = model?.forceUpdateOnReload == true ? .on : .off
        showDetails()
    }

    private func status(_ registration: JSON) -> String {
        guard let version = model?.versions(of: registration.str("registrationId") ?? "").first else { return "" }
        return "#\(version.str("versionId") ?? "") \(version.str("status") ?? "") · \(version.str("runningStatus") ?? "")"
    }

    private func showDetails() {
        for button in buttons { button.isEnabled = selection != nil }
        guard let registration = selection, let model else { return details.show("", language: .plain) }
        let id = registration.str("registrationId") ?? ""
        var lines = ["Scope: \(registration.str("scopeURL") ?? "")", "Registration: \(id)", ""]
        for version in model.versions(of: id) {
            lines.append("Version #\(version.str("versionId") ?? "")")
            lines.append("  Script: \(version.str("scriptURL") ?? "")")
            lines.append("  Status: \(version.str("status") ?? "") · \(version.str("runningStatus") ?? "")")
            if let modified = version.num("scriptLastModified"), modified > 0 {
                lines.append("  Script modified: \(Date(timeIntervalSince1970: modified).formatted())")
            }
            if let received = version.num("scriptResponseTime"), received > 0 {
                lines.append("  Script received: \(Date(timeIntervalSince1970: received).formatted())")
            }
            let clients = version["controlledClients"] as? [String] ?? []
            if !clients.isEmpty { lines.append("  Controls \(clients.count) client\(clients.count == 1 ? "" : "s")") }
            lines.append("")
        }
        let errors = model.errors(of: id)
        if !errors.isEmpty {
            lines.append("Errors")
            for error in errors {
                lines.append("  \(error.str("errorMessage") ?? "") — \(error.str("sourceURL") ?? ""):\(error.int("lineNumber") ?? 0)")
            }
        }
        details.show(lines.joined(separator: "\n"), language: .plain)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { registrations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let registration = registrations[row]
        switch tableColumn?.identifier.rawValue {
        case "scope": return InspectorTable.cell(tableView, "scope", registration.str("scopeURL") ?? "", color: InspectorTheme.link)
        case "status":
            let text = status(registration)
            return InspectorTable.cell(tableView, "status", text, color: text.contains("running") ? .systemGreen : .secondaryLabelColor)
        default:
            let script = model?.versions(of: registration.str("registrationId") ?? "").first?.str("scriptURL") ?? ""
            return InspectorTable.cell(tableView, "script", script, font: InspectorTheme.mono())
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { InspectorRowView() }
    func tableViewSelectionDidChange(_ notification: Notification) { showDetails() }
}

private final class FramesSection: AppSectionView {
    private let tree = ValueTreeView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(tree)
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.reload() }, width: 24)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        tree.frame = contentFrame
    }

    override func modelChanged(_ change: ApplicationChange) {
        if case .origin = change { reload() }
    }

    override func reload() {
        session?.call("Page.getFrameTree") { [weak self] result, _ in
            guard let self, let root = result?.obj("frameTree") else { return }
            tree.show([node(root)])
            tree.expandRoots()
        }
    }

    private func node(_ tree: JSON) -> ValueNode {
        let frame = tree.obj("frame") ?? [:]
        func text(_ value: String, _ color: NSColor = .labelColor) -> NSAttributedString {
            NSMutableAttributedString().add(value, color)
        }
        var children: [ValueNode] = [
            GroupNode(name: "URL", value: text((frame.str("url") ?? "") + (frame.str("urlFragment") ?? ""), InspectorTheme.link)),
            GroupNode(name: "Origin", value: text(frame.str("securityOrigin") ?? "", InspectorTheme.string)),
            GroupNode(name: "MIME type", value: text(frame.str("mimeType") ?? "")),
            GroupNode(name: "Secure context", value: text(frame.str("secureContextType") ?? "")),
            GroupNode(name: "Cross-origin isolated", value: text(frame.str("crossOriginIsolatedContextType") ?? "")),
        ]
        if let ad = frame.obj("adFrameStatus")?.str("adFrameType"), ad != "none" {
            children.append(GroupNode(name: "Ad frame", value: text(ad, InspectorTheme.warning)))
        }
        let apis = frame["gatedAPIFeatures"] as? [String] ?? []
        if !apis.isEmpty { children.append(GroupNode(name: "Gated APIs", value: text(apis.joined(separator: ", ")))) }
        children += tree.list("childFrames").map(node)
        let name = frame.str("name").flatMap { $0.isEmpty ? nil : $0 } ?? (frame["parentId"] == nil ? "top" : "frame")
        return GroupNode(name: name, value: text(DevSite.label(frame.str("url") ?? ""), .secondaryLabelColor), children: children)
    }
}

private final class StorageOverviewSection: AppSectionView {
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let originLabel = Label.make("", size: 12, weight: .semibold)
    private let usageLabel = Label.make("", size: 11.5, color: .secondaryLabelColor)
    private let bar = UsageBar()
    private var breakdown: [(String, Double)] = []
    private var breakdownLabels: [NSTextField] = []
    private var breakdownBars: [UsageBar] = []
    private let clearHeading = Label.make("Clear site data", size: 12, weight: .semibold)
    private let checks: [(type: String, box: NSButton)] = [
        ("cookies", NSButton(checkboxWithTitle: "Cookies", target: nil, action: nil)),
        ("local_storage", NSButton(checkboxWithTitle: "Local and session storage", target: nil, action: nil)),
        ("indexeddb", NSButton(checkboxWithTitle: "IndexedDB", target: nil, action: nil)),
        ("cache_storage", NSButton(checkboxWithTitle: "Cache storage", target: nil, action: nil)),
        ("service_workers", NSButton(checkboxWithTitle: "Service workers", target: nil, action: nil)),
        ("file_systems,shader_cache,storage_buckets,shared_storage,interest_groups", NSButton(checkboxWithTitle: "Everything else", target: nil, action: nil)),
    ]
    private let clear = NSButton(title: "Clear Site Data", target: nil, action: nil)
    private let clearStatus = Label.make("", size: 11, color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        for view in [originLabel, usageLabel, bar, clearHeading, clear, clearStatus] as [NSView] { content.addSubview(view) }
        for (_, box) in checks {
            box.controlSize = .small
            box.font = Theme.font(11.5)
            box.state = .on
            content.addSubview(box)
        }
        clear.controlSize = .small
        clear.bezelStyle = .push
        clear.font = Theme.font(11.5)
        clear.onAction { [weak self] in self?.clearData() }
        toolbar.add(InspectorButton("arrow.clockwise", tip: "Refresh") { [weak self] in self?.reload() }, width: 24)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func modelChanged(_ change: ApplicationChange) {
        if case .origin = change { reload() }
    }

    override func layout() {
        super.layout()
        scroll.frame = contentFrame
        let width = max(scroll.contentSize.width, 200)
        let inset: CGFloat = 14, inner = width - 2 * inset
        var y: CGFloat = 14
        originLabel.frame = NSRect(x: inset, y: y, width: inner, height: 17)
        y += 22
        usageLabel.frame = NSRect(x: inset, y: y, width: inner, height: 16)
        y += 20
        bar.frame = NSRect(x: inset, y: y, width: inner, height: 8)
        y += 18
        for (i, label) in breakdownLabels.enumerated() {
            label.frame = NSRect(x: inset, y: y, width: min(170, inner * 0.45), height: 16)
            breakdownBars[i].frame = NSRect(x: inset + min(176, inner * 0.47), y: y + 4, width: max(inner - min(176, inner * 0.47), 20), height: 6)
            y += 20
        }
        y += 14
        clearHeading.frame = NSRect(x: inset, y: y, width: inner, height: 17)
        y += 24
        for (_, box) in checks {
            box.frame = NSRect(x: inset, y: y, width: inner, height: 18)
            y += 22
        }
        y += 6
        clear.frame = NSRect(x: inset - 4, y: y, width: 120, height: 24)
        clearStatus.frame = NSRect(x: inset + 124, y: y + 4, width: max(inner - 124, 0), height: 16)
        y += 40
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    private static func label(_ type: String) -> String {
        switch type {
        case "local_storage": "Local storage"
        case "indexeddb": "IndexedDB"
        case "cache_storage": "Cache storage"
        case "service_workers": "Service workers"
        case "file_systems": "File system"
        case "shader_cache": "Shader cache"
        case "storage_buckets": "Storage buckets"
        case "shared_storage": "Shared storage"
        case "interest_groups": "Interest groups"
        case "cookies": "Cookies"
        case "websql": "Web SQL"
        default: type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    override func reload() {
        guard let session, let model else { return }
        originLabel.stringValue = model.origin.isEmpty ? "No origin" : model.origin
        guard !model.origin.isEmpty else { return }
        session.call("Storage.getUsageAndQuota", ["origin": model.origin]) { [weak self] result, error in
            guard let self else { return }
            let usage = result?.num("usage") ?? 0, quota = result?.num("quota") ?? 0
            usageLabel.stringValue = error ?? "\(Format.bytes(usage)) used of \(Format.bytes(quota)) quota"
                + (result?.bool("overrideActive") == true ? " (overridden)" : "")
            bar.fraction = quota > 0 ? max(usage / quota, usage > 0 ? 0.01 : 0) : 0
            breakdown = (result?.list("usageBreakdown") ?? []).compactMap { item in
                guard let type = item.str("storageType"), let bytes = item.num("usage"), bytes > 0 else { return nil }
                return (type, bytes)
            }.sorted { $0.1 > $1.1 }
            for view in breakdownLabels as [NSView] + breakdownBars { view.removeFromSuperview() }
            breakdownLabels = breakdown.map { type, bytes in
                Label.make("\(Self.label(type))  \(Format.bytes(bytes))", size: 11.5)
            }
            breakdownBars = breakdown.map { _, bytes in
                let bar = UsageBar()
                bar.fraction = usage > 0 ? bytes / usage : 0
                return bar
            }
            for view in breakdownLabels as [NSView] + breakdownBars { content.addSubview(view) }
            needsLayout = true
        }
    }

    private func clearData() {
        guard let session, let model, !model.origin.isEmpty else { return }
        let types = checks.filter { $0.box.state == .on }.map(\.type)
        guard !types.isEmpty else { return }
        clearStatus.stringValue = "Clearing…"
        session.call("Storage.clearDataForOrigin", ["origin": model.origin, "storageTypes": types.joined(separator: ",")]) { [weak self] _, error in
            guard let self else { return }
            clearStatus.stringValue = error ?? "Cleared."
            model.refreshDOMStorage()
            model.refreshDatabases()
            model.refreshCaches()
            reload()
        }
    }
}

private final class UsageBar: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Theme.faint(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        NSColor.controlAccentColor.setFill()
        let filled = NSRect(x: 0, y: 0, width: max(bounds.width * min(fraction, 1), bounds.height), height: bounds.height)
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
