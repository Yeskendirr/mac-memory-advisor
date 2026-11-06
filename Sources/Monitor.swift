import SwiftUI
import AppKit
import Darwin

enum SortKey: String, CaseIterable, Identifiable {
    case memory = "By memory", cpu = "By CPU", files = "By open files", age = "By uptime", name = "By name"
    var id: String { rawValue }
}

enum Mode: String, CaseIterable, Identifiable {
    case disks = "Disks", ram = "RAM"
    var id: String { rawValue }
}

enum MemFilter: String, CaseIterable, Identifiable {
    case all = "All", safe = "Safe to quit", careful = "Be careful", critical = "System"
    var id: String { rawValue }
    func matches(_ g: ProcGroup) -> Bool {
        switch self {
        case .all: return true
        case .safe: return g.assessment?.level == .safe
        case .careful: return g.assessment?.level == .careful
        case .critical: return g.assessment?.level == .critical
        }
    }
}

struct InfoAlert: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct EjectFailure: Identifiable {
    let id = UUID()
    let volume: VolumeInfo
    let message: String
}

@MainActor
final class Monitor: ObservableObject {
    @Published var volumes: [VolumeInfo] = []
    @Published var selectedID: String = ""
    @Published var groups: [ProcGroup] = []
    @Published var selection: Set<String> = []
    @Published var sortKey: SortKey = .memory
    @Published var stopping: [String: Date] = [:]
    @Published var busy = false
    @Published var busyText = ""
    @Published var lastUpdate: Date?
    @Published var alert: InfoAlert?
    @Published var ejectFailure: EjectFailure?
    @Published var holdersReport: InfoAlert?
    @Published var mode: Mode = .disks
    @Published var ram = RAMSummary()
    @Published var memFilter: MemFilter = .all
    private var lastMemScan: Date?
    private var stoppingTitles: [String: String] = [:]
    private var stuckLogged: Set<String> = []

    init() {
        if UserDefaults.standard.string(forKey: "startMode") == "ram" { mode = .ram }   // for testing: -startMode ram
        AppLog.write("app started, tab \"\(mode.rawValue)\"")
    }

    let totalRAM = Double(ProcessInfo.processInfo.physicalMemory)
    private let scanner = Scanner()
    private let scanQueue = DispatchQueue(label: "diskmonitor.scan", qos: .userInitiated)
    private var scanning = false
    static let stuckAfter: TimeInterval = 20

    var selectedVolume: VolumeInfo? { volumes.first { $0.id == selectedID } }

    var availableSorts: [SortKey] { mode == .ram ? [.memory, .cpu, .age, .name] : [.memory, .cpu, .files, .name] }
    var visibleGroups: [ProcGroup] { mode == .ram ? groups.filter { memFilter.matches($0) } : groups }
    var userRAM: UInt64 { groups.filter { !$0.id.hasPrefix("sysother:") }.reduce(0) { $0 + $1.memory } }   // your own processes only (system ones report RSS, not footprint)
    var reclaimable: UInt64 { groups.filter { $0.assessment?.level == .safe }.reduce(0) { $0 + $1.memory } }
    var reclaimableCount: Int { groups.filter { $0.assessment?.level == .safe }.count }

    var sortedGroups: [ProcGroup] {
        let g = visibleGroups
        switch sortKey {
        case .memory: return g.sorted { $0.memory > $1.memory }
        case .cpu:    return g.sorted { $0.cpu > $1.cpu }
        case .files:  return g.sorted { $0.files > $1.files }
        case .age:    return g.sorted { $0.ageSeconds > $1.ageSeconds }
        case .name:   return g.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }
    var stoppable: [ProcGroup] { groups.filter { !$0.isProtected } }
    var selectedGroups: [ProcGroup] { groups.filter { selection.contains($0.id) && !$0.isProtected } }
    var stuckSelected: [ProcGroup] { selectedGroups.filter { isStuck($0.id) } }

    func isStuck(_ id: String) -> Bool {
        guard let t = stopping[id] else { return false }
        return Date().timeIntervalSince(t) > Monitor.stuckAfter
    }

    // MARK: Refresh

    func switchMode(_ new: Mode) {
        guard new != mode else { return }
        mode = new
        sortKey = .memory
        groups = []; selection = []; stopping = [:]; lastUpdate = nil; lastMemScan = nil
        refresh()
    }

    func refresh() {
        if mode == .ram {
            if let t = lastMemScan, Date().timeIntervalSince(t) < 4.5, !groups.isEmpty { return }
            guard !scanning else { return }
            scanning = true
            lastMemScan = Date()
            scanQueue.async { [scanner] in
                let r = scanner.scanAll()
                Task { @MainActor in self.applyRAM(r.groups, r.ram) }
            }
            return
        }
        let vols = loadVolumes()
        volumes = vols
        if selectedVolume == nil {
            let start = UserDefaults.standard.string(forKey: "startVolume")      // for testing: -startVolume /
            selectedID = vols.first(where: { $0.id == start })?.id
                ?? vols.first(where: { !$0.isInternal })?.id ?? vols.first?.id ?? ""
        }
        guard let vol = selectedVolume, !scanning else { return }
        // lsof over the whole internal volume is heavy - poll it at most once per 12 seconds
        if vol.isInternal, let t = lastUpdate, Date().timeIntervalSince(t) < 12, !groups.isEmpty { return }
        scanning = true
        scanQueue.async { [scanner] in
            let g = scanner.scan(vol)
            Task { @MainActor in self.apply(g, for: vol.id) }
        }
    }

    private func applyRAM(_ g: [ProcGroup], _ r: RAMSummary) {
        scanning = false
        guard mode == .ram else { return }
        groups = g
        ram = r
        let ids = Set(g.map(\.id))
        selection = selection.intersection(ids)
        reconcileStopping(ids)
        lastUpdate = Date()
    }

    private func apply(_ g: [ProcGroup], for volID: String) {
        scanning = false
        guard mode == .disks, volID == selectedID else { return }
        groups = g
        let ids = Set(g.map(\.id))
        selection = selection.intersection(ids)
        reconcileStopping(ids)
        lastUpdate = Date()
    }

    private func reconcileStopping(_ ids: Set<String>) {
        for (id, t) in stopping where !ids.contains(id) {
            AppLog.write("exited: \"\(stoppingTitles[id] ?? id)\" after \(Int(Date().timeIntervalSince(t))) s")
            stoppingTitles[id] = nil; stuckLogged.remove(id)
        }
        for (id, t) in stopping where ids.contains(id) && Date().timeIntervalSince(t) > Monitor.stuckAfter && !stuckLogged.contains(id) {
            stuckLogged.insert(id)
            AppLog.write("DID NOT exit within \(Int(Monitor.stuckAfter)) s: \"\(stoppingTitles[id] ?? id)\"")
        }
        stopping = stopping.filter { ids.contains($0.key) }
    }

    func volumeChanged() {
        groups = []
        selection = []
        stopping = [:]
        refresh()
    }

    private func scanAsync(_ vol: VolumeInfo) async -> [ProcGroup] {
        await withCheckedContinuation { cont in
            scanQueue.async { [scanner] in cont.resume(returning: scanner.scan(vol)) }
        }
    }

    // MARK: Stopping

    func selectAll() {
        // in RAM mode "select all" picks only what is safe to quit (not Docker, not editors holding data)
        let pool = mode == .ram ? stoppable.filter { $0.assessment?.level == .safe } : stoppable
        selection = Set(pool.map(\.id))
    }
    func clearSelection() { selection = [] }

    func stopSelected() { stop(Set(selectedGroups.map(\.id)), force: false) }
    func forceSelected() { stop(Set(selectedGroups.map(\.id)), force: true) }

    func stop(_ ids: Set<String>, force: Bool) {
        for g in groups where ids.contains(g.id) && !g.isProtected {
            stopping[g.id] = Date()
            stoppingTitles[g.id] = g.title
            AppLog.write("stop (\(force ? "FORCE" : "graceful")): \"\(g.title)\" pid=\(g.procs.map { String($0.pid) }.joined(separator: ",")) memory=\(fmtMem(g.memory)) uptime=\(fmtAge(g.ageSeconds)) tab=\(mode.rawValue)")
            if let app = g.appPath {
                // the app itself + nested helper apps (e.g. RobloxMenuBar.app inside Roblox.app).
                // Quit nested ones first, otherwise they relaunch the main app.
                let running = NSWorkspace.shared.runningApplications.filter {
                    guard let path = $0.bundleURL?.path else { return false }
                    return path == app || path.hasPrefix(app + "/")
                }.sorted { ($0.bundleURL?.path.count ?? 0) > ($1.bundleURL?.path.count ?? 0) }
                if !running.isEmpty {
                    AppLog.write("  quitting as application: " + running.map { ($0.bundleURL?.lastPathComponent ?? "?") + "[\($0.processIdentifier)]" }.joined(separator: ", "))
                    for r in running { if force { _ = r.forceTerminate() } else { _ = r.terminate() } }
                    // windowless helpers without Quit support (crash handlers etc.) - send a plain SIGTERM
                    let covered = Set(running.map { $0.processIdentifier })
                    // only processes INSIDE the .app bundle; the Docker VM (a system process) is never signalled directly -
                    // it must stop by itself when Docker quits normally
                    if !force { for p in g.procs where !covered.contains(p.pid) && p.path.hasPrefix(app + "/") { kill(p.pid, SIGTERM) } }
                    continue
                }
            }
            for p in g.procs { signal(p, force: force) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    private func signal(_ p: ProcRow, force: Bool) {
        if force { kill(p.pid, SIGKILL); return }
        if p.command.contains("qemu-system") {                 // Android emulator - stop cleanly via adb
            DispatchQueue.global().async { if !Monitor.emulatorKill() { kill(p.pid, SIGTERM) } }
            return
        }
        if p.name == "postgres", p.command.contains(" -D ") { kill(p.pid, SIGINT); return }   // fast shutdown
        kill(p.pid, SIGTERM)
    }

    nonisolated static func emulatorKill() -> Bool {
        let home = NSHomeDirectory()
        let env = ProcessInfo.processInfo.environment
        let sdkRoots = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], "\(home)/Library/Android/sdk"].compactMap { $0 }
        let candidates = sdkRoots.map { "\($0)/platform-tools/adb" } + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        func run(_ args: [String]) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: adb); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }
        let devs = run(["devices"]).split(separator: "\n").compactMap { l -> String? in
            let t = l.split(separator: "\t"); return (t.count == 2 && t[0].hasPrefix("emulator-")) ? String(t[0]) : nil
        }
        if devs.isEmpty { return false }
        for d in devs { _ = run(["-s", d, "emu", "kill"]) }
        return true
    }

    // MARK: Eject

    func requestEject() {
        guard let vol = selectedVolume, !vol.isInternal else { return }
        if stoppable.isEmpty { eject(vol) } else { pendingEjectConfirm = true }
    }
    @Published var pendingEjectConfirm = false

    func stopAllAndEject() {
        guard let vol = selectedVolume else { return }
        stop(Set(stoppable.map(\.id)), force: false)
        busy = true; busyText = String(localized: "Stopping processes...")
        Task {
            var waited = 0
            var left: [ProcGroup] = []
            while waited < 90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000); waited += 2
                left = await scanAsync(vol).filter { !$0.isProtected }
                busyText = left.isEmpty ? String(localized: "Ejecting disk...") : String(localized: "Waiting for: \(left.prefix(3).map(\.title).joined(separator: ", "))")
                if left.isEmpty { break }
            }
            if left.isEmpty {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                eject(vol)
            } else {
                busy = false
                alert = InfoAlert(title: String(localized: "Some processes did not quit"),
                                  text: String(localized: "Still running: \(left.map(\.title).joined(separator: ", ")).\nThe disk was left mounted. Quit them manually or use \"Force quit\" (unsaved data may be lost)."))
                refresh()
            }
        }
    }

    func eject(_ vol: VolumeInfo) {
        busy = true; busyText = String(localized: "Ejecting \"\(vol.name)\"...")
        AppLog.write("eject \"\(vol.name)\" (\(vol.id)): attempt")
        let url = URL(fileURLWithPath: vol.id)
        DispatchQueue.global().async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                Task { @MainActor in
                    self.busy = false
                    AppLog.write("eject \"\(vol.name)\": SUCCESS")
                    self.alert = InfoAlert(title: String(localized: "Disk ejected"), text: String(localized: "\"\(vol.name)\" can be safely unplugged."))
                    self.selectedID = ""
                    self.volumeChanged()
                }
            } catch {
                Task { @MainActor in
                    self.busy = false
                    AppLog.write("eject \"\(vol.name)\": REFUSED - \(error.localizedDescription)")
                    self.ejectFailure = EjectFailure(volume: vol, message: error.localizedDescription)
                    self.refresh()
                }
            }
        }
    }

    // MARK: Diagnostics for system-level holders (needs an administrator password)

    private func adminShell(_ shell: String) -> (ok: Bool, out: String) {
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        let r = NSAppleScript(source: "do shell script \"\(esc)\" with administrator privileges")?.executeAndReturnError(&err)
        if let e = err {
            if (e[NSAppleScript.errorNumber] as? Int) == -128 { return (false, "") }   // user cancelled
            return (false, (e[NSAppleScript.errorMessage] as? String) ?? String(localized: "error"))
        }
        return (true, r?.stringValue ?? "")
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func whoHolds(_ vol: VolumeInfo) {
        let r = adminShell("/usr/sbin/lsof -nP -w \(q(vol.id)) | /usr/bin/awk 'NR>1{print $1, $2, $3}' | /usr/bin/sort -u")
        if !r.ok && r.out.isEmpty { return }
        var text = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.ok { holdersReport = InfoAlert(title: String(localized: "Could not get the list"), text: text); return }
        if text.isEmpty { text = String(localized: "Nothing holds files on this volume.") }
        let lower = text.lowercased()
        var hint = ""
        if lower.contains("mds") || lower.contains("mdworker") {
            hint = "\n\n" + String(localized: "-> Spotlight (mds / mdworker) is holding this disk. Use \"Turn off Spotlight\" to disable indexing for this volume.")
        } else if lower.contains("fseventsd") {
            hint = "\n\n" + String(localized: "-> fseventsd normally lets go during eject; if not, wait a few seconds and retry.")
        }
        AppLog.write("who holds \"\(vol.name)\": " + text.replacingOccurrences(of: "\n", with: " | "))
        holdersReport = InfoAlert(title: String(localized: "What holds \"\(vol.name)\"  (process  PID  user)"), text: text + hint)
    }

    private func userRun(_ exe: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    func disableSpotlight(_ vol: VolumeInfo) {
        // mdutil exits 0 even on error - so inspect the text and re-check the status ourselves
        let alt = "/System/Volumes/Data" + vol.id
        let script = "out=$(/usr/bin/mdutil -i off \(q(vol.id)) 2>&1); case \"$out\" in *rror*) out=$(/usr/bin/mdutil -i off \(q(alt)) 2>&1);; esac; echo \"$out\""
        let r = adminShell(script)
        if !r.ok && r.out.isEmpty { return }            // user cancelled the password prompt
        let status = userRun("/usr/bin/mdutil", ["-s", vol.id])
        let off = status.lowercased().contains("disabled")
        AppLog.write("Spotlight on \"\(vol.name)\": " + (off ? "disabled (verified)" : "NOT disabled - \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))"))
        if off {
            holdersReport = InfoAlert(title: String(localized: "Spotlight turned off"),
                                      text: String(localized: "Indexing on \"\(vol.name)\" is off (verified). Try ejecting again."))
        } else {
            let cmd = "sudo mdutil -i off \(vol.id)"
            holdersReport = InfoAlert(title: String(localized: "Spotlight was NOT turned off"),
                                      text: String(localized: "macOS did not let the app change the indexing state:\n\(r.out.trimmingCharacters(in: .whitespacesAndNewlines))\n\nRun this in Terminal instead:\n\n\(cmd)\n\nThen try ejecting again."))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }
}
