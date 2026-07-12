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
import os

nonisolated enum Keychain {
    private static let log = Logger(subsystem: "com.omwhisper.mac", category: "Keychain")
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
        // A non-success, non-notFound status means the item exists but this build
        // can't read it (e.g. ACL from a differently-signed build) — logged so a
        // "No key saved yet" that's actually an access failure is diagnosable.
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("load[\(account, privacy: .public)]: read failed status=\(status, privacy: .public)")
        }
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
        // Add-first, update-on-duplicate — NEVER delete-first. An earlier
        // delete-then-add could leave the item deleted-with-nothing-added if the
        // add failed or its keychain auth prompt was dismissed, so re-saving kept
        // making the key vanish. Add-first can't destroy an existing key on failure.
        var attributes = query
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            log.info("save[\(account, privacy: .public)]: add=duplicate update=\(updateStatus, privacy: .public)")
            guard updateStatus == errSecSuccess else { throw KeychainError.unhandled(updateStatus) }
        } else {
            log.info("save[\(account, privacy: .public)]: add=\(addStatus, privacy: .public)")
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        }
        // Verify it actually landed — turns any silent write oddity into a clear
        // error instead of a UI that claims "saved" over an unreadable item.
        let persisted = load(account: account) == key
        log.info("save[\(account, privacy: .public)]: verify=\(persisted, privacy: .public)")
        guard persisted else { throw KeychainError.notPersisted }
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
