// SPDX-License-Identifier: GPL-3.0-or-later

// Where the daemon keeps provider keys (docs/dev/engine-internals.md, "Credentials and usage").
//
// The contract can write a key and never read one back (ai.proto, `Credential`), so the secret
// lives behind this protocol and nothing above it: `CredentialStore` keeps what a listing shows in
// `ai.json` and asks a `SecretStore` only when a worker needs the key. On macOS that is a
// login-keychain item `leylined` creates, which the daemon reads without a prompt and any other
// program reads only after macOS asks the user; elsewhere, where the daemon runs for development
// and CI, it is a file only the user can read. No error thrown here carries a secret: the messages
// name the file or the keychain status, never what was being stored.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
#endif

/// One secret per provider, written, read and removed by the provider's name.
protocol SecretStore: Sendable {
    func set(provider: String, secret: String) throws
    /// The provider's secret, or nil when none is stored.
    func get(provider: String) throws -> String?
    /// Removing a secret that is not stored is not an error.
    func remove(provider: String) throws
}

/// Why a secret could not be stored, read or removed. The message names the file or the
/// keychain's own words, so it can go into a log line or an `ErrorDetail` as it stands.
struct SecretStoreError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// The platform's store: the login keychain on macOS, `credentials.json` in `dataPath` elsewhere.
func defaultSecretStore(dataPath: String) -> any SecretStore {
    #if canImport(Security)
    return KeychainSecrets()
    #else
    return FileSecrets(path: dataPath + "/credentials.json")
    #endif
}

/// `credentials.json`: a JSON object of provider name to secret, mode 0600 in a directory of mode
/// 0700. Every write goes to a temporary file created 0600 by `open(2)` and is renamed over the old
/// one, so the secret is never in a file another user can read, not even for the moment between
/// a write and a `chmod`, and a crash mid-write leaves the previous file whole
/// (docs/dev/swift-style.md, "Foundation on two platforms").
struct FileSecrets: SecretStore {
    let path: String

    func set(provider: String, secret: String) throws {
        var all = try load()
        all[provider] = secret
        try save(all)
    }

    func get(provider: String) throws -> String? {
        try load()[provider]
    }

    func remove(provider: String) throws {
        var all = try load()
        guard all.removeValue(forKey: provider) != nil else { return }
        try save(all)
    }

    private func load() throws -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        guard let all = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw SecretStoreError(message: "\(path) is not a key file")
        }
        return all
    }

    private func save(_ all: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(all)
        data.append(0x0a)
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw SecretStoreError(message: "cannot create \(dir): \(error.localizedDescription)")
        }
        let tmp = path + ".tmp-\(getpid())"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecretStoreError(message: "cannot write \(tmp): \(Self.errnoText())") }
        // O_CREAT's mode only applies to a new file; one left behind by a crash keeps its own.
        _ = fchmod(fd, 0o600)
        let wrote = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard wrote, synced else {
            let why = Self.errnoText()
            unlink(tmp)
            throw SecretStoreError(message: "cannot write \(tmp): \(why)")
        }
        guard rename(tmp, path) == 0 else {
            let why = Self.errnoText()
            unlink(tmp)
            throw SecretStoreError(message: "cannot replace \(path): \(why)")
        }
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}

#if canImport(Security)
/// A login-keychain generic password per provider: service `com.leysdr.leyline`, account the
/// provider's name, readable after the first unlock so a daemon launchd starts at login can read
/// it. Created by `leylined`, so the daemon reads it without a prompt and macOS asks the user
/// before any other program does. Never compiled on Linux; checked on the Mac only.
struct KeychainSecrets: SecretStore {
    static let service = "com.leysdr.leyline"

    private func query(_ provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider,
        ]
    }

    func set(provider: String, secret: String) throws {
        // Replace rather than update: an item another build of leylined created carries that
        // build's access list, and a fresh item carries this one's.
        let deleted = SecItemDelete(query(provider) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw Self.error(deleted, "cannot replace the \(provider) key in the keychain")
        }
        var add = query(provider)
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Leyline: \(provider) key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status, "cannot store the \(provider) key in the keychain") }
    }

    func get(provider: String) throws -> String? {
        var search = query(provider)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.error(status, "cannot read the \(provider) key from the keychain")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func remove(provider: String) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status, "cannot remove the \(provider) key from the keychain")
        }
    }

    private static func error(_ status: OSStatus, _ what: String) -> SecretStoreError {
        let words = (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
        return SecretStoreError(message: "\(what): \(words)")
    }
}
#endif
