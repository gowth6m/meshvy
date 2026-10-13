import Foundation
import Testing

@testable import MeshvyCore

@Suite("Format")
struct FormatTests {
    @Test("relative times step through the units")
    func relative() {
        let now = Date()
        #expect(Format.relative(now.addingTimeInterval(30)) == "just now")
        #expect(Format.relative(now.addingTimeInterval(-5)) == "5s ago")
        #expect(Format.relative(now.addingTimeInterval(-90)) == "1m ago")
        #expect(Format.relative(now.addingTimeInterval(-7200)) == "2h ago")
        #expect(Format.relative(now.addingTimeInterval(-86_400 * 3)) == "3d ago")
    }

    @Test("counts stay short")
    func compactCount() {
        #expect(Format.compactCount(0) == "0")
        #expect(Format.compactCount(999) == "999")
        #expect(Format.compactCount(1500) == "1.5k")
        #expect(Format.compactCount(42_000) == "42k")
        #expect(Format.compactCount(2_500_000) == "2.5M")
    }

    // The model id is what Claude reports, not what we asked for, so the
    // tidying has to survive bracket suffixes, bedrock prefixes and date stamps.
    @Test("model ids become something a card can show", arguments: [
        ("claude-opus-5", "Opus 5"),
        ("claude-opus-5[1m]", "Opus 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
        ("us.anthropic.claude-sonnet-5", "Sonnet 5"),
    ])
    func model(raw: String, expected: String) {
        #expect(Format.model(raw) == expected)
    }

    @Test("a model we cannot name is nil rather than a placeholder")
    func modelNil() {
        #expect(Format.model(nil) == nil)
        #expect(Format.model("") == nil)
        #expect(Format.model("<synthetic>") == nil)
    }
}
