import AppKit

let hasBrowserDevTools = MBEngine.claimDevToolsPipe()

let dataDirectory = ProcessInfo.processInfo.environment["MBGA_DATA_DIR"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MBGA", isDirectory: true)
let core = BrowserCore(dataDir: dataDirectory.path)
let loadsExtensionHelper = hasBrowserDevTools && core.snapshot().profiles.contains {
    !InstalledExtension.all(in: core.profileDir(profileId: $0.id)).isEmpty
}
MBEngine.setLoadsExtensionHelper(loadsExtensionHelper)

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

let appDelegate = MainActor.assumeIsolated { AppDelegate(core: core) }
app.delegate = appDelegate
MBEngine.runMessageLoop()

_ = core.persist()
MBEngine.shutdown()
MainActor.assumeIsolated { Updater.shared.installOnExit() }
