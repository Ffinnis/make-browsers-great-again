import AppKit
import Darwin

enum ProcessFootprint {
    static func megabytes() -> Int {
        var total: UInt64 = 0
        var queue = [getpid()]
        while let pid = queue.popLast() {
            total += footprint(of: pid)
            queue += children(of: pid)
        }
        return Int(total / (1 << 20))
    }

    private static func footprint(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        return ok ? usage.ri_phys_footprint : 0
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let found = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(found, 0)))).filter { $0 > 0 }
    }
}

extension BrowserStore {
    var memoryLimitMB: UInt32 { snapshot.memoryLimitMb }

    func setMemoryLimit(_ megabytes: UInt32) {
        core.setMemoryLimit(megabytes: megabytes)
        refresh()
        enforceMemoryLimit()
    }

    func prepareForSleep() {
        core.setAgentSpace(spaceId: agentPreferences.ownSpace ? agentPreferences.spaceID : nil)
        for store in Self.open.allObjects {
            for (id, view) in store.views {
                let allowed = [MBSitePermission.notifications, .camera, .microphone].contains { view.state(for: $0) == .allow }
                core.setNotifiesOrCalls(id: id, notifiesOrCalls: allowed)
            }
        }
    }

    func enforceMemoryLimit() {
        guard memoryLimitMB > 0 else { return }
        let sleepers = core.collectOverLimit(usedMb: UInt32(clamping: ProcessFootprint.megabytes()))
        guard !sleepers.isEmpty else { return }
        sleepers.forEach(destroyView)
        setNeedsRefresh()
    }
}
