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

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let status): return "Couldn't access the Keychain (status \(status))."
            }
        }
    }

    static func loadAssemblyAIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAssemblyAIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount,
        ]
        if loadAssemblyAIKey() != nil {
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        } else {
            var attributes = query
            attributes[kSecValueData as String] = data
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        }
    }

    static func deleteAssemblyAIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: assemblyAIAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
