import Foundation
import Security

struct CredentialStore {
    var account = Deployment.current.credentialAccount

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Deployment.current.bundleID + ".session",
         kSecAttrAccount as String: account]
    }

    func load() throws -> Credentials? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw ConnectionIssue.invalidResponse }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    func save(_ credentials: Credentials) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func clear() throws {
        #if !ITERATE_VOICE_ONLY
        if account == Deployment.current.credentialAccount { WidgetSnapshotService.selectPairing(nil) }
        #endif
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "The iOS Keychain could not access your sign-in. Unlock your device and try again.",
            ])
        }
    }
}
