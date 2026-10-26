import AppKit

final class EqualizerView: NSView {
    private let bars = (0..<3).map { _ in CALayer() }
    private let durations: [CFTimeInterval] = [0.42, 0.31, 0.53]
    private let rest: [CGFloat] = [0.45, 0.8, 0.6]

    var barColor: NSColor = .labelColor {
        didSet { updateColors() }
    }

    var playing = false {
        didSet {
            let animate = playing && !Motion.reduced
            if animate != animating { animating = animate; updateAnimations() }
        }
    }
    private var animating = false

    var onClick: (() -> Void)?

    func showMuted(_ muted: Bool) {
        alphaValue = muted ? 0.3 : 0.6
        toolTip = muted ? "Muted. Click to unmute" : "Playing. Click to mute"
    }

    override func mouseDown(with event: NSEvent) {
        if onClick == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let onClick else { return super.mouseUp(with: event) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 11) }

    override func layout() {
        super.layout()
        let width: CGFloat = 2.5, gap = (bounds.width - width * 3) / 2
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (width + gap) + width / 2, y: 0)
            if !animating { bar.transform = CATransform3DMakeScale(1, rest[i], 1) }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for bar in bars { bar.backgroundColor = barColor.cgColor }
        }
    }

    private func updateAnimations() {
        for (i, bar) in bars.enumerated() {
            let current = bar.presentation()?.transform
            bar.removeAllAnimations()
            bar.transform = CATransform3DMakeScale(1, rest[i], 1)
            guard animating else {
                if let current, !Motion.reduced, window != nil {
                    let settle = CABasicAnimation(keyPath: "transform")
                    settle.fromValue = current
                    settle.toValue = bar.transform
                    settle.duration = Motion.quick.duration
                    settle.timingFunction = Motion.quick.timing
                    bar.add(settle, forKey: "settle")
                }
                continue
            }
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.25
            bounce.toValue = 1.0
            bounce.duration = durations[i]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.isRemovedOnCompletion = false
            bar.add(bounce, forKey: "bounce")
        }
    }
}
