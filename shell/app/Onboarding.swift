import AppKit

struct ImportRequest {
    let id = UUID()
    let firstLaunch: Bool
}

@MainActor
final class ImportSheet: NSObject {
    let request: ImportRequest
    let window: NSWindow
    var onClose: (() -> Void)?
    private let store: BrowserStore

    private enum Phase {
        case scanning
        case choosing([ImportSourceInfo])
        case importing
        case signingIn
        case done(ImportSummary, [String])
        case style
    }

    private var phase = Phase.scanning
    private var selected: Set<String> = []
    private var signIns = true
    private var passwords = true
    private weak var importButton: NSButton?
    private var imported = false
    private var closed = false
    private let title = Label.make(size: 22, weight: .semibold)
    private let subtitle = Label.wrapping("", size: 13)
    private let body = NSStackView()
    private let buttons = NSStackView()
    private let stack = NSStackView()

    init(request: ImportRequest, store: BrowserStore) {
        self.request = request
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: true)
        super.init()
        build()
        render()
        Task { await start() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        window.sheetParent?.endSheet(window)
        onClose?()
    }

    private func build() {
        subtitle.preferredMaxLayoutWidth = 492
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        buttons.spacing = 8
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        stack.setViews([header, body, buttons], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [body, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 540),
        ])
        window.contentView = content
    }

    private func start() async {
        if ProcessInfo.processInfo.environment["MBGA_DEBUG_ONBOARDING"] == "style" {
            phase = .style
            render()
            return
        }
        let core = store.core
        let home = ProcessInfo.processInfo.environment["MBGA_IMPORT_HOME"] ?? NSHomeDirectory()
        let sources = await Task.detached { core.detectBrowsers(home: home) }.value
        selected = Set(Self.defaultChoice(sources).map { s in s.profiles.map { Self.key(s, $0) } } ?? [])
        phase = .choosing(sources)
        render()
    }

    private static func defaultChoice(_ sources: [ImportSourceInfo]) -> ImportSourceInfo? {
        let usable = sources.filter { $0.error == nil && !$0.profiles.isEmpty }
        let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        return usable.first { $0.bundleId != nil && $0.bundleId == defaultBrowser } ?? usable.first
    }

    static func key(_ source: ImportSourceInfo, _ profile: ImportProfileInfo) -> String {
        source.id + "\n" + profile.id
    }

    private func runImport(_ sources: [ImportSourceInfo]) {
        let choices = sources.compactMap { source -> ImportChoice? in
            let ids = source.profiles.filter { selected.contains(Self.key(source, $0)) }.map(\.id)
            return ids.isEmpty ? nil : ImportChoice(sourceId: source.id, profileIds: ids)
        }
        phase = .importing
        render()
        let core = store.core
        Task {
            let summary = await Task.detached { core.importBrowsers(choices: choices) }.value
            store.refresh()
            imported = true
            var notes: [String] = []
            if signIns || passwords {
                phase = .signingIn
                render()
            }
            if signIns { notes += await bringSignIns(summary, sources: sources) }
            if passwords { notes += await bringPasswords(summary, sources: sources) }
            phase = .done(summary, notes)
            render()
        }
    }

    private func bringSignIns(_ summary: ImportSummary, sources: [ImportSourceInfo]) async -> [String] {
        var notes: [String] = []
        for link in summary.profiles {
            guard let source = sources.first(where: { $0.id == link.sourceId }), SignIns.available(source),
                  let profile = source.profiles.first(where: { $0.id == link.profileId }) else { continue }
            let outcome = await SignIns.bring(from: source, profileID: link.profileId, into: link.into, store: store)
            let name = source.profiles.count == 1 ? source.name : SignIns.title(profile, of: source)
            notes.append(SignIns.describe(outcome, from: name, named: true))
        }
        return notes
    }

    private func bringPasswords(_ summary: ImportSummary, sources: [ImportSourceInfo]) async -> [String] {
        var notes: [String] = []
        for link in summary.profiles {
            guard let source = sources.first(where: { $0.id == link.sourceId }), PasswordImport.available(source),
                  let profile = source.profiles.first(where: { $0.id == link.profileId }), profile.passwords > 0 else { continue }
            let outcome = await PasswordImport.bring(from: source, profileID: link.profileId, into: link.into, store: store)
            let name = source.profiles.count == 1 ? source.name : SignIns.title(profile, of: source)
            notes.append(PasswordImport.describe(outcome, from: name, named: true))
        }
        _ = store.core.persist()
        return notes
    }

    private func next() {
        if request.firstLaunch {
            phase = .style
            render()
        } else {
            finish()
        }
    }

    private func finish() {
        close()
        guard request.firstLaunch else { return }
        store.core.finishOnboarding()
        store.refresh()
        if !imported, store.visibleTabID == nil { store.commandBar = .newTab }
    }

    private func render() {
        if case .style = phase {
            title.stringValue = "Make it yours"
            subtitle.stringValue = "Pick a layout and how much color your spaces bring. You can change both later from the View menu."
        } else {
            title.stringValue = request.firstLaunch ? "Welcome to MBGA" : "Import from Another Browser"
            subtitle.stringValue = "Bring your spaces, pinned tabs, open tabs, bookmarks, sign-ins and passwords from the browsers on this Mac."
        }
        for view in body.arrangedSubviews { view.removeFromSuperview() }
        for view in buttons.arrangedSubviews { view.removeFromSuperview() }
        let finish: () -> Void = { [weak self] in self?.finish() }
        let next: () -> Void = { [weak self] in self?.next() }
        switch phase {
        case .scanning:
            body.addArrangedSubview(status("Looking for other browsers…"))
            addButtons(cancel: (request.firstLaunch ? "Skip" : "Cancel", finish))
        case .choosing(let sources):
            let cancel = (request.firstLaunch ? "Start Fresh" : "Cancel", next)
            if sources.isEmpty {
                let none = Label.make("No other browsers with tabs or bookmarks were found on this Mac.",
                                      color: .secondaryLabelColor)
                body.addArrangedSubview(centered(none, height: 120))
                addButtons(cancel: cancel, primary: ("Get Started", next))
            } else {
                body.addArrangedSubview(sourceList(sources))
                if sources.contains(where: SignIns.available) {
                    let keep = NSButton(checkboxWithTitle: "Stay signed in to sites", target: nil, action: nil)
                    keep.state = signIns ? .on : .off
                    keep.onAction { [weak self, weak keep] in self?.signIns = keep?.state == .on }
                    body.setCustomSpacing(12, after: body.arrangedSubviews.last!)
                    body.addArrangedSubview(keep)
                }
                if sources.contains(where: PasswordImport.available) {
                    let bring = NSButton(checkboxWithTitle: "Bring saved passwords", target: nil, action: nil)
                    bring.state = passwords ? .on : .off
                    bring.onAction { [weak self, weak bring] in self?.passwords = bring?.state == .on }
                    if !sources.contains(where: SignIns.available) {
                        body.setCustomSpacing(12, after: body.arrangedSubviews.last!)
                    }
                    body.addArrangedSubview(bring)
                }
                let note = Label.wrapping("Your other browsers stay as they are. Staying signed in brings their cookies; macOS asks once per browser before MBGA can read them and their passwords. Safari's passwords come from a file the Passwords app exports (Settings ▸ Passwords). History isn't imported.",
                                          size: 11)
                note.preferredMaxLayoutWidth = 492
                body.addArrangedSubview(note)
                let runImport: () -> Void = { [weak self] in self?.runImport(sources) }
                importButton = addButtons(cancel: cancel, primary: ("Import", runImport))
                importButton?.isEnabled = !selected.isEmpty
            }
        case .importing:
            body.addArrangedSubview(status("Importing…"))
            addButtons(cancel: (request.firstLaunch ? "Skip" : "Cancel", finish))
        case .signingIn:
            let what = signIns && passwords ? "sign-ins and passwords" : signIns ? "sign-ins" : "passwords"
            body.addArrangedSubview(status("Bringing your \(what)…"))
            addButtons(cancel: nil)
        case .done(let summary, let notes):
            body.addArrangedSubview(doneView(summary, notes: notes))
            addButtons(cancel: nil, primary: (request.firstLaunch ? "Continue" : "Done", next))
        case .style:
            body.addArrangedSubview(StylePicker(store: store))
            addButtons(cancel: nil, primary: ("Start Browsing", finish))
        }
        resize()
        if window.isVisible, !Motion.reduced {
            for view in [body, buttons] as [NSView] { view.alphaValue = 0 }
            Motion.animate(Motion.fade) {
                for view in [body, buttons] as [NSView] { view.animator().alphaValue = 1 }
            }
        }
    }

    private func resize() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: 540, height: stack.fittingSize.height)
        if window.isVisible {
            var frame = window.frame
            let height = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).height
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true, animate: !Motion.reduced)
        } else {
            window.setContentSize(size)
        }
    }

    @discardableResult
    private func addButtons(cancel: (String, () -> Void)?, primary: (String, () -> Void)? = nil) -> NSButton? {
        if let (title, action) = cancel {
            let button = NSButton.push(title, action: action)
            button.keyEquivalent = "\u{1b}"
            buttons.addArrangedSubview(button)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttons.addArrangedSubview(spacer)
        guard let (title, action) = primary else { return nil }
        let button = NSButton.push(title, action: action)
        button.keyEquivalent = "\r"
        buttons.addArrangedSubview(button)
        return button
    }

    private func status(_ text: String) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, Label.make(text, color: .secondaryLabelColor)])
        row.spacing = 10
        return centered(row, height: 120)
    }

    private func centered(_ view: NSView, height: CGFloat) -> NSView {
        let box = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: height),
            box.widthAnchor.constraint(equalToConstant: 492),
        ])
        return box
    }

    private func sourceList(_ sources: [ImportSourceInfo]) -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        for source in sources {
            let row = SourceRow(source: source, selected: selected) { [weak self] key, on in
                guard let self else { return }
                if on { selected.insert(key) } else { selected.remove(key) }
                importButton?.isEnabled = !selected.isEmpty
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 492).isActive = true
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        document.frame = NSRect(origin: .zero, size: list.fittingSize)
        scroll.documentView = document
        let height = min(list.fittingSize.height, 340)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 492).isActive = true
        return scroll
    }

    private func doneView(_ s: ImportSummary, notes: [String]) -> NSView {
        let check = NSImageView(image: .symbol("checkmark.circle.fill", size: 28, weight: .regular) ?? NSImage())
        check.contentTintColor = .systemGreen
        let headline = Label.make(summaryText(s), size: 14, weight: .medium)
        let detail = Label.wrapping("Bookmarks are in folders under each space's pinned tabs. Nothing loads until you open it.",
                                    size: 13)
        detail.preferredMaxLayoutWidth = 440
        let text = NSStackView(views: [headline, detail])
        for note in notes {
            let line = Label.wrapping(note, size: 13)
            line.preferredMaxLayoutWidth = 440
            text.addArrangedSubview(line)
        }
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [check, text])
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func summaryText(_ s: ImportSummary) -> String {
        var parts: [String] = []
        if s.spaces > 0 { parts.append(plural(s.spaces, "space")) }
        if s.pinned > 0 { parts.append(plural(s.pinned, "pinned tab or bookmark", "pinned tabs and bookmarks")) }
        if s.favorites > 0 { parts.append(plural(s.favorites, "favorite")) }
        if s.today > 0 { parts.append(plural(s.today, "open tab")) }
        return parts.isEmpty ? "Nothing to import." : "Imported " + ListFormatter.localizedString(byJoining: parts) + "."
    }
}

private func plural(_ n: UInt32, _ one: String, _ many: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? one : many ?? one + "s")"
}

private final class SourceRow: NSView {
    private let source: ImportSourceInfo
    private let toggled: (String, Bool) -> Void
    private let stack = NSStackView()

    init(source: ImportSourceInfo, selected: Set<String>, toggled: @escaping (String, Bool) -> Void) {
        self.source = source
        self.toggled = toggled
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        let icon = NSImageView()
        if let id = source.bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon.image = .symbol("globe", size: 20, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
        }
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let name = Label.make(source.name, size: 13, weight: .semibold)
        let text = NSStackView(views: [name])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if let error = source.error {
            text.addArrangedSubview(Label.make(error, size: 11, color: .secondaryLabelColor))
        } else if source.profiles.count == 1, !describe(source.profiles[0]).isEmpty {
            text.addArrangedSubview(Label.make(describe(source.profiles[0]), size: 11, color: .secondaryLabelColor))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var top: [NSView] = [icon, text, spacer]
        if source.error != nil, source.kind == .safari {
            let settings = NSButton.push("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            settings.controlSize = .small
            top.append(settings)
        } else if source.profiles.count == 1 {
            top.append(checkbox(source.profiles[0], selected: selected))
        }
        let topRow = NSStackView(views: top)
        topRow.spacing = 10
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.addArrangedSubview(topRow)
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        if source.profiles.count > 1 {
            for profile in source.profiles {
                let label = Label.make(profileLabel(profile), size: 12, weight: .medium)
                let description = describe(profile)
                let labels = NSStackView(views: [label])
                if !description.isEmpty {
                    labels.addArrangedSubview(Label.make(description, size: 11, color: .secondaryLabelColor))
                }
                labels.orientation = .vertical
                labels.alignment = .leading
                labels.spacing = 1
                let gap = NSView()
                gap.setContentHuggingPriority(.init(1), for: .horizontal)
                let row = NSStackView(views: [labels, gap, checkbox(profile, selected: selected)])
                row.edgeInsets = NSEdgeInsets(top: 0, left: 38, bottom: 0, right: 0)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        alphaValue = source.error == nil ? 1 : 0.75
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.faint(effectiveAppearance.isDark ? 0.06 : 0.04).cgColor
    }

    private func checkbox(_ profile: ImportProfileInfo, selected: Set<String>) -> NSButton {
        let key = ImportSheet.key(source, profile)
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        box.state = selected.contains(key) ? .on : .off
        box.onAction { [weak self, weak box] in
            guard let box else { return }
            self?.toggled(key, box.state == .on)
        }
        return box
    }

    private func profileLabel(_ profile: ImportProfileInfo) -> String {
        let prefix = source.name + " · "
        return profile.name.hasPrefix(prefix) ? String(profile.name.dropFirst(prefix.count)) : profile.name
    }

    private func describe(_ p: ImportProfileInfo) -> String {
        var parts: [String] = []
        if source.kind == .arc {
            if p.spaces > 0 { parts.append(plural(p.spaces, "space")) }
            if p.pinned > 0 { parts.append(plural(p.pinned, "pinned tab")) }
            if p.favorites > 0 { parts.append(plural(p.favorites, "favorite")) }
            if p.today > 0 { parts.append(plural(p.today, "Today tab")) }
        } else {
            if p.pinned > 0 { parts.append(plural(p.pinned, "bookmark")) }
            if p.today > 0 { parts.append(plural(p.today, "open tab")) }
        }
        if p.passwords > 0 { parts.append(plural(p.passwords, "password")) }
        return parts.joined(separator: " · ")
    }
}

private final class StylePicker: NSStackView {
    private let store: BrowserStore
    private var layoutChoices: [StyleChoice] = []
    private var colorChoices: [StyleChoice] = []

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let color = store.activeSpace.color
        addArrangedSubview(Label.make("Layout", size: 13, weight: .semibold))
        let layouts = NSStackView()
        layouts.spacing = 12
        layouts.distribution = .fillEqually
        for layout in SidebarLayout.allCases {
            let choice = StyleChoice(title: layout.title, detail: Self.detail(layout),
                                     preview: StylePreview(layout: layout, style: TintStyle.saved, color: color))
            choice.onPick = { [weak self] in
                self?.store.setLayout(layout)
                self?.refresh()
            }
            layoutChoices.append(choice)
            layouts.addArrangedSubview(choice)
        }
        addArrangedSubview(layouts)
        setCustomSpacing(16, after: layouts)
        addArrangedSubview(Label.make("Color", size: 13, weight: .semibold))
        let colors = NSStackView()
        colors.spacing = 12
        colors.distribution = .fillEqually
        for style in TintStyle.allCases {
            let choice = StyleChoice(title: style.title, detail: nil,
                                     preview: StylePreview(layout: store.layout, style: style, color: color))
            choice.onPick = { [weak self] in
                UserDefaults.standard.set(style.rawValue, forKey: TintStyle.defaultsKey)
                self?.refresh()
            }
            colorChoices.append(choice)
            colors.addArrangedSubview(choice)
        }
        addArrangedSubview(colors)
        for row in [layouts, colors] { row.widthAnchor.constraint(equalToConstant: 492).isActive = true }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func detail(_ layout: SidebarLayout) -> String {
        switch layout {
        case .full: "Tabs and spaces on the left"
        case .compact: "Just the icons"
        case .focus: "Just the page"
        }
    }

    private func refresh() {
        let style = TintStyle.saved
        for (choice, layout) in zip(layoutChoices, SidebarLayout.allCases) {
            choice.selected = store.layout == layout
            choice.preview.style = style
        }
        for (choice, option) in zip(colorChoices, TintStyle.allCases) {
            choice.selected = style == option
            choice.preview.layout = store.layout
        }
    }
}

private final class StyleChoice: NSView {
    let preview: StylePreview
    var onPick: (() -> Void)?
    var selected = false {
        didSet { preview.selected = selected }
    }

    init(title: String, detail: String?, preview: StylePreview) {
        self.preview = preview
        super.init(frame: .zero)
        let label = Label.make(title, size: 12, weight: .medium)
        var views: [NSView] = [preview, label]
        if let detail {
            let small = Label.wrapping(detail, size: 11)
            small.preferredMaxLayoutWidth = 150
            views.append(small)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        preview.heightAnchor.constraint(equalToConstant: 74).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { onPick?() }
}

private final class StylePreview: NSView {
    var layout: SidebarLayout { didSet { needsDisplay = true } }
    var style: TintStyle { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    private let color: UInt32

    init(layout: SidebarLayout, style: TintStyle, color: UInt32) {
        self.layout = layout
        self.style = style
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let stops = Theme.gradient(for: RGB(color), dark: effectiveAppearance.isDark, active: true, style: style)
        NSGradient(colors: stops.map(\.nsColor))?.draw(in: bounds, angle: 90)
        let faint = { (alpha: CGFloat) in NSColor.labelColor.withAlphaComponent(alpha) }
        var pageX: CGFloat = 3
        let inset: CGFloat = layout == .focus ? 3 : 5
        switch layout {
        case .full:
            faint(0.15).setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 12, width: 34, height: 6), xRadius: 3, yRadius: 3).fill()
            for i in 0..<4 {
                faint(i == 1 ? 0.3 : 0.12).setFill()
                NSBezierPath(roundedRect: NSRect(x: 6, y: 22 + CGFloat(i) * 8, width: i == 1 ? 34 : 28, height: 4),
                             xRadius: 2, yRadius: 2).fill()
            }
            pageX = 46
        case .compact:
            for i in 0..<5 {
                faint(i == 1 ? 0.3 : 0.14).setFill()
                NSBezierPath(roundedRect: NSRect(x: 4, y: 12 + CGFloat(i) * 11, width: 7, height: 7),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
            pageX = 16
        case .focus:
            pageX = inset
        }
        let page = NSBezierPath(roundedRect: NSRect(x: pageX, y: inset, width: bounds.width - pageX - inset,
                                                    height: bounds.height - inset * 2), xRadius: 4, yRadius: 4)
        NSColor.white.setFill()
        page.fill()
        NSGraphicsContext.restoreGraphicsState()
        (selected ? NSColor.controlAccentColor : faint(0.12)).setStroke()
        shape.lineWidth = selected ? 2 : 1
        shape.stroke()
    }

    override func mouseDown(with event: NSEvent) { (superview?.superview as? StyleChoice)?.onPick?() }
}
