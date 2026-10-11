import Darwin
import Foundation

/// A sub-agent the orchestrator dispatched with the Agent tool.
///
/// These never appear in `~/.claude/sessions` — the Agent tool runs them inside
/// the parent session, so the only record is a `tool_use` block in the parent's
/// transcript and, once it finishes, the matching `tool_result`.
struct SubAgent: Identifiable, Hashable {
    enum State: Hashable {
        case running
        case finished(ok: Bool)

        var isRunning: Bool { if case .running = self { return true } else { return false } }
    }

    /// The tool-use id, stable for the life of the call.
    var id: String
    /// Short label the orchestrator gave the task.
    var title: String
    /// Which agent definition was used, e.g. `general-purpose`.
    var kind: String
    /// The full instruction it was handed.
    var prompt: String
    var state: State = .running
    var startedAt: Date?
    var finishedAt: Date?
    /// First lines of what it reported back.
    var result: String?
    var totalTokens: Int?
    /// Handle the parent can use to continue it.
    var agentID: String?

    var subtitle: String {
        switch state {
        case .running: return kind
        case .finished(let ok): return ok ? kind : kind + " · failed"
        }
    }
}

/// Reads sub-agents out of a live transcript.
///
/// Called repeatedly while an orchestrator works, so it parses only the tail of
/// the file and only the lines that can possibly matter.
struct SubAgentTracker {
    /// Matches `TranscriptLoader`: enough history to be useful, bounded so a
    /// long session does not make each refresh more expensive than the last.
    static let maxParsedBytes = 8 * 1024 * 1024

    private static let nAgentTool = StaticNeedle(#""name":"Agent""#)
    private static let nToolResult = StaticNeedle(#""tool_use_id""#)

    func subAgents(inTranscriptAt url: URL) -> [SubAgent] {
        guard let data = try? JSONLScanner.map(url) else { return [] }

        var start = 0
        if data.count > Self.maxParsedBytes {
            let approximate = data.count - Self.maxParsedBytes
            start = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                let remaining = raw.count - approximate
                guard remaining > 0, let newline = memchr(base + approximate, 0x0A, remaining) else {
                    return approximate
                }
                return (UnsafeRawPointer(newline) - base) + 1
            }
        }

        var ordered: [String] = []
        var byID: [String: SubAgent] = [:]
        var results: [String: (text: String, isError: Bool, at: Date?)] = [:]

        JSONLScanner.scan(data, from: start) { line in
            // Cheap reject first: most lines are neither a dispatch nor a result.
            let isDispatch = line.contains(Self.nAgentTool)
            let isResult = line.contains(Self.nToolResult)
            guard isDispatch || isResult else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { return }

            let timestamp = (object["timestamp"] as? String)
                .flatMap(ISO8601DateFormatter.transcript.date(from:))

            for block in blocks {
                switch block["type"] as? String {
                case "tool_use" where (block["name"] as? String) == "Agent":
                    guard let id = block["id"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let prompt = input["prompt"] as? String ?? ""
                    let agent = SubAgent(
                        id: id,
                        title: (input["description"] as? String)
                            ?? String(prompt.prefix(60))
                            ?? "Sub-agent",
                        kind: input["subagent_type"] as? String ?? "agent",
                        prompt: prompt,
                        startedAt: timestamp
                    )
                    if byID[id] == nil { ordered.append(id) }
                    byID[id] = agent

                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { continue }
                    results[id] = (
                        Self.flatten(block["content"]),
                        block["is_error"] as? Bool ?? false,
                        timestamp
                    )

                default:
                    continue
                }
            }
        }

        return ordered.compactMap { id in
            guard var agent = byID[id] else { return nil }
            if let outcome = results[id] {
                agent.state = .finished(ok: !outcome.isError)
                agent.finishedAt = outcome.at
                agent.result = Self.summary(of: outcome.text)
                agent.totalTokens = Self.totalTokens(in: outcome.text)
                agent.agentID = Self.agentID(in: outcome.text)
            }
            return agent
        }
    }

    // MARK: - Result parsing

    private static func flatten(_ content: Any?) -> String {
        switch content {
        case let text as String: return text
        case let blocks as [[String: Any]]:
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        default: return ""
        }
    }

    /// The tail of an Agent result carries a machine block — an `agentId` line
    /// and a `<usage>` envelope. Strip it so the card shows what the sub-agent
    /// actually said.
    private static func summary(of text: String) -> String {
        var body = text
        if let marker = body.range(of: "\nagentId:") {
            body = String(body[body.startIndex..<marker.lowerBound])
        }
        if let marker = body.range(of: "<usage>") {
            body = String(body[body.startIndex..<marker.lowerBound])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func totalTokens(in text: String) -> Int? {
        guard let range = text.range(of: "total_tokens: ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func agentID(in text: String) -> String? {
        guard let range = text.range(of: "agentId: ") else { return nil }
        let value = text[range.upperBound...].prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }
}
