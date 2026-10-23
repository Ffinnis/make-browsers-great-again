import AppKit
import CryptoKit

/// Keeps MBGA up to date, as Arc does: it checks the releases on GitHub now
/// and then, downloads a new version in the background, and offers to
/// restart into it from the foot of the sidebar. Quitting installs it too.
///
/// A release carries update.json, naming its archive with the archive's
/// SHA-256 signed by the release key (Ed25519). The archive is checked
/// against the key built into this copy before anything is unpacked, and
/// the app inside must be MBGA and newer than this one.
@MainActor
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        case failed(String)
    }

    /// What the updater is doing, or found last.
    private(set) var state = State.idle {
        didSet { if state != oldValue { BrowserStore.updateChanged() } }
    }
    /// The version unpacked and waiting: restarting, or quitting, installs
    /// it. It stays while MBGA looks for a newer one.
    private(set) var readyVersion: String? {
        didSet { if readyVersion != oldValue { BrowserStore.updateChanged() } }
    }
    /// Checks and installs on its own. Off, it only checks when asked.
    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticKey)
            schedule()
        }
    }
    /// The card in the sidebar was hidden: the update still installs on quit.
    private(set) var cardHidden = false

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Where releases are announced. Builds from source have none, unless
    /// MBGA_UPDATE_FEED names one (a file:// URL works, for trying updates).
    private let feed: URL?
    private let publicKey: Curve25519.Signing.PublicKey?
    private var scheduler: NSBackgroundActivityScheduler?
    /// Set by Restart to Update: MBGA opens again once it's replaced.
    private var relaunch = false

    private static let automaticKey = "AutomaticUpdates"
    private static let lastCheckKey = "LastUpdateCheck"
    private static let lastVersionKey = "LastRunVersion"
    /// Arc looks a few times a day; so does MBGA, when the Mac isn't busy.
    private static let interval: TimeInterval = 4 * 3600
    private nonisolated static let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.mbga.browser/Update", isDirectory: true)

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = ProcessInfo.processInfo.environment["MBGA_UPDATE_FEED"] ?? info["MBGAUpdateFeed"] as? String
        self.feed = feed.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        publicKey = (info["MBGAUpdatePublicKey"] as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    var isDownloading: Bool {
        if case .downloading = state { true } else { false }
    }

    /// Whether this copy can update itself at all.
    var available: Bool { feed != nil && publicKey != nil }

    /// At launch: picks up an update downloaded earlier, says what just
    /// got installed, and starts checking.
    func start(store: BrowserStore) {
        let defaults = UserDefaults.standard
        if let last = defaults.string(forKey: Self.lastVersionKey), last != currentVersion,
           Self.isNewer(currentVersion, than: last) {
            store.showToast(Toast(message: "Updated to MBGA \(currentVersion)", symbol: "sparkles"), duration: 6)
        }
        defaults.set(currentVersion, forKey: Self.lastVersionKey)
        guard available else { return }
        if let staged = Self.stagedVersion(), Self.isNewer(staged, than: currentVersion) {
            readyVersion = staged
        } else {
            try? FileManager.default.removeItem(at: Self.staging)
        }
        schedule()
    }

    private func schedule() {
        scheduler?.invalidate()
        scheduler = nil
        guard available, automatic else { return }
        // Not while the first pages load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.mbga.browser.update-check")
        scheduler.repeats = true
        scheduler.interval = Self.interval
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] done in
            DispatchQueue.main.async { self?.check(userInitiated: false) }
            done(.finished)
        }
        self.scheduler = scheduler
    }

    // MARK: Checking and downloading

    /// Looks for a newer version and downloads it. Asked from the menu, the
    /// answer shows in a toast.
    func check(userInitiated: Bool) {
        let store = BrowserStore.front
        guard let feed, let publicKey else {
            if userInitiated {
                store?.showToast(Toast(message: "This copy of MBGA was built from source and doesn't update itself",
                                       symbol: "hammer"), duration: 6)
            }
            return
        }
        switch state {
        case .checking, .downloading: return
        default: break
        }
        if userInitiated, let version = readyVersion {
            cardHidden = false
            BrowserStore.updateChanged()
            store?.showToast(Toast(message: "MBGA \(version) is ready: restart to update", symbol: "arrow.down.circle"))
            return
        }
        // Background checks: a few times a day is plenty.
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if !userInitiated, Date().timeIntervalSince(lastCheck) < Self.interval / 2 { return }
        if let problem = installProblem {
            state = .failed(problem)
            if userInitiated { store?.showToast(Toast(message: problem, symbol: "exclamationmark.triangle"), duration: 8) }
            return
        }
        let current = readyVersion ?? currentVersion
        state = .checking
        Task {
            do {
                let release = try await Self.latest(from: feed)
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard Self.isNewer(release.version, than: current),
                      release.minimumSystemVersion.map(Self.systemSupports) ?? true
                else {
                    state = .upToDate
                    if userInitiated {
                        BrowserStore.front?.showToast(Toast(message: "MBGA \(current) is the latest version"))
                    }
                    return
                }
                state = .downloading(version: release.version)
                if userInitiated {
                    BrowserStore.front?.showToast(Toast(message: "Downloading MBGA \(release.version)…",
                                                        symbol: "arrow.down.circle"))
                }
                try await Self.download(release, publicKey: publicKey, current: currentVersion)
                cardHidden = false
                readyVersion = release.version
                state = .idle
            } catch {
                NSLog("update: %@", String(describing: error))
                state = .failed(Self.describe(error))
                if userInitiated {
                    BrowserStore.front?.showToast(Toast(message: Self.describe(error), symbol: "exclamationmark.triangle"),
                                                  duration: 8)
                }
            }
        }
    }

    /// Why MBGA couldn't replace itself where it is, if it couldn't.
    private var installProblem: String? {
        let app = Bundle.main.bundleURL
        // Opened straight from Downloads, macOS runs a read-only copy.
        if app.path.contains("/AppTranslocation/") {
            return "Move MBGA to Applications to get updates"
        }
        let folder = app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder),
              FileManager.default.isWritableFile(atPath: app.path)
        else { return "MBGA can't update itself in \(folder)" }
        return nil
    }

    struct Release: Decodable {
        let version: String
        let url: URL
        let size: Int?
        let sha256: String
        /// Base64 Ed25519 signature of the archive's SHA-256.
        let signature: String
        let minimumSystemVersion: String?
    }

    enum Failure: Error {
        case feed, download, tampered, unpack, notNewer
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case Failure.feed: "Couldn't reach MBGA's releases"
        case Failure.download: "The update didn't download"
        case Failure.tampered: "The update wasn't signed by MBGA's key, so it was thrown away"
        case Failure.unpack, Failure.notNewer: "The update couldn't be unpacked"
        default: "Couldn't check for updates: \(error.localizedDescription)"
        }
    }

    private nonisolated static func latest(from feed: URL) async throws -> Release {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("MBGA", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.feed }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw Failure.feed }
        return release
    }

    /// Downloads, verifies and unpacks the release into the staging folder.
    private nonisolated static func download(_ release: Release, publicKey: Curve25519.Signing.PublicKey,
                                             current: String) async throws {
        let (file, response) = try await URLSession.shared.download(from: release.url)
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.download }
        try await Task.detached(priority: .utility) {
            let digest = try sha256(of: file)
            guard digest.hex == release.sha256.lowercased(),
                  let signature = Data(base64Encoded: release.signature),
                  publicKey.isValidSignature(signature, for: Data(digest))
            else { throw Failure.tampered }

            let fm = FileManager.default
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try? fm.removeItem(at: unpacked)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            guard run("/usr/bin/ditto", ["-x", "-k", file.path, unpacked.path]),
                  let app = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                      .first(where: { $0.pathExtension == "app" }),
                  let info = info(of: app),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
            else { throw Failure.unpack }
            guard let version = info["CFBundleShortVersionString"] as? String,
                  version == release.version, isNewer(version, than: current)
            else { throw Failure.notNewer }
            let staged = staging.appendingPathComponent("MBGA.app")
            try? fm.removeItem(at: staged)
            try fm.moveItem(at: app, to: staged)
            try? fm.removeItem(at: unpacked)
        }.value
    }

    private nonisolated static func sha256(of file: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize()
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private nonisolated static func stagedVersion() -> String? {
        info(of: staging.appendingPathComponent("MBGA.app"))?["CFBundleShortVersionString"] as? String
    }

    /// Read afresh: Bundle remembers what it read at a path.
    private nonisolated static func info(of app: URL) -> [String: Any]? {
        (try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }

    /// Whether `a` is a later version than `b` ("0.0.10" is after "0.0.9").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private nonisolated static func systemSupports(_ minimum: String) -> Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return !isNewer(minimum, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    // MARK: Installing

    /// Quits, puts the new version in place and opens it again, where you
    /// left off.
    func restartToUpdate() {
        guard readyVersion != nil else { return }
        relaunch = true
        NSApp.terminate(nil)
    }

    func hideCard() {
        cardHidden = true
        BrowserStore.updateChanged()
    }

    /// Called as MBGA exits, once the engine has shut down. A downloaded
    /// update replaces this copy as soon as the process is gone; a script
    /// does it, since nothing can replace an app while it runs.
    func installOnExit() {
        guard readyVersion != nil else { return }
        let staged = Self.staging.appendingPathComponent("MBGA.app")
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.1; done
        old="$2.replaced-$$"
        if mv "$2" "$old"; then
          if mv "$3" "$2"; then rm -rf "$old"; else mv "$old" "$2"; fi
        fi
        app="$2"; again="$4"; shift 4
        [ "$again" = 1 ] && open "$@" "$app"
        exit 0
        """
        // Opened again with the same MBGA_ settings, such as another data
        // folder: `open` doesn't pass on the environment.
        let environment = ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("MBGA_") }
            .flatMap { ["--env", "\($0.key)=\($0.value)"] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "mbga-update", String(getpid()), Bundle.main.bundleURL.path, staged.path,
                             relaunch ? "1" : "0"] + environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Updater {
    /// Where updating stands, for Settings.
    var statusText: String {
        let version = "This is MBGA \(currentVersion)."
        guard available else { return "\(version) Built from source, it doesn't update itself." }
        switch state {
        case .checking: return "\(version) Checking for updates…"
        case .downloading(let next): return "\(version) Downloading \(next)…"
        case .upToDate: return "\(version) It's the latest version."
        case .failed(let problem): return "\(version) \(problem)."
        case .idle: return "\(version) Updates download in the background and install when you restart."
        }
    }
}
