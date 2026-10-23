import Darwin
import Foundation

guard CommandLine.arguments.count == 2, let root = pid_t(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: sample <root-pid>\n".utf8))
    exit(2)
}

func allPIDs() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) * 2)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(count)))
}

func parent(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

func name(of pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    proc_name(pid, &buf, UInt32(buf.count))
    return String(cString: buf)
}

func processType(of pid: pid_t) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "unknown" }
    let args = buf[4..<size].split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
    func value(_ key: String) -> String? {
        args.first { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }
    }
    guard let type = value("--type=") else { return "browser" }
    if let sub = value("--utility-sub-type=") { return "\(type):\(sub)" }
    return type
}

var children: [pid_t: [pid_t]] = [:]
for pid in allPIDs() where pid > 0 {
    if let p = parent(of: pid) { children[p, default: []].append(pid) }
}
var tree: [pid_t] = []
var queue = [root]
while let pid = queue.popLast() {
    tree.append(pid)
    queue.append(contentsOf: children[pid] ?? [])
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func ns(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) }

var procs: [[String: Any]] = []
var footprint: UInt64 = 0, cpu: UInt64 = 0, energy: UInt64 = 0, wakeups: UInt64 = 0
for pid in tree {
    var usage = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
        }
    }
    guard ok else { continue }
    let cpuNs = ns(usage.ri_user_time + usage.ri_system_time)
    footprint += usage.ri_phys_footprint
    cpu += cpuNs
    energy += usage.ri_energy_nj
    let procWakeups = usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups
    wakeups += procWakeups
    procs.append([
        "pid": pid, "name": name(of: pid), "type": processType(of: pid),
        "footprint": usage.ri_phys_footprint, "cpu_ns": cpuNs, "energy_nj": usage.ri_energy_nj,
        "wakeups": procWakeups,
    ])
}

let out: [String: Any] = [
    "t": Date().timeIntervalSince1970, "count": procs.count,
    "footprint": footprint, "cpu_ns": cpu, "energy_nj": energy, "wakeups": wakeups,
    "procs": procs,
]
print(String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self))
