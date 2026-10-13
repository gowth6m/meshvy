import Foundation
import Testing

@testable import FileSystemKit

@Suite("LineView")
struct LineViewTests {
    /// Runs `body` against `text` as a `LineView`, the way the scanner hands
    /// one out: a pointer into mapped bytes, not a String.
    private func view<R>(_ text: String, _ body: (LineView) -> R) -> R {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBytes { raw in
            body(LineView(base: UnsafeRawPointer(raw.baseAddress!), count: raw.count))
        }
    }

    @Test("finds a needle that is there and not one that is not")
    func contains() {
        let needle = StaticNeedle("\"type\":")
        #expect(view(#"{"type":"user"}"#) { $0.contains(needle) })
        #expect(view(#"{"other":1}"#) { !$0.contains(needle) })
    }

    @Test("reads the string that follows a needle")
    func stringAfter() {
        let needle = StaticNeedle("\"type\":\"")
        #expect(view(#"{"type":"assistant","x":1}"#) { $0.string(after: needle) } == "assistant")
    }

    @Test("reads the integer that follows a needle")
    func intAfter() {
        let needle = StaticNeedle("\"tokens\":")
        #expect(view(#"{"tokens":4096}"#) { $0.int(after: needle) } == 4096)
    }

    @Test("a needle that is absent yields nil rather than garbage")
    func missingNeedle() {
        let needle = StaticNeedle("\"nope\":\"")
        #expect(view(#"{"type":"user"}"#) { $0.string(after: needle) } == nil)
        #expect(view(#"{"type":"user"}"#) { $0.int(after: needle) } == nil)
    }

    @Test("counts every occurrence, not just the first")
    func occurrences() {
        let needle = StaticNeedle("tool_use")
        #expect(view(#"[{"t":"tool_use"},{"t":"tool_use"}]"#) { $0.occurrences(of: needle) } == 2)
    }
}

@Suite("JSONLScanner")
struct JSONLScannerTests {
    @Test("visits each complete line once")
    func scansLines() {
        let data = Data("one\ntwo\nthree\n".utf8)
        var seen: [String] = []
        JSONLScanner.scan(data, from: 0) { seen.append(String(decoding: $0.data, as: UTF8.self)) }
        #expect(seen == ["one", "two", "three"])
    }

    // An agent appends while we read, so the tail is routinely half a record.
    // Resuming from the returned offset is what keeps a partial line from being
    // parsed as a whole one.
    @Test("stops at the last newline and reports a resumable offset")
    func partialTail() {
        let data = Data("one\ntwo\nthr".utf8)
        var seen: [String] = []
        let next = JSONLScanner.scan(data, from: 0) { seen.append(String(decoding: $0.data, as: UTF8.self)) }
        #expect(seen == ["one", "two"])
        #expect(next == 8)

        // the rest arrives; resuming from `next` yields the line exactly once
        let grown = Data("one\ntwo\nthree\n".utf8)
        var rest: [String] = []
        JSONLScanner.scan(grown, from: next) { rest.append(String(decoding: $0.data, as: UTF8.self)) }
        #expect(rest == ["three"])
    }

    @Test("skips blank lines instead of reporting empty records")
    func blankLines() {
        var seen = 0
        JSONLScanner.scan(Data("a\n\n\nb\n".utf8), from: 0) { _ in seen += 1 }
        #expect(seen == 2)
    }

    @Test("an empty file yields nothing and does not move the cursor")
    func empty() {
        var seen = 0
        #expect(JSONLScanner.scan(Data(), from: 0) { _ in seen += 1 } == 0)
        #expect(seen == 0)
    }

    @Test("an out-of-range start offset is clamped rather than trapping")
    func clampsOffset() {
        var seen = 0
        JSONLScanner.scan(Data("a\nb\n".utf8), from: 9_999) { _ in seen += 1 }
        #expect(seen == 0)
    }

    @Test("maps a file off disk")
    func mapsFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meshvy-scan-\(UUID().uuidString).jsonl")
        try Data("x\ny\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var seen = 0
        JSONLScanner.scan(try JSONLScanner.map(url), from: 0) { _ in seen += 1 }
        #expect(seen == 2)
    }
}
