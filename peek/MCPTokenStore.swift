import Foundation
import Security
import OSLog

private let log = Logger(subsystem: "com.oldsalt.peek", category: "mcp-token")

// Generic-password Keychain wrapper for the MCP server's bearer token. Single
// token per install; rotation is destructive (generate → invalidate old). The
// keychain item is accessible only after first device unlock so cron-style
// post-reboot logins don't leak the token before the user authenticates.

enum MCPTokenStoreError: Error, LocalizedError {
    case keychainStatus(OSStatus)
    case malformedRandomBytes

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "Keychain error"
            return "\(msg) (\(s))"
        case .malformedRandomBytes:
            return "Failed to generate secure random bytes"
        }
    }
}

enum MCPTokenStore {
    private static let service = "com.oldsalt.peek.mcp"
    private static let account = "mcp-token"

    static func generateAndStore() throws -> String {
        let token = try randomToken()
        try store(token: token)
        log.info("mcp token rotated")
        return token
    }

    static func currentToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MCPTokenStoreError.keychainStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func revoke() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPTokenStoreError.keychainStatus(status)
        }
        if status == errSecSuccess { log.info("mcp token revoked") }
    }

    private static func store(token: String) throws {
        try revoke()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MCPTokenStoreError.keychainStatus(status)
        }
    }

    // 32 random bytes, URL-safe base64 (no padding). 256 bits of entropy is
    // overkill for a localhost-only bearer but cheap.
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw MCPTokenStoreError.malformedRandomBytes
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
