import Foundation

/// Decoding that tolerates a key that is not there.
///
/// Swift's synthesised `init(from:)` ignores a property's default value and
/// insists on the key being present. For a file the app rewrites on every
/// change that is fine — until a release adds a field, at which point every
/// board saved before it existed fails to decode and the user opens Meshvy to
/// find their workspaces gone. These let a model read an older file and fill in
/// what was not written yet.
extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when the key is absent or unreadable.
    public func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    /// The stored value of an optional field, or nil.
    public func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
