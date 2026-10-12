import Foundation

/// Reads a board saved by an older Meshvy: `Meshvy --formattest`.
///
/// `workspaces.json` is the only file in the app whose loss costs the user
/// something they cannot get back by waiting — it is the list of what they are
/// working on. Swift's synthesised `Codable` insists on every key being present
/// whatever default a property declares, so a release that adds one field would
/// make the whole file unreadable and the board would come up empty. The
/// models decode leniently instead; this proves they still do.
enum FormatTest {
    static func run() {
        var failures: [String] = []

        // Exactly what 0.9.0 wrote: no `browsers`, no `archivedAt`, and
        // terminals with no model or effort on them.
        let legacy = """
        {
          "version": 1,
          "activeWorkspaceID": "6E8E2F7E-0D3A-4C2E-9D7B-7A1E3C4F5A6B",
          "workspaces": [
            {
              "id": "6E8E2F7E-0D3A-4C2E-9D7B-7A1E3C4F5A6B",
              "name": "Payments revamp",
              "branch": "payments-revamp",
              "root": "/Users/someone/.meshvy/payments-revamp",
              "boardWidth": 820,
              "boardHeight": 540,
              "createdAt": 760000000,
              "repos": [
                {
                  "id": "/Users/someone/code/api/.git",
                  "name": "api",
                  "originPath": "/Users/someone/code/api",
                  "worktreePath": "/Users/someone/.meshvy/payments-revamp/api"
                }
              ],
              "terminals": [
                {
                  "id": "11111111-2222-3333-4444-555555555555",
                  "role": "repo",
                  "title": "api-agt-9f2c",
                  "cwd": "/Users/someone/.meshvy/payments-revamp/api",
                  "x": 120, "y": 240, "width": 580, "height": 340,
                  "createdAt": 760000100
                }
              ]
            }
          ]
        }
        """

        do {
            let document = try JSONDecoder().decode(
                WorkspaceStore.Document.self, from: Data(legacy.utf8)
            )
            let workspace = document.workspaces.first
            print("workspaces: \(document.workspaces.count)")
            print("name:       \(workspace?.name ?? "-")")
            print("repos:      \(workspace?.repos.map(\.name).joined(separator: ", ") ?? "-")")
            print("terminals:  \(workspace?.terminals.count ?? 0)")
            print("browsers:   \(workspace?.browsers.count ?? 0) (field did not exist)")
            print("archived:   \(workspace?.isArchived.description ?? "-")")

            if document.workspaces.count != 1 { failures.append("the workspace did not survive") }
            if workspace?.name != "Payments revamp" { failures.append("the name did not survive") }
            if workspace?.repos.first?.name != "api" { failures.append("the repository did not survive") }
            if workspace?.terminals.first?.title != "api-agt-9f2c" {
                failures.append("the terminal did not survive")
            }
            if workspace?.browsers.isEmpty != true { failures.append("browsers should have read as none") }
            if workspace?.isArchived != false { failures.append("a board with no archive flag should read as live") }
            if workspace?.boardWidth != 820 { failures.append("the board size did not survive") }
            if workspace?.terminals.first?.effort != nil { failures.append("effort should have read as unset") }
        } catch {
            failures.append("a 0.9.0 board no longer decodes: \(error)")
        }

        // And the round trip, so what this version writes is readable too.
        var current = Workspace(name: "Round trip", branch: "rt", root: "/tmp/rt")
        current.browsers = [BrowserNode(title: "App", url: "http://localhost:3000")]
        current.archivedAt = Date()
        do {
            let data = try JSONEncoder().encode(WorkspaceStore.Document(workspaces: [current]))
            let back = try JSONDecoder().decode(WorkspaceStore.Document.self, from: data)
            print("round trip: \(back.workspaces.first?.browsers.first?.url ?? "-")")
            if back.workspaces.first?.browsers.first?.url != "http://localhost:3000" {
                failures.append("a browser node did not survive the round trip")
            }
            if back.workspaces.first?.isArchived != true {
                failures.append("the archive flag did not survive the round trip")
            }
        } catch {
            failures.append("round trip failed: \(error)")
        }

        guard failures.isEmpty else {
            print("FORMATTEST FAILED:")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
        print("FORMATTEST OK")
        exit(0)
    }
}
