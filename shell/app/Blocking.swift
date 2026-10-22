import Foundation

enum AdBlocking {
    private static let maxAge: TimeInterval = 4 * 86_400

    nonisolated static func install(core: BrowserCore) {
        MBEngine.setRequestFilter { url, page, kind in
            core.shouldBlock(url: url, page: page, kind: kind)
        } pageScript: { page in
            core.pageScript(page: page)
        } pageReply: { page, report in
            core.cosmeticReply(page: page, report: report)
        } earlyScript: { page in
            core.needsEarlyScript(page: page)
        }
    }

    nonisolated static func reload(core: BrowserCore) async -> Bool {
        await Task.detached(priority: .userInitiated) { core.loadFilters() }.value
    }

    nonisolated static func loadCached(core: BrowserCore) -> Bool {
        core.loadCachedFilters()
    }

    nonisolated static func updateLists(core: BrowserCore, loaded: Bool) {
        Task.detached(priority: .utility) {
            if !loaded { _ = core.loadFilters() }
            let dir = URL(fileURLWithPath: core.filterDir(), isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var changed = false
            for list in core.filterLists() {
                let file = dir.appendingPathComponent(list.fileName)
                let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                guard modified.map({ Date().timeIntervalSince($0) > maxAge }) ?? true,
                      let url = URL(string: list.url),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count > 10_000
                else { continue }
                if (try? data.write(to: file, options: .atomic)) != nil { changed = true }
            }
            if changed { _ = core.loadFilters() }
        }
    }
}
