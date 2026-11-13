import Foundation
import Security

enum Credential: String, CaseIterable {
    case openAI, claude, gemini

    var name: String {
        switch self {
        case .openAI: "OpenAI API key"
        case .claude: "Anthropic API key"
        case .gemini: "Gemini API key"
        }
    }
}

protocol CredentialStore {
    func read(_ credential: Credential) throws -> String?
    func write(_ value: String, for credential: Credential) throws
    func delete(_ credential: Credential) throws
}

struct Keychain: CredentialStore {
    var service = "org.cuelens.mac.providers"

    private func query(_ credential: Credential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue,
            kSecAttrSynchronizable as String: false
        ]
    }

    func read(_ credential: Credential) throws -> String? {
        var request = query(credential)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ProviderError.credentialUnavailable
        }
        return value
    }

    func write(_ value: String, for credential: Credential) throws {
        let request = query(credential)
        let valueAttributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(request as CFDictionary, valueAttributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = request.merging(valueAttributes) { _, value in value }
            let insert = SecItemAdd(item as CFDictionary, nil)
            if insert == errSecDuplicateItem {
                try check(SecItemUpdate(request as CFDictionary, valueAttributes as CFDictionary))
            } else {
                try check(insert)
            }
        } else {
            try check(status)
        }
    }

    func delete(_ credential: Credential) throws {
        let status = SecItemDelete(query(credential) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ProviderError.keychain(status) }
    }
}
