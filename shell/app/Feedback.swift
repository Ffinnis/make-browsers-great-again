import AppKit

@MainActor
final class ToastView: FlippedView {
    private let store: BrowserStore
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let message = Label.make(size: 13, weight: .medium)
    private let divider = CALayer()
    private let undo = NSButton()
    private let shortcut = Label.make("⌘Z", size: 11, color: .tertiaryLabelColor)
    private var undoable = false

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        fill.cornerRadius = 18
        layer?.addSublayer(fill)
        layer?.addSublayer(divider)
        icon.contentTintColor = .secondaryLabelColor
        undo.isBordered = false
        undo.attributedTitle = NSAttributedString(string: "Undo", attributes: [
            .font: Theme.font(13, .semibold), .foregroundColor: NSColor.controlAccentColor,
        ])
        undo.onAction { store.undoClose() }
        for view in [icon, message, undo, shortcut] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    func configure(_ toast: Toast) {
        icon.image = .symbol(toast.symbol, size: 12, weight: .semibold)
        message.stringValue = toast.message
        undoable = toast.undoable
        undo.isHidden = !undoable
        shortcut.isHidden = !undoable
        divider.isHidden = !undoable
        needsLayout = true
    }

    var preferredWidth: CGFloat {
        28 + 14 + message.textWidth + (undoable ? 20 + 40 + 6 + 22 : 0)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        var x: CGFloat = 14
        icon.frame = NSRect(x: x, y: bounds.midY - 7, width: 14, height: 14)
        x += 22
        let width = message.textWidth
        message.frame = NSRect(x: x, y: bounds.midY - 8, width: width, height: 16)
        x += width + 10
        divider.frame = NSRect(x: x, y: bounds.midY - 7, width: 1, height: 14)
        x += 10
        undo.frame = NSRect(x: x, y: bounds.midY - 9, width: 40, height: 18)
        x += 44
        shortcut.frame = NSRect(x: x, y: bounds.midY - 7, width: 22, height: 14)
        CATransaction.commit()
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        fill.paint(fill: Theme.toastFill, border: Theme.faint(0.1), in: effectiveAppearance)
        fill.borderWidth = 0.5
        fill.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.14).cgColor
        fill.shadowOpacity = 1
        fill.shadowRadius = 14
        fill.shadowOffset = CGSize(width: 0, height: -6)
        divider.backgroundColor = Theme.faint(0.15).cgColor
    }

    override func mouseUp(with event: NSEvent) { store.dismissToast() }
    override func mouseDown(with event: NSEvent) {}
}

@MainActor
final class MiniPlayerView: HoverView {
    private let store: BrowserStore
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let title = Label.make(size: 12, weight: .medium)
    private let equalizer = EqualizerView()
    private let subtitle = Label.make(size: 11, color: .secondaryLabelColor)
    private let playPause = NSButton()
    private let hide = NSButton()
    private var media: (tab: TabInfo, space: SpaceInfo)?

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        icon.imageScaling = .scaleProportionallyUpOrDown
        equalizer.alphaValue = 0.55
        for button in [playPause, hide] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.contentTintColor = .labelColor
        }
        playPause.onAction { [weak self] in
            guard let self, let media else { return }
            store.toggleMedia(media.tab.id)
        }
        hide.image = .symbol("xmark", size: 9, weight: .bold)
        hide.toolTip = "Hide"
        hide.onAction { store.dismissMedia() }
        for view in [icon, title, equalizer, subtitle, playPause, hide] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var paused: Bool { media.map { store.pausedMediaTab == $0.tab.id } ?? false }

    func update(_ media: (tab: TabInfo, space: SpaceInfo)?) {
        guard let media else { return }
        let sameTab = self.media?.tab.id == media.tab.id
        let wasPaused = paused
        self.media = media
        if !sameTab, window != nil, !Motion.reduced {
            for view in [icon, title, subtitle] as [NSView] {
                view.alphaValue = 0
            }
            Motion.animate(Motion.fade) {
                for view in [icon, title, subtitle] as [NSView] { view.animator().alphaValue = 1 }
            }
        }
        icon.image = FaviconCache.shared.image(for: media.tab)
        title.stringValue = media.tab.displayTitle
        subtitle.stringValue = media.space.id == store.activeSpace.id ? media.tab.host : "\(media.space.icon) \(media.space.name)"
        if sameTab, wasPaused != paused, let layer = playPause.layer, !Motion.reduced {
            let swap = CATransition()
            swap.type = .fade
            swap.duration = Motion.quick.duration
            layer.add(swap, forKey: "swap")
        }
        playPause.image = .symbol(paused ? "play.fill" : "pause.fill", size: 12, weight: .regular)
        playPause.toolTip = paused ? "Play" : "Pause"
        equalizer.playing = !paused
        updateHide(animated: sameTab)
    }

    override func hoverChanged() {
        super.hoverChanged()
        updateHide(animated: true)
    }

    private func updateHide(animated: Bool) {
        let show = paused && hovering
        guard show == hide.isHidden || hide.alphaValue < 1 else { return }
        hide.setVisible(show, animated: animated)
        needsLayout = true
        if animated, window != nil, !Motion.reduced {
            Motion.animate(Motion.quick) { layoutSubtreeIfNeeded() }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        icon.frame = NSRect(x: 10, y: bounds.midY - 10, width: 20, height: 20)
        let trailing: CGFloat = paused && hovering ? 24 : 6
        hide.frame = NSRect(x: bounds.width - 24, y: bounds.midY - 13, width: 18, height: 26)
        playPause.frame = NSRect(x: bounds.width - trailing - 26, y: bounds.midY - 13, width: 26, height: 26)
        let textX: CGFloat = 40
        let textWidth = max(playPause.frame.minX - textX - 6, 0)
        let titleWidth = min(title.textWidth, textWidth - 17)
        title.frame = NSRect(x: textX, y: 7, width: max(titleWidth, 0), height: 15)
        equalizer.frame = NSRect(x: textX + max(titleWidth, 0) + 6, y: 9, width: 11, height: 10)
        subtitle.frame = NSRect(x: textX, y: 24, width: textWidth, height: 14)
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.controlHoverFill : Theme.controlFill, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let media, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        store.select(media.tab.id, in: media.space.id)
    }
}

@MainActor
final class UpdateCardView: HoverView {
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let title = Label.make("Restart to Update", size: 12, weight: .medium)
    private let subtitle = Label.make(size: 11, color: .secondaryLabelColor)
    private let hide = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        icon.image = .symbol("arrow.down.circle.fill", size: 16, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        hide.isBordered = false
        hide.bezelStyle = .regularSquare
        hide.contentTintColor = .secondaryLabelColor
        hide.image = .symbol("xmark", size: 9, weight: .bold)
        hide.toolTip = "Hide (installs when you quit)"
        hide.onAction { Updater.shared.hideCard() }
        hide.isHidden = true
        toolTip = "MBGA quits and opens again, with your tabs where they were"
        for view in [icon, title, subtitle, hide] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(version: String) {
        subtitle.stringValue = "MBGA \(version) is ready"
    }

    override func hoverChanged() {
        super.hoverChanged()
        hide.setVisible(hovering, animated: true)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        icon.frame = NSRect(x: 10, y: bounds.midY - 10, width: 20, height: 20)
        hide.frame = NSRect(x: bounds.width - 24, y: bounds.midY - 13, width: 18, height: 26)
        let textWidth = max(bounds.width - 40 - 28, 0)
        title.frame = NSRect(x: 40, y: 7, width: textWidth, height: 15)
        subtitle.frame = NSRect(x: 40, y: 24, width: textWidth, height: 14)
    }

    override func updateLayer() {
        fill.paint(fill: hovering ? Theme.controlHoverFill : Theme.controlFill, in: effectiveAppearance)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        Updater.shared.restartToUpdate()
    }
}

final class CleanupCellView: NSTableCellView {
    private let store: BrowserStore
    private let fill = FillLayer()
    private let title = Label.make(size: 12.5, weight: .semibold)
    private let detail = Label.wrapping("MBGA can tidy them up. You can always bring them back.", size: 11.5)
    private let notNow: NSButton
    private let once: NSButton
    private let daily: NSButton

    init(store: BrowserStore) {
        self.store = store
        notNow = .push("Not Now") { store.answerCleanup(.notNow) }
        once = .push("Once") { store.answerCleanup(.once) }
        daily = .push("Daily") { store.answerCleanup(.daily) }
        super.init(frame: .zero)
        wantsLayer = true
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        for button in [notNow, once, daily] { button.controlSize = .small; button.font = Theme.font(11) }
        daily.keyEquivalent = "\r"
        for view in [title, detail, notNow, once, daily] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(count: Int) {
        title.stringValue = "\(count) tabs haven't been touched in a while"
        needsLayout = true
    }

    override func updateLayer() {
        fill.paint(fill: Theme.controlFill, in: effectiveAppearance)
    }

    override func layout() {
        super.layout()
        let card = bounds.insetBy(dx: 0, dy: 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = card
        CATransaction.commit()
        let width = card.width - 20
        title.frame = NSRect(x: 10, y: card.minY + 9, width: width, height: 16)
        detail.frame = NSRect(x: 10, y: card.minY + 27, width: width, height: 30)
        let y = card.maxY - 28
        notNow.frame = NSRect(x: 6, y: y, width: notNow.intrinsicContentSize.width, height: 24)
        let dailyWidth = daily.intrinsicContentSize.width, onceWidth = once.intrinsicContentSize.width
        daily.frame = NSRect(x: card.width - 6 - dailyWidth, y: y, width: dailyWidth, height: 24)
        once.frame = NSRect(x: daily.frame.minX - onceWidth, y: y, width: onceWidth, height: 24)
    }
}

@MainActor
final class DropPreviewView: NSView {
    private let dim = CALayer()
    private let frameLayer = FillLayer()
    private let page = FillLayer()
    private let dots = (0..<3).map { _ in CALayer() }
    private let icon = NSImageView()
    private let bigIcon = NSImageView()
    private let title = Label.make(size: 12, weight: .medium)
    private let hint = Label.make("Drop to open in a little window", size: 13, weight: .medium,
                                  color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(dim)
        layer?.addSublayer(frameLayer)
        frameLayer.cornerRadius = 16
        frameLayer.addSublayer(page)
        page.cornerRadius = 10
        for dot in dots {
            dot.cornerRadius = 4
            frameLayer.addSublayer(dot)
        }
        hint.alignment = .center
        for view in [icon, title, bigIcon, hint] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ tab: TabInfo) {
        icon.image = FaviconCache.shared.image(for: tab)
        bigIcon.image = icon.image
        title.stringValue = tab.displayTitle
        needsLayout = true
    }

    private var card: NSRect {
        NSRect(x: bounds.midX - 150, y: bounds.midY - 180, width: 300, height: 360)
    }

    override func layout() {
        super.layout()
        let card = card
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        frameLayer.frame = card
        page.frame = NSRect(x: 6, y: 32, width: card.width - 12, height: card.height - 38)
        for (i, dot) in dots.enumerated() { dot.frame = NSRect(x: 12 + CGFloat(i) * 14, y: 12, width: 8, height: 8) }
        CATransaction.commit()
        icon.frame = NSRect(x: card.minX + 60, y: card.minY + 9, width: 13, height: 13)
        title.frame = NSRect(x: card.minX + 79, y: card.minY + 8, width: card.width - 92, height: 15)
        bigIcon.frame = NSRect(x: card.midX - 17, y: card.midY - 20, width: 34, height: 34)
        hint.frame = NSRect(x: card.minX, y: card.midY + 22, width: card.width, height: 17)
    }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        frameLayer.paint(fill: dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.94, alpha: 1),
                         border: Theme.faint(0.12), in: effectiveAppearance)
        frameLayer.borderWidth = 0.5
        frameLayer.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        frameLayer.shadowOpacity = 1
        frameLayer.shadowRadius = 24
        frameLayer.shadowOffset = CGSize(width: 0, height: -10)
        page.paint(fill: dark ? NSColor(white: 0.12, alpha: 1) : .white, in: effectiveAppearance)
        for dot in dots { dot.backgroundColor = Theme.faint(0.2).cgColor }
    }
}

@MainActor
final class EmptySpaceHintView: FlippedView {
    private let store: BrowserStore
    private let field = EmptySearchField()

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        field.onClick = { store.commandBar = .newTab }
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {}

    override func layout() {
        super.layout()
        let width = min(520, bounds.width - 80)
        field.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.midY - 60, width: width, height: 46)
    }
}

@MainActor
final class ElsewhereHintView: FlippedView {
    private let store: BrowserStore
    private let icon = NSImageView()
    private let title = Label.make("Showing in another window", size: 15, weight: .semibold)
    private let picture = CALayer()

    init(store: BrowserStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .aqua)
        icon.image = .symbol("macwindow.on.rectangle", size: 28)
        icon.contentTintColor = .tertiaryLabelColor
        title.alignment = .center
        title.textColor = .secondaryLabelColor
        for view in [icon, title] as [NSView] { addSubview(view) }
        picture.contentsGravity = .resize
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        let image = store.elsewhereImage
        picture.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        icon.isHidden = image != nil
        title.isHidden = image != nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let top = bounds.midY - 50
        icon.frame = NSRect(x: bounds.midX - 20, y: top, width: 40, height: 34)
        title.frame = NSRect(x: 20, y: top + 46, width: bounds.width - 40, height: 20)
        if let size = store.elsewhereImage?.size, size.width > 0 {
            picture.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.width * size.height / size.width)
        }
    }
}

private final class EmptySearchField: HoverView {
    var onClick: (() -> Void)?
    private let fill = FillLayer()
    private let icon = NSImageView()
    private let placeholder = Label.make("Search or enter address", size: 16, color: .placeholderTextColor)
    private let chip = Label.chip("⌘T")

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.cornerRadius = 12
        layer?.addSublayer(fill)
        icon.image = .symbol("magnifyingglass", size: 15)
        icon.contentTintColor = .secondaryLabelColor
        for view in [icon, placeholder, chip] as [NSView] { addSubview(view) }
        appearance = NSAppearance(named: .aqua)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        icon.frame = NSRect(x: 16, y: bounds.midY - 9, width: 18, height: 18)
        let chipWidth = chip.textWidth + 10
        chip.frame = NSRect(x: bounds.width - 14 - chipWidth, y: bounds.midY - 9, width: chipWidth, height: 18)
        placeholder.frame = NSRect(x: 44, y: bounds.midY - 10, width: chip.frame.minX - 52, height: 20)
    }

    override func updateLayer() {
        fill.paint(fill: NSColor(white: hovering ? 0.94 : 0.965, alpha: 1), border: .black.withAlphaComponent(0.07),
                   in: effectiveAppearance)
        fill.borderWidth = 0.5
        chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
