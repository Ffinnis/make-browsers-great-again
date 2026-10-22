import AppKit

struct SpaceEditorRequest {
    let id = UUID()
    let spaceID: UInt64?
}

@MainActor
final class SheetPresenter {
    private var spaceEditor: SpaceEditorSheet?
    private var importer: ImportSheet?

    func showSpaceEditor(_ request: SpaceEditorRequest?, store: BrowserStore, in window: NSWindow) {
        if let request {
            guard spaceEditor?.request.id != request.id else { return }
            spaceEditor?.close()
            let sheet = SpaceEditorSheet(request: request, store: store)
            spaceEditor = sheet
            sheet.onClose = { [weak self, weak store] in
                self?.spaceEditor = nil
                if store?.spaceEditor?.id == request.id { store?.spaceEditor = nil }
            }
            window.beginSheet(sheet.window)
        } else {
            spaceEditor?.close()
        }
    }

    func showImport(_ request: ImportRequest?, store: BrowserStore, in window: NSWindow) {
        if let request {
            guard importer?.request.id != request.id else { return }
            importer?.close()
            let sheet = ImportSheet(request: request, store: store)
            importer = sheet
            sheet.onClose = { [weak self, weak store] in
                self?.importer = nil
                if store?.importSheet?.id == request.id { store?.importSheet = nil }
            }
            window.beginSheet(sheet.window)
        } else {
            importer?.close()
        }
    }
}

@MainActor
final class SpaceEditorSheet: NSObject, NSTextFieldDelegate {
    let request: SpaceEditorRequest
    let window: NSWindow
    var onClose: (() -> Void)?
    private let store: BrowserStore
    private let iconField = NSTextField()
    private let nameField = NSTextField()
    private let swatches = NSStackView()
    private let profiles = NSPopUpButton()
    private let newProfile = NSTextField()
    private let unused = NSStackView()
    private var saveButton: NSButton!
    private var color: UInt32 = Theme.spaceColors[0]
    private var closed = false

    private var editing: SpaceInfo? {
        request.spaceID.flatMap { id in store.snapshot.spaces.first { $0.id == id } }
    }

    init(request: SpaceEditorRequest, store: BrowserStore) {
        self.request = request
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: true)
        super.init()
        build()
        load()
    }

    func close() {
        guard !closed else { return }
        closed = true
        window.sheetParent?.endSheet(window)
        onClose?()
    }

    private func build() {
        let title = Label.make(editing == nil ? "New Space" : "Edit Space", size: 13, weight: .semibold)

        iconField.font = Theme.font(18)
        iconField.alignment = .center
        iconField.placeholderString = "🙂"
        iconField.delegate = self
        iconField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        nameField.placeholderString = "Space name"
        nameField.delegate = self
        let emoji = NSButton(image: .symbol("face.smiling", size: 14) ?? NSImage(), target: nil, action: nil)
        emoji.bezelStyle = .push
        emoji.toolTip = "Pick an emoji"
        emoji.onAction { [weak self] in
            self?.window.makeFirstResponder(self?.iconField)
            NSApp.orderFrontCharacterPalette(nil)
        }
        let nameRow = NSStackView(views: [iconField, nameField, emoji])
        nameRow.spacing = 8

        swatches.spacing = 10
        for swatch in Theme.spaceColors {
            let view = SwatchView(color: swatch)
            view.onPick = { [weak self] picked in
                self?.color = picked
                self?.updateSwatches()
            }
            swatches.addArrangedSubview(view)
        }

        let profileLabel = Label.make("Profile")
        let profileRow = NSStackView(views: [profileLabel, profiles])
        profileRow.spacing = 8
        newProfile.placeholderString = "New profile name"
        newProfile.delegate = self
        let addProfile = NSButton.push("Add Profile") { [weak self] in self?.addProfile() }
        let newRow = NSStackView(views: [newProfile, addProfile])
        newRow.spacing = 8
        let caption = Label.wrapping("Each profile keeps its own cookies, logins and site data. Spaces with the same profile share Favorites.",
                                     size: 11)
        caption.preferredMaxLayoutWidth = 360
        unused.orientation = .vertical
        unused.alignment = .leading
        unused.spacing = 4

        var buttons: [NSView] = []
        if let editing, store.snapshot.spaces.count > 1 {
            let delete = NSButton.push("Delete Space") { [weak self] in
                guard let self else { return }
                store.deleteSpace(editing.id)
                close()
            }
            delete.hasDestructiveAction = true
            buttons.append(delete)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttons.append(spacer)
        let cancel = NSButton.push("Cancel") { [weak self] in self?.close() }
        cancel.keyEquivalent = "\u{1b}"
        saveButton = NSButton.push(editing == nil ? "Create" : "Save") { [weak self] in self?.save() }
        saveButton.keyEquivalent = "\r"
        buttons += [cancel, saveButton]
        let buttonRow = NSStackView(views: buttons)
        buttonRow.spacing = 8

        let stack = NSStackView(views: [title, nameRow, swatches, profileRow, newRow, caption, unused, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(8, after: profileRow)
        stack.setCustomSpacing(8, after: newRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for row in [nameRow, newRow, buttonRow] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 400),
        ])
        window.contentView = content
        window.initialFirstResponder = nameField
    }

    private func load() {
        if let space = editing {
            nameField.stringValue = space.name
            iconField.stringValue = space.icon
            color = space.color
        } else {
            let count = store.snapshot.spaces.count
            iconField.stringValue = ["✨", "💼", "🎨", "📚", "🎮", "🧪", "🌿", "🚀"][count % 8]
            color = Theme.spaceColors[count % Theme.spaceColors.count]
        }
        reloadProfiles(selecting: editing?.profileId ?? store.activeSpace.profileId)
        updateSwatches()
        updateSave()
    }

    private func reloadProfiles(selecting id: UInt64) {
        profiles.removeAllItems()
        for profile in store.snapshot.profiles {
            profiles.addItem(withTitle: profile.name)
            profiles.lastItem?.tag = Int(profile.id)
            profiles.lastItem?.representedObject = profile.id
        }
        if let index = store.snapshot.profiles.firstIndex(where: { $0.id == id }) { profiles.selectItem(at: index) }
        profiles.onAction { [weak self] in self?.reloadUnused() }
        reloadUnused()
    }

    private var profileID: UInt64 {
        profiles.selectedItem?.representedObject as? UInt64 ?? store.activeSpace.profileId
    }

    private func reloadUnused() {
        for view in unused.arrangedSubviews { view.removeFromSuperview() }
        guard store.snapshot.profiles.count > 1 else { return }
        for profile in store.snapshot.profiles where profile.spaceCount == 0 && profile.id != profileID {
            let label = Label.make("Unused profile: \(profile.name)", size: 11)
            let delete = NSButton.push("Delete") { [weak self] in
                guard let self else { return }
                store.deleteProfile(profile.id)
                reloadProfiles(selecting: profileID)
            }
            delete.controlSize = .small
            delete.hasDestructiveAction = true
            unused.addArrangedSubview(NSStackView(views: [label, delete]))
        }
    }

    private func updateSwatches() {
        for case let view as SwatchView in swatches.arrangedSubviews { view.selected = view.color == color }
    }

    private func updateSave() {
        saveButton.isEnabled = !nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addProfile() {
        let trimmed = newProfile.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let id = store.createProfile(trimmed)
        newProfile.stringValue = ""
        reloadProfiles(selecting: id)
    }

    private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let space = editing {
            store.updateSpace(space.id, name: name, icon: iconField.stringValue, color: color, profileID: profileID)
        } else {
            store.createSpace(name: name, icon: iconField.stringValue, color: color, profileID: profileID)
        }
        close()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === iconField, field.stringValue.count > 1 {
            field.stringValue = String(field.stringValue.suffix(1))
        }
        updateSave()
    }
}

private final class SwatchView: NSView {
    let color: UInt32
    var onPick: ((UInt32) -> Void)?
    var selected = false {
        didSet { needsDisplay = true }
    }

    init(color: UInt32) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        RGB(color).nsColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        if selected {
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onPick?(color) }
}
