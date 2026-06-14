import Foundation
import Security

enum VaraCredentialProvider: String, CaseIterable, Identifiable {
    case elevenLabs
    case groq
    case openAI
    case anthropic

    var id: String { rawValue }

    var keychainAccount: String {
        switch self {
        case .elevenLabs: "elevenlabs.api-key"
        case .groq: "groq.api-key"
        case .openAI: "openai.api-key"
        case .anthropic: "anthropic.api-key"
        }
    }
}

protocol VaraCredentialStoring {
    func credential(for provider: VaraCredentialProvider) throws -> String?
    func saveCredential(_ credential: String, for provider: VaraCredentialProvider) throws
    func deleteCredential(for provider: VaraCredentialProvider) throws
    func credential(forCustomEndpoint id: UUID) throws -> String?
    func saveCredential(_ credential: String, forCustomEndpoint id: UUID) throws
}

struct VaraKeychainCredentialStore: VaraCredentialStoring {
    var service: String

    init(service: String = Bundle.main.bundleIdentifier.map { "\($0).credentials" } ?? "dk.56n.vara.credentials") {
        self.service = service
    }

    func credential(for provider: VaraCredentialProvider) throws -> String? {
        try credential(account: provider.keychainAccount)
    }

    func saveCredential(_ credential: String, for provider: VaraCredentialProvider) throws {
        try saveCredential(credential, account: provider.keychainAccount)
    }

    func deleteCredential(for provider: VaraCredentialProvider) throws {
        try deleteCredential(account: provider.keychainAccount)
    }

    func credential(forCustomEndpoint id: UUID) throws -> String? {
        try credential(account: Self.customEndpointAccount(id))
    }

    func saveCredential(_ credential: String, forCustomEndpoint id: UUID) throws {
        try saveCredential(credential, account: Self.customEndpointAccount(id))
    }

    private static func customEndpointAccount(_ id: UUID) -> String {
        "custom-endpoint.\(id.uuidString).api-key"
    }

    private func credential(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw VaraKeychainError.unhandledStatus(status)
        }

        guard let data = item as? Data else {
            throw VaraKeychainError.invalidData
        }

        return String(data: data, encoding: .utf8)
    }

    private func saveCredential(_ credential: String, account: String) throws {
        guard !credential.isEmpty else {
            try deleteCredential(account: account)
            return
        }

        let data = Data(credential.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw VaraKeychainError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VaraKeychainError.unhandledStatus(addStatus)
        }
    }

    private func deleteCredential(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaraKeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum VaraKeychainError: Error, Equatable {
    case invalidData
    case unhandledStatus(OSStatus)
}
