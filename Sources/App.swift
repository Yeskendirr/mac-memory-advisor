import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DiskMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Memory Advisor") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandMenu("Language") {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        if lang != AppLanguage.current { lang.apply() }
                    } label: {
                        if lang == AppLanguage.current { Label(lang.title, systemImage: "checkmark") } else { Text(lang.title) }
                    }
                }
            }
        }
    }
}

// MARK: - Language selection
// The app follows the system language by default. A manual choice is stored in the app's own
// `AppleLanguages` preference (the standard macOS per-app language override) and the app relaunches.

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System default")
        case .en: return "English"
        case .ru: return "Русский"
        }
    }

    static var current: AppLanguage {
        guard let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ""),
              let langs = domain["AppleLanguages"] as? [String], let first = langs.first else { return .system }
        if first.hasPrefix("ru") { return .ru }
        if first.hasPrefix("en") { return .en }
        return .system
    }

    func apply() {
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages") }
        UserDefaults.standard.synchronize()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Formatting

func fmtBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
func fmtMem(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}

private var iconCache: [String: NSImage] = [:]
func appIcon(_ path: String) -> NSImage {
    if let i = iconCache[path] { return i }
    let i = NSWorkspace.shared.icon(forFile: path)
    iconCache[path] = i
    return i
}

// MARK: - Main window

struct ContentView: View {
    @StateObject var m = Monitor()
    @State private var confirmStop = false
    @State private var confirmForce = false
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var maxMem: UInt64 { max(m.groups.map(\.memory).max() ?? 1, 1) }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            if m.mode == .disks {
                volumeBar
                Divider()
                summaryBar
                columnHeader
            } else {
                RAMPanel(r: m.ram, userMem: m.userRAM, reclaimable: m.reclaimable, reclaimableCount: m.reclaimableCount)
                Divider()
                ramSortBar
                memHeader
            }
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 540)
        .onAppear {
            m.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { m.refresh() }   // second sample - needed for CPU %
        }
        .onReceive(timer) { _ in m.refresh() }
        .onChange(of: m.selectedID) { _, _ in if m.mode == .disks { m.volumeChanged() } }
        .overlay { if m.busy { busyOverlay } }
        .alert(item: $m.alert) { a in Alert(title: Text(a.title), message: Text(a.text), dismissButton: .default(Text("OK"))) }
        .confirmationDialog("Stop the selected items (\(m.selectedGroups.count))?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop") { m.stopSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps are quit like Cmd+Q and may ask about unsaved data. Other processes receive a gentle termination signal.")
        }
        .confirmationDialog("Force quit (\(m.stuckSelected.count))?", isPresented: $confirmForce, titleVisibility: .visible) {
            Button("Force quit", role: .destructive) { m.stop(Set(m.stuckSelected.map(\.id)), force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved data in these processes will be lost.")
        }
        .confirmationDialog("Processes are still running on this disk (\(m.stoppable.count))", isPresented: $m.pendingEjectConfirm, titleVisibility: .visible) {
            Button("Stop everything and eject") { m.stopAllAndEject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are quit gracefully first (Docker, emulator, apps), then the disk is ejected.")
        }
        .sheet(item: $m.ejectFailure) { f in ejectFailureSheet(f) }
        .sheet(item: $m.holdersReport) { r in holdersSheet(r) }
    }

    // MARK: Disks

    var volumeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(m.volumes) { v in
                    VolumeCard(v: v, selected: v.id == m.selectedID)
                        .onTapGesture { m.selectedID = v.id }
                }
            }
            .padding(12)
        }
        .background(.bar)
    }

    var summaryBar: some View {
        let totalMem = m.groups.reduce(UInt64(0)) { $0 + $1.memory }
        let pct = Double(totalMem) / m.totalRAM * 100
        let procs = m.groups.reduce(0) { $0 + $1.procs.count }
        return HStack {
            if let v = m.selectedVolume {
                Text("\(v.name): \(m.groups.count) groups, \(procs) processes, memory \(fmtMem(totalMem)) (\(String(format: "%.1f", pct))% of \(fmtMem(UInt64(m.totalRAM))))")
                    .font(.subheadline)
            }
            Spacer()
            sortPicker
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    var sortPicker: some View {
        Picker("", selection: $m.sortKey) {
            ForEach(m.availableSorts) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        .pickerStyle(.menu).frame(width: 140).labelsHidden()
    }

    var ramSortBar: some View {
        HStack {
            Text("\(m.visibleGroups.count) groups of \(m.groups.count) · sort:").font(.subheadline).foregroundStyle(.secondary)
            sortPicker
            Spacer()
            Text("Click ⓘ - what it is, where it is used, whether it can be quit").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    var columnHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 22, height: 1)      // the height is required: Color.clear would otherwise stretch to fill the window
            Color.clear.frame(width: 30, height: 1)
            Text("Process / application").frame(maxWidth: .infinity, alignment: .leading)
            Text("Procs").frame(width: 44, alignment: .trailing)
            Text("Files").frame(width: 56, alignment: .trailing)
            Text("CPU").frame(width: 52, alignment: .trailing)
            Text("Memory (% of RAM)").frame(width: 230, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: List

    var list: some View {
        Group {
            if m.groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: m.lastUpdate == nil ? "hourglass" : "checkmark.circle")
                        .font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(m.lastUpdate == nil ? String(localized: "Scanning...") : (m.mode == .ram ? String(localized: "No processes match this filter") : String(localized: "None of your processes hold files on this disk"))).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(m.sortedGroups) { g in
                            let checkedBinding = Binding(get: { m.selection.contains(g.id) },
                                                         set: { on in if on { m.selection.insert(g.id) } else { m.selection.remove(g.id) } })
                            if m.mode == .ram {
                                MemRow(g: g, checked: checkedBinding, totalRAM: m.totalRAM, maxMem: maxMem,
                                       stopping: m.stopping[g.id] != nil, stuck: m.isStuck(g.id))
                            } else {
                                GroupRow(g: g, checked: checkedBinding, totalRAM: m.totalRAM, maxMem: maxMem,
                                         stopping: m.stopping[g.id] != nil, stuck: m.isStuck(g.id))
                            }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    // MARK: Bottom bar

    var footer: some View {
        HStack(spacing: 10) {
            Button(m.mode == .ram ? String(localized: "Select safe ones") : String(localized: "Select all")) { m.selectAll() }.disabled(m.stoppable.isEmpty)
            Button("Clear selection") { m.clearSelection() }.disabled(m.selection.isEmpty)
            let selMem = m.selectedGroups.reduce(UInt64(0)) { $0 + $1.memory }
            Text(m.selectedGroups.isEmpty ? String(localized: "Gray rows are system processes and cannot be stopped from here")
                                          : String(localized: "Selected: \(m.selectedGroups.count) · will free ~\(fmtMem(selMem)) of memory"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !m.stuckSelected.isEmpty {
                Button("Force quit (\(m.stuckSelected.count))") { confirmForce = true }.tint(.red)
            }
            Button("Stop selected") { confirmStop = true }
                .buttonStyle(.borderedProminent).tint(.orange)
                .disabled(m.selectedGroups.isEmpty)
            if m.mode == .disks, let v = m.selectedVolume, !v.isInternal {
                Button("What holds the disk?") { m.whoHolds(v) }
                    .help("Also lists system processes (Spotlight etc.). Requires an administrator password")
                Button { m.requestEject() } label: { Label("Eject disk", systemImage: "eject.fill") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 10) {
                ProgressView()
                Text(m.busyText).font(.callout)
            }
            .padding(24).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Sheets

    func ejectFailureSheet(_ f: EjectFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Could not eject \"\(f.volume.name)\"", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("The disk is busy: something still holds it, so macOS refused to unmount it. Forcing it could lose data, so the app does not.")
            Text(f.message).font(.caption).foregroundStyle(.secondary)
            Text("Check your own processes in the list. If it is empty, a system service is holding the disk (most often Spotlight). The button below shows the exact list and needs an administrator password.")
                .font(.callout)
            HStack {
                Button("What holds the disk?") { m.ejectFailure = nil; m.whoHolds(f.volume) }
                Button("Turn off Spotlight on this disk") { m.ejectFailure = nil; m.disableSpotlight(f.volume) }
                Spacer()
                Button("Close") { m.ejectFailure = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560)
    }

    func holdersSheet(_ r: InfoAlert) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(r.title).font(.headline)
            ScrollView { Text(r.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 120, maxHeight: 280)
            HStack {
                if let v = m.selectedVolume, !v.isInternal, r.text.lowercased().contains("mds") {
                    Button("Turn off Spotlight on \"\(v.name)\"") { m.holdersReport = nil; m.disableSpotlight(v) }
                }
                Spacer()
                Button("Close") { m.holdersReport = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 600)
    }
}

// MARK: - Disk card

struct VolumeCard: View {
    let v: VolumeInfo
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: v.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                .font(.title2).foregroundStyle(v.isInternal ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(v.name).font(.headline)
                    Text(v.isInternal ? String(localized: "internal") : String(localized: "external"))
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2)).clipShape(Capsule())
                }
                Text("\(fmtBytes(v.free)) free of \(fmtBytes(v.total))").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: v.usedFraction).tint(v.usedFraction > 0.9 ? .red : .accentColor)
            }
        }
        .padding(10).frame(width: 280)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

// MARK: - Process row

struct GroupRow: View {
    let g: ProcGroup
    @Binding var checked: Bool
    let totalRAM: Double
    let maxMem: UInt64
    let stopping: Bool
    let stuck: Bool

    var pct: Double { Double(g.memory) / totalRAM * 100 }
    var barColor: Color { pct >= 8 ? .red : (pct >= 3 ? .orange : .green) }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $checked).labelsHidden().toggleStyle(.checkbox)
                .disabled(g.isProtected).frame(width: 22).opacity(g.isProtected ? 0 : 1)
            Group {
                if let app = g.appPath { Image(nsImage: appIcon(app)).resizable() }
                else { Image(systemName: g.isProtected ? "lock.fill" : "terminal.fill").resizable().scaledToFit().padding(5).foregroundStyle(.secondary) }
            }.frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(g.title).font(.body.weight(.medium)).lineLimit(1)
                    if stopping && !stuck { ProgressView().controlSize(.small); Text("stopping...").font(.caption).foregroundStyle(.secondary) }
                    if stuck { Text("did not quit").font(.caption).foregroundStyle(.red) }
                }
                Text(g.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)

            Text("\(g.procs.count)").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
            Text("\(g.files)").frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", g.cpu)).frame(width: 52, alignment: .trailing)
                .foregroundStyle(g.cpu >= 50 ? .red : (g.cpu >= 15 ? .orange : .primary))

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(barColor)
                            .frame(width: max(3, geo.size.width * CGFloat(Double(g.memory) / Double(maxMem))))
                    }
                }.frame(width: 90, height: 8)
                Text("\(fmtMem(g.memory)) · \(String(format: "%.1f", pct))%")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(pct >= 8 ? .red : .primary)
            }.frame(width: 230, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .opacity(g.isProtected ? 0.55 : 1)
        .background(checked ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !g.isProtected { checked.toggle() } }
        .help(g.isProtected ? String(localized: "macOS system process - cannot be stopped from this app") : g.procs.map { "\($0.pid) \($0.name)" }.joined(separator: "\n"))
    }
}
