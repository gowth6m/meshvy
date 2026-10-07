import Foundation

/// Full parse of a single transcript, for the reader pane. Unlike the indexer
/// this does decode JSON, which is fine for one file on demand.
struct TranscriptLoader {
    /// Hard cap on rendered events; the tail is what matters when reading back.
    static let maxEvents = 4000
    /// Long tool payloads are elided — the reader shows a prefix and a count.
    static let maxBodyCharacters = 6000

    func load(_ summary: SessionSummary) -> Transcript {
        var events: [TranscriptEvent] = []
        var totalInput = 0
        var totalOutput = 0
        var cacheRead = 0
        var toolCounts: [String: Int] = [:]

        guard let data = try? JSONLScanner.map(summary.fileURL) else {
            return Transcript(
                sessionId: summary.id, events: [], totalInputTokens: 0,
                totalOutputTokens: 0, cacheReadTokens: 0, toolUseCounts: [:], truncated: false
            )
        }

        JSONLScanner.scan(data, from: 0) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any],
                  let type = object["type"] as? String else { return }

            let uuid = object["uuid"] as? String ?? UUID().uuidString
            let timestamp = (object["timestamp"] as? String).flatMap(ISO8601DateFormatter.transcript.date(from:))
            let isSidechain = object["isSidechain"] as? Bool ?? false

            switch type {
            case "user":
                let message = object["message"] as? [String: Any]
                for (index, event) in Self.userEvents(message, uuid: uuid, timestamp: timestamp, isSidechain: isSidechain).enumerated() {
                    _ = index
                    events.append(event)
                }

            case "assistant":
                let message = object["message"] as? [String: Any]
                let model = message?["model"] as? String
                if let usage = message?["usage"] as? [String: Any] {
                    totalInput += (usage["input_tokens"] as? Int) ?? 0
                    totalOutput += (usage["output_tokens"] as? Int) ?? 0
                    cacheRead += (usage["cache_read_input_tokens"] as? Int) ?? 0
                }
                for event in Self.assistantEvents(
                    message, uuid: uuid, timestamp: timestamp, model: model,
                    isSidechain: isSidechain, toolCounts: &toolCounts
                ) {
                    events.append(event)
                }

            case "system":
                let content = (object["content"] as? String) ?? (object["message"] as? String) ?? ""
                guard !content.isEmpty else { return }
                events.append(TranscriptEvent(
                    id: uuid, kind: .system, timestamp: timestamp,
                    text: Self.clamp(content), model: nil,
                    isSidechain: isSidechain, startsCollapsed: true
                ))

            default:
                // queue-operation / attachment / latch records are plumbing.
                return
            }
        }

        let truncated = events.count > Self.maxEvents
        if truncated { events = Array(events.suffix(Self.maxEvents)) }

        return Transcript(
            sessionId: summary.id,
            events: events,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            cacheReadTokens: cacheRead,
            toolUseCounts: toolCounts,
            truncated: truncated
        )
    }

    // MARK: - Block decoding

    private static func userEvents(
        _ message: [String: Any]?, uuid: String, timestamp: Date?, isSidechain: Bool
    ) -> [TranscriptEvent] {
        guard let message else { return [] }

        if let text = message["content"] as? String {
            let cleaned = PromptCleaner.clean(text)
            guard !cleaned.isEmpty else { return [] }
            return [TranscriptEvent(
                id: uuid, kind: .userMessage, timestamp: timestamp,
                text: clamp(cleaned), model: nil, isSidechain: isSidechain, startsCollapsed: false
            )]
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var events: [TranscriptEvent] = []
        for (index, block) in blocks.enumerated() {
            let blockType = block["type"] as? String ?? ""
            let id = "\(uuid)#\(index)"
            switch blockType {
            case "text":
                let cleaned = PromptCleaner.clean(block["text"] as? String ?? "")
                guard !cleaned.isEmpty else { continue }
                events.append(TranscriptEvent(
                    id: id, kind: .userMessage, timestamp: timestamp,
                    text: clamp(cleaned), model: nil, isSidechain: isSidechain, startsCollapsed: false
                ))
            case "tool_result":
                let isError = block["is_error"] as? Bool ?? false
                let body = stringify(block["content"])
                events.append(TranscriptEvent(
                    id: id, kind: .toolResult(ok: !isError), timestamp: timestamp,
                    text: clamp(body), model: nil, isSidechain: isSidechain, startsCollapsed: true
                ))
            case "image":
                events.append(TranscriptEvent(
                    id: id, kind: .attachment(kind: "Image"), timestamp: timestamp,
                    text: "(image)", model: nil, isSidechain: isSidechain, startsCollapsed: true
                ))
            default:
                continue
            }
        }
        return events
    }

    private static func assistantEvents(
        _ message: [String: Any]?, uuid: String, timestamp: Date?, model: String?,
        isSidechain: Bool, toolCounts: inout [String: Int]
    ) -> [TranscriptEvent] {
        guard let blocks = message?["content"] as? [[String: Any]] else { return [] }
        var events: [TranscriptEvent] = []
        for (index, block) in blocks.enumerated() {
            let blockType = block["type"] as? String ?? ""
            let id = "\(uuid)#\(index)"
            switch blockType {
            case "text":
                let text = block["text"] as? String ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                events.append(TranscriptEvent(
                    id: id, kind: .assistantMessage, timestamp: timestamp,
                    text: clamp(text), model: model, isSidechain: isSidechain, startsCollapsed: false
                ))
            case "thinking":
                let text = block["thinking"] as? String ?? ""
                guard !text.isEmpty else { continue }
                events.append(TranscriptEvent(
                    id: id, kind: .thinking, timestamp: timestamp,
                    text: clamp(text), model: model, isSidechain: isSidechain, startsCollapsed: true
                ))
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                toolCounts[name, default: 0] += 1
                events.append(TranscriptEvent(
                    id: id, kind: .toolUse(name: name), timestamp: timestamp,
                    text: clamp(describeToolInput(block["input"])), model: model,
                    isSidechain: isSidechain, startsCollapsed: true
                ))
            default:
                continue
            }
        }
        return events
    }

    /// Prefers the shape a human scans for: a command, a path, a pattern.
    private static func describeToolInput(_ input: Any?) -> String {
        guard let dictionary = input as? [String: Any] else { return stringify(input) }
        for key in ["command", "file_path", "pattern", "path", "prompt", "url", "query"] {
            if let value = dictionary[key] as? String, !value.isEmpty {
                let rest = dictionary.keys.filter { $0 != key }.sorted()
                let suffix = rest.isEmpty ? "" : "\n\n" + prettyJSON(dictionary.filter { rest.contains($0.key) })
                return value + suffix
            }
        }
        return prettyJSON(dictionary)
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return text
    }

    private static func stringify(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let blocks as [[String: Any]]:
            return blocks.compactMap { block in
                if let text = block["text"] as? String { return text }
                if let type = block["type"] as? String { return "(\(type))" }
                return nil
            }.joined(separator: "\n")
        case let list as [Any]: return list.map { stringify($0) }.joined(separator: "\n")
        case let dictionary as [String: Any]: return prettyJSON(dictionary)
        case .none: return ""
        default: return String(describing: value!)
        }
    }

    private static func clamp(_ text: String) -> String {
        guard text.count > maxBodyCharacters else { return text }
        let kept = text.prefix(maxBodyCharacters)
        let elided = text.count - maxBodyCharacters
        return kept + "\n\n… \(elided.formatted()) more characters"
    }
}
