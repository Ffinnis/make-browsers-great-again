import AppKit

// Before anything opens a file: the descriptors it needs must be free.
let hasBrowserDevTools = MBEngine.claimDevToolsPipe()

// MBGA_DATA_DIR keeps benchmarks and experiments away from real browsing data.
let dataDirectory = ProcessInfo.processInfo.environment["MBGA_DATA_DIR"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MBGA", isDirectory: true)
let core = BrowserCore(dataDir: dataDirectory.path)
// Extensions need the helper to see MBGA's tabs; without any, it'd only cost.
let loadsExtensionHelper = hasBrowserDevTools && core.snapshot().profiles.contains {
    !InstalledExtension.all(in: core.profileDir(profileId: $0.id)).isEmpty
}
MBEngine.setLoadsExtensionHelper(loadsExtensionHelper)

// The engine requires its NSApplication subclass to exist before it starts.
let app = MBApplication.shared
guard MBEngine.start(
    withArgc: CommandLine.argc,
    argv: CommandLine.unsafeArgv,
    rootCachePath: core.engineRootDir(),
    strictSiteIsolation: core.snapshot().strictSiteIsolation,
    isolatedOrigins: core.isolatedOrigins()
) else {
    fatalError("Failed to start the browser engine")
}
MBEngine.setConvertsVideo(core.snapshot().convertVideo)

// main.swift runs on the main thread, which is also the engine's UI thread.
let appDelegate = MainActor.assumeIsolated { AppDelegate(core: core) }
app.delegate = appDelegate
MBEngine.runMessageLoop()

_ = core.persist()
MBEngine.shutdown()
MainActor.assumeIsolated { Updater.shared.installOnExit() }
