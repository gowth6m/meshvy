import Darwin
import Foundation

/// A view over one JSONL line, with just enough primitives to pull out fields
/// without paying for `JSONSerialization` on 400 MB of transcripts.
///
/// Transcript records are written as compact JSON (verified: no `"type": "x"`
/// spaced form appears in the store), so literal-needle matching is reliable.
/// Record-level keys are *not* in a fixed order and `attachment` records nest
/// their own `type`, so callers must match on the full `"type":"value"` pair.
public struct LineView {
    public let base: UnsafeRawPointer
    public let count: Int
    /// Byte offset of this line within the mapped file, so a caller can record a
    /// position now and re-create the view in a later pass.
    public let offsetInFile: Int

    public init(base: UnsafeRawPointer, count: Int, offsetInFile: Int = 0) {
        self.base = base
        self.count = count
        self.offsetInFile = offsetInFile
    }

    public func contains(_ needle: StaticNeedle) -> Bool { find(needle, from: 0) != nil }

    /// Byte offset of `needle` at or after `from`, or nil.
    public func find(_ needle: StaticNeedle, from: Int) -> Int? {
        guard from < count else { return nil }
        let found = memmem(base + from, count - from, needle.pointer, needle.count)
        guard let found else { return nil }
        return UnsafeRawPointer(found) - base
    }

    public func occurrences(of needle: StaticNeedle) -> Int {
        var total = 0
        var cursor = 0
        while let hit = find(needle, from: cursor) {
            total += 1
            cursor = hit + needle.count
        }
        return total
    }

    /// Value of a `"key":"<string>"` pair, unescaped only for the common cases.
    /// Returns nil when absent or when the value is not a string.
    public func string(after needle: StaticNeedle, limit: Int = 4096) -> String? {
        guard let hit = find(needle, from: 0) else { return nil }
        let start = hit + needle.count
        guard start < count else { return nil }
        var end = start
        let maxEnd = min(count, start + limit)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        while end < maxEnd {
            let byte = bytes[end]
            if byte == 0x5C { end += 2; continue }     // backslash escape
            if byte == 0x22 { break }                   // closing quote
            end += 1
        }
        guard end > start, end < count else { return nil }
        let raw = Data(bytes: base + start, count: end - start)
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        return text.unescapingJSONStringBody()
    }

    /// Value of a `"key":<number>` pair. Ignores non-integers.
    public func int(after needle: StaticNeedle) -> Int? {
        guard let hit = find(needle, from: 0) else { return nil }
        var cursor = hit + needle.count
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var negative = false
        if cursor < count, bytes[cursor] == 0x2D { negative = true; cursor += 1 }
        var value = 0
        var digits = 0
        while cursor < count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            value = value * 10 + Int(bytes[cursor] - 0x30)
            cursor += 1
            digits += 1
            if digits > 18 { break }
        }
        guard digits > 0 else { return nil }
        return negative ? -value : value
    }

    public var data: Data { Data(bytes: base, count: count) }
}

/// A byte pattern held for the lifetime of the process so `memmem` can take a
/// stable pointer. Created once at module scope, never per line.
public final class StaticNeedle {
    public let pointer: UnsafeRawPointer
    public let count: Int

    public init(_ literal: String) {
        let bytes = Array(literal.utf8)
        count = bytes.count
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        pointer = UnsafeRawPointer(buffer)
    }
}

/// Walks a mapped file as newline-delimited records.
public enum JSONLScanner {
    /// Calls `body` for each complete line in `[from, size)`.
    /// Returns the offset just past the last complete line consumed, so an
    /// incremental re-scan can resume on a record boundary.
    @discardableResult
    public static func scan(
        _ data: Data,
        from: Int,
        _ body: (LineView) -> Void
    ) -> Int {
        data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return from }
            let total = raw.count
            var cursor = max(0, min(from, total))
            var lastComplete = cursor
            while cursor < total {
                let remaining = total - cursor
                guard let nl = memchr(base + cursor, 0x0A, remaining) else { break }
                let lineEnd = UnsafeRawPointer(nl) - base
                if lineEnd > cursor {
                    body(LineView(base: base + cursor, count: lineEnd - cursor, offsetInFile: cursor))
                }
                cursor = lineEnd + 1
                lastComplete = cursor
            }
            return lastComplete
        }
    }

    /// Maps a file read-only. `.mappedIfSafe` keeps multi-hundred-MB transcripts
    /// out of resident memory.
    public static func map(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

extension String {
    /// Minimal unescape for the subset of escapes the CLI emits inside strings
    /// we surface (paths, titles, prompts).
    public func unescapingJSONStringBody() -> String {
        guard contains("\\") else { return self }
        var out = ""
        out.reserveCapacity(count)
        var iterator = makeIterator()
        while let char = iterator.next() {
            guard char == "\\" else { out.append(char); continue }
            guard let escape = iterator.next() else { break }
            switch escape {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "u":
                var hex = ""
                for _ in 0..<4 { if let digit = iterator.next() { hex.append(digit) } }
                if let scalarValue = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(scalarValue) {
                    out.append(Character(scalar))
                }
            default: out.append(escape)
            }
        }
        return out
    }
}
