import Foundation
import Testing

@testable import SessionKit

@Suite("PromptCleaner")
struct PromptCleanerTests {
    // What the board shows as a session's opening prompt is the first user
    // message, which the CLI pads with machine-generated wrappers. Showing
    // those verbatim made every card read as boilerplate.
    @Test("strips a wrapper and keeps what the person actually typed")
    func stripsWrapper() {
        let raw = "<system-reminder>ignore me</system-reminder>Fix the login bug"
        #expect(PromptCleaner.clean(raw) == "Fix the login bug")
    }

    @Test("strips every kind of wrapper the CLI emits", arguments: [
        "<system_instruction>x</system_instruction>",
        "<system-reminder>x</system-reminder>",
        "<command-name>x</command-name>",
        "<local-command-stdout>x</local-command-stdout>",
        "<meshvy-brief>x</meshvy-brief>",
    ])
    func stripsEachWrapper(wrapper: String) {
        #expect(PromptCleaner.clean(wrapper + "real text") == "real text")
    }

    @Test("strips several wrappers in one message")
    func stripsMany() {
        let raw = "<system-reminder>a</system-reminder>keep<command-name>b</command-name> this"
        #expect(PromptCleaner.clean(raw) == "keep this")
    }

    // A truncated transcript line can open a wrapper and never close it;
    // everything from the tag on is machine text, so it all goes.
    @Test("an unclosed wrapper takes everything after it")
    func unclosedWrapper() {
        #expect(PromptCleaner.clean("keep this<system-reminder>and lose the rest") == "keep this")
    }

    @Test("text with no wrapper is returned trimmed")
    func plainText() {
        #expect(PromptCleaner.clean("  just a prompt  ") == "just a prompt")
    }

    @Test("a message that is nothing but wrappers comes back empty")
    func allWrapper() {
        #expect(PromptCleaner.clean("<system-reminder>only this</system-reminder>").isEmpty)
    }
}
