import AppKit
import Foundation
import Observation

/// Checks GitHub Releases for a newer build and installs it in place.
///
/// Not Sparkle: Sparkle needs a publicly reachable appcast, and this repository
/// is private. The GitHub API serves the same information, and the `gh` CLI the
/// developer already has signed in supplies the token — the same way the app
/// shells out to `git` and `claude`. If the repository is ever made public the
/// unauthenticated path works unchanged.
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
                let archive = try await Self.download(release.zipURL, repository: repository) { progress in
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
    private static func token() -> String? {
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

    private static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        return request
    }

    private static func fetchLatest(repository: String) async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(
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

    private static func downloadText(_ url: URL, repository: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(
            for: request(url, accept: "application/octet-stream")
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func download(
        _ url: URL,
        repository: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(
            for: request(url, accept: "application/octet-stream")
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.message("Could not download the update.")
        }
        let total = http.expectedContentLength
        var data = Data()
        data.reserveCapacity(total > 0 ? Int(total) : 8_000_000)
        var lastReported = 0.0

        for try await byte in bytes {
            data.append(byte)
            if total > 0 {
                let fraction = Double(data.count) / Double(total)
                // Reporting every byte would flood the main actor.
                if fraction - lastReported > 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshvy-update-\(UUID().uuidString).zip")
        try data.write(to: destination)
        return destination
    }

    private static func verify(archive: URL, against checksums: String?) throws {
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

    private static func unpack(_ archive: URL) throws -> URL {
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
    private static func validate(_ bundle: URL) throws {
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
    private static func scheduleSwap(staged: URL, destination: URL) throws {
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
