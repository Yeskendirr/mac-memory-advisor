import Foundation
import AppKit
import Darwin

// MARK: - Types

enum Level { case safe, careful, critical }

struct Assessment {
    let level: Level
    let label: String          // short badge text
    let summary: String        // one-line "why"
    let reasons: [String]      // details
}

struct RAMSummary {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Int = 1      // 1 normal, 2 warning, 4 critical
    var used: UInt64 { app + wired + compressed }
}

func fmtAge(_ s: TimeInterval) -> String {
    let t = Int(max(0, s))
    if t < 60 { return String(localized: "\(t) s") }
    if t < 3600 { return String(localized: "\(t / 60) min") }
    if t < 86400 { return String(localized: "\(t / 3600) h \((t % 3600) / 60) min") }
    let d = t / 86400, h = (t % 86400) / 3600
    return h > 0 ? String(localized: "\(d) d \(h) h") : String(localized: "\(d) d")
}

// MARK: - RAM summary

func readRAM() -> RAMSummary {
    var r = RAMSummary()
    r.total = ProcessInfo.processInfo.physicalMemory
    let ps = UInt64(getpagesize())
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var vm = vm_statistics64_data_t()
    let kr = withUnsafeMutablePointer(to: &vm) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let internalPages = UInt64(vm.internal_page_count), purg = UInt64(vm.purgeable_count)
        r.app = (internalPages > purg ? internalPages - purg : 0) * ps
        r.wired = UInt64(vm.wire_count) * ps
        r.compressed = UInt64(vm.compressor_page_count) * ps
        r.cached = (UInt64(vm.external_page_count) + purg) * ps
        r.free = UInt64(vm.free_count) * ps
    }
    var sw = xsw_usage()
    var sz = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { r.swapUsed = sw.xsu_used; r.swapTotal = sw.xsu_total }
    var lvl: Int32 = 1
    var lsz = MemoryLayout<Int32>.size
    if sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &lsz, nil, 0) == 0 { r.pressure = Int(lvl) }
    return r
}

// MARK: - Advisor: is it safe to quit?

enum Advisor {
    static let updaterTokens = ["autoupdate", "updater", "shipit", "keystone", "softwareupdate", "sparkle", "squirrel"]
    static let dbNames = ["postgres", "mysqld", "mongod", "redis-server", "minio", "elasticsearch", "kibana", "logstash", "opensearch"]
    static let devNames: Set<String> = ["node", "npm", "npx", "tsx", "vite", "next-server", "esbuild", "java", "gradle", "python", "python3",
                                        "adb", "emulator", "netsimd", "qemu-system-aarch64-headless", "qemu-system-aarch64", "bun", "deno", "ruby", "php"]
    // (Russian names are matched too: macOS shows localized app names)
    static let valuableApps = ["safari", "google chrome", "arc", "firefox", "visual studio code", "xcode", "docker", "терминал", "terminal",
                               "iterm", "word", "excel", "powerpoint", "pages", "numbers", "keynote", "figma", "obsidian", "заметки", "notes",
                               "android studio", "chatgpt", "claude", "cursor", "antigravity", "почта", "mail"]

    static func assess(_ g: ProcGroup, info: (policy: NSApplication.ActivationPolicy, active: Bool)?) -> Assessment {
        let age = g.ageSeconds, ageText = fmtAge(age)
        let name = g.title.lowercased()
        let cmd = g.procs.map(\.command).joined(separator: " ").lowercased()
        let cpu = g.cpu
        let ports = g.ports, clients = g.clients
        var facts: [String] = [String(localized: "Running for: \(ageText)"), String(localized: "Memory: \(fmtMem(g.memory))"), String(format: String(localized: "CPU now: %.0f%%"), cpu)]
        if !ports.isEmpty { let portList = ports.map { ":\($0)" }.joined(separator: ", "); facts.append(String(localized: "Listening on port: \(portList) · connections: \(clients)")) }

        if g.isProtected {
            return Assessment(level: .critical, label: String(localized: "System"), summary: String(localized: "macOS system process - leave it alone"),
                              reasons: [String(localized: "Part of macOS (UI, networking, WebKit, Spotlight, ...). Stopping it freezes the interface or breaks a feature."),
                                        String(localized: "Its memory is released automatically when the app that uses it quits.")] + facts)
        }
        if name == "claude" || name == "codex" || cmd.hasPrefix("claude ") {
            return Assessment(level: .careful, label: String(localized: "Be careful"), summary: String(localized: "AI assistant session in a terminal"),
                              reasons: [String(localized: "A running Claude/Codex CLI session. Quitting it ends the current conversation and any commands it is running.")] + facts)
        }
        let key = name + " " + cmd
        if updaterTokens.contains(where: { key.contains($0) }) {
            return Assessment(level: .safe, label: String(localized: "Safe to quit"), summary: String(localized: "background app updater"),
                              reasons: [String(localized: "An auto-update helper. If you quit it, it simply starts again when needed.")] + facts)
        }
        if name.contains("crashpad") || name.contains("crashreporter") {
            return Assessment(level: .safe, label: String(localized: "Safe to quit"), summary: String(localized: "crash reporter"),
                              reasons: [String(localized: "Only needed at the moment an app crashes.")] + facts)
        }
        if dbNames.contains(where: { name.contains($0) || cmd.contains("/" + $0) }) {
            if clients == 0 && age > 3600 {
                return Assessment(level: .safe, label: String(localized: "Safe to quit"), summary: String(localized: "database service with no clients for \(ageText)"),
                                  reasons: [String(localized: "Nothing is connected to it right now. It is stopped gracefully (fast shutdown), data is preserved.")] + facts)
            }
            return Assessment(level: .careful, label: String(localized: "Be careful"), summary: clients > 0 ? String(localized: "clients are connected (\(clients))") : String(localized: "database service"),
                              reasons: [String(localized: "Stopping it cuts your projects off from the database. Data is kept, but client apps will get errors.")] + facts)
        }
        let isMCP = cmd.contains("mcp")
        let isDev = Advisor.devNames.contains(name) || ["node_modules", "next dev", "vite", "webpack", "gradle", "tsx watch", "emulator"].contains(where: { cmd.contains($0) })
        if g.appPath == nil, isDev || isMCP {
            if isMCP {
                return Assessment(level: .careful, label: String(localized: "Be careful"), summary: String(localized: "tool server for an AI assistant/editor (MCP)"),
                                  reasons: [String(localized: "An MCP server started by an AI assistant session or editor. Quitting it removes that tool from the active session.")] + facts)
            }
            if !ports.isEmpty {
                if clients == 0 && age > 3600 {
                    return Assessment(level: .safe, label: String(localized: "Safe to quit"), summary: String(localized: "dev server :\(ports[0]) with no clients for \(ageText)"),
                                      reasons: [String(localized: "Looks like a forgotten dev server: the port is open but nothing is connected to it."), String(localized: "Quitting is harmless - start it again with your project command.")] + facts)
                }
                return Assessment(level: .careful, label: String(localized: "Be careful"), summary: clients > 0 ? String(localized: "clients are connected (\(clients))") : String(localized: "server started recently"),
                                  reasons: [clients > 0 ? String(localized: "There are active connections - someone (a browser, an app) is using this server.") : String(localized: "The server started less than an hour ago - you may be working with it.")] + facts)
            }
            if cpu < 1 && age > 6 * 3600 {
                return Assessment(level: .safe, label: String(localized: "Safe to quit"), summary: String(localized: "idle for \(ageText), CPU ~0"),
                                  reasons: [String(localized: "A background dev process that has been doing nothing for a long time.")] + facts)
            }
            return Assessment(level: .careful, label: String(localized: "Be careful"), summary: String(localized: "development process"),
                              reasons: [String(localized: "May be part of a build, a watch mode or a parent process. Check the command and project folder in the details.")] + facts)
        }
        if g.appPath != nil, let info = info {
            let busy = info.active
            if valuableApps.contains(where: { name.contains($0) }) {
                var why = String(localized: "May hold unsaved data. It is quit like Cmd+Q - the app will ask about saving.")
                if name.contains("docker") { why = String(localized: "Stops the virtual machine and containers. Images and volumes are kept.") }
                if name.contains("терминал") || name.contains("terminal") || name.contains("iterm") { why = String(localized: "Closes terminal windows and the commands running in them (including AI assistant sessions).") }
                return Assessment(level: .careful, label: String(localized: "Be careful"), summary: busy ? String(localized: "currently the active app") : String(localized: "may hold unsaved data"),
                                  reasons: [why] + facts)
            }
            if info.policy != .regular {
                return Assessment(level: .safe, label: String(localized: "Safe to quit"), summary: String(localized: "background utility / menu bar item"),
                                  reasons: [String(localized: "Runs in the background without windows. Safe to quit; it returns when launched manually or at login (if it is a login item).")] + facts)
            }
            if !busy && cpu < 1 && age > 12 * 3600 {
                return Assessment(level: .safe, label: String(localized: "Safe to quit"), summary: String(localized: "open for \(ageText), not in use"),
                                  reasons: [String(localized: "A regular app that has been idle for a long time (CPU ~0) and is not in focus. Quits like Cmd+Q.")] + facts)
            }
            return Assessment(level: .careful, label: String(localized: "Be careful"), summary: busy ? String(localized: "currently the active app") : String(localized: "regular application"),
                              reasons: [String(localized: "Quits like Cmd+Q; the app may ask about unsaved data.")] + facts)
        }
        return Assessment(level: .careful, label: String(localized: "Be careful"), summary: String(localized: "purpose not recognized"),
                          reasons: [String(localized: "Could not work out what this process is for. See the command and working folder below.")] + facts)
    }
}

// MARK: - Descriptions of well-known system processes

let knownDescriptions: [String: String] = [
    "com.apple.WebKit.WebContent": String(localized: "renders web pages (Safari and WebKit-based apps)"),
    "com.apple.WebKit.Networking": String(localized: "networking for web pages (WebKit)"),
    "com.apple.WebKit.GPU": String(localized: "graphics for web pages (WebKit)"),
    "mdworker_shared": String(localized: "Spotlight indexing"),
    "mds_stores": String(localized: "Spotlight store"),
    "Finder": String(localized: "macOS file manager"),
    "Dock": String(localized: "Dock and Mission Control"),
    "ControlCenter": String(localized: "Control Center"),
    "WindowServer": String(localized: "draws windows and the screen"),
    "SystemUIServer": String(localized: "menu bar and system indicators"),
    "cfprefsd": String(localized: "macOS preferences service"),
    "launchd": String(localized: "starts and supervises macOS processes"),
    "kernel_task": String(localized: "the kernel"),
    "bluetoothd": String(localized: "Bluetooth"),
    "photolibraryd": String(localized: "Photos library service"),
    "mediaanalysisd": String(localized: "photo analysis (faces, objects)"),
    "com.apple.Virtualization.VirtualMachine": String(localized: "virtual machine")
]

// MARK: - Whole-system scanner (RAM tab)

extension Scanner {
    static func etimeSeconds(_ s: String) -> TimeInterval {
        var d = 0.0, rest = s
        if let r = s.firstIndex(of: "-") { d = Double(s[s.startIndex..<r]) ?? 0; rest = String(s[s.index(after: r)...]) }
        let p = rest.split(separator: ":").compactMap { Double($0) }
        switch p.count {
        case 3: return d * 86400 + p[0] * 3600 + p[1] * 60 + p[2]
        case 2: return d * 86400 + p[0] * 60 + p[1]
        default: return d * 86400
        }
    }

    private func lsofPairs(_ args: [String]) -> [(Int32, String)] {
        var out: [(Int32, String)] = []
        var cur: Int32 = 0
        for line in run("/usr/sbin/lsof", args).split(separator: "\n") {
            guard let c = line.first else { continue }
            if c == "p" { cur = Int32(line.dropFirst()) ?? 0 }
            else if c == "n", cur != 0 { out.append((cur, String(line.dropFirst()))) }
        }
        return out
    }

    func scanAll() -> (groups: [ProcGroup], ram: RAMSummary) {
        let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let now = Date()

        // ps: pid, ppid, uid, elapsed time, rss, command
        struct P { let pid: Int32; let ppid: Int32; let uid: UInt32; let age: TimeInterval; let rss: UInt64; let cmd: String }
        var plist: [P] = []
        for line in run("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,etime=,rss=,command="]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 5, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let uid = UInt32(parts[2]),
                  let rss = UInt64(parts[4]) else { continue }
            plist.append(P(pid: pid, ppid: ppid, uid: uid, age: Scanner.etimeSeconds(String(parts[3])), rss: rss * 1024,
                           cmd: parts.count > 5 ? String(parts[5]) : ""))
        }

        // ports, connections, working directories
        var listen: [Int32: Set<Int>] = [:]
        for (pid, n) in lsofPairs(["-nP", "-w", "-iTCP", "-sTCP:LISTEN", "-Fpn"]) {
            if let port = Int(n.split(separator: ":").last ?? "") { listen[pid, default: []].insert(port) }
        }
        var clients: [Int32: Int] = [:]
        for (pid, n) in lsofPairs(["-nP", "-w", "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"]) {
            guard let own = listen[pid], let local = n.components(separatedBy: "->").first,
                  let port = Int(local.split(separator: ":").last ?? ""), own.contains(port) else { continue }
            clients[pid, default: 0] += 1
        }
        var cwds: [Int32: String] = [:]
        for (pid, n) in lsofPairs(["-nP", "-w", "-d", "cwd", "-Fpn"]) { cwds[pid] = n }

        // applications (activation policy, focus)
        var appInfo: [String: (policy: NSApplication.ActivationPolicy, active: Bool)] = [:]
        var dockerURL: URL?
        for a in NSWorkspace.shared.runningApplications {
            if let u = a.bundleURL { appInfo[u.path] = (a.activationPolicy, a.isActive) }
            if a.bundleIdentifier == "com.docker.docker" { dockerURL = a.bundleURL }
        }

        // process rows
        var newPrev: [Int32: (cpuNs: UInt64, at: UInt64)] = [:]
        var rows: [ProcRow] = []
        for p in plist where p.uid == myUID && p.pid != myPID {
            let path = procPath(p.pid)
            var name = path.isEmpty ? String(p.cmd.split(separator: " ").first ?? "?") : (path as NSString).lastPathComponent
            if name.first?.isNumber == true, name.allSatisfy({ $0.isNumber || $0 == "." }) {
                // the binary is named after a version (e.g. "2.1.318") - use argv[0] as the real name
                let argv0 = ((p.cmd.split(separator: " ").first.map(String.init) ?? "") as NSString).lastPathComponent
                if !argv0.isEmpty, argv0.first?.isNumber != true { name = argv0 }
            }
            var mem: UInt64 = 0, cpu = 0.0
            if let u = usage(p.pid) {
                mem = u.mem
                newPrev[p.pid] = (u.cpuNs, nowNs)
                if let pr = prevCPUAll[p.pid], nowNs > pr.at, u.cpuNs >= pr.cpuNs { cpu = Double(u.cpuNs - pr.cpuNs) / Double(nowNs - pr.at) * 100 }
            }
            var row = ProcRow(pid: p.pid, ppid: p.ppid, name: name, path: path, command: p.cmd, memory: mem, cpu: cpu, files: 0)
            row.started = now.addingTimeInterval(-p.age)
            row.ports = Array(listen[p.pid] ?? []).sorted()
            row.clients = clients[p.pid] ?? 0
            row.cwd = cwds[p.pid]
            rows.append(row)
        }
        prevCPUAll = newPrev

        // grouping
        let home = NSHomeDirectory()
        func short(_ s: String) -> String { s.hasPrefix(home) ? "~" + s.dropFirst(home.count) : s }
        var groups: [String: ProcGroup] = [:]
        var order: [String] = []
        func add(_ key: String, _ make: () -> ProcGroup, _ row: ProcRow) {
            if groups[key] == nil { groups[key] = make(); order.append(key) }
            groups[key]!.procs.append(row)
        }
        for row in rows {
            let system = Scanner.isSystemPath(row.path)
            let protectedName = Scanner.protectedNames.contains(row.name)
            if row.name.contains("Virtualization.VirtualMachine"), let d = dockerURL {
                let key = "app:" + d.path
                add(key, { ProcGroup(id: key, title: "Docker Desktop", subtitle: "virtual machine with your images and containers", appPath: d.path, isProtected: false, procs: []) }, row)
            } else if let app = Scanner.outerApp(row.path) {
                let key = "app:" + app
                let title = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
                add(key, { ProcGroup(id: key, title: title, subtitle: "application", appPath: app,
                                     isProtected: app.hasPrefix("/System/Library/") || protectedName, procs: []) }, row)
            } else if system || protectedName {
                let key = "sys:" + row.name
                add(key, { ProcGroup(id: key, title: row.name, subtitle: knownDescriptions[row.name] ?? "macOS system process",
                                     appPath: nil, isProtected: true, procs: []) }, row)
            } else {
                var args = row.command
                if !row.path.isEmpty, args.hasPrefix(row.path) { args = String(args.dropFirst(row.path.count)) }
                args = short(args.trimmingCharacters(in: .whitespaces))
                if args.count > 110 { args = String(args.prefix(110)) + "…" }
                // processes of one project (npm + next + next-server) are merged by working directory
                if let cwd = row.cwd, cwd != "/", cwd != home, !cwd.hasPrefix("/private/var") {
                    let key = "proj:\(row.name):\(cwd)"
                    add(key, { ProcGroup(id: key, title: row.name, subtitle: short(cwd), appPath: nil, isProtected: false, procs: []) }, row)
                } else {
                    let key = "pid:\(row.pid)"
                    add(key, { ProcGroup(id: key, title: row.name, subtitle: args.isEmpty ? short(row.path) : args, appPath: nil, isProtected: false, procs: []) }, row)
                }
            }
        }
        // root and service-user processes: footprint is unreadable without root, so show RSS
        for p in plist where p.uid != myUID {
            var path = procPath(p.pid)
            if path.isEmpty { path = String(p.cmd.split(separator: " ").first ?? "") }
            let name = path.isEmpty ? "?" : (path as NSString).lastPathComponent
            var row = ProcRow(pid: p.pid, ppid: p.ppid, name: name, path: path, command: p.cmd, memory: p.rss, cpu: 0, files: 0)
            row.started = now.addingTimeInterval(-p.age)
            let owner = p.uid == 0 ? "root" : "system service"
            let key = "sysother:" + name
            add(key, { ProcGroup(id: key, title: name, subtitle: (knownDescriptions[name] ?? "system process (\(owner))") + " · memory is RSS",
                                 appPath: nil, isProtected: true, procs: []) }, row)
        }
        var result = order.compactMap { groups[$0] }
        for i in result.indices {
            let info = result[i].appPath.flatMap { appInfo[$0] }
            result[i].assessment = Advisor.assess(result[i], info: info)
        }
        return (result, readRAM())
    }
}
