import AppKit
import Foundation
import Observation

/// Every request the updater makes, with a budget for the whole transfer
/// rather than only for the gaps in it: `timeoutInterval` on a request is an
/// idle timeout, which says nothing about how long a five-megabyte asset may
/// take in total.
private let updateSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 600
    return URLSession(configuration: configuration)
}()

/// One asset, streamed to a file, reporting progress as it lands.
///
/// The delegate belongs to the session rather than to the task: a task-level
/// delegate handed to the async `download(for:delegate:)` is never sent
/// `didWriteData` on Darwin, so the bar would sit at nothing for the whole
/// transfer and only jump to done.
private final class AssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var resume: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func fetch(_ request: URLRequest) async throws -> URL {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        // The budget for the whole transfer. `timeoutInterval` on a request
        // only covers the gaps between packets, which says nothing about how
        // long several megabytes may take end to end.
        configuration.timeoutIntervalForResource = 600
        // An installer is not worth caching, and this one is megabytes.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        // The session holds the delegate — which is this object — until it is
        // invalidated, so it has to be, whichever way the download goes.
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            resume = continuation
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = resume
        resume = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // A refusal has a body too, and it would unpack to nothing useful.
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            finish(.failure(UpdateService.Failure.message("Could not download the update.")))
            return
        }
        // The file is gone the moment this returns, so it moves now.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshvy-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success has already been reported by the time this runs; `finish`
        // ignores the second call.
        if let error { finish(.failure(error)) }
    }
}

/// Checks GitHub Releases for a newer build and installs it in place.
///
/// Not Sparkle: Sparkle needs a publicly reachable appcast, and a release here
/// is a GitHub release. The API serves the same information unauthenticated,
/// which is the path this takes now that the repository is public; the `gh`
/// CLI's token is still picked up when it is there, so nothing breaks if the
/// repository is ever closed again.
@MainActor
@Observable
final class UpdateService {
    struct Release: Equatable {
        var version: String
        var tag: String
        var notes: String
        var zipURL: URL
        var checksumURL: URL?
        var sizeBytes: Int
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case readyToRestart
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Version of the running bundle. Nil for a `swift run` build, which has no
    /// Info.plist and should never be told it is out of date.
    static var currentVersion: String? {
        guard let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              value != "0.0.0" else { return nil }
        return value
    }

    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private let repository = "gowth6m/meshvy"
    private var installedPath: URL { Bundle.main.bundleURL }

    // MARK: - Checking

    func check(announceNoUpdate: Bool = false) {
        guard !isBusy else { return }
        guard let current = Self.currentVersion else {
            state = announceNoUpdate ? .failed("This is a development build — updates are disabled.") : .idle
            return
        }
        state = .checking
        let repository = self.repository

        Task {
            do {
                let release = try await Self.fetchLatest(repository: repository)
                if Self.isNewer(release.version, than: current) {
                    state = .available(release)
                } else {
                    state = announceNoUpdate ? .upToDate : .idle
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func dismiss() {
        state = .idle
    }

    /// `1.2.10` is newer than `1.2.9`; a plain string compare gets that wrong.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let left = parts(candidate)
        let right = parts(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Installing

    func installAndRestart() {
        guard case .available(let release) = state else { return }
        let destination = installedPath
        let repository = self.repository

        Task {
            do {
                state = .downloading(0)
                let archive = try await Self.download(release.zipURL) { progress in
                    Task { @MainActor in self.state = .downloading(progress) }
                }
                if let checksumURL = release.checksumURL {
                    let expected = try? await Self.downloadText(checksumURL, repository: repository)
                    try Self.verify(archive: archive, against: expected)
                }
                let staged = try Self.unpack(archive)
                try Self.validate(staged)
                try Self.scheduleSwap(staged: staged, destination: destination)
                state = .readyToRestart
                // The helper waits for this process to exit before swapping.
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - GitHub

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var url: String
            var size: Int
        }
        var tag_name: String
        var name: String?
        var body: String?
        var assets: [Asset]
        var draft: Bool
        var prerelease: Bool
    }

    /// The token the `gh` CLI already holds. Private repositories need it for
    /// both the release listing and the asset download.
    private nonisolated static func token() -> String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            let result = Shell.run(candidate, ["auth", "token"], cwd: nil, timeout: 8)
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok, !value.isEmpty { return value }
        }
        return nil
    }

    private nonisolated static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        return request
    }

    private nonisolated static func fetchLatest(repository: String) async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let (data, response) = try await updateSession.data(
            for: request(url, accept: "application/vnd.github+json")
        )
        guard let http = response as? HTTPURLResponse else { throw Failure.message("No response from GitHub.") }
        guard http.statusCode != 404 else {
            throw Failure.message("No releases found, or this machine is not signed in to a GitHub account with access.")
        }
        guard http.statusCode == 200 else {
            throw Failure.message("GitHub returned \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(APIRelease.self, from: data)
        guard let zip = decoded.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let zipURL = URL(string: zip.url) else {
            throw Failure.message("That release has no .zip to install.")
        }
        let checksum = decoded.assets
            .first { $0.name.contains("SHA256") }
            .flatMap { URL(string: $0.url) }

        return Release(
            version: decoded.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v")),
            tag: decoded.tag_name,
            notes: decoded.body ?? "",
            zipURL: zipURL,
            checksumURL: checksum,
            sizeBytes: zip.size
        )
    }

    private nonisolated static func downloadText(_ url: URL, repository: String) async throws -> String {
        let (data, _) = try await updateSession.data(
            for: request(url, accept: "application/octet-stream")
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Streams the asset straight to disk.
    ///
    /// This used to read `URLSession.AsyncBytes` a byte at a time and append
    /// each one to a `Data`. That manages about 140 KB/s on an idle machine —
    /// and because every member of this type is on the main actor, it ran on
    /// the main thread, behind the canvas and every terminal redrawing on it.
    /// The connection then sat idle waiting to be read, long enough for the
    /// request to time out: a five-megabyte update that the network had
    /// finished delivering in under a second reported "the request timed out".
    private nonisolated static func download(
        _ url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await AssetDownload(onProgress: progress)
            .fetch(request(url, accept: "application/octet-stream"))
    }

    private nonisolated static func verify(archive: URL, against checksums: String?) throws {
        guard let checksums, !checksums.isEmpty else { return }
        let name = archive.lastPathComponent
        _ = name
        let result = Shell.run("/usr/bin/shasum", ["-a", "256", archive.path], cwd: nil, timeout: 60)
        guard result.ok, let digest = result.stdout.split(separator: " ").first.map(String.init) else {
            throw Failure.message("Could not checksum the download.")
        }
        // The published list covers several files; the zip's line is the one
        // that has to match.
        let expected = checksums
            .split(separator: "\n")
            .first { $0.contains(".zip") }?
            .split(separator: " ").first
            .map(String.init)
        guard let expected else { return }
        guard digest == expected else {
            throw Failure.message("The download did not match its published checksum and was discarded.")
        }
    }

    private nonisolated static func unpack(_ archive: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshvy-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // ditto, not unzip: it preserves the bundle's symlinks and signature.
        let result = Shell.run(
            "/usr/bin/ditto", ["-x", "-k", archive.path, directory.path], cwd: nil, timeout: 180
        )
        guard result.ok else { throw Failure.message("Could not unpack the update.") }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw Failure.message("The update did not contain an app.")
        }
        return app
    }

    /// Refuse to install anything that is not recognisably this app.
    private nonisolated static func validate(_ bundle: URL) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "dev.gowtham.meshvy"
        else {
            throw Failure.message("The downloaded app is not Meshvy.")
        }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Meshvy")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.message("The downloaded app has no executable.")
        }
    }

    /// A running bundle cannot replace itself, so a detached helper waits for
    /// this process to exit, swaps the two, and relaunches. It restores the old
    /// bundle if the swap fails, so a failed update never leaves nothing
    /// installed.
    private nonisolated static func scheduleSwap(staged: URL, destination: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; DEST="$2"; STAGED="$3"
        n=0
        while kill -0 "$PID" 2>/dev/null && [ "$n" -lt 600 ]; do sleep 0.2; n=$((n+1)); done
        BACKUP="$DEST.meshvy-previous"
        rm -rf "$BACKUP"
        if [ -d "$DEST" ] && ! mv "$DEST" "$BACKUP"; then exit 1; fi
        if ! mv "$STAGED" "$DEST"; then
          [ -d "$BACKUP" ] && mv "$BACKUP" "$DEST"
          open "$DEST"
          exit 1
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        rm -rf "$BACKUP"
        open "$DEST"
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshvy-install-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            url.path, String(ProcessInfo.processInfo.processIdentifier),
            destination.path, staged.path
        ]
        try process.run()
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }
}
