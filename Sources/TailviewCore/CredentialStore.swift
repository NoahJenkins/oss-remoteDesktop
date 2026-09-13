import Foundation
import Security

public protocol CredentialStore: Sendable {
    func load(peerID: String, desktopProtocol: DesktopProtocol) throws -> SessionCredentials?
    func save(peerID: String, desktopProtocol: DesktopProtocol, credentials: SessionCredentials) throws
    func delete(peerID: String, desktopProtocol: DesktopProtocol) throws
}

public struct KeychainError: Error, Equatable {
    public var status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private struct Key: Hashable {
        var peerID: String
        var desktopProtocol: DesktopProtocol
    }

    private let lock = NSLock()
    private var items: [Key: SessionCredentials] = [:]

    public init() {}

    public func load(peerID: String, desktopProtocol: DesktopProtocol) throws -> SessionCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return items[Key(peerID: peerID, desktopProtocol: desktopProtocol)]
    }

    public func save(peerID: String, desktopProtocol: DesktopProtocol, credentials: SessionCredentials) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Key(peerID: peerID, desktopProtocol: desktopProtocol)] = credentials
    }

    public func delete(peerID: String, desktopProtocol: DesktopProtocol) throws {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: Key(peerID: peerID, desktopProtocol: desktopProtocol))
    }
}

public final class KeychainCredentialStore: CredentialStore, Sendable {
    public static let service = "app.tailview.credentials"

    private struct Payload: Codable {
        var username: String
        var password: String
    }

    public init() {}

    public func load(peerID: String, desktopProtocol: DesktopProtocol) throws -> SessionCredentials? {
        var query = baseQuery(peerID: peerID, desktopProtocol: desktopProtocol)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return SessionCredentials(username: payload.username, password: payload.password)
    }

    public func save(peerID: String, desktopProtocol: DesktopProtocol, credentials: SessionCredentials) throws {
        let data = try JSONEncoder().encode(
            Payload(username: credentials.username, password: credentials.password)
        )
        let query = baseQuery(peerID: peerID, desktopProtocol: desktopProtocol)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
            return
        }
        throw KeychainError(status: updateStatus)
    }

    public func delete(peerID: String, desktopProtocol: DesktopProtocol) throws {
        let status = SecItemDelete(baseQuery(peerID: peerID, desktopProtocol: desktopProtocol) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainError(status: status)
    }

    private func baseQuery(peerID: String, desktopProtocol: DesktopProtocol) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(peerID)|\(desktopProtocol.rawValue)",
        ]
    }
}
