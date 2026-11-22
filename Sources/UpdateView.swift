import SwiftUI

/// Sheet for the self-updater: offer, download progress, result.
struct UpdateSheet: View {
    @ObservedObject var u: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch u.state {
            case .idle, .checking:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking for updates...") }
                buttons { Spacer(); Button("Cancel") { u.dismiss() }.keyboardShortcut(.cancelAction) }

            case .upToDate:
                Label("Memory Advisor is up to date", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("You have the latest version, \(u.currentVersion).").foregroundStyle(.secondary)
                buttons { Spacer(); Button("OK") { u.dismiss() }.keyboardShortcut(.defaultAction) }

            case .available(let r):
                header(r)
                notes(r)
                buttons {
                    Button("Skip this version") { u.skip(r) }
                    Spacer()
                    Button("Later") { u.dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Update now") { u.install(r) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }

            case .downloading(let r, let p):
                header(r)
                ProgressView(value: p) {
                    Text("Downloading... \(Int(p * 100))%").font(.callout)
                }
                buttons { Spacer(); Button("Cancel") { u.dismiss() }.keyboardShortcut(.cancelAction) }

            case .installing(let r):
                header(r)
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Installing. The app will restart by itself.") }

            case .manualInstall(let r, _):
                header(r)
                Text("This copy of the app cannot replace itself (it is not in a folder you can write to, e.g. it was started from Downloads or from the DMG). The new version's DMG has been opened: drag Memory Advisor to Applications and replace the old one.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons { Spacer(); Button("OK") { u.dismiss() }.keyboardShortcut(.defaultAction) }

            case .failed(let msg):
                Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(msg).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                buttons {
                    Button("Open the releases page") { u.openReleasePage(); u.dismiss() }
                    Spacer()
                    Button("Close") { u.dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 520)
        .interactiveDismissDisabled()
    }

    func header(_ r: Updater.Release) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("A new version of Memory Advisor is available", systemImage: "arrow.down.circle.fill").font(.headline)
            Text("Version \(r.version) is out - you have \(u.currentVersion).").foregroundStyle(.secondary)
        }
    }

    func notes(_ r: Updater.Release) -> some View {
        ScrollView {
            Text(Self.render(r.notes)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(minHeight: 80, maxHeight: 220)
        .padding(8).background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func buttons<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack { content() }
    }

    /// Release notes are GitHub Markdown; headings become bold lines, inline formatting is kept.
    static func render(_ md: String) -> AttributedString {
        let text = md.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { return "**" + t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**" }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { return "• " + t.dropFirst(2) }
            return String(line)
        }.joined(separator: "\n")
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(md)
    }
}
