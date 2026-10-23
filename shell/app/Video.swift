import AppKit

// H.264 and AAC, which the engine can't decode, play by being converted in
// the page (shell/resources/media). The core keeps the setting; the engine
// applies it to pages loaded afterwards.
extension BrowserStore {
    var convertsVideo: Bool { snapshot.convertVideo }

    func setConvertsVideo(_ enabled: Bool) {
        core.setConvertVideo(enabled: enabled)
        MBEngine.setConvertsVideo(enabled)
        refresh()
    }
}
