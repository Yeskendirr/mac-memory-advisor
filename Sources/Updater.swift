import Foundation
import AppKit
import CryptoKit

/// Self-updater backed by GitHub Releases.
/// Checks `releases/latest` of the public repo, offers the new version, downloads its DMG,
/// verifies the SHA-256 GitHub publishes for the asset, replaces this app bundle and relaunches.
/// The update check is the app's only network request; it can be turned off in the app menu.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "Yeskendirr/mac-memory-advisor"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    private static let autoCheckKey = "autoCheckUpdates"
    private static let skippedKey = "skippedUpdateVersion"
    private static let checkInterval: TimeInterval = 12 * 3600

    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let dmgURL: URL
        let dmgSize: Int64
        let sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, Double)
        case installing(Release)
        case manualInstall(Release, URL)    // the bundle cannot be replaced in place - the DMG was opened instead
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var showSheet = false

    private var timer: Timer?
    private var downloader: Downloader?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    /// Called once at launch: a quiet check now and then every 12 hours while the app runs.
    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check(manual: false) }
        }
    }

    /// Manual checks always report a result; automatic ones only speak up when there is an update.
    func check(manual: Bool) {
        if !manual && !Self.autoCheckEnabled { return }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        if manual { state = .checking; showSheet = true }
        Task {
            do {
                let r = try await fetchLatest()
                let newer = Self.isNewer(r.version, than: currentVersion)
                let skipped = UserDefaults.standard.string(forKey: Self.skippedKey) == r.version
                if newer && (manual || !skipped) {
                    AppLog.write("update: \(r.version) available (installed \(currentVersion))")
                    state = .available(r); showSheet = true
                } else if manual {
                    state = .upToDate
                } else {
                    state = .idle
                }
            } catch {
                if manual { state = .failed(error.localizedDescription) } else { state = .idle }
            }
        }
    }

    func skip(_ r: Release) {
        UserDefaults.standard.set(r.version, forKey: Self.skippedKey)
        dismiss()
    }

    func dismiss() {
        downloader?.cancel(); downloader = nil
        showSheet = false
        state = .idle
    }

    func openReleasePage(_ r: Release? = nil) {
        NSWorkspace.shared.open(r?.pageURL ?? Self.releasesPage)
    }

    // MARK: GitHub API

    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: Self.latestAPI, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MemoryAdvisor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(String(localized: "GitHub did not answer (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))."))
        }
        let api = try JSONDecoder().decode(APIRelease.self, from: data)
        guard let dmg = api.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let dmgURL = URL(string: dmg.browser_download_url),
              let page = URL(string: api.html_url) else {
            throw UpdateError(String(localized: "The latest release has no DMG to download."))
        }
        var sha: String?
        if let d = dmg.digest, d.hasPrefix("sha256:") { sha = String(d.dropFirst(7)).lowercased() }
        let version = api.tag_name.hasPrefix("v") ? String(api.tag_name.dropFirst()) : api.tag_name
        return Release(version: version, notes: api.body ?? "", pageURL: page, dmgURL: dmgURL, dmgSize: dmg.size, sha256: sha)
    }

    private struct APIRelease: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browser_download_url: String
            let digest: String?
        }
    }

    /// Numeric comparison of dotted versions: 1.10.0 > 1.9.2, 1.1 == 1.1.0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Download and install

    func install(_ r: Release) {
        state = .downloading(r, 0)
        AppLog.write("update: downloading \(r.dmgURL.absoluteString)")
        let d = Downloader(url: r.dmgURL, expectedSize: r.dmgSize) { [weak self] p in
            Task { @MainActor in
                if case .downloading(let cur, _) = self?.state, cur == r { self?.state = .downloading(r, p) }
            }
        }
        downloader = d
        Task {
            do {
                let dmg = try await d.run(to: Self.workDir.appendingPathComponent("MemoryAdvisor-\(r.version).dmg"))
                downloader = nil
                state = .installing(r)
                try await Task.detached { try Self.verify(dmg, sha256: r.sha256) }.value
                let target = Bundle.main.bundleURL
                guard Self.canReplace(target) else {
                    AppLog.write("update: \(target.path) is not writable, opening the DMG instead")
                    NSWorkspace.shared.open(dmg)
                    state = .manualInstall(r, dmg)
                    return
                }
                let staged = try await Task.detached { try Self.extractApp(from: dmg, version: r.version) }.value
                try Self.relaunch(replacing: target, with: staged, dmg: dmg)
                AppLog.write("update: installing \(r.version) into \(target.path) and relaunching")
                quitForRelaunch()
            } catch is CancellationError {
                return
            } catch {
                AppLog.write("update failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// AppKit postpones `terminate` while a sheet is attached, so the sheet is closed first;
    /// `exit` is a fallback in case something still vetoes the quit - the swap script waits for this process.
    private func quitForRelaunch() {
        showSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }

    nonisolated private static var workDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent((Bundle.main.bundleIdentifier ?? "MemoryAdvisor") + "/Updates")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func verify(_ file: URL, sha256 expected: String?) throws {
        guard let expected else { return }       // older GitHub responses carry no digest - HTTPS is all we have then
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError(String(localized: "The downloaded file is damaged (checksum mismatch). Try again later."))
        }
    }

    /// The bundle can be swapped in place only if its folder is writable and macOS has not moved it
    /// to a read-only App Translocation mount (an app started straight from Downloads or a DMG).
    private static func canReplace(_ app: URL) -> Bool {
        let path = app.path
        if path.contains("/AppTranslocation/") { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: path)
    }

    /// Mounts the DMG read-only, copies the app out of it and checks it really is Memory Advisor of the expected version.
    nonisolated private static func extractApp(from dmg: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("MemoryAdvisorUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }

        let attach = shell("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        guard attach.status == 0 else { throw UpdateError(String(localized: "Could not open the downloaded DMG.") + " " + attach.output) }
        defer { _ = shell("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        guard let name = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError(String(localized: "The DMG does not contain the app."))
        }
        let src = mount.appendingPathComponent(name)
        let staged = workDir.appendingPathComponent("staged/\(name)")
        try? fm.removeItem(at: staged.deletingLastPathComponent())
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copy = shell("/usr/bin/ditto", [src.path, staged.path])
        guard copy.status == 0 else { throw UpdateError(String(localized: "Could not copy the new version.") + " " + copy.output) }

        let info = Bundle(url: staged)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError(String(localized: "The downloaded app is not the expected version of Memory Advisor."))
        }
        let sig = shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        guard sig.status == 0 else { throw UpdateError(String(localized: "The new version's code signature is invalid.") + " " + sig.output) }
        _ = shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// Starts a small detached script that waits for this process to exit, swaps the bundle
    /// (restoring the old one if the copy fails) and opens the app again.
    private static func relaunch(replacing target: URL, with staged: URL, dmg: URL) throws {
        let script = """
        pid="$1"; src="$2"; dst="$3"; dmg="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$dst.old"
        if mv "$dst" "$dst.old" && /usr/bin/ditto "$src" "$dst"; then
          rm -rf "$dst.old" "$src" "$dmg"
        else
          rm -rf "$dst"; mv "$dst.old" "$dst"
        fi
        /usr/bin/open "$dst"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "updater", String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path, dmg.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    nonisolated private static func shell(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// URLSession download with progress reporting, wrapped in async/await.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let expectedSize: Int64
    private let onProgress: (Double) -> Void
    private var destination: URL?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let lock = NSLock()

    init(url: URL, expectedSize: Int64, onProgress: @escaping (Double) -> Void) {
        self.url = url; self.expectedSize = expectedSize; self.onProgress = onProgress
    }

    func run(to dest: URL) async throws -> URL {
        destination = dest
        return try await withCheckedThrowingContinuation { c in
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            lock.lock(); continuation = c; session = s; lock.unlock()
            s.downloadTask(with: url).resume()
        }
    }

    func cancel() {
        lock.lock(); let s = session; lock.unlock()
        s?.invalidateAndCancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ r: Result<URL, Error>) {
        lock.lock()
        let c = continuation, s = session
        continuation = nil
        lock.unlock()
        guard let c else { return }
        c.resume(with: r)
        s?.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        let t = total > 0 ? total : expectedSize
        if t > 0 { onProgress(min(1, Double(written) / Double(t))) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(UpdateError(String(localized: "Download failed (HTTP \(http.statusCode))."))))
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)   // must happen before this method returns
            finish(.success(dest))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
