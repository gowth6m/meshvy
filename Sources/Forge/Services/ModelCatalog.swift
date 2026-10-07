import Foundation
import Observation
import Security

/// A model offered in the launch sheet.
struct ClaudeModel: Identifiable, Hashable, Codable {
    /// `nil` means "whatever the CLI is configured to use".
    var id: String?
    var displayName: String
    /// Input context window in tokens, when known.
    var contextWindow: Int?

    var key: String { id ?? "__inherit__" }
}

/// Where the model list came from.
enum ModelSource: Equatable {
    case builtIn
    case live(Date)
    case failed(String)

    var label: String {
        switch self {
        case .builtIn: return "built-in list"
        case .live: return "live from the Models API"
        case .failed(let message): return "built-in list — \(message)"
        }
    }
}

/// Supplies the models Forge can launch an agent with.
///
/// The built-in list is always available and is what the app ships with. When an
/// Anthropic API key is present — from `ANTHROPIC_API_KEY` or saved in the
/// keychain — the catalogue refreshes from `GET /v1/models` so newly released
/// models appear without an app update.
enum ModelDefaults {
    /// Current models, most capable first. Ordered so the default sits on the
    /// tier most people want rather than the cheapest.
    static let builtIn: [ClaudeModel] = [
        ClaudeModel(id: nil, displayName: "Inherit CLI default", contextWindow: nil),
        ClaudeModel(id: "claude-opus-5", displayName: "Opus 5", contextWindow: 1_000_000),
        ClaudeModel(id: "claude-fable-5-1", displayName: "Fable 5.1", contextWindow: 1_000_000),
        ClaudeModel(id: "claude-opus-4-8", displayName: "Opus 4.8", contextWindow: 1_000_000),
        ClaudeModel(id: "claude-sonnet-5", displayName: "Sonnet 5", contextWindow: 1_000_000),
        ClaudeModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", contextWindow: 200_000)
    ]

    /// What a new agent uses unless the user picks otherwise.
    static let modelID: String? = "claude-opus-5"
}

@MainActor
@Observable
final class ModelCatalog {
    private(set) var models: [ClaudeModel] = ModelDefaults.builtIn
    /// Model new terminals launch with.
    var selectedModelID: String? = ModelDefaults.modelID
    private(set) var source: ModelSource = .builtIn
    private(set) var isRefreshing = false

    var hasCredential: Bool { ModelCatalog.resolveKey() != nil }

    /// Pulls the live list. Silently keeps the built-in list when there is no
    /// credential — model choice must keep working offline.
    func refresh() {
        guard !isRefreshing, let key = ModelCatalog.resolveKey() else { return }
        isRefreshing = true

        Task {
            do {
                let fetched = try await ModelCatalog.fetch(apiKey: key)
                guard !fetched.isEmpty else {
                    isRefreshing = false
                    return
                }
                // Keep "inherit" at the top; the API does not know about it.
                models = [ModelDefaults.builtIn[0]] + fetched
                source = .live(Date())
            } catch {
                source = .failed(error.localizedDescription)
            }
            isRefreshing = false
        }
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account: ModelCatalog.keychainAccount)
        } else {
            Keychain.set(trimmed, account: ModelCatalog.keychainAccount)
        }
        refresh()
    }

    func displayName(for id: String?) -> String {
        models.first { $0.id == id }?.displayName
            ?? Format.model(id)
            ?? "Inherit CLI default"
    }

    // MARK: - Fetching

    private static let keychainAccount = "anthropic-api-key"

    /// Environment first, then the keychain. Never reads Claude Code's own
    /// credentials — launching an agent uses the CLI's auth, and this key is
    /// only for listing models.
    static func resolveKey() -> String? {
        if let environment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !environment.isEmpty {
            return environment
        }
        return Keychain.get(account: keychainAccount)
    }

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable {
            var id: String
            var display_name: String?
            var max_input_tokens: Int?
        }
        var data: [Entry]
    }

    private static func fetch(apiKey: String) async throws -> [ClaudeModel] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CatalogError.message("no response")
        }
        guard http.statusCode == 200 else {
            throw CatalogError.message("Models API returned \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { entry in
            ClaudeModel(
                id: entry.id,
                displayName: entry.display_name ?? Format.model(entry.id) ?? entry.id,
                contextWindow: entry.max_input_tokens
            )
        }
    }

    enum CatalogError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }
}

/// Minimal keychain wrapper for the one secret Forge stores.
enum Keychain {
    private static let service = "dev.gowtham.forge"

    static func set(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
