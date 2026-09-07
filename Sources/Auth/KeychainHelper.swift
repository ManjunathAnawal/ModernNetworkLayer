//
//  KeychainHelper.swift
//  NetworkLayer
//
//  A minimal wrapper around the Keychain Services C API for persisting
//  tokens securely. We deliberately avoid a third-party wrapper to keep
//  this networking layer dependency-free and auditable.
//
//  TRADE-OFF NOTE — Keychain vs. UserDefaults/Files:
//  Tokens MUST NOT live in UserDefaults or a plain file: UserDefaults is
//  an unencrypted plist and is trivially readable on a jailbroken device
//  or from a device backup. Keychain items are encrypted at rest and can
//  be scoped with `kSecAttrAccessible` to control availability relative
//  to device lock state. The only downside is the C API's verbosity,
//  which this file exists to hide from the rest of the codebase.
//
import Foundation
import Security

public protocol KeychainStoring: Sendable {
    func set(_ data: Data, for key: String) throws
    func get(_ key: String) throws -> Data?
    func delete(_ key: String) throws
}

public struct KeychainHelper: KeychainStoring {
    private let service: String
    /// `.afterFirstUnlockThisDeviceOnly` is the standard choice for auth
    /// tokens: they survive background app refresh / silent push
    /// (unlike `.whenUnlocked`, which would evict the token while the
    /// phone is locked and a background task tries to refresh it), but
    /// never sync to iCloud Keychain or restore onto a different device
    /// (unlike the non-`ThisDeviceOnly` variants), which is what you want
    /// for a per-device session token.
    private let accessibility: CFString

    public init(service: String = Bundle.main.bundleIdentifier ?? "com.app.networklayer",
                accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) {
        self.service = service
        self.accessibility = accessibility
    }

    public func set(_ data: Data, for key: String) throws {
        // Delete any existing item first — SecItemAdd fails with
        // errSecDuplicateItem if one already exists, and SecItemUpdate has
        // more edge cases around attribute changes, so "delete then add"
        // is the simplest correct approach for a single-value-per-key store.
        try? delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status: status)
        }
    }

    public func get(_ key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status: status)
        }
    }

    public func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }
}

public enum KeychainError: Error, Equatable {
    case unhandled(status: OSStatus)
}

/// In-memory stand-in for unit tests — the real Keychain is unavailable
/// (or behaves inconsistently) in `swift test` / SPM test hosts without a
/// signed app, so all tests inject this instead.
public final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func set(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }

    public func get(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func delete(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}
