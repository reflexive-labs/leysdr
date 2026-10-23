// SPDX-License-Identifier: GPL-3.0-or-later

// Where the daemon keeps provider keys (docs/dev/engine-internals.md, "Credentials and usage").
//
// The contract can write a key and never read one back (ai.proto, `Credential`), so the secret
// lives behind this protocol and nothing above it: `CredentialStore` keeps what a listing shows in
// `ai.json` and asks a `SecretStore` only when a worker needs the key. On macOS that is a
// login-keychain item `leylined` creates, which the daemon reads without a prompt and any other
// program reads only after macOS asks the user; elsewhere, where the daemon runs for development
// and CI, it is a file only the user can read, in a directory only the user can open. No error thrown here carries a secret: the messages
// name the file or the keychain status, never what was being stored.

import Foundation
import Logging
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
/// keychain's own words and status, so it can go into a log line or an `ErrorDetail` as it
/// stands. `remedy` is what to do about it when the cause says more than "add the key again"
/// (`KeychainFailure.remedy`); empty otherwise.
struct SecretStoreError: Error, CustomStringConvertible {
    let message: String
    var remedy: String = ""
    /// The message and the remedy in one line.
    var description: String { remedy.isEmpty ? message : "\(message); \(remedy)" }
}

/// How a failed keychain call reads (docs/plans/app.md, MC-8). Here rather than in
/// `KeychainSecrets` so the words are tested on every platform; only the numbers are needed.
enum KeychainFailure {
    /// Statuses with which the keychain refuses the calling program rather than reporting on the
    /// item: the item's access list names another build of leylined. A source build signed ad hoc
    /// is a new program after every relink, and a daemon whose file was relinked under it fails
    /// every read. Under launchd no prompt can be shown, so the refusal arrives as one of these.
    static let identityStatuses: [Int32: String] = [
        -25293: "errSecAuthFailed",
        -25308: "errSecInteractionNotAllowed",
        -25244: "errSecInvalidOwnerEdit",
        -25243: "errSecNoAccessForItem",
        -128: "errSecUserCanceled",
    ]

    static func isIdentity(_ status: Int32) -> Bool { identityStatuses[status] != nil }

    /// `what: the keychain's words (OSStatus n)`; the status alone when the keychain has no words.
    static func message(_ what: String, status: Int32, words: String?) -> String {
        guard let words, !words.isEmpty else { return "\(what): OSStatus \(status)" }
        return "\(what): \(words) (OSStatus \(status))"
    }

    /// Whether `executable` is a daemon built from source: one in a SwiftPM build directory, or
    /// the copy `make reload` installs. The app's helper and a packaged install are neither.
    static func runsFromSource(_ executable: String) -> Bool {
        executable.contains("/.build/") || executable.contains("/Library/Application Support/Leyline/bin/")
    }

    /// The developer's way out of a refusal for code identity: `make reload` installs a signed
    /// copy, and the key is added again so its access list names that copy. Empty for any other
    /// status, and for a daemon not built from source, whose user has no `make`.
    static func remedy(status: Int32, provider: String, executable: String) -> String {
        guard isIdentity(status), runsFromSource(executable) else { return "" }
        let again = "run make reload, then add the key again with ley ai add \(provider)"
        guard executable.contains("/.build/") else { return again }
        return "this leylined runs from a build directory that a rebuild replaces under it; \(again)"
    }

    static func error(_ what: String, provider: String, status: Int32, words: String?,
                      executable: String) -> SecretStoreError
    {
        SecretStoreError(message: message(what, status: status, words: words),
                         remedy: remedy(status: status, provider: provider, executable: executable))
    }

    /// The running daemon's executable, with symlinks resolved.
    static var executable: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ""))
            .resolvingSymlinksInPath().path
    }
}

/// Which store holds the keys: `leylined --secrets`, else `LEYLINE_SECRETS`, else the platform's.
package enum SecretsKind: String, CaseIterable, Sendable {
    /// `secrets/credentials.json` in the data directory, on every platform. A daemon a test or an
    /// eval starts uses it, so a key it is given never reaches the Mac's login keychain.
    case file
    /// The login keychain. Only macOS has one; elsewhere this is the file.
    case keychain

    /// `LEYLINE_SECRETS` from `environment`; a value that is neither kind is the platform default.
    package static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SecretsKind? {
        environment["LEYLINE_SECRETS"].flatMap { SecretsKind(rawValue: $0.lowercased()) }
    }
}

/// The store `kind` names, or the platform's when it names none: the login keychain on macOS,
/// `secrets/credentials.json` in `dataPath` elsewhere.
func defaultSecretStore(dataPath: String, kind: SecretsKind? = SecretsKind.fromEnvironment()) -> any SecretStore {
    if kind == .file { return FileSecrets(inData: dataPath) }
    #if canImport(Security)
    return KeychainSecrets()
    #else
    return FileSecrets(inData: dataPath)
    #endif
}

/// Where `store` keeps keys, for the daemon's start-up line `AI keys in …`: the file's path, or
/// `the login keychain`. A test harness reads that line and refuses a daemon that names the
/// keychain, so a key a test adds can never reach the person's own.
func secretStoreLocation(_ store: any SecretStore) -> String {
    if let f = store as? FileSecrets { return f.path }
    #if canImport(Security)
    if store is KeychainSecrets { return "the login keychain" }
    #endif
    return "a store of \(type(of: store))"
}

/// `secrets/credentials.json`: a JSON object of provider name to secret, mode 0600, in a
/// directory of its own kept at mode 0700. The data directory itself is not enough: the record
/// store and the recordings may have created it 0755 first, and its mode is theirs. Every write
/// goes through `writePrivateFile(_:to:)`, and a temporary file a crash left, which may hold a
/// secret, is removed the next time the file is read.
struct FileSecrets: SecretStore {
    let path: String

    init(path: String) {
        self.path = path
    }

    /// The key file in a data directory: `<data>/secrets/credentials.json`.
    init(inData dataPath: String) {
        self.init(path: dataPath + "/secrets/credentials.json")
    }

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
        sweepPrivateFileTemporaries(of: path)
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
            // A directory that already existed keeps its mode through createDirectory.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            try writePrivateFile(data, to: path)
        } catch let error as PrivateFileError {
            throw SecretStoreError(message: error.message)
        } catch {
            throw SecretStoreError(message: "cannot create \(dir): \(error.localizedDescription)")
        }
    }
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
            throw Self.error(deleted, "cannot replace the \(provider) key in the keychain", provider)
        }
        var add = query(provider)
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Leyline: \(provider) key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status, "cannot store the \(provider) key in the keychain", provider) }
    }

    func get(provider: String) throws -> String? {
        var search = query(provider)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.error(status, "cannot read the \(provider) key from the keychain", provider)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func remove(provider: String) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status, "cannot remove the \(provider) key from the keychain", provider)
        }
    }

    private static let log = Logger(label: "leyline.ai")

    /// The failure in the keychain's words and status, logged here so no failed call goes
    /// unrecorded whichever caller swallows it (a worker's key read used to).
    private static func error(_ status: OSStatus, _ what: String, _ provider: String) -> SecretStoreError {
        let words = SecCopyErrorMessageString(status, nil) as String?
        let error = KeychainFailure.error(what, provider: provider, status: status, words: words,
                                          executable: KeychainFailure.executable)
        log.error("\(error.description)")
        return error
    }
}
#endif
