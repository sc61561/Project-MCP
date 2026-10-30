import Foundation
import Security

public struct ConnectionSettings: Codable, Equatable, Sendable {
    public var projectPath: String
    public var tunnelID: String
    public var organizationID: String
    public var rememberKey: Bool

    public init(projectPath: String = "", tunnelID: String = "", organizationID: String = "", rememberKey: Bool = false) {
        self.projectPath = projectPath
        self.tunnelID = tunnelID
        self.organizationID = organizationID
        self.rememberKey = rememberKey
    }
}

public final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "projectMCP.connectionSettings"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> ConnectionSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(ConnectionSettings.self, from: data)
    }
    public func save(_ settings: ConnectionSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: key)
    }
}

public protocol CredentialBackend {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

public enum CredentialError: Error, LocalizedError, Equatable {
    case accessDenied, invalidData, keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .accessDenied: return "无法访问钥匙串，请解锁后重试"
        case .invalidData: return "钥匙串密钥格式无效"
        case .keychain(let status): return "钥匙串操作失败（\(status)）"
        }
    }
}

public final class CredentialStore {
    private let backend: any CredentialBackend
    public init(backend: any CredentialBackend = KeychainCredentialBackend()) { self.backend = backend }
    public func read() throws -> String? { try backend.read() }
    public func save(_ key: String) throws { try backend.save(key) }
    public func delete() throws { try backend.delete() }
    public func update(key: String, remember: Bool) throws {
        if remember { try save(key) } else { try delete() }
    }
}

public final class KeychainCredentialBackend: CredentialBackend {
    private let service: String
    private let account: String
    public init(service: String = "com.sc61561.project-mcp", account: String = "control-plane-api-key") {
        self.service = service
        self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        if [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled].contains(status) {
            throw CredentialError.accessDenied
        }
        throw CredentialError.keychain(status)
    }
    public func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw CredentialError.invalidData }
        return key
    }
    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(request as CFDictionary, nil))
        } else { try check(status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}
