import Foundation
import Testing

@testable import MeshvyModels

@Suite("ThreadState")
struct ThreadStateTests {
    private func state(_ agent: AgentState?, running: Bool = true, resolved: Bool = false) -> ThreadState {
        ThreadState.of(
            activity: agent.map { AgentActivity(sessionID: "s", state: $0) },
            isRunning: running,
            isResolved: resolved
        )
    }

    @Test("an agent's lifecycle reads as where the thread stands")
    func lifecycle() {
        #expect(state(.working) == .working)
        #expect(state(.blocked) == .needsYou)
        #expect(state(.done) == .ready)
        #expect(state(.waiting) == .idle)
        #expect(state(nil) == .idle)
        #expect(state(.ended) == .stopped)
    }

    @Test("a thread whose process is gone is stopped, whatever it last said")
    func stopped() {
        #expect(state(.working, running: false) == .stopped)
        #expect(state(.blocked, running: false) == .stopped)
    }

    // You put it away, so it stays away until someone writes to it again.
    @Test("resolved wins over everything")
    func resolvedWins() {
        #expect(state(.blocked, resolved: true) == .resolved)
        #expect(state(nil, running: false, resolved: true) == .resolved)
        #expect(!ThreadState.resolved.isOpen)
    }

    @Test("whatever wants you sorts first")
    func ranking() {
        let sorted = ThreadState.allCases.sorted { $0.rank < $1.rank }
        #expect(sorted.first == .needsYou)
        #expect(sorted.last == .resolved)
        #expect(Set(ThreadState.allCases.map(\.rank)).count == ThreadState.allCases.count)
    }

    // Boards saved before threads could be resolved must still open.
    @Test("a terminal saved without resolvedAt decodes as open")
    func decodesOlderBoards() throws {
        let json = #"{"role":"repo","title":"Fix login","cwd":"/tmp"}"#
        let node = try JSONDecoder().decode(TerminalNode.self, from: Data(json.utf8))
        #expect(node.isThread)
        #expect(!node.isResolved)
    }
}
