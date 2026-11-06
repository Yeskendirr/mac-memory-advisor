import Foundation
import AppKit
import Darwin

// MARK: - Models

struct VolumeInfo: Identifiable, Hashable {
    let id: String          // mount point (used for eject)
    let scanPath: String    // path passed to lsof (for the system volume: the Data volume)
    let name: String
    let isInternal: Bool
    let total: Int64
    let free: Int64
    var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

struct ProcRow: Hashable {
    let pid: Int32
    let ppid: Int32
    let name: String
    let path: String
    let command: String
    var memory: UInt64
    var cpu: Double
    var files: Int
    var started: Date? = nil
    var ports: [Int] = []
    var clients: Int = 0
    var cwd: String? = nil
}

struct ProcGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let appPath: String?
    let isProtected: Bool
    var procs: [ProcRow]
    var assessment: Assessment? = nil

    var started: Date? { procs.compactMap(\.started).min() }
    var ageSeconds: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }
    var ports: [Int] { Array(Set(procs.flatMap(\.ports))).sorted() }
    var clients: Int { procs.reduce(0) { $0 + $1.clients } }

    var memory: UInt64 { procs.reduce(0) { $0 + $1.memory } }
    var cpu: Double { procs.reduce(0) { $0 + $1.cpu } }
    var files: Int { procs.reduce(0) { $0 + $1.files } }
}

// MARK: - Volumes

func loadVolumes() -> [VolumeInfo] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
                                  .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                  .volumeAvailableCapacityForImportantUsageKey]
    guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                           options: [.skipHiddenVolumes]) else { return [] }
    var out: [VolumeInfo] = []
    for u in urls {
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
        if v.volumeIsLocal != true || v.volumeIsBrowsable != true { continue }
        let path = u.path
        let isRoot = path == "/"
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        out.append(VolumeInfo(id: path,
                              scanPath: isRoot ? "/System/Volumes/Data" : path,
                              name: v.volumeName ?? (path as NSString).lastPathComponent,
                              isInternal: (v.volumeIsInternal ?? false) || isRoot,
                              total: Int64(v.volumeTotalCapacity ?? 0),
                              free: free))
    }
    return out.sorted { a, b in
        if a.isInternal != b.isInternal { return a.isInternal }
        return a.name < b.name
    }
}

// MARK: - Process scanner

final class Scanner: @unchecked Sendable {   // only ever called from one serial queue
    var prevCPU: [Int32: (cpuNs: UInt64, at: UInt64)] = [:]
    var prevCPUAll: [Int32: (cpuNs: UInt64, at: UInt64)] = [:]
    var tb = mach_timebase_info_data_t()
    let myUID = getuid()
    let myPID = getpid()

    init() { mach_timebase_info(&tb) }

    func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func procPath(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    func usage(_ pid: Int32) -> (mem: UInt64, cpuNs: UInt64)? {
        var ri = rusage_info_current()
        let r = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        if r != 0 { return nil }
        let cpu = (ri.ri_user_time &+ ri.ri_system_time) &* UInt64(tb.numer) / UInt64(max(tb.denom, 1))
        return (ri.ri_phys_footprint, cpu)
    }

    static func outerApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<r.lowerBound]) + ".app"
    }

    static func isSystemPath(_ p: String) -> Bool {
        p.hasPrefix("/System/") || p.hasPrefix("/usr/libexec/") || p.hasPrefix("/usr/sbin/") || p.hasPrefix("/sbin/")
    }

    static let protectedNames: Set<String> = [
        "launchd", "Finder", "Dock", "WindowServer", "loginwindow", "SystemUIServer", "kernel_task", "MemoryAdvisor",
        "ControlCenter", "NotificationCenter", "Spotlight", "WindowManager"
    ]

    func scan(_ vol: VolumeInfo) -> [ProcGroup] {
        // 1. who has files open on the volume (and how many)
        let lsofOut = run("/usr/sbin/lsof", ["-nP", "-w", "-F", "pf", vol.scanPath])
        var files: [Int32: Int] = [:]
        var cur: Int32 = 0
        for line in lsofOut.split(separator: "\n") {
            guard let c = line.first else { continue }
            if c == "p" { cur = Int32(line.dropFirst()) ?? 0; if cur != 0 { files[cur, default: 0] += 0 } }
            else if c == "f", cur != 0 { files[cur, default: 0] += 1 }
        }
        files[myPID] = nil
        let pids = files.keys.sorted()
        if pids.isEmpty { return [] }

        // 2. ppid / uid / command line
        let psOut = run("/bin/ps", ["-ww", "-o", "pid=,ppid=,uid=,command=", "-p", pids.map(String.init).joined(separator: ",")])
        var info: [Int32: (ppid: Int32, uid: UInt32, cmd: String)] = [:]
        for line in psOut.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let uid = UInt32(parts[2]) else { continue }
            info[pid] = (ppid, uid, parts.count > 3 ? String(parts[3]) : "")
        }

        // 3. memory and CPU
        let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var newPrev: [Int32: (cpuNs: UInt64, at: UInt64)] = [:]
        var rows: [ProcRow] = []
        for pid in pids {
            guard let i = info[pid], i.uid == myUID else { continue }   // processes of other users / root are skipped
            let path = procPath(pid)
            var name = path.isEmpty ? String(i.cmd.split(separator: " ").first ?? "?") : (path as NSString).lastPathComponent
            if name.first?.isNumber == true, name.allSatisfy({ $0.isNumber || $0 == "." }) {
                // the binary is named after a version (e.g. "2.1.318") - use argv[0] as the real name
                let argv0 = ((i.cmd.split(separator: " ").first.map(String.init) ?? "") as NSString).lastPathComponent
                if !argv0.isEmpty, argv0.first?.isNumber != true { name = argv0 }
            }
            var mem: UInt64 = 0
            var cpu = 0.0
            if let u = usage(pid) {
                mem = u.mem
                newPrev[pid] = (u.cpuNs, nowNs)
                if let p = prevCPU[pid], nowNs > p.at, u.cpuNs >= p.cpuNs {
                    cpu = Double(u.cpuNs - p.cpuNs) / Double(nowNs - p.at) * 100.0
                }
            }
            rows.append(ProcRow(pid: pid, ppid: i.ppid, name: name, path: path, command: i.cmd,
                                memory: mem, cpu: cpu, files: files[pid] ?? 0))
        }
        prevCPU = newPrev

        // 4. grouping: whole apps, system processes by name, everything else one by one
        let dockerApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.docker.docker" }
        let home = NSHomeDirectory()
        var groups: [String: ProcGroup] = [:]
        var order: [String] = []

        func add(_ key: String, _ make: () -> ProcGroup, _ row: ProcRow) {
            if groups[key] == nil { groups[key] = make(); order.append(key) }
            groups[key]!.procs.append(row)
        }

        for var row in rows {
            row.cpu = max(0, row.cpu)
            let system = Scanner.isSystemPath(row.path)
            let protectedName = Scanner.protectedNames.contains(row.name)

            if row.name.contains("Virtualization.VirtualMachine"), let d = dockerApp, let url = d.bundleURL {
                let key = "app:" + url.path
                add(key, { ProcGroup(id: key, title: "Docker Desktop", subtitle: String(localized: "virtual machine with your images and containers"),
                                     appPath: url.path, isProtected: false, procs: []) }, row)
            } else if let app = Scanner.outerApp(row.path) {
                let key = "app:" + app
                let title = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
                add(key, { ProcGroup(id: key, title: title, subtitle: String(localized: "application"),
                                     // only system shells are protected (Finder, Dock, Control Center...);
                                     // Safari, Terminal and other regular apps can be stopped
                                     appPath: app, isProtected: app.hasPrefix("/System/Library/") || protectedName, procs: []) }, row)
            } else if system || protectedName {
                let key = "sys:" + row.name
                let pretty = row.name.contains("Virtualization.VirtualMachine") ? String(localized: "Virtual machine") : row.name
                add(key, { ProcGroup(id: key, title: pretty, subtitle: String(localized: "macOS system process"),
                                     appPath: nil, isProtected: true, procs: []) }, row)
            } else {
                var args = row.command
                if !row.path.isEmpty, args.hasPrefix(row.path) { args = String(args.dropFirst(row.path.count)) }
                args = args.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: home, with: "~")
                if args.count > 110 { args = String(args.prefix(110)) + "…" }
                let key = "pid:\(row.pid)"
                add(key, { ProcGroup(id: key, title: row.name, subtitle: args.isEmpty ? row.path : args,
                                     appPath: nil, isProtected: false, procs: []) }, row)
            }
        }
        return order.compactMap { groups[$0] }
    }
}
