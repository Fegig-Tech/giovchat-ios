#if canImport(Security)
import Foundation
import Security

/// Stores sessions in the Keychain as generic passwords, readable after the first unlock and never synced or
/// restored to another device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
///
/// Each scope is one item: the service is ``service`` and the account is the scope key. The item holds the
/// conversation id and the session token as JSON.
///
/// On macOS the items go to the data protection keychain (`kSecUseDataProtectionKeychain`), the one iOS uses, where
/// the accessibility class and ``accessGroup`` apply and no keychain prompt can appear. Apps without a keychain
/// entitlement (unsigned builds, command-line tools) cannot use it; for them the store falls back to the login
/// keychain.
public struct KeychainGiovSessionStore: GiovSessionStore {
    /// The Keychain service the items are filed under.
    public let service: String
    /// An optional Keychain access group, to share sessions between an app and its extensions.
    public let accessGroup: String?

    public init(service: String = "app.giovchat.session", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// A Keychain call failed with `status` (an `OSStatus`). `errSecInteractionNotAllowed` (-25308) means the device
    /// has not been unlocked since it started; the controller tries again later.
    public struct KeychainError: Error, Sendable, Equatable {
        public let status: Int32
    }

    private func baseQuery(scope: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    /// Runs `call` against the data protection keychain, falling back to the login keychain on macOS when the app has
    /// no entitlement for the former. Only adding reports the missing entitlement; a search without it just finds
    /// nothing, so reads also fall back when nothing is found (that is where a write without the entitlement went).
    private func withKeychain(fallbackOn fallback: Set<OSStatus> = [errSecMissingEntitlement], _ call: (_ dataProtection: Bool) -> OSStatus) -> OSStatus {
        #if os(macOS)
        let status = call(true)
        return fallback.contains(status) ? call(false) : status
        #else
        return call(false)
        #endif
    }

    public func read(scope: String) async throws -> GiovSession? {
        var result: AnyObject?
        let status = withKeychain(fallbackOn: [errSecMissingEntitlement, errSecItemNotFound]) { dataProtection in
            var query = baseQuery(scope: scope, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            result = nil
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        let map = parseJSONObject(data)
        guard let id = map.at("conversationId").string, let token = map.at("sessionToken").string else { return nil }
        return GiovSession(conversationId: id, sessionToken: token)
    }

    public func write(scope: String, session: GiovSession) async throws {
        let payload = JSONValue.object([
            "conversationId": .string(session.conversationId),
            "sessionToken": .string(session.sessionToken),
        ]).serialized
        let data = Data(payload.utf8)
        let status = withKeychain { dataProtection in
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updated = SecItemUpdate(baseQuery(scope: scope, dataProtection: dataProtection) as CFDictionary, update as CFDictionary)
            guard updated == errSecItemNotFound else { return updated }
            var add = baseQuery(scope: scope, dataProtection: dataProtection)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(scope: String) async throws {
        // Both keychains, like reads: the item is in whichever one the write could use.
        #if os(macOS)
        let statuses = [true, false].map { SecItemDelete(baseQuery(scope: scope, dataProtection: $0) as CFDictionary) }
        #else
        let statuses = [SecItemDelete(baseQuery(scope: scope, dataProtection: false) as CFDictionary)]
        #endif
        let ignored: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        if let status = statuses.first(where: { !ignored.contains($0) }) { throw KeychainError(status: status) }
    }
}
#endif
