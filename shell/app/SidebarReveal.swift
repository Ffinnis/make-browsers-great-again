import AppKit

@MainActor
final class SidebarReveal {
    private weak var store: BrowserStore?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var menuOpen = false

    private let intentDelay: TimeInterval = 0.12
    private let graceDelay: TimeInterval = 0.3
    private let reach: CGFloat = 24
    private let edge: CGFloat = 6

    init(store: BrowserStore) {
        self.store = store
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuOpen = false
                self?.pointerMoved()
            }
        })
    }

    private var sidebarWidth: CGFloat {
        UserDefaults.standard.object(forKey: "sidebarWidth") as? CGFloat ?? 260
    }

    private enum Zone { case edge, reach, away }

    private func zone() -> Zone {
        guard let window = store?.window, window.isVisible, NSApp.isActive else { return .away }
        let frame = window.frame
        let point = NSEvent.mouseLocation
        let x = point.x - frame.minX
        let fromTop = frame.maxY - point.y
        guard fromTop >= -reach, point.y >= frame.minY - reach else { return .away }
        if x <= edge, fromTop >= 0, point.y >= frame.minY { return .edge }
        if x <= sidebarWidth + reach { return .reach }
        return .away
    }

    private func pointerMoved() {
        guard let store, store.layout != .full, !store.contentFullscreen else {
            cancelTimers()
            return
        }
        let zone = zone()
        if store.sidebarPeek {
            let held = NSEvent.pressedMouseButtons != 0
            if zone == .away, !menuOpen, !held {
                startOnce(&closeTimer, after: graceDelay) { [weak self] in
                    guard let self, self.zone() == .away, !self.menuOpen else { return }
                    self.store?.sidebarPeek = false
                }
            } else {
                stop(&closeTimer)
            }
            return
        }
        if zone == .edge {
            startOnce(&openTimer, after: intentDelay) { [weak self] in
                guard let self, self.zone() == .edge else { return }
                self.store?.sidebarPeek = true
            }
        } else {
            stop(&openTimer)
        }
    }

    private func startOnce(_ timer: inout Timer?, after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        guard timer?.isValid != true else { return }
        let t = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop(_ timer: inout Timer?) {
        timer?.invalidate()
        timer = nil
    }

    private func cancelTimers() {
        stop(&openTimer)
        stop(&closeTimer)
    }
}
