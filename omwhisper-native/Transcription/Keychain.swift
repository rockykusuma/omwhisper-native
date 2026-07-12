//
//  Keychain.swift
//  OmWhisper
//
//  Minimal wrapper over the Security framework, scoped to exactly one named
//  generic-password item: the user's AssemblyAI API key (CloudEngine, M4.2).
//  The API key must never touch UserDefaults or any other plaintext store.
//

import Foundation
import Security

nonisolated enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.omwhisper.mac"
    private static let assemblyAIAccount = "assemblyai-api-key"
    private static let cloudLLMAccount = "cloud-llm-api-key"

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        case notPersisted
        var errorDescription: String? {
            switch self {
            case .unhandled(let status): return "Couldn't access the Keychain (status \(status))."
            case .notPersisted: return "The key didn't persist to the Keychain — please try saving again."
            }
        }
    }

    // MARK: AssemblyAI (M4.2 CloudEngine)
    static func loadAssemblyAIKey() -> String? { load(account: assemblyAIAccount) }
    static func saveAssemblyAIKey(_ key: String) throws { try save(key, account: assemblyAIAccount) }
    static func deleteAssemblyAIKey() throws { try delete(account: assemblyAIAccount) }

    // MARK: Cloud polish LLM (M3-2b)
    static func loadCloudLLMKey() -> String? { load(account: cloudLLMAccount) }
    static func saveCloudLLMKey(_ key: String) throws { try save(key, account: cloudLLMAccount) }
    static func deleteCloudLLMKey() throws { try delete(account: cloudLLMAccount) }

    // MARK: Cloud transcription providers (multi-provider) — one account per provider.
    static func loadSTTKey(_ provider: CloudProviderKind) -> String? { load(account: provider.keychainAccount) }
    static func saveSTTKey(_ key: String, provider: CloudProviderKind) throws { try save(key, account: provider.keychainAccount) }
    static func deleteSTTKey(_ provider: CloudProviderKind) throws { try delete(account: provider.keychainAccount) }

    // MARK: Generic core

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add, NOT add-vs-update keyed on load(). The real AssemblyAI
        // bug: a leftover item from a differently-signed earlier build (dev
        // rebuilds re-sign) is unreadable by the current build — load() returns
        // nil ("No key saved yet") — yet still blocks a plain SecItemAdd with
        // errSecDuplicateItem, and SecItemUpdate can be ACL-blocked too. Delete
        // matches by attributes only (no read/ACL needed), clearing the leftover;
        // then add a fresh item this build owns.
        SecItemDelete(query as CFDictionary)   // errSecItemNotFound is fine — ignore
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        // Verify it actually landed — turns any silent write oddity into a clear
        // error instead of a UI that claims "saved" over an unreadable item.
        guard load(account: account) == key else { throw KeychainError.notPersisted }
    }

    private static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
