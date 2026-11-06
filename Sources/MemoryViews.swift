import SwiftUI
import AppKit

// MARK: - RAM panel (summary)

struct RAMPanel: View {
    let r: RAMSummary
    let userMem: UInt64
    let reclaimable: UInt64
    let reclaimableCount: Int

    var pressureText: (String, Color) {
        switch r.pressure {
        case 4: return (String(localized: "Critical"), .red)
        case 2: return (String(localized: "Elevated"), .orange)
        default: return (String(localized: "Normal"), .green)
        }
    }

    var body: some View {
        let total = Double(max(r.total, 1))
        let segs: [(String, UInt64, Color)] = [
            (String(localized: "Apps"), r.app, .blue), (String(localized: "Wired (system)"), r.wired, .orange),
            (String(localized: "Compressed"), r.compressed, .purple), (String(localized: "Cached"), r.cached, Color.gray.opacity(0.55)), (String(localized: "Free"), r.free, .green.opacity(0.55))
        ]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory (RAM)").font(.headline)
                Text("\(fmtMem(r.used)) used of \(fmtMem(r.total)) (\(Int(Double(r.used) / total * 100))%)").foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(pressureText.1).frame(width: 9, height: 9)
                    Text("Pressure: \(pressureText.0)").font(.callout)
                }
                Text("Swap: \(fmtMem(r.swapUsed)) of \(fmtMem(r.swapTotal))").font(.callout)
                    .foregroundStyle(r.swapTotal > 0 && Double(r.swapUsed) / Double(r.swapTotal) > 0.7 ? Color.orange : Color.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                        Rectangle().fill(s.2).frame(width: max(0, geo.size.width * CGFloat(Double(s.1) / total)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 4))
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
            HStack(spacing: 16) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(s.2).frame(width: 10, height: 10)
                        Text("\(s.0) \(fmtMem(s.1))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Your processes: \(fmtMem(userMem))").font(.caption)
                Text("Safe to quit: ~\(fmtMem(reclaimable)) (\(reclaimableCount))")
                    .font(.caption.weight(.semibold)).foregroundStyle(reclaimable > 0 ? Color.green : Color.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Process row in RAM mode

func levelColor(_ l: Level?) -> Color {
    switch l { case .safe: return .green; case .careful: return .orange; case .critical: return .gray; case nil: return .gray }
}

struct MemRow: View {
    let g: ProcGroup
    @Binding var checked: Bool
    let totalRAM: Double
    let maxMem: UInt64
    let stopping: Bool
    let stuck: Bool
    @State private var showInfo = false

    var pct: Double { Double(g.memory) / totalRAM * 100 }
    var barColor: Color { pct >= 8 ? .red : (pct >= 3 ? .orange : .green) }
    var a: Assessment? { g.assessment }
    var age: String { g.started == nil ? "—" : fmtAge(g.ageSeconds) }
    var longLived: Bool { g.ageSeconds > 3 * 86400 }

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
                    if g.procs.count > 1 { Text("×\(g.procs.count)").font(.caption).foregroundStyle(.secondary) }
                    if stopping && !stuck { ProgressView().controlSize(.small); Text("stopping...").font(.caption).foregroundStyle(.secondary) }
                    if stuck { Text("did not quit").font(.caption).foregroundStyle(.red) }
                }
                Text(a?.summary ?? g.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }.frame(maxWidth: .infinity, alignment: .leading)

            Text(age).font(.callout).frame(width: 84, alignment: .trailing)
                .foregroundStyle(longLived ? Color.orange : Color.secondary)
            Text(String(format: "%.0f%%", g.cpu)).frame(width: 46, alignment: .trailing)
                .foregroundStyle(g.cpu >= 50 ? .red : (g.cpu >= 15 ? .orange : .primary))

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(barColor).frame(width: max(3, geo.size.width * CGFloat(Double(g.memory) / Double(maxMem))))
                    }
                }.frame(width: 70, height: 8)
                Text("\(fmtMem(g.memory)) · \(String(format: "%.1f", pct))%")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(pct >= 8 ? .red : .primary)
            }.frame(width: 215, alignment: .leading)

            Text(a?.label ?? "")
                .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                .frame(width: 104)
                .background(levelColor(a?.level).opacity(0.18)).foregroundStyle(a?.level == .critical ? Color.secondary : levelColor(a?.level))
                .clipShape(Capsule())

            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).help("Details: what it is, where it is used, whether it can be quit")
                .popover(isPresented: $showInfo, arrowEdge: .leading) { MemDetail(g: g) }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .opacity(g.isProtected ? 0.6 : 1)
        .background(checked ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !g.isProtected { checked.toggle() } }
    }
}

// MARK: - Details

struct MemDetail: View {
    let g: ProcGroup
    var a: Assessment? { g.assessment }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let app = g.appPath { Image(nsImage: appIcon(app)).resizable().frame(width: 34, height: 34) }
                    VStack(alignment: .leading) {
                        Text(g.title).font(.title3.weight(.semibold))
                        Text(g.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let a = a {
                    HStack(spacing: 6) {
                        Circle().fill(levelColor(a.level)).frame(width: 10, height: 10)
                        Text(a.label).font(.headline)
                        Text("— " + a.summary).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(a.reasons.enumerated()), id: \.offset) { _, r in
                            Text("• " + r).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                Text("Where it is used").font(.headline)
                if let s = g.started {
                    let f = DateFormatter(); let _ = (f.dateStyle = .medium, f.timeStyle = .short, f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"))
                    Text("Started: \(f.string(from: s)) (\(fmtAge(g.ageSeconds)) ago)").font(.callout)
                }
                Text("Processes: \(g.procs.count) · memory \(fmtMem(g.memory))").font(.callout)
                if !g.ports.isEmpty { Text("Ports: \(g.ports.map { ":\($0)" }.joined(separator: ", ")) · connections: \(g.clients)").font(.callout) }
                ForEach(g.procs.sorted { $0.memory > $1.memory }.prefix(8), id: \.pid) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("PID \(p.pid) · \(p.name) · \(fmtMem(p.memory))").font(.system(.caption, design: .monospaced))
                        if let c = p.cwd { Text("folder: \(c)").font(.caption2).foregroundStyle(.secondary) }
                        Text(p.command).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }.textSelection(.enabled)
                }
                if g.procs.count > 8 { Text("...and \(g.procs.count - 8) more").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Window parts for the RAM tab

extension ContentView {
    var modeBar: some View {
        HStack {
            Picker("", selection: Binding(get: { m.mode }, set: { m.switchMode($0) })) {
                ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            Spacer()
            if m.mode == .ram {
                Picker("Show", selection: $m.memFilter) {
                    ForEach(MemFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }.frame(width: 250)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    var memHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 22, height: 1)
            Color.clear.frame(width: 30, height: 1)
            Text("Process / application  ·  why").frame(maxWidth: .infinity, alignment: .leading)
            Text("Uptime").frame(width: 84, alignment: .trailing)
            Text("CPU").frame(width: 46, alignment: .trailing)
            Text("Memory (% of RAM)").frame(width: 215, alignment: .leading)
            Text("Verdict").frame(width: 104)
            Color.clear.frame(width: 22, height: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}
