import AppKit

extension BrowserStore {
    var convertsVideo: Bool { snapshot.convertVideo }

    func setConvertsVideo(_ enabled: Bool) {
        core.setConvertVideo(enabled: enabled)
        MBEngine.setConvertsVideo(enabled)
        refresh()
    }
}
