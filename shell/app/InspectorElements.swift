import AppKit

@MainActor
final class DOMNode {
    let id: Int
    let backendID: Int
    let type: Int
    let name: String
    let localName: String
    var value: String
    var attributes: [(name: String, value: String)]
    var childCount: Int
    var children: [DOMNode]?
    weak var parent: DOMNode?
    var shadowRoots: [DOMNode] = []
    var contentDocument: DOMNode?
    var templateContent: DOMNode?
    var before: DOMNode?
    var after: DOMNode?
    let pseudoType: String?
    let shadowRootType: String?
    let frameID: String?

    init(_ json: JSON) {
        id = json.int("nodeId") ?? 0
        backendID = json.int("backendNodeId") ?? 0
        type = json.int("nodeType") ?? 1
        name = json.str("nodeName") ?? ""
        localName = json.str("localName") ?? ""
        value = json.str("nodeValue") ?? ""
        let flat = json["attributes"] as? [String] ?? []
        attributes = stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }
        childCount = json.int("childNodeCount") ?? 0
        pseudoType = json.str("pseudoType")
        shadowRootType = json.str("shadowRootType")
        frameID = json.str("frameId")
    }

    var isElement: Bool { type == 1 }
    var isText: Bool { type == 3 }

    func attribute(_ name: String) -> String? { attributes.first { $0.name == name }?.value }

    var shownChildren: [DOMNode] {
        var nodes = shadowRoots
        if let templateContent { nodes.append(templateContent) }
        if let contentDocument { nodes.append(contentDocument) }
        if let before { nodes.append(before) }
        nodes += (children ?? []).filter { !($0.isText && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        if let after { nodes.append(after) }
        return nodes
    }

    var hasChildren: Bool {
        if let inline = inlineText, !inline.isEmpty { return false }
        return !shownChildren.isEmpty || (children == nil && childCount > 0)
    }

    var inlineText: String? {
        guard isElement, shadowRoots.isEmpty, contentDocument == nil, before == nil, after == nil,
              let children, children.count == 1, children[0].isText else { return nil }
        let text = children[0].value
        return text.count <= 80 && !text.contains("\n") ? text : nil
    }

    var shortName: String {
        if let pseudoType { return "::\(pseudoType)" }
        guard isElement else { return name.lowercased() }
        var text = localName.isEmpty ? name.lowercased() : localName
        if let id = attribute("id"), !id.isEmpty { text += "#\(id)" }
        if let classes = attribute("class") {
            text += classes.split(separator: " ").prefix(3).map { ".\($0)" }.joined()
        }
        return text
    }

    func walk(_ visit: (DOMNode) -> Void) {
        visit(self)
        for child in shadowRoots { child.walk(visit) }
        templateContent?.walk(visit)
        contentDocument?.walk(visit)
        before?.walk(visit)
        after?.walk(visit)
        for child in children ?? [] { child.walk(visit) }
    }
}

@MainActor
final class ClosingTag {
    let node: DOMNode
    init(_ node: DOMNode) { self.node = node }
}

@MainActor
final class ElementsModel: InspectorModel {
    private weak var session: InspectorSession?
    private(set) var document: DOMNode?
    private var nodes: [Int: DOMNode] = [:]
    private(set) var selected: DOMNode?
    private(set) var styleSheets: [String: JSON] = [:]
    let reset = Signal<Void>()
    let nodeChanged = Signal<DOMNode>()
    let selectionChanged = Signal<Void>()
    let stylesChanged = Signal<Void>()
    let revealed = Signal<DOMNode>()
    private var started = false
    private var waitingReveal: Int?
    private var childWaiters: [Int: [@MainActor () -> Void]] = [:]

    init(session: InspectorSession) { self.session = session }

    func start() {
        guard let session, !started else { return }
        started = true
        session.on("DOM.", self) { [weak self] method, params in self?.domEvent(method, params) }
        session.on("CSS.", self) { [weak self] method, params in
            guard let self else { return }
            switch method {
            case "CSS.styleSheetAdded":
                if let header = params.obj("header"), let id = header.str("styleSheetId") { styleSheets[id] = header }
            case "CSS.styleSheetRemoved":
                if let id = params.str("styleSheetId") { styleSheets[id] = nil }
            case "CSS.styleSheetChanged", "CSS.mediaQueryResultChanged", "CSS.fontsUpdated":
                stylesChanged.send()
            default: break
            }
        }
        session.call("DOM.enable")
        session.call("CSS.enable")
        session.call("Overlay.enable")
        fetchDocument()
    }

    func stop() {
        session?.call("Overlay.hideHighlight")
        session?.call("CSS.disable")
        session?.call("Overlay.disable")
        session?.call("DOM.disable")
    }

    private func fetchDocument() {
        guard let session else { return }
        session.call("DOM.getDocument", ["depth": 3]) { [weak self] result, _ in
            guard let self, let root = result?.obj("root") else { return }
            nodes = [:]
            let document = build(root, parent: nil)
            self.document = document
            let previous = selected
            selected = nil
            reset.send()
            if let waitingReveal {
                self.waitingReveal = nil
                reveal(backendNodeID: waitingReveal)
            } else if let previous, let again = document.find({ $0.backendID == previous.backendID }) {
                select(again)
                revealed.send(again)
            } else if let body = document.find({ $0.localName == "body" }) {
                select(body)
                revealed.send(body)
            }
        }
    }

    @discardableResult
    private func build(_ json: JSON, parent: DOMNode?) -> DOMNode {
        let node = DOMNode(json)
        node.parent = parent
        nodes[node.id] = node
        if let children = json["children"] as? [JSON] { node.children = children.map { build($0, parent: node) } }
        node.shadowRoots = json.list("shadowRoots").map { build($0, parent: node) }
        node.contentDocument = json.obj("contentDocument").map { build($0, parent: node) }
        node.templateContent = json.obj("templateContent").map { build($0, parent: node) }
        for pseudo in json.list("pseudoElements") {
            switch pseudo.str("pseudoType") {
            case "before": node.before = build(pseudo, parent: node)
            case "after": node.after = build(pseudo, parent: node)
            default: break
            }
        }
        return node
    }

    func node(_ id: Int) -> DOMNode? { nodes[id] }

    private func domEvent(_ method: String, _ params: JSON) {
        switch method {
        case "DOM.documentUpdated":
            fetchDocument()
        case "DOM.setChildNodes":
            guard let parent = params.int("parentId").flatMap({ nodes[$0] }) else { return }
            parent.children = params.list("nodes").map { build($0, parent: parent) }
            parent.childCount = parent.children?.count ?? 0
            nodeChanged.send(parent)
            for waiter in childWaiters.removeValue(forKey: parent.id) ?? [] { waiter() }
        case "DOM.childNodeInserted":
            guard let parent = params.int("parentNodeId").flatMap({ nodes[$0] }), let json = params.obj("node") else { return }
            let node = build(json, parent: parent)
            parent.childCount += 1
            if var children = parent.children {
                let previous = params.int("previousNodeId") ?? 0
                let index = children.firstIndex { $0.id == previous }.map { $0 + 1 } ?? 0
                children.insert(node, at: min(index, children.count))
                parent.children = children
            }
            nodeChanged.send(parent)
        case "DOM.childNodeRemoved":
            guard let parent = params.int("parentNodeId").flatMap({ nodes[$0] }), let id = params.int("nodeId") else { return }
            parent.children?.removeAll { $0.id == id }
            parent.childCount = max(parent.childCount - 1, 0)
            if let removed = nodes.removeValue(forKey: id), let selected, isAncestor(removed, of: selected) {
                select(parent)
            }
            nodeChanged.send(parent)
        case "DOM.childNodeCountUpdated":
            guard let node = params.int("nodeId").flatMap({ nodes[$0] }) else { return }
            node.childCount = params.int("childNodeCount") ?? node.childCount
            nodeChanged.send(node)
        case "DOM.attributeModified":
            guard let node = params.int("nodeId").flatMap({ nodes[$0] }), let name = params.str("name") else { return }
            let value = params.str("value") ?? ""
            if let index = node.attributes.firstIndex(where: { $0.name == name }) {
                node.attributes[index].value = value
            } else {
                node.attributes.append((name, value))
            }
            nodeChanged.send(node)
            if node === selected { stylesChanged.send() }
        case "DOM.attributeRemoved":
            guard let node = params.int("nodeId").flatMap({ nodes[$0] }), let name = params.str("name") else { return }
            node.attributes.removeAll { $0.name == name }
            nodeChanged.send(node)
            if node === selected { stylesChanged.send() }
        case "DOM.characterDataModified":
            guard let node = params.int("nodeId").flatMap({ nodes[$0] }) else { return }
            node.value = params.str("characterData") ?? ""
            if let parent = node.parent { nodeChanged.send(parent) }
            nodeChanged.send(node)
        case "DOM.inlineStyleInvalidated":
            let ids = params["nodeIds"] as? [Int] ?? []
            if let selected, ids.contains(selected.id) { stylesChanged.send() }
        case "DOM.shadowRootPushed":
            guard let host = params.int("hostId").flatMap({ nodes[$0] }), let root = params.obj("root") else { return }
            host.shadowRoots.append(build(root, parent: host))
            nodeChanged.send(host)
        case "DOM.shadowRootPopped":
            guard let host = params.int("hostId").flatMap({ nodes[$0] }), let id = params.int("rootId") else { return }
            host.shadowRoots.removeAll { $0.id == id }
            nodeChanged.send(host)
        case "DOM.pseudoElementAdded":
            guard let parent = params.int("parentId").flatMap({ nodes[$0] }), let json = params.obj("pseudoElement") else { return }
            let node = build(json, parent: parent)
            if node.pseudoType == "before" { parent.before = node } else if node.pseudoType == "after" { parent.after = node }
            nodeChanged.send(parent)
        case "DOM.pseudoElementRemoved":
            guard let parent = params.int("parentId").flatMap({ nodes[$0] }), let id = params.int("pseudoElementId") else { return }
            if parent.before?.id == id { parent.before = nil }
            if parent.after?.id == id { parent.after = nil }
            nodeChanged.send(parent)
        default:
            break
        }
    }

    private func isAncestor(_ ancestor: DOMNode, of node: DOMNode) -> Bool {
        var current: DOMNode? = node
        while let next = current {
            if next === ancestor { return true }
            current = next.parent
        }
        return false
    }

    func loadChildren(_ node: DOMNode, _ done: @escaping @MainActor () -> Void) {
        guard node.children == nil, node.childCount > 0 else { return done() }
        let first = childWaiters[node.id] == nil
        childWaiters[node.id, default: []].append(done)
        if first { session?.call("DOM.requestChildNodes", ["nodeId": node.id, "depth": 1]) }
    }

    func select(_ node: DOMNode?) {
        guard node !== selected else { return }
        selected = node
        if let node, node.id > 0 { session?.call("DOM.setInspectedNode", ["nodeId": node.id]) }
        selectionChanged.send()
    }

    func reveal(backendNodeID: Int) {
        guard let session else { return }
        guard document != nil else {
            waitingReveal = backendNodeID
            return
        }
        session.call("DOM.pushNodesByBackendIdsToFrontend", ["backendNodeIds": [backendNodeID]]) { [weak self] result, _ in
            guard let self, let id = (result?["nodeIds"] as? [Int])?.first, let node = nodes[id] else { return }
            select(node)
            revealed.send(node)
        }
    }

    func highlight(_ node: DOMNode?) {
        guard let session else { return }
        guard let node, node.id > 0, node.isElement || node.pseudoType != nil || node.isText else {
            session.call("Overlay.hideHighlight")
            return
        }
        session.call("Overlay.highlightNode", ["nodeId": node.id, "highlightConfig": Self.highlightConfig])
    }

    static let highlightConfig: JSON = {
        func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Double) -> JSON { ["r": r, "g": g, "b": b, "a": a] }
        return ["showInfo": true, "showStyles": true, "showRulers": false, "showExtensionLines": false,
                "contentColor": rgba(111, 168, 220, 0.66), "paddingColor": rgba(147, 196, 125, 0.55),
                "borderColor": rgba(255, 229, 153, 0.66), "marginColor": rgba(246, 178, 107, 0.66)]
    }()

    func edit(_ method: String, _ params: JSON, _ done: (@MainActor (JSON?, String?) -> Void)? = nil) {
        guard let session else { return }
        session.call(method, params) { result, error in
            session.call("DOM.markUndoableState")
            done?(result, error)
        }
    }

    func undo() { session?.call("DOM.undo") }
    func redo() { session?.call("DOM.redo") }

    func resolve(_ node: DOMNode) async -> JSON? {
        guard let session else { return nil }
        return try? await session.send("DOM.resolveNode", ["nodeId": node.id, "objectGroup": "elements"]).obj("object")
    }

    func callOn(_ node: DOMNode, _ function: String, returnByValue: Bool = true) async -> Any? {
        guard let session, let object = await resolve(node), let id = object.str("objectId") else { return nil }
        let result = try? await session.send("Runtime.callFunctionOn", ["objectId": id, "functionDeclaration": function,
                                                                        "returnByValue": returnByValue])
        return result?.obj("result")?["value"]
    }

    private var searchID: String?
    private(set) var searchResults: [Int] = []

    func search(_ query: String, _ done: @escaping @MainActor (Int) -> Void) {
        guard let session else { return }
        if let searchID { session.call("DOM.discardSearchResults", ["searchId": searchID]) }
        searchID = nil
        searchResults = []
        guard !query.isEmpty else { return done(0) }
        session.call("DOM.performSearch", ["query": query, "includeUserAgentShadowDOM": false]) { [weak self] result, _ in
            guard let self, let id = result?.str("searchId"), let count = result?.int("resultCount") else { return done(0) }
            searchID = id
            guard count > 0 else { return done(0) }
            session.call("DOM.getSearchResults", ["searchId": id, "fromIndex": 0, "toIndex": min(count, 500)]) { [weak self] result, _ in
                self?.searchResults = result?["nodeIds"] as? [Int] ?? []
                done(count)
            }
        }
    }

    func path(to node: DOMNode) -> [DOMNode] {
        var path: [DOMNode] = []
        var current: DOMNode? = node
        while let next = current {
            path.insert(next, at: 0)
            current = next.parent
        }
        return path
    }
}

private extension DOMNode {
    func find(_ test: (DOMNode) -> Bool) -> DOMNode? {
        var found: DOMNode?
        walk { node in if found == nil, test(node) { found = node } }
        return found
    }
}

@MainActor
enum DOMText {
    static let font = InspectorTheme.mono(11)

    static func row(_ node: DOMNode, expanded: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch node.type {
        case 1:
            if let pseudo = node.pseudoType { return out.add("::\(pseudo)", InspectorTheme.tag, font: font) }
            let name = node.localName.isEmpty ? node.name.lowercased() : node.localName
            out.add("<", InspectorTheme.tag, font: font).add(name, InspectorTheme.tag, font: font)
            for (attribute, value) in node.attributes {
                out.add(" ", .labelColor, font: font).add(attribute, InspectorTheme.attribute, font: font)
                out.add("=\"", .secondaryLabelColor, font: font)
                out.add(value.clipped(attribute == "style" || attribute == "d" ? 120 : 300).oneLine, InspectorTheme.string, font: font)
                out.add("\"", .secondaryLabelColor, font: font)
            }
            out.add(">", InspectorTheme.tag, font: font)
            if let inline = node.inlineText {
                out.add(inline, .labelColor, font: font)
                out.add("</\(name)>", InspectorTheme.tag, font: font)
            } else if !expanded, node.hasChildren {
                out.add("…", .secondaryLabelColor, font: font).add("</\(name)>", InspectorTheme.tag, font: font)
            } else if !node.hasChildren, !voidElements.contains(name) {
                out.add("</\(name)>", InspectorTheme.tag, font: font)
            }
        case 3:
            out.add("\"\(node.value.trimmingCharacters(in: .whitespacesAndNewlines).clipped(400).oneLine)\"", .labelColor, font: font)
        case 8:
            out.add("<!--\(node.value.clipped(300).oneLine)-->", InspectorTheme.comment, font: font)
        case 9:
            out.add("#document", .secondaryLabelColor, font: font)
            if node.parent != nil, let frame = node.frameID { out.add("  (frame \(frame.prefix(6)))", .tertiaryLabelColor, font: font) }
        case 10:
            out.add("<!DOCTYPE \(node.name)>", InspectorTheme.comment, font: font)
        case 11:
            out.add(node.shadowRootType.map { "#shadow-root (\($0))" } ?? "#document-fragment", .secondaryLabelColor, font: font)
        default:
            out.add(node.name, .secondaryLabelColor, font: font)
        }
        return out
    }

    static func closing(_ node: DOMNode) -> NSAttributedString {
        let name = node.localName.isEmpty ? node.name.lowercased() : node.localName
        return NSMutableAttributedString().add("</\(name)>", InspectorTheme.tag, font: font)
    }

    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                            "param", "source", "track", "wbr"]
}

final class ElementsPanel: InspectorPanelView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let toolbar = InspectorToolbar()
    private let search = InspectorFilterField(placeholder: "Find by text, selector or XPath")
    private let searchCount = Label.make("", size: 11, color: .secondaryLabelColor)
    private let tree = DOMOutlineView()
    private let treeScroll = NSScrollView()
    private let crumbs = BreadcrumbBar()
    private let treePane = FlippedView()
    private let sidebar = ElementSidebar()
    private lazy var split = InspectorSplitView(treePane, sidebar, vertical: false, key: "elements", fraction: 0.5, minimum: 90)
    private var model: ElementsModel?
    private var closingTags: [Int: ClosingTag] = [:]
    private var searchIndex = 0
    private var suppressSelection = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.onChange = { [weak self] text in self?.find(text) }
        search.target = self
        search.action = #selector(searchAction)
        toolbar.add(search, width: nil)
        toolbar.add(searchCount, width: 56)
        let undo = InspectorButton("arrow.uturn.backward", tip: "Undo  ⌘Z") { [weak self] in self?.model?.undo() }
        let redo = InspectorButton("arrow.uturn.forward", tip: "Redo  ⇧⌘Z") { [weak self] in self?.model?.redo() }
        toolbar.add(undo, width: 24)
        toolbar.add(redo, width: 24)
        addSubview(toolbar)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        column.resizingMask = .autoresizingMask
        tree.addTableColumn(column)
        tree.outlineTableColumn = column
        tree.headerView = nil
        tree.style = .plain
        tree.rowHeight = 18
        tree.indentationPerLevel = 12
        tree.backgroundColor = .clear
        tree.focusRingType = .none
        tree.intercellSpacing = .zero
        tree.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tree.autoresizesOutlineColumn = false
        tree.dataSource = self
        tree.delegate = self
        tree.target = self
        tree.doubleAction = #selector(doubleClicked)
        tree.menuForRow = { [weak self] row in self?.menu(row) }
        tree.onKey = { [weak self] event in self?.key(event) ?? false }
        tree.onHover = { [weak self] row in self?.hover(row) }
        treeScroll.documentView = tree
        treeScroll.hasVerticalScroller = true
        treeScroll.hasHorizontalScroller = true
        treeScroll.autohidesScrollers = true
        treeScroll.drawsBackground = false
        treeScroll.borderType = .noBorder
        treePane.addSubview(treeScroll)
        crumbs.onSelect = { [weak self] node in
            self?.model?.select(node)
            self?.revealRow(node)
        }
        treePane.addSubview(crumbs)
        addSubview(split)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        split.frame = NSRect(x: 0, y: toolbar.frame.maxY, width: bounds.width, height: bounds.height - toolbar.frame.maxY)
        split.layoutSubtreeIfNeeded()
        let pane = treePane.bounds
        crumbs.frame = NSRect(x: 0, y: pane.height - BreadcrumbBar.height, width: pane.width, height: BreadcrumbBar.height)
        treeScroll.frame = NSRect(x: 0, y: 0, width: pane.width, height: max(pane.height - BreadcrumbBar.height, 0))
        crumbs.autoresizingMask = [.width, .minYMargin]
        treeScroll.autoresizingMask = [.width, .height]
        sizeTreeColumn()
    }

    private func sizeTreeColumn() {
        guard let column = tree.tableColumns.first else { return }
        let width = max(treeScroll.contentSize.width, column.width)
        if column.width < width { column.width = width }
    }

    override func sessionChanged() {
        for signal in [model?.reset, model?.selectionChanged].compactMap(\.self) { signal.stopObserving(self) }
        model?.nodeChanged.stopObserving(self)
        model?.revealed.stopObserving(self)
        model = isShown ? session?.model(ElementsModel.self) : nil
        observe()
    }

    override func panelDidAppear() {
        if model == nil, let session {
            model = session.model(ElementsModel.self)
            observe()
        }
        reloadTree()
    }

    override func panelDidDisappear() {
        model?.highlight(nil)
    }

    override func focusFilter() { window?.makeFirstResponder(search) }

    private func observe() {
        closingTags = [:]
        sidebar.bind(model, session: session)
        guard let model else {
            tree.reloadData()
            crumbs.show([])
            return
        }
        model.reset.observe(self) { [weak self] in self?.reloadTree() }
        model.nodeChanged.observe(self) { [weak self] node in self?.reload(node) }
        model.selectionChanged.observe(self) { [weak self] in self?.selectionChanged() }
        model.revealed.observe(self) { [weak self] node in self?.revealRow(node) }
        reloadTree()
    }

    private func reloadTree() {
        changedNodes = [:]
        closingTags = [:]
        tree.reloadData()
        guard let document = model?.document else { return }
        for child in document.shownChildren {
            tree.expandItem(child)
            if child.localName == "html" {
                for grandchild in child.shownChildren where grandchild.localName == "body" { expand(grandchild) }
            }
        }
        if let selected = model?.selected { revealRow(selected) }
        selectionChanged()
    }

    private var changedNodes: [ObjectIdentifier: DOMNode] = [:]
    private lazy var reloadChanged = Coalescer(delay: 0.05) { [weak self] in self?.reloadChangedNodes() }

    private func reload(_ node: DOMNode) {
        changedNodes[ObjectIdentifier(node)] = node
        reloadChanged.schedule()
    }

    private func reloadChangedNodes() {
        guard !changedNodes.isEmpty else { return }
        let nodes = changedNodes
        changedNodes = [:]
        let covered = { (node: DOMNode) in
            var ancestor = node.parent
            while let current = ancestor {
                if nodes[ObjectIdentifier(current)] != nil { return true }
                ancestor = current.parent
            }
            return false
        }
        if let document = model?.document, nodes[ObjectIdentifier(document)] != nil {
            reloadRow(document)
        } else {
            for node in nodes.values where !covered(node) { reloadRow(node) }
        }
        if let selected = model?.selected, tree.row(forItem: selected) >= 0, tree.selectedRow != tree.row(forItem: selected) {
            selectRow(of: selected)
        }
        sizeTreeColumn()
    }

    private func reloadRow(_ node: DOMNode) {
        let row = tree.row(forItem: node)
        guard row >= 0 || node === model?.document else { return }
        let expanded = tree.isItemExpanded(node)
        tree.reloadItem(node === model?.document ? nil : node, reloadChildren: true)
        if expanded, row >= 0, !tree.isItemExpanded(node) { tree.expandItem(node) }
    }

    private func selectionChanged() {
        guard let model else { return }
        if let selected = model.selected { selectRow(of: selected) }
        crumbs.show(model.selected.map { model.path(to: $0).filter { $0.type == 1 || $0.type == 11 } } ?? [])
        sidebar.selectionChanged()
    }

    private func selectRow(of node: DOMNode) {
        let row = tree.row(forItem: node)
        guard row >= 0 else { return }
        suppressSelection = true
        tree.selectRowIndexes([row], byExtendingSelection: false)
        suppressSelection = false
    }

    private func revealRow(_ node: DOMNode) {
        guard let model else { return }
        reloadChanged.flush()
        for ancestor in model.path(to: node).dropLast() where ancestor !== model.document { tree.expandItem(ancestor) }
        let row = tree.row(forItem: node)
        guard row >= 0 else { return }
        selectRow(of: node)
        let visible = treeScroll.contentView.bounds
        let rect = tree.rect(ofRow: row)
        if !visible.contains(rect) {
            treeScroll.contentView.scroll(to: NSPoint(x: max(rect.minX - 40 + CGFloat(tree.level(forRow: row)) * 0, 0) * 0,
                                                      y: max(rect.midY - visible.height / 2, 0)))
            treeScroll.reflectScrolledClipView(treeScroll.contentView)
        }
    }

    private func expand(_ node: DOMNode) {
        guard let model else { return }
        if node.children == nil, node.childCount > 0 {
            model.loadChildren(node) { [weak self] in
                self?.tree.reloadItem(node, reloadChildren: true)
                self?.tree.expandItem(node)
            }
        } else {
            tree.expandItem(node)
        }
    }

    private func find(_ query: String) {
        searchIndex = 0
        model?.search(query) { [weak self] count in
            guard let self else { return }
            searchCount.stringValue = query.isEmpty ? "" : count == 0 ? "No match" : "1 of \(count)"
            showSearchResult()
        }
    }

    @objc private func searchAction() {
        guard let results = model?.searchResults, !results.isEmpty else { return }
        searchIndex = (searchIndex + (NSEvent.modifierFlags.contains(.shift) ? -1 : 1) + results.count) % results.count
        searchCount.stringValue = "\(searchIndex + 1) of \(results.count)"
        showSearchResult()
    }

    private func showSearchResult() {
        guard let model, model.searchResults.indices.contains(searchIndex) else { return }
        let id = model.searchResults[searchIndex]
        if let node = model.node(id) {
            model.select(node)
            revealRow(node)
        }
    }

    private func node(atRow row: Int) -> DOMNode? {
        let item = tree.item(atRow: row)
        return item as? DOMNode ?? (item as? ClosingTag)?.node
    }

    private func hover(_ row: Int?) {
        model?.highlight(row.flatMap { node(atRow: $0) })
    }

    @objc private func doubleClicked() {
        let row = tree.clickedRow
        guard row >= 0, let node = node(atRow: row) else { return }
        if node.isText {
            editText(node)
        } else if node.isElement, node.pseudoType == nil {
            editHTML(node)
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        guard let model, let node = model.selected else { return false }
        let command = event.modifierFlags.contains(.command)
        switch event.charactersIgnoringModifiers {
        case "z" where command:
            if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }
            return true
        case "c" where command:
            copyOuterHTML(node)
            return true
        case "h" where !command:
            toggleHidden(node)
            return true
        default:
            break
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            model.edit("DOM.removeNode", ["nodeId": node.id])
            return true
        }
        if event.keyCode == 36, node.isElement {
            editHTML(node)
            return true
        }
        return false
    }

    private func menu(_ row: Int) -> NSMenu? {
        guard let model, let node = node(atRow: row) else { return nil }
        model.select(node)
        let menu = NSMenu()
        if node.isElement, node.pseudoType == nil {
            menu.add("Add Attribute") { [weak self] in self?.editAttribute(node, name: nil) }
            if !node.attributes.isEmpty {
                menu.addSubmenu(titled: "Edit Attribute") { sub in
                    for attribute in node.attributes {
                        sub.add(attribute.name) { [weak self] in self?.editAttribute(node, name: attribute.name) }
                    }
                }
            }
            menu.add("Edit as HTML") { [weak self] in self?.editHTML(node) }
            menu.add("Duplicate Element") {
                guard let parent = node.parent else { return }
                let next = parent.children?.drop { $0 !== node }.dropFirst().first
                var params: JSON = ["nodeId": node.id, "targetNodeId": parent.id]
                if let next { params["insertBeforeNodeId"] = next.id }
                model.edit("DOM.copyTo", params)
            }
            menu.add("Delete Element") { model.edit("DOM.removeNode", ["nodeId": node.id]) }
            menu.addItem(.separator())
            menu.addSubmenu(titled: "Copy") { sub in
                sub.add("Copy Element") { [weak self] in self?.copyOuterHTML(node) }
                sub.add("Copy Selector") { [weak self] in self?.copySelector(node, kind: "selector") }
                sub.add("Copy JS Path") { [weak self] in self?.copySelector(node, kind: "js") }
                sub.add("Copy XPath") { [weak self] in self?.copySelector(node, kind: "xpath") }
                sub.add("Copy Styles") {
                    Task {
                        let text = await model.callOn(node, """
                        function(){ const s = getComputedStyle(this); let out = ''; for (const p of s) out += p + ': ' + s.getPropertyValue(p) + ';\\n'; return out }
                        """) as? String
                        if let text { Format.copy(text) }
                    }
                }
            }
            menu.addSubmenu(titled: "Force State") { [weak self] sub in
                for state in ["hover", "active", "focus", "focus-within", "focus-visible", "visited", "target"] {
                    let on = self?.sidebar.forcedStates[node.id]?.contains(state) ?? false
                    sub.add(":\(state)", state: on) { self?.sidebar.toggleForcedState(state, on: node) }
                }
            }
            menu.add(sidebar.hiddenNodes.contains(node.id) ? "Show Element" : "Hide Element") { [weak self] in self?.toggleHidden(node) }
            menu.addSubmenu(titled: "Break On") { sub in
                for (title, type) in [("Subtree Modifications", "subtree-modified"), ("Attribute Modifications", "attribute-modified"),
                                      ("Node Removal", "node-removed")] {
                    sub.add(title) { [weak self] in
                        self?.session?.call("Debugger.enable")
                        self?.session?.call("DOMDebugger.setDOMBreakpoint", ["nodeId": node.id, "type": type])
                    }
                }
                sub.addItem(.separator())
                sub.add("Remove All") { [weak self] in
                    for type in ["subtree-modified", "attribute-modified", "node-removed"] {
                        self?.session?.call("DOMDebugger.removeDOMBreakpoint", ["nodeId": node.id, "type": type])
                    }
                }
            }
            menu.addItem(.separator())
            menu.add("Scroll into View") { [weak self] in self?.session?.call("DOM.scrollIntoViewIfNeeded", ["nodeId": node.id]) }
            menu.add("Focus") { Task { _ = await model.callOn(node, "function(){ this.focus() }") } }
            menu.add("Store as Global Variable") { [weak self] in self?.storeGlobal(node) }
            if node.localName == "a" || node.localName == "img" || node.localName == "script" || node.localName == "link",
               let link = node.attribute("href") ?? node.attribute("src") {
                menu.add("Copy Link Address") { Format.copy(link) }
            }
        } else if node.isText {
            menu.add("Edit Text") { [weak self] in self?.editText(node) }
            menu.add("Delete") { model.edit("DOM.removeNode", ["nodeId": node.id]) }
        } else if node.type == 8 {
            menu.add("Delete Comment") { model.edit("DOM.removeNode", ["nodeId": node.id]) }
        }
        if node.hasChildren {
            menu.addItem(.separator())
            menu.add("Expand Recursively") { [weak self] in self?.expandRecursively(node) }
            menu.add("Collapse Children") { [weak self] in
                guard let self else { return }
                for child in node.shownChildren { tree.collapseItem(child, collapseChildren: true) }
            }
        }
        return menu
    }

    private func expandRecursively(_ node: DOMNode) {
        session?.call("DOM.requestChildNodes", ["nodeId": node.id, "depth": -1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.tree.expandItem(node, expandChildren: true)
        }
    }

    private func toggleHidden(_ node: DOMNode) {
        sidebar.toggleHidden(node)
    }

    private func copyOuterHTML(_ node: DOMNode) {
        session?.call("DOM.getOuterHTML", ["nodeId": node.id]) { result, _ in
            if let html = result?.str("outerHTML") { Format.copy(html) }
        }
    }

    private func copySelector(_ node: DOMNode, kind: String) {
        guard let model else { return }
        let function = """
        function(kind){
          const el = this;
          if (kind === 'xpath') {
            const parts = [];
            for (let n = el; n && n.nodeType === 1; n = n.parentNode) {
              if (n.id) { parts.unshift('//*[@id="' + n.id + '"]'); return parts.join('/') }
              let i = 1; for (let s = n.previousElementSibling; s; s = s.previousElementSibling) if (s.localName === n.localName) i++;
              parts.unshift(n.localName + '[' + i + ']');
            }
            return '/' + parts.join('/');
          }
          const parts = [];
          for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
            if (n.id && /^[A-Za-z][\\w-]*$/.test(n.id)) { parts.unshift('#' + n.id); break }
            let part = n.localName;
            const parent = n.parentElement;
            if (parent) {
              const same = [...parent.children].filter(c => c.localName === n.localName);
              if (same.length > 1) part += ':nth-child(' + ([...parent.children].indexOf(n) + 1) + ')';
            }
            parts.unshift(part);
          }
          const selector = parts.join(' > ');
          return kind === 'js' ? 'document.querySelector(' + JSON.stringify(selector) + ')' : selector;
        }
        """
        Task {
            guard let object = await model.resolve(node), let id = object.str("objectId"), let session else { return }
            let result = try? await session.send("Runtime.callFunctionOn", [
                "objectId": id, "functionDeclaration": function, "arguments": [["value": kind]], "returnByValue": true,
            ])
            if let text = result?.obj("result")?.str("value") { Format.copy(text) }
        }
    }

    private func storeGlobal(_ node: DOMNode) {
        guard let model, let session else { return }
        Task {
            guard let object = await model.resolve(node), let id = object.str("objectId") else { return }
            let result = try? await session.send("Runtime.callFunctionOn", [
                "objectId": id, "returnByValue": true,
                "functionDeclaration": "function(){ let i = 1; while (('temp' + i) in globalThis) i++; globalThis['temp' + i] = this; return 'temp' + i }",
            ])
            if let name = result?.obj("result")?.str("value") {
                session.model(ConsoleModel.self).evaluate(name)
                session.showPanel?(.console)
            }
        }
    }

    private func editHTML(_ node: DOMNode) {
        guard let model, let row = rowView(for: node) else { return }
        session?.call("DOM.getOuterHTML", ["nodeId": node.id]) { [weak self] result, _ in
            guard let self, let html = result?.str("outerHTML") else { return }
            TextEditPopover.show(title: "Edit as HTML", text: html, language: .html, relativeTo: row, of: tree) { text in
                model.edit("DOM.setOuterHTML", ["nodeId": node.id, "outerHTML": text])
            }
        }
    }

    private func editText(_ node: DOMNode) {
        guard let model, let row = rowView(for: node) else { return }
        TextEditPopover.show(title: "Edit Text", text: node.value, language: .plain, relativeTo: row, of: tree) { text in
            model.edit("DOM.setNodeValue", ["nodeId": node.id, "value": text])
        }
    }

    private func editAttribute(_ node: DOMNode, name: String?) {
        guard let model, let row = rowView(for: node) else { return }
        let current = name.flatMap { n in node.attribute(n).map { "\(n)=\"\($0)\"" } } ?? ""
        TextEditPopover.show(title: name == nil ? "Add Attribute" : "Edit Attribute", text: current, language: .html,
                             relativeTo: row, of: tree, singleLine: true) { text in
            var params: JSON = ["nodeId": node.id, "text": text]
            if let name { params["name"] = name }
            if text.trimmingCharacters(in: .whitespaces).isEmpty, let name {
                model.edit("DOM.removeAttribute", ["nodeId": node.id, "name": name])
            } else {
                model.edit("DOM.setAttributesAsText", params)
            }
        }
    }

    private func rowView(for node: DOMNode) -> NSRect? {
        let row = tree.row(forItem: node)
        return row >= 0 ? tree.rect(ofRow: row) : nil
    }

    private func items(of item: Any?) -> [AnyObject] {
        guard let node = item as? DOMNode ?? model?.document else { return [] }
        if item == nil { return node.shownChildren }
        var children: [AnyObject] = node.shownChildren
        if node.isElement, node.pseudoType == nil, !children.isEmpty {
            let closing = closingTags[node.id] ?? ClosingTag(node)
            closingTags[node.id] = closing
            children.append(closing)
        }
        return children
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        items(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DOMNode)?.hasChildren ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? DOMNode, let model else { return false }
        if node.children == nil, node.childCount > 0 {
            model.loadChildren(node) { [weak self] in
                self?.tree.reloadItem(node, reloadChildren: true)
                self?.tree.expandItem(node)
            }
            return false
        }
        return true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? DOMNode { tree.reloadItem(node, reloadChildren: false) }
        sizeTreeColumn()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? DOMNode { tree.reloadItem(node, reloadChildren: false) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let closing = item as? ClosingTag {
            return InspectorTable.cell(outlineView, "dom", DOMText.closing(closing.node))
        }
        guard let node = item as? DOMNode else { return nil }
        let text = DOMText.row(node, expanded: outlineView.isItemExpanded(node))
        let cell = InspectorTable.cell(outlineView, "dom", text)
        cell.alphaValue = sidebarHidden(node) ? 0.5 : 1
        return cell
    }

    private func sidebarHidden(_ node: DOMNode) -> Bool { sidebar.hiddenNodes.contains(node.id) }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { InspectorRowView() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let model else { return }
        let row = tree.selectedRow
        guard row >= 0, let node = node(atRow: row) else { return }
        if tree.item(atRow: row) is ClosingTag {
            selectRow(of: node)
        }
        model.select(node)
    }
}

final class DOMOutlineView: InspectorOutlineView {
    var onHover: ((Int?) -> Void)?
    private var area: NSTrackingArea?
    private var hovered: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let value = row >= 0 ? row : nil
        guard value != hovered else { return }
        setRowHovered(hovered, false)
        hovered = value
        setRowHovered(value, true)
        onHover?(value)
    }

    override func mouseExited(with event: NSEvent) {
        setRowHovered(hovered, false)
        hovered = nil
        onHover?(nil)
    }

    private func setRowHovered(_ row: Int?, _ on: Bool) {
        guard let row, row < numberOfRows else { return }
        (rowView(atRow: row, makeIfNecessary: false) as? InspectorRowView)?.hovered = on
    }
}

final class BreadcrumbBar: FlippedView {
    static let height: CGFloat = 22
    var onSelect: ((DOMNode) -> Void)?
    private let scroll = NSScrollView()
    private let strip = FlippedView()
    private let line = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(line)
        scroll.documentView = strip
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = InspectorTheme.bar.cgColor
        line.backgroundColor = InspectorTheme.separator.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
        scroll.frame = NSRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 1)
        strip.frame.size.height = bounds.height - 1
        strip.scroll(NSPoint(x: max(strip.frame.width - scroll.contentSize.width, 0), y: 0))
    }

    func show(_ path: [DOMNode]) {
        strip.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 6
        for (i, node) in path.enumerated() {
            let button = NSButton(title: node.shortName, target: nil, action: nil)
            button.isBordered = false
            button.font = InspectorTheme.mono(10.5, i == path.count - 1 ? .semibold : .regular)
            button.contentTintColor = i == path.count - 1 ? .labelColor : .secondaryLabelColor
            button.attributedTitle = NSAttributedString(string: node.shortName.clipped(40), attributes: [
                .font: InspectorTheme.mono(10.5, i == path.count - 1 ? .semibold : .regular),
                .foregroundColor: i == path.count - 1 ? NSColor.labelColor : InspectorTheme.tag,
            ])
            button.onAction { [weak self] in self?.onSelect?(node) }
            button.sizeToFit()
            button.frame = NSRect(x: x, y: 2, width: button.frame.width + 4, height: 17)
            strip.addSubview(button)
            x += button.frame.width + 2
            if i < path.count - 1 {
                let separator = NSTextField(labelWithString: "›")
                separator.font = Theme.font(10)
                separator.textColor = .tertiaryLabelColor
                separator.frame = NSRect(x: x, y: 3, width: 8, height: 14)
                strip.addSubview(separator)
                x += 10
            }
        }
        strip.frame = NSRect(x: 0, y: 0, width: x + 6, height: bounds.height - 1)
        needsLayout = true
    }
}

final class ElementSidebar: FlippedView {
    private let tabs = InspectorChips(["Styles", "Computed", "Listeners", "Properties", "Accessibility"])
    private let bar = InspectorToolbar()
    private let styles = StylesView()
    private let computed = ComputedView()
    private let values = ValueTreeView()
    private weak var model: ElementsModel?
    private weak var session: InspectorSession?
    private var tab = UserDefaults.standard.integer(forKey: "inspector.elements.tab")
    private lazy var refresh = Coalescer(delay: 0.1) { [weak self] in self?.reload() }
    private(set) var forcedStates: [Int: Set<String>] = [:]
    private(set) var hiddenNodes: Set<Int> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        tabs.selected = [tab]
        tabs.onChange = { [weak self] selected in
            guard let self else { return }
            tab = selected.first ?? 0
            UserDefaults.standard.set(tab, forKey: "inspector.elements.tab")
            reload()
        }
        bar.add(tabs, width: tabs.preferredWidth)
        addSubview(bar)
        addSubview(styles)
        addSubview(computed)
        addSubview(values)
        styles.sidebar = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        let content = NSRect(x: 0, y: bar.frame.maxY, width: bounds.width, height: max(bounds.height - bar.frame.maxY, 0))
        for view in [styles, computed, values] as [NSView] { view.frame = content }
    }

    func bind(_ model: ElementsModel?, session: InspectorSession?) {
        self.model?.stylesChanged.stopObserving(self)
        self.model = model
        self.session = session
        styles.model = model
        styles.session = session
        computed.model = model
        computed.session = session
        forcedStates = [:]
        hiddenNodes = []
        model?.stylesChanged.observe(self) { [weak self] in self?.refresh.schedule() }
        reload()
    }

    func selectionChanged() { refresh.flush() }

    private func reload() {
        styles.isHidden = tab != 0
        computed.isHidden = tab != 1
        values.isHidden = tab < 2
        let node = model?.selected
        switch tab {
        case 0: styles.show(node)
        case 1: computed.show(node)
        case 2: showListeners(node)
        case 3: showProperties(node)
        default: showAccessibility(node)
        }
    }

    private func showListeners(_ node: DOMNode?) {
        values.show([])
        guard let node, let model, let session, node.isElement else { return }
        Task {
            guard let object = await model.resolve(node), let id = object.str("objectId") else { return }
            let result = try? await session.send("DOMDebugger.getEventListeners", ["objectId": id, "depth": 1])
            let listeners = result?.list("listeners") ?? []
            let types = Dictionary(grouping: listeners) { $0.str("type") ?? "" }
            let groups = types.keys.sorted().map { type -> ValueNode in
                GroupNode(name: type, children: types[type]!.map { listener in
                    var flags: [String] = []
                    if listener.bool("useCapture") { flags.append("capture") }
                    if listener.bool("passive") { flags.append("passive") }
                    if listener.bool("once") { flags.append("once") }
                    let handler = listener.obj("handler") ?? ["type": "function", "description": "handler"]
                    let label = "line \((listener.int("lineNumber") ?? 0) + 1)" + (flags.isEmpty ? "" : " · " + flags.joined(separator: ", "))
                    return RemoteValueNode(name: label, object: handler, session: session)
                })
            }
            guard model.selected === node else { return }
            values.show(groups.isEmpty ? [GroupNode(name: "", value: NSMutableAttributedString().add("No event listeners", .tertiaryLabelColor))] : groups)
            values.expandRoots()
        }
    }

    private func showProperties(_ node: DOMNode?) {
        values.show([])
        guard let node, let model, let session else { return }
        Task {
            guard let object = await model.resolve(node), model.selected === node else { return }
            let root = RemoteValueNode(name: node.shortName, object: object, session: session)
            values.show([root])
            values.expand(root)
        }
    }

    private func showAccessibility(_ node: DOMNode?) {
        values.show([])
        guard let node, let session else { return }
        Task {
            let result = try? await session.send("Accessibility.getPartialAXTree", ["nodeId": node.id, "fetchRelatives": true])
            guard model?.selected === node else { return }
            let nodes = result?.list("nodes") ?? []
            guard let mine = nodes.first(where: { $0.int("backendDOMNodeId") == node.backendID }) ?? nodes.first else {
                values.show([GroupNode(name: "", value: NSMutableAttributedString().add("Not in the accessibility tree", .tertiaryLabelColor))])
                return
            }
            func text(_ value: JSON?) -> NSAttributedString {
                let raw = value?["value"].map { "\($0)" } ?? ""
                return NSMutableAttributedString().add(raw.isEmpty ? "—" : raw, raw.isEmpty ? .tertiaryLabelColor : .labelColor)
            }
            var rows: [ValueNode] = [
                GroupNode(name: "Role", value: text(mine.obj("role"))),
                GroupNode(name: "Name", value: text(mine.obj("name"))),
            ]
            if let description = mine.obj("description") { rows.append(GroupNode(name: "Description", value: text(description))) }
            if mine.bool("ignored") {
                let reasons = mine.list("ignoredReasons").compactMap { $0.str("name") }.joined(separator: ", ")
                rows.append(GroupNode(name: "Ignored", value: NSMutableAttributedString().add(reasons.isEmpty ? "yes" : reasons, InspectorTheme.warning)))
            }
            let properties = mine.list("properties").map { GroupNode(name: $0.str("name") ?? "", value: text($0.obj("value"))) }
            if !properties.isEmpty { rows.append(GroupNode(name: "Properties", children: properties)) }
            var chain: [String] = []
            var parentID = mine.str("parentId")
            while let id = parentID, let parent = nodes.first(where: { $0.str("nodeId") == id }) {
                let role = parent.obj("role")?["value"].map { "\($0)" } ?? ""
                let name = parent.obj("name")?["value"].map { "\($0)" } ?? ""
                if !parent.bool("ignored") { chain.insert(name.isEmpty ? role : "\(role) \"\(name.clipped(30))\"", at: 0) }
                parentID = parent.str("parentId")
            }
            if !chain.isEmpty { rows.append(GroupNode(name: "Ancestors", value: NSMutableAttributedString().add(chain.joined(separator: " › "), .secondaryLabelColor))) }
            values.show(rows)
            values.expandRoots()
        }
    }

    func toggleForcedState(_ state: String, on node: DOMNode) {
        var states = forcedStates[node.id] ?? []
        if states.contains(state) { states.remove(state) } else { states.insert(state) }
        forcedStates[node.id] = states
        session?.call("CSS.forcePseudoState", ["nodeId": node.id, "forcedPseudoClasses": Array(states)])
        styles.forcedChanged()
        refresh.schedule()
    }

    func toggleHidden(_ node: DOMNode) {
        guard let model else { return }
        let hide = !hiddenNodes.contains(node.id)
        if hide { hiddenNodes.insert(node.id) } else { hiddenNodes.remove(node.id) }
        Task {
            _ = await model.callOn(node, "function(hide){ this.style.setProperty('visibility', hide ? 'hidden' : '', hide ? 'important' : '') }"
                .replacingOccurrences(of: "function(hide){", with: "function(){ const hide = \(hide);"))
        }
    }
}

final class StylesView: FlippedView {
    weak var model: ElementsModel?
    weak var session: InspectorSession?
    weak var sidebar: ElementSidebar?
    private let toolbar = InspectorToolbar()
    private let filter = InspectorFilterField(placeholder: "Filter styles")
    private let hov = InspectorButton("hand.point.up.left", tip: "Force element state (:hover, :focus…)")
    private let newRule = InspectorButton("plus", tip: "New style rule")
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let empty = InspectorEmptyView("Select an element to see its styles.")
    private var node: DOMNode?
    private var blocks: [RuleBlock] = []
    private var filterText = ""
    private var loading = 0
    private var shownResult: NSDictionary?

    override init(frame: NSRect) {
        super.init(frame: frame)
        filter.onChange = { [weak self] text in
            self?.filterText = text
            self?.layoutBlocks()
        }
        hov.action = { [weak self] in self?.showStates() }
        newRule.action = { [weak self] in self?.addRule() }
        toolbar.add(filter, width: nil)
        toolbar.add(hov, width: 24)
        toolbar.add(newRule, width: 24)
        addSubview(toolbar)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        addSubview(empty)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        scroll.frame = NSRect(x: 0, y: toolbar.frame.maxY, width: bounds.width, height: max(bounds.height - toolbar.frame.maxY, 0))
        empty.frame = scroll.frame
        layoutBlocks()
    }

    override func viewDidHide() {
        super.viewDidHide()
        shownResult = nil
    }

    func forcedChanged() {
        guard let node else { return }
        hov.isOn = !(sidebar?.forcedStates[node.id]?.isEmpty ?? true)
    }

    func show(_ node: DOMNode?) {
        let same = node === self.node
        self.node = node
        forcedChanged()
        guard let node, let session, node.isElement || node.pseudoType != nil else {
            setBlocks([])
            empty.isHidden = false
            empty.text = node == nil ? "Select an element to see its styles." : "Text and comments have no styles."
            return
        }
        empty.isHidden = true
        loading += 1
        let ticket = loading
        session.call("CSS.getMatchedStylesForNode", ["nodeId": node.id]) { [weak self] result, error in
            guard let self, ticket == loading, self.node === node else { return }
            guard let result else {
                setBlocks([])
                empty.isHidden = false
                empty.text = error ?? "No styles."
                return
            }
            let raw = result as NSDictionary
            if same, shownResult == raw { return }
            shownResult = raw
            let offset = same ? scroll.contentView.bounds.origin : .zero
            setBlocks(makeBlocks(result, node: node))
            scroll.contentView.scroll(to: offset)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func makeBlocks(_ result: JSON, node: DOMNode) -> [RuleBlock] {
        var rules: [StyleRule] = []
        if let inline = result.obj("inlineStyle") {
            rules.append(StyleRule(selector: "element.style", style: inline, origin: "inline", media: [], source: nil))
        }
        for match in result.list("matchedCSSRules").reversed() {
            guard let rule = match.obj("rule") else { continue }
            rules.append(StyleRule(rule: rule, sheets: model?.styleSheets ?? [:], matching: match["matchingSelectors"] as? [Int]))
        }
        if let attributes = result.obj("attributesStyle"), !attributes.list("cssProperties").isEmpty {
            rules.append(StyleRule(selector: "\(node.localName)[Attributes Style]", style: attributes, origin: "attributes", media: [], source: nil))
        }
        for pseudo in result.list("pseudoElements") {
            let type = pseudo.str("pseudoType") ?? ""
            for match in pseudo.list("matches").reversed() {
                guard let rule = match.obj("rule") else { continue }
                var styleRule = StyleRule(rule: rule, sheets: model?.styleSheets ?? [:], matching: match["matchingSelectors"] as? [Int])
                styleRule.heading = "Pseudo ::\(type) element"
                rules.append(styleRule)
            }
        }
        var ancestor = node.parent
        for entry in result.list("inherited") {
            while let current = ancestor, !current.isElement { ancestor = current.parent }
            let name = ancestor?.shortName ?? "ancestor"
            var first = true
            if let inline = entry.obj("inlineStyle"), inline.list("cssProperties").contains(where: { Self.inherits($0.str("name") ?? "") }) {
                var rule = StyleRule(selector: "style attribute", style: inline, origin: "inline", media: [], source: nil)
                rule.heading = "Inherited from \(name)"
                rule.inherited = true
                first = false
                rules.append(rule)
            }
            for match in entry.list("matchedCSSRules").reversed() {
                guard let raw = match.obj("rule") else { continue }
                var rule = StyleRule(rule: raw, sheets: model?.styleSheets ?? [:], matching: match["matchingSelectors"] as? [Int])
                rule.inherited = true
                guard rule.declarations.contains(where: { Self.inherits($0.name) }) else { continue }
                if first { rule.heading = "Inherited from \(name)"; first = false }
                rules.append(rule)
            }
            ancestor = ancestor?.parent
        }
        var winners: [String: (important: Bool, rule: Int)] = [:]
        for (r, rule) in rules.enumerated() {
            for (d, declaration) in rule.declarations.enumerated() where declaration.enabled && declaration.parsedOK {
                if rule.inherited, !Self.inherits(declaration.name) {
                    rules[r].declarations[d].inactive = true
                    continue
                }
                let key = declaration.name
                if let winner = winners[key] {
                    if declaration.important, !winner.important, winner.rule != r || true {
                        for (wr, wrule) in rules.enumerated() where wr <= r {
                            for (wd, wdecl) in wrule.declarations.enumerated() where wdecl.name == key && !wdecl.important && !(wr == r && wd == d) {
                                rules[wr].declarations[wd].overridden = true
                            }
                        }
                        winners[key] = (true, r)
                    } else {
                        rules[r].declarations[d].overridden = true
                    }
                } else {
                    winners[key] = (declaration.important, r)
                }
            }
        }
        return rules.map { RuleBlock(rule: $0, styles: self) }
    }

    static func inherits(_ name: String) -> Bool {
        if name.hasPrefix("--") { return true }
        let inherited: Set = ["color", "cursor", "direction", "font", "font-family", "font-size", "font-style", "font-variant",
                              "font-weight", "font-stretch", "font-feature-settings", "letter-spacing", "line-height",
                              "list-style", "list-style-type", "list-style-position", "list-style-image", "quotes",
                              "text-align", "text-indent", "text-transform", "text-shadow", "visibility", "white-space",
                              "word-break", "word-spacing", "word-wrap", "overflow-wrap", "caret-color", "tab-size",
                              "-webkit-font-smoothing", "text-rendering", "hyphens", "orientation", "writing-mode",
                              "border-collapse", "border-spacing", "caption-side", "empty-cells", "speak", "accent-color",
                              "color-scheme", "pointer-events", "user-select", "-webkit-text-fill-color"]
        return inherited.contains(name)
    }

    func blockResized() { layoutBlocks() }

    private func setBlocks(_ new: [RuleBlock]) {
        if new.isEmpty { shownResult = nil }
        blocks.forEach { $0.removeFromSuperview() }
        blocks = new
        blocks.forEach { document.addSubview($0) }
        layoutBlocks()
    }

    private func layoutBlocks() {
        let width = scroll.contentSize.width
        var y: CGFloat = 0
        for block in blocks {
            block.filter = filterText
            let height = block.layoutRows(width: width)
            block.isHidden = height == 0
            block.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 20, scroll.contentSize.height))
    }

    private func showStates() {
        guard let node, let sidebar else { return }
        let menu = NSMenu()
        for state in ["hover", "active", "focus", "focus-within", "focus-visible", "visited", "target"] {
            let on = sidebar.forcedStates[node.id]?.contains(state) ?? false
            menu.add(":\(state)", state: on) { [weak sidebar] in sidebar?.toggleForcedState(state, on: node) }
        }
        hov.popUp(menu)
    }

    private func addRule() {
        guard let node, let session, node.isElement else { return }
        let selector = node.attribute("id").flatMap { $0.isEmpty ? nil : "#\($0)" }
            ?? node.attribute("class")?.split(separator: " ").first.map { ".\($0)" } ?? node.localName
        Task {
            let frame = node.frameID ?? session.mainFrameID
            guard let sheet = try? await session.send("CSS.createStyleSheet", ["frameId": frame]).str("styleSheetId") else { return }
            let text = (try? await session.send("CSS.getStyleSheetText", ["styleSheetId": sheet]).str("text")) ?? ""
            let lines = text.components(separatedBy: "\n")
            let location: JSON = ["startLine": lines.count - 1, "startColumn": lines.last?.utf16.count ?? 0,
                                  "endLine": lines.count - 1, "endColumn": lines.last?.utf16.count ?? 0]
            _ = try? await session.send("CSS.addRule", ["styleSheetId": sheet, "ruleText": "\(selector) {}", "location": location])
            show(node)
        }
    }

    func setStyleText(_ rule: StyleRule, _ text: String) {
        guard let session, let node else { return }
        if let sheet = rule.styleSheetID, let range = rule.range {
            session.call("CSS.setStyleTexts", ["edits": [["styleSheetId": sheet, "range": range, "text": text]]]) { [weak self] _, error in
                if let error { NSLog("styles: %@", error) }
                self?.show(node)
            }
        } else if rule.origin == "inline" {
            model?.edit("DOM.setAttributeValue", ["nodeId": node.id, "name": "style", "value": text]) { [weak self] _, _ in self?.show(node) }
        }
    }

    func reveal(_ rule: StyleRule) {
        guard let source = rule.source, let range = rule.range else { return }
        session?.revealSource(url: source, line: range.int("startLine") ?? 0, column: range.int("startColumn") ?? 0)
    }

    func setSelector(_ rule: StyleRule, _ text: String) {
        guard let session, let sheet = rule.styleSheetID, let range = rule.selectorRange, let node else { return }
        session.call("CSS.setRuleSelector", ["styleSheetId": sheet, "range": range, "selector": text]) { [weak self] _, _ in self?.show(node) }
    }
}

struct StyleDeclaration {
    var name: String
    var value: String
    var important: Bool
    var enabled: Bool
    var parsedOK: Bool
    var text: String?
    var overridden = false
    var inactive = false
}

struct StyleRule {
    var selector: String
    var heading: String?
    var origin: String
    var media: [String]
    var source: String?
    var styleSheetID: String?
    var range: JSON?
    var selectorRange: JSON?
    var declarations: [StyleDeclaration] = []
    var inherited = false
    var matching: [Int]?
    var selectors: [String] = []

    init(selector: String, style: JSON, origin: String, media: [String], source: String?) {
        self.selector = selector
        self.origin = origin
        self.media = media
        self.source = source
        styleSheetID = style.str("styleSheetId")
        range = style.obj("range")
        declarations = Self.declarations(style)
    }

    init(rule: JSON, sheets: [String: JSON], matching: [Int]?) {
        let list = rule.obj("selectorList")
        selector = list?.str("text") ?? ""
        selectors = list?.list("selectors").compactMap { $0.str("text") } ?? []
        selectorRange = list?.list("selectors").first?.obj("range").flatMap { first in
            list?.list("selectors").last?.obj("range").map { last in
                ["startLine": first["startLine"]!, "startColumn": first["startColumn"]!, "endLine": last["endLine"]!, "endColumn": last["endColumn"]!]
            }
        }
        self.matching = matching
        origin = rule.str("origin") ?? "regular"
        media = rule.list("media").compactMap { $0.str("text") }.map { "@media \($0)" }
            + rule.list("containerQueries").compactMap { $0.str("text") }.map { "@container \($0)" }
            + rule.list("supports").compactMap { $0.str("text") }.map { "@supports \($0)" }
            + rule.list("layers").compactMap { $0.str("text") }.filter { !$0.isEmpty }.map { "@layer \($0)" }
        let style = rule.obj("style") ?? [:]
        styleSheetID = style.str("styleSheetId") ?? rule.str("styleSheetId")
        range = style.obj("range")
        if let id = rule.str("styleSheetId"), let header = sheets[id] {
            let url = header.str("sourceURL") ?? ""
            source = url.isEmpty ? nil : url
        }
        declarations = Self.declarations(style)
    }

    private static func declarations(_ style: JSON) -> [StyleDeclaration] {
        let properties = style.list("cssProperties")
        let authored = properties.contains { $0.str("text") != nil }
        return properties.compactMap { property in
            if authored, property.str("text") == nil { return nil }
            guard let name = property.str("name") else { return nil }
            var value = property.str("value") ?? ""
            let important = property.bool("important")
            if important { value = value.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces) }
            return StyleDeclaration(name: name, value: value, important: important,
                                    enabled: !property.bool("disabled"), parsedOK: property["parsedOk"] as? Bool ?? true,
                                    text: property.str("text"))
        }
    }

    var editable: Bool { (origin == "regular" || origin == "inline" || origin == "inspector") && (styleSheetID != nil || origin == "inline") }

    func text(with declarations: [StyleDeclaration]) -> String {
        let lines = declarations.map { d -> String in
            let line = "\(d.name): \(d.value)\(d.important ? " !important" : "");"
            return d.enabled ? line : ""
        }
        return origin == "inline" && styleSheetID == nil ? lines.joined(separator: " ") : "\n    " + lines.joined(separator: "\n    ") + "\n"
    }
}

final class RuleBlock: FlippedView, NSViewToolTipOwner {
    private(set) var rule: StyleRule
    private weak var styles: StylesView?
    var filter = ""
    private var lines: [(line: Line, y: CGFloat, height: CGFloat)] = []
    private var adding = false
    private let font = InspectorTheme.mono(11)
    private lazy var drawn: [(name: NSAttributedString, nameWidth: CGFloat, value: NSAttributedString, color: NSColor?)] =
        rule.declarations.map { declaration in
            let name = nameText(declaration)
            return (name, ceil(name.size().width) + 2, valueText(declaration), CSSColor.parse(declaration.value))
        }
    private lazy var source: NSAttributedString? = makeSourceText()
    private lazy var sourceWidth: CGFloat = source.map { ceil($0.size().width) + 2 } ?? 0

    private enum Line {
        case heading(String), media(String), selector, declaration(Int), adding, close
    }

    init(rule: StyleRule, styles: StylesView) {
        self.rule = rule
        self.styles = styles
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func layoutRows(width: CGFloat) -> CGFloat {
        lines = []
        let matches = filter.isEmpty || rule.selector.localizedCaseInsensitiveContains(filter)
            || rule.declarations.contains(where: matchesFilter)
        guard matches else { return 0 }
        var y: CGFloat = 0
        func add(_ line: Line, _ height: CGFloat) {
            lines.append((line, y, height))
            y += height
        }
        if let heading = rule.heading { add(.heading(heading), 24) }
        for media in rule.media { add(.media(media), 17) }
        add(.selector, 20)
        let all = filter.isEmpty || rule.selector.localizedCaseInsensitiveContains(filter)
        for (index, declaration) in rule.declarations.enumerated() where all || matchesFilter(declaration) {
            add(.declaration(index), 18)
        }
        if adding { add(.adding, 18) }
        add(.close, 22)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        return y
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        for entry in lines {
            switch entry.line {
            case .selector where source != nil: addToolTip(sourceRect(entry.y), owner: self, userData: nil)
            case .declaration(let index) where tip(for: rule.declarations[index]) != nil:
                addToolTip(NSRect(x: 0, y: entry.y, width: bounds.width, height: entry.height), owner: self, userData: nil)
            default: break
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for entry in lines where entry.y < dirtyRect.maxY && entry.y + entry.height > dirtyRect.minY {
            let y = entry.y
            switch entry.line {
            case .heading(let heading):
                draw(NSAttributedString(string: heading, attributes: [.font: Theme.font(11, .medium), .foregroundColor: NSColor.secondaryLabelColor]),
                     in: NSRect(x: 8, y: y + 6, width: bounds.width - 16, height: 16))
            case .media(let media):
                draw(NSMutableAttributedString().add(media, .secondaryLabelColor, font: InspectorTheme.mono(10.5)),
                     in: NSRect(x: 8, y: y + 4, width: bounds.width - 16, height: 15))
            case .selector:
                draw(selectorText(), in: selectorRect(y))
                source?.draw(with: sourceRect(y), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            case .declaration(let index):
                drawDeclaration(index, at: y)
            case .adding:
                drawCheckbox(on: true, enabled: true, at: y)
            case .close:
                draw(NSMutableAttributedString().add("}", .labelColor, font: font), in: NSRect(x: 8, y: y, width: 20, height: 16))
            }
        }
        InspectorTheme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func drawCheckbox(on: Bool, enabled: Bool, at y: CGFloat) {
        let box = NSRect(x: 11, y: y + 3, width: 12, height: 12)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if on {
            (enabled ? NSColor.controlAccentColor : Theme.faint(0.16)).setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 3, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 5.2, y: box.maxY - 3.2))
            check.line(to: NSPoint(x: box.maxX - 2.8, y: box.minY + 3.2))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            (enabled ? NSColor.white : NSColor.secondaryLabelColor).setStroke()
            check.stroke()
        } else {
            Theme.faint(enabled ? 0.4 : 0.2).setStroke()
            let inner = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            inner.lineWidth = 1
            inner.stroke()
        }
    }

    private func drawDeclaration(_ index: Int, at y: CGFloat) {
        let declaration = rule.declarations[index]
        drawCheckbox(on: declaration.enabled, enabled: rule.editable, at: y)
        let (name, value, swatch) = parts(index, y: y)
        draw(drawn[index].name, in: name)
        if let swatch, let color = drawn[index].color {
            let path = NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2)
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        draw(drawn[index].value, in: value)
    }

    private func draw(_ text: NSAttributedString, in rect: NSRect) {
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func nameText(_ declaration: StyleDeclaration) -> NSAttributedString {
        let dim = declaration.overridden || !declaration.enabled || declaration.inactive
        let color = !declaration.parsedOK ? InspectorTheme.warning
            : dim ? InspectorTheme.property.withAlphaComponent(0.5) : InspectorTheme.property
        let text = NSMutableAttributedString(string: declaration.name, attributes: struck(declaration, color))
        text.add(":", .secondaryLabelColor, font: font)
        return text
    }

    private func valueText(_ declaration: StyleDeclaration) -> NSAttributedString {
        let dim = declaration.overridden || !declaration.enabled || declaration.inactive
        let text = NSMutableAttributedString(string: declaration.value + (declaration.important ? " !important" : ""),
                                             attributes: struck(declaration, dim ? .tertiaryLabelColor : .labelColor))
        text.add(";", .secondaryLabelColor, font: font)
        return text
    }

    private func struck(_ declaration: StyleDeclaration, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if declaration.overridden || !declaration.enabled { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    private func parts(_ index: Int, y: CGFloat) -> (name: NSRect, value: NSRect, swatch: NSRect?) {
        let name = NSRect(x: 26, y: y + 1, width: min(drawn[index].nameWidth, bounds.width * 0.5), height: 16)
        var x = name.maxX + 4
        var swatch: NSRect?
        if drawn[index].color != nil {
            swatch = NSRect(x: x, y: y + 4, width: 10, height: 10)
            x += 14
        }
        return (name, NSRect(x: x, y: y + 1, width: max(bounds.width - x - 8, 20), height: 16), swatch)
    }

    private func selectorText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        if rule.selectors.count > 1, let matching = rule.matching {
            for (i, selector) in rule.selectors.enumerated() {
                if i > 0 { out.add(", ", .secondaryLabelColor, font: font) }
                out.add(selector, matching.contains(i) ? .labelColor : .tertiaryLabelColor, font: font)
            }
        } else {
            out.add(rule.selector, rule.origin == "user-agent" ? .secondaryLabelColor : .labelColor, font: font)
        }
        out.add(" {", .labelColor, font: font)
        return out
    }

    private func makeSourceText() -> NSAttributedString? {
        let text: String
        switch rule.origin {
        case "user-agent": text = "user agent stylesheet"
        case "inline", "attributes": return nil
        case "inspector": text = "inspector-stylesheet"
        default:
            guard let source = rule.source else { return nil }
            var name = URL(string: source)?.lastPathComponent ?? source
            if name.isEmpty || name == "/" { name = "(index)" }
            text = "\(name):\((rule.range?.int("startLine") ?? 0) + 1)"
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingHead
        return NSAttributedString(string: text, attributes: [
            .font: InspectorTheme.mono(10.5), .paragraphStyle: style,
            .foregroundColor: rule.origin == "user-agent" ? NSColor.tertiaryLabelColor : InspectorTheme.link,
        ])
    }

    private func sourceRect(_ y: CGFloat) -> NSRect {
        let width = min(sourceWidth, bounds.width * 0.45)
        return NSRect(x: bounds.width - width - 8, y: y + 4, width: width, height: 16)
    }

    private func selectorRect(_ y: CGFloat) -> NSRect {
        let source = source == nil ? 0 : sourceRect(y).width
        return NSRect(x: 8, y: y + 4, width: max(bounds.width - 24 - source, 40), height: 16)
    }

    private func matchesFilter(_ declaration: StyleDeclaration) -> Bool {
        "\(declaration.name): \(declaration.value)".localizedCaseInsensitiveContains(filter)
    }

    private func line(at point: NSPoint) -> (line: Line, y: CGFloat, height: CGFloat)? {
        lines.first { point.y >= $0.y && point.y < $0.y + $0.height }
    }

    private func tip(for declaration: StyleDeclaration) -> String? {
        declaration.inactive ? "Not inherited" : !declaration.parsedOK ? "Invalid property value" : nil
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let entry = line(at: point) else { return "" }
        switch entry.line {
        case .selector: return rule.source ?? ""
        case .declaration(let index): return tip(for: rule.declarations[index]) ?? ""
        default: return ""
        }
    }

    override func resetCursorRects() {
        guard rule.editable, !visibleRect.isEmpty else { return }
        for entry in lines {
            switch entry.line {
            case .selector where rule.origin != "inline": addCursorRect(selectorRect(entry.y), cursor: .iBeam)
            case .declaration(let index):
                let parts = parts(index, y: entry.y)
                addCursorRect(parts.name, cursor: .iBeam)
                addCursorRect(parts.value, cursor: .iBeam)
            default: break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let entry = line(at: point) else { return }
        switch entry.line {
        case .selector:
            if source != nil, sourceRect(entry.y).contains(point) {
                styles?.reveal(rule)
            } else if selectorRect(entry.y).contains(point) {
                editSelector(at: entry.y)
            }
        case .declaration(let index):
            let parts = parts(index, y: entry.y)
            if point.x < parts.name.minX {
                toggle(index)
            } else if point.x < parts.value.minX {
                editName(index, at: entry.y)
            } else {
                editValue(index, at: entry.y)
            }
        case .close:
            addDeclaration()
        default:
            break
        }
    }

    private func toggle(_ index: Int) {
        guard rule.editable else { return }
        var declarations = rule.declarations
        declarations[index].enabled.toggle()
        styles?.setStyleText(rule, rule.text(with: declarations))
    }

    private func editName(_ index: Int, at y: CGFloat) {
        guard rule.editable else { return }
        let declaration = rule.declarations[index]
        InlineEditor.edit(declaration.name, at: parts(index, y: y).name, in: self, minWidth: 120) { [weak self] text in
            guard let self, let text else { return }
            if text.contains(":") {
                edit(index, name: text, value: "")
            } else if text != declaration.name {
                edit(index, name: text, value: declaration.value)
            } else if declaration.value.isEmpty {
                editValue(index, at: y)
            }
        }
    }

    private func editValue(_ index: Int, at y: CGFloat) {
        guard rule.editable else { return }
        let declaration = rule.declarations[index]
        let current = declaration.value + (declaration.important ? " !important" : "")
        InlineEditor.edit(current, at: parts(index, y: y).value, in: self, minWidth: 140) { [weak self] text in
            guard let self, let text, text != current else { return }
            edit(index, name: declaration.name, value: text)
        }
    }

    private func edit(_ index: Int, name: String, value: String) {
        guard rule.editable else { return }
        var declarations = rule.declarations
        if name.isEmpty || (value.isEmpty && name == declarations[safe: index]?.name) {
            if declarations.indices.contains(index) { declarations.remove(at: index) }
        } else {
            let parsed = Self.parse(name.contains(":") ? name : "\(name): \(value)")
            if declarations.indices.contains(index) {
                declarations.replaceSubrange(index...index, with: parsed)
            } else {
                declarations += parsed
            }
        }
        styles?.setStyleText(rule, rule.text(with: declarations))
    }

    static func parse(_ text: String) -> [StyleDeclaration] {
        text.split(separator: ";").compactMap { part in
            let pieces = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2, !pieces[0].isEmpty else { return nil }
            var value = pieces[1]
            let important = value.hasSuffix("!important")
            if important { value = String(value.dropLast(10)).trimmingCharacters(in: .whitespaces) }
            return StyleDeclaration(name: pieces[0], value: value, important: important, enabled: true, parsedOK: true)
        }
    }

    private func addDeclaration() {
        guard rule.editable, !adding else { return }
        adding = true
        styles?.blockResized()
        guard let entry = lines.first(where: { if case .adding = $0.line { true } else { false } }) else { return }
        let index = rule.declarations.count
        let nameRect = NSRect(x: 26, y: entry.y + 1, width: 120, height: 16)
        InlineEditor.edit("", at: nameRect, in: self, minWidth: 120) { [weak self] name in
            guard let self else { return }
            guard let name, !name.isEmpty else { return finishAdding() }
            if name.contains(":") {
                finishAdding()
                return edit(index, name: name, value: "")
            }
            InlineEditor.edit("", at: NSRect(x: nameRect.minX + 128, y: nameRect.minY, width: 140, height: 16), in: self, minWidth: 140) { [weak self] value in
                guard let self else { return }
                finishAdding()
                if let value, !value.isEmpty { edit(index, name: name, value: value) }
            }
        }
    }

    private func finishAdding() {
        adding = false
        styles?.blockResized()
    }

    private func editSelector(at y: CGFloat) {
        guard rule.editable, rule.origin != "inline" else { return }
        InlineEditor.edit(rule.selector, at: selectorRect(y), in: self) { [weak self] text in
            guard let self, let text, !text.isEmpty, text != rule.selector else { return }
            styles?.setSelector(rule, text)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor
enum InlineEditor {
    private final class Delegate: NSObject, NSTextFieldDelegate {
        let done: (String?) -> Void
        var finished = false
        init(_ done: @escaping (String?) -> Void) { self.done = done }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { finish(control, nil); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:)) {
                finish(control, control.stringValue)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(field, field.stringValue)
        }

        func finish(_ control: NSControl, _ value: String?) {
            guard !finished else { return }
            finished = true
            control.removeFromSuperview()
            done(value)
        }
    }

    private nonisolated(unsafe) static var key: UInt8 = 0

    static func edit(_ text: String, at frame: NSRect, in host: NSView, minWidth: CGFloat = 80, done: @escaping (String?) -> Void) {
        let field = NSTextField(string: text)
        field.font = InspectorTheme.mono(11)
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = InspectorTheme.surface
        field.frame = NSRect(x: frame.minX - 2, y: frame.minY - 1, width: max(frame.width + 8, minWidth),
                             height: frame.height + 2).intersection(host.bounds.insetBy(dx: 0, dy: -4))
        let delegate = Delegate(done)
        objc_setAssociatedObject(field, &key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        field.delegate = delegate
        host.addSubview(field)
        host.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
}

final class ComputedView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    weak var model: ElementsModel?
    weak var session: InspectorSession?
    private let toolbar = InspectorToolbar()
    private let filter = InspectorFilterField(placeholder: "Filter")
    private let showAll = InspectorButton("list.bullet", tip: "Show all properties, not only those set by rules")
    private let box = BoxModelView()
    private let table = InspectorTableView()
    private lazy var scroll = InspectorTable.make(table, columns: [("name", "Property", 150), ("value", "Value", 200)], header: false)
    private var all: [(name: String, value: String)] = []
    private var shown: [(name: String, value: String)] = []
    private var authored: Set<String> = []
    private var node: DOMNode?

    override init(frame: NSRect) {
        super.init(frame: frame)
        filter.onChange = { [weak self] _ in self?.applyFilter() }
        showAll.isOn = UserDefaults.standard.bool(forKey: "inspector.computed.all")
        showAll.action = { [weak self] in
            guard let self else { return }
            showAll.isOn.toggle()
            UserDefaults.standard.set(showAll.isOn, forKey: "inspector.computed.all")
            applyFilter()
        }
        toolbar.add(filter, width: nil)
        toolbar.add(showAll, width: 24)
        addSubview(toolbar)
        addSubview(box)
        table.dataSource = self
        table.delegate = self
        table.menuForRow = { [weak self] row in
            guard let self, shown.indices.contains(row) else { return nil }
            let item = shown[row]
            let menu = NSMenu()
            menu.add("Copy Declaration") { Format.copy("\(item.name): \(item.value);") }
            menu.add("Copy Value") { Format.copy(item.value) }
            return menu
        }
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InspectorToolbar.height)
        box.frame = NSRect(x: 0, y: toolbar.frame.maxY, width: bounds.width, height: 170)
        scroll.frame = NSRect(x: 0, y: box.frame.maxY, width: bounds.width, height: max(bounds.height - box.frame.maxY, 0))
    }

    func show(_ node: DOMNode?) {
        self.node = node
        guard let node, let session, node.isElement || node.pseudoType != nil else {
            all = []
            applyFilter()
            box.model = nil
            return
        }
        session.call("CSS.getComputedStyleForNode", ["nodeId": node.id]) { [weak self] result, _ in
            guard let self, self.node === node else { return }
            all = (result?.list("computedStyle") ?? []).compactMap { entry in
                guard let name = entry.str("name") else { return nil }
                return (name, entry.str("value") ?? "")
            }.sorted { $0.name < $1.name }
            applyFilter()
        }
        session.call("CSS.getMatchedStylesForNode", ["nodeId": node.id]) { [weak self] result, _ in
            guard let self, self.node === node else { return }
            var names = Set<String>()
            let styles = [result?.obj("inlineStyle")].compactMap(\.self) + (result?.list("matchedCSSRules") ?? []).compactMap { $0.obj("rule")?.obj("style") }
            for style in styles { for property in style.list("cssProperties") { if let name = property.str("name") { names.insert(name) } } }
            authored = names
            applyFilter()
        }
        session.call("DOM.getBoxModel", ["nodeId": node.id]) { [weak self] result, _ in
            guard let self, self.node === node else { return }
            box.model = result?.obj("model")
        }
    }

    private func applyFilter() {
        let text = filter.stringValue
        shown = all.filter { item in
            (showAll.isOn || authored.contains(item.name) || authored.isEmpty)
                && (text.isEmpty || item.name.localizedCaseInsensitiveContains(text) || item.value.localizedCaseInsensitiveContains(text))
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        if tableColumn?.identifier.rawValue == "name" {
            return InspectorTable.cell(tableView, "name", item.name, color: InspectorTheme.property, font: InspectorTheme.mono(11))
        }
        return InspectorTable.cell(tableView, "value", item.value, font: InspectorTheme.mono(11))
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { InspectorRowView() }
}

final class BoxModelView: NSView {
    var model: JSON? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else {
            let text = "No box model" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.font(11), .foregroundColor: NSColor.tertiaryLabelColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            return
        }
        func quad(_ name: String) -> [Double] { (model[name] as? [NSNumber])?.map(\.doubleValue) ?? [] }
        let content = quad("content"), padding = quad("padding"), border = quad("border"), margin = quad("margin")
        guard content.count == 8, padding.count == 8, border.count == 8, margin.count == 8 else { return }
        func edges(_ outer: [Double], _ inner: [Double]) -> [Double] {
            [inner[1] - outer[1], outer[2] - inner[2], outer[5] - inner[5], inner[0] - outer[0]]
        }
        let layers: [(String, [Double], NSColor)] = [
            ("margin", edges(margin, border), NSColor(srgbRed: 0.96, green: 0.7, blue: 0.42, alpha: 0.55)),
            ("border", edges(border, padding), NSColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 0.75)),
            ("padding", edges(padding, content), NSColor(srgbRed: 0.58, green: 0.77, blue: 0.49, alpha: 0.55)),
        ]
        var rect = bounds.insetBy(dx: max((bounds.width - 300) / 2, 12), dy: 10)
        let step: CGFloat = 26
        let font = InspectorTheme.mono(10)
        func draw(_ text: String, at point: NSPoint, color: NSColor = .labelColor) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attributes)
        }
        func number(_ value: Double) -> String {
            let rounded = (value * 100).rounded() / 100
            return rounded == 0 ? "–" : rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.2f", rounded)
        }
        for (name, sides, color) in layers {
            color.setFill()
            let path = NSBezierPath(rect: rect)
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            draw(name, at: NSPoint(x: rect.minX + 26, y: rect.minY + 8), color: NSColor.black.withAlphaComponent(0.6))
            draw(number(sides[0]), at: NSPoint(x: rect.midX, y: rect.minY + step / 2), color: .black)
            draw(number(sides[2]), at: NSPoint(x: rect.midX, y: rect.maxY - step / 2), color: .black)
            draw(number(sides[3]), at: NSPoint(x: rect.minX + step / 2, y: rect.midY), color: .black)
            draw(number(sides[1]), at: NSPoint(x: rect.maxX - step / 2, y: rect.midY), color: .black)
            rect = rect.insetBy(dx: step, dy: step)
        }
        NSColor(srgbRed: 0.44, green: 0.66, blue: 0.86, alpha: 0.6).setFill()
        NSBezierPath(rect: rect).fill()
        let width = model.num("width") ?? (content[2] - content[0])
        let height = model.num("height") ?? (content[5] - content[1])
        draw("\(number(width)) × \(number(height))", at: NSPoint(x: rect.midX, y: rect.midY), color: .black)
    }
}

@MainActor
enum TextEditPopover {
    private final class Controller: NSViewController {
        let code = CodeView()
        let done: (String) -> Void
        weak var popover: NSPopover?
        let singleLine: Bool

        init(text: String, language: CodeLanguage, title: String, singleLine: Bool, done: @escaping (String) -> Void) {
            self.done = done
            self.singleLine = singleLine
            super.init(nibName: nil, bundle: nil)
            let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 440, height: singleLine ? 84 : 300))
            let label = Label.make(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
            label.frame = NSRect(x: 12, y: 8, width: 300, height: 16)
            root.addSubview(label)
            code.frame = NSRect(x: 8, y: 28, width: 424, height: root.frame.height - 66)
            code.autoresizingMask = [.width, .height]
            code.textView.isEditable = true
            code.wraps = true
            code.show(text, language: language)
            code.textView.font = InspectorTheme.mono(11)
            code.wantsLayer = true
            code.layer?.borderWidth = 1
            code.layer?.borderColor = InspectorTheme.separator.cgColor
            code.layer?.cornerRadius = 4
            if singleLine { code.rulersVisible = false }
            root.addSubview(code)
            let save = NSButton.push("Save") { [weak self] in self?.commit() }
            save.keyEquivalent = singleLine ? "\r" : ""
            save.frame = NSRect(x: 440 - 88, y: root.frame.height - 34, width: 80, height: 28)
            root.addSubview(save)
            let hint = Label.make(singleLine ? "Return to save, Escape to cancel" : "⌘Return to save, Escape to cancel", size: 10.5,
                                  color: .tertiaryLabelColor)
            hint.frame = NSRect(x: 12, y: root.frame.height - 28, width: 260, height: 16)
            root.addSubview(hint)
            view = root
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidAppear() {
            super.viewDidAppear()
            view.window?.makeFirstResponder(code.textView)
            code.textView.selectAll(nil)
        }

        func commit() {
            done(code.text)
            popover?.close()
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, event.modifierFlags.contains(.command) { commit(); return }
            super.keyDown(with: event)
        }
    }

    private final class Monitor {
        var token: Any?
    }

    static func show(title: String, text: String, language: CodeLanguage, relativeTo rect: NSRect, of view: NSView,
                     singleLine: Bool = false, done: @escaping (String) -> Void) {
        let controller = Controller(text: text, language: language, title: title, singleLine: singleLine, done: done)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.popover = popover
        let monitor = Monitor()
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak controller] event in
            guard let controller, controller.view.window?.isKeyWindow == true else { return event }
            if event.keyCode == 36, event.modifierFlags.contains(.command) || controller.singleLine {
                controller.commit()
                return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { _ in
            if let token = monitor.token { NSEvent.removeMonitor(token) }
            monitor.token = nil
        }
        let visible = view.visibleRect
        let anchor = NSRect(x: max(rect.minX, visible.minX) + 40, y: rect.minY, width: 20, height: rect.height)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }
}
