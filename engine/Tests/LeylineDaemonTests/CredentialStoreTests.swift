// SPDX-License-Identifier: GPL-3.0-or-later

// The key file and the key list behind it: who can read the file, what survives a rewrite, and
// what a listing shows (docs/dev/engine-internals.md, "Credentials and usage").

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class CredentialStoreTests: XCTestCase {
    private let secret = "sk-test-SECRETMARKER9f3"

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testTheKeyFileIsReadableOnlyByItsOwner() throws {
        let dir = try makeTempDir("secrets")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // The record store and the recordings create the data directory 0755 before any key.
        let data = dir + "/data"
        try FileManager.default.createDirectory(atPath: data + "/secrets", withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data)
        let store = FileSecrets(inData: data)
        let path = data + "/secrets/credentials.json"
        try store.set(provider: "anthropic", secret: secret)
        XCTAssertEqual(try mode(path), 0o600)
        XCTAssertEqual(try mode(data + "/secrets"), 0o700, "the key's directory is the user's alone, whoever made it")
        XCTAssertEqual(try mode(data), 0o755, "the data directory is left as the others made it")
        // A rewrite keeps the mode: the new file is a new inode created 0600, not the old one.
        try store.set(provider: "openai", secret: "sk-other-0000")
        XCTAssertEqual(try mode(path), 0o600)
    }

    /// `LEYLINE_SECRETS=file` puts the keys in the data directory on every platform, which is what
    /// keeps a test or eval daemon on a Mac out of the login keychain; any other value is the
    /// platform's choice, and `--secrets` wins over the variable.
    func testLeylineSecretsFileSelectsTheFileStore() throws {
        XCTAssertEqual(SecretsKind.fromEnvironment(["LEYLINE_SECRETS": "file"]), .file)
        XCTAssertEqual(SecretsKind.fromEnvironment(["LEYLINE_SECRETS": "keychain"]), .keychain)
        XCTAssertNil(SecretsKind.fromEnvironment(["LEYLINE_SECRETS": "vault"]))
        XCTAssertNil(SecretsKind.fromEnvironment([:]))

        let dir = try makeTempDir("secrets")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let data = dir + "/data"
        let store = defaultSecretStore(dataPath: data, kind: SecretsKind.fromEnvironment(["LEYLINE_SECRETS": "file"]))
        XCTAssertTrue(store is FileSecrets, "LEYLINE_SECRETS=file is the file store, not \(type(of: store))")
        try store.set(provider: "anthropic", secret: secret)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data + "/secrets/credentials.json"), "the key is under --data")
        XCTAssertEqual(try store.get(provider: "anthropic"), secret)
    }

    /// The start-up line `AI keys in …` names the file's path or the keychain; the test harnesses
    /// read it and refuse a daemon that names the keychain.
    func testTheStartUpLineNamesWhereKeysAreKept() {
        XCTAssertEqual(secretStoreLocation(FileSecrets(inData: "/tmp/d")), "/tmp/d/secrets/credentials.json")
        #if canImport(Security)
        XCTAssertEqual(secretStoreLocation(KeychainSecrets()), "the login keychain")
        #endif
    }

    func testSecretsRoundTripPerProvider() throws {
        let dir = try makeTempDir("secrets")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileSecrets(path: dir + "/credentials.json")
        XCTAssertNil(try store.get(provider: "anthropic"))
        try store.set(provider: "anthropic", secret: secret)
        try store.set(provider: "openai", secret: "sk-other-0000")
        try store.set(provider: "anthropic", secret: secret + "-new")
        // A second store on the same file is a daemon restarted.
        let reopened = FileSecrets(path: dir + "/credentials.json")
        XCTAssertEqual(try reopened.get(provider: "anthropic"), secret + "-new")
        XCTAssertEqual(try reopened.get(provider: "openai"), "sk-other-0000")
    }

    func testRemoveTakesOneProviderAndToleratesAMissingOne() throws {
        let dir = try makeTempDir("secrets")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileSecrets(path: dir + "/credentials.json")
        try store.set(provider: "anthropic", secret: secret)
        try store.set(provider: "openai", secret: "sk-other-0000")
        try store.remove(provider: "anthropic")
        try store.remove(provider: "never-added")
        XCTAssertNil(try store.get(provider: "anthropic"))
        XCTAssertEqual(try store.get(provider: "openai"), "sk-other-0000")
        let text = try String(contentsOfFile: dir + "/credentials.json", encoding: .utf8)
        XCTAssertFalse(text.contains("SECRETMARKER"), "a removed secret is gone from the file")
    }

    func testATemporaryFileACrashLeftIsSweptOnRead() throws {
        let dir = try makeTempDir("secrets")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stale = dir + "/credentials.json.tmp-99999"
        try "{\"anthropic\": \"\(secret)\"}".write(toFile: stale, atomically: false, encoding: .utf8)
        XCTAssertNil(try FileSecrets(path: dir + "/credentials.json").get(provider: "anthropic"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
    }

    func testAWriteLeavesNoTemporaryFileBehind() throws {
        let dir = try makeTempDir("secrets")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileSecrets(path: dir + "/credentials.json")
        for i in 0..<5 { try store.set(provider: "p\(i)", secret: secret) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["credentials.json"])
    }

    func testAnUnreadableKeyFileIsAnErrorNamingTheFileAndNotItsContents() throws {
        let dir = try makeTempDir("secrets")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/credentials.json"
        try "not json SECRETMARKER".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FileSecrets(path: path).get(provider: "anthropic")) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains(path), text)
            XCTAssertFalse(text.contains("SECRETMARKER"), text)
        }
    }

    func testTheListShowsTheLastFourAndNeverTheSecret() async throws {
        let dir = try makeTempDir("credentials")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = CredentialStore(path: dir + "/ai.json", secrets: FileSecrets(path: dir + "/credentials.json"))
        let credential = try await store.set(provider: "anthropic", secret: secret, label: "home", endpoint: "")
        XCTAssertEqual(credential.lastFour, "R9f3")
        XCTAssertEqual(credential.label, "home")
        XCTAssertGreaterThan(credential.addedAtNs, 0)
        let stored = try await store.secret(provider: "anthropic")
        XCTAssertEqual(stored, secret)
        let listing = try await store.snapshot().jsonString()
        XCTAssertFalse(listing.contains("SECRETMARKER"), listing)
        XCTAssertEqual(try mode(dir + "/ai.json"), 0o600, "the key list is the user's alone too")
        let file = try String(contentsOfFile: dir + "/ai.json", encoding: .utf8)
        XCTAssertFalse(file.contains("SECRETMARKER"), "ai.json holds what a listing shows, never the key")
        XCTAssertEqual(CredentialStore.lastFour(of: "abcd"), "", "a secret of four shows none of itself")
        XCTAssertEqual(CredentialStore.lastFour(of: "abcde"), "bcde")
    }

    func testTheListSurvivesARestartAndADeleteTakesTheSecret() async throws {
        let dir = try makeTempDir("credentials")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secrets = FileSecrets(path: dir + "/credentials.json")
        let first = CredentialStore(path: dir + "/ai.json", secrets: secrets)
        let added = try await first.set(provider: "anthropic", secret: secret, label: "", endpoint: "https://gw.example")
        var check = Leyline_V1_CredentialCheck()
        check.outcome = .accepted
        check.atNs = 7
        let recorded = await first.recordCheck(provider: "anthropic", addedAtNs: added.addedAtNs, check)
        XCTAssertNotNil(recorded)
        let stale = await first.recordCheck(provider: "anthropic", addedAtNs: added.addedAtNs + 1, check)
        XCTAssertNil(stale, "a check of a key that has since been replaced is not recorded")
        var model = Leyline_V1_FeatureModel()
        model.feature = "speech"
        model.provider = "openai"
        model.model = "whisper-1"
        _ = await first.setFeature(model)

        let second = CredentialStore(path: dir + "/ai.json", secrets: secrets)
        let state = await second.snapshot()
        XCTAssertEqual(state.credentials.map(\.provider), ["anthropic"])
        XCTAssertEqual(state.credentials.first?.endpoint, "https://gw.example")
        XCTAssertEqual(state.credentials.first?.lastCheck.outcome, .accepted)
        XCTAssertEqual(state.features, [model])

        let removed = try await second.remove(provider: "anthropic")
        XCTAssertTrue(removed)
        let again = try await second.remove(provider: "anthropic")
        XCTAssertFalse(again, "a second delete finds nothing")
        let gone = try await second.secret(provider: "anthropic")
        XCTAssertNil(gone)
        XCTAssertNil(try secrets.get(provider: "anthropic"))
        let after = await second.snapshot()
        XCTAssertTrue(after.credentials.isEmpty)
    }
    // MARK: A key the keychain will not give up (docs/plans/app.md, MC-8)

    private static let buildTree = "/Users/me/leysdr/engine/.build/arm64-apple-macosx/release/leylined"
    private static let reloadCopy = "/Users/me/Library/Application Support/Leyline/bin/leylined"
    private static let appHelper = "/Applications/Leyline.app/Contents/Helpers/leylined"

    func testAFailedKeychainCallNamesItsWordsAndStatus() {
        XCTAssertEqual(KeychainFailure.message("cannot read the openai key from the keychain", status: -25308,
                                               words: "User interaction is not allowed."),
                       "cannot read the openai key from the keychain: User interaction is not allowed. (OSStatus -25308)")
        XCTAssertEqual(KeychainFailure.message("cannot read the openai key from the keychain", status: -50, words: nil),
                       "cannot read the openai key from the keychain: OSStatus -50",
                       "a status the Security framework has no words for is named by its number")
        XCTAssertEqual(KeychainFailure.message("x", status: -50, words: ""), "x: OSStatus -50")
    }

    func testOnlyARefusalOfTheProgramSendsADeveloperToMakeReload() {
        for status: Int32 in [-25293, -25308, -25244, -25243, -128] {
            XCTAssertTrue(KeychainFailure.isIdentity(status), "\(status)")
            XCTAssertEqual(KeychainFailure.remedy(status: status, provider: "openai", executable: Self.buildTree),
                           "this leylined runs from a build directory that a rebuild replaces under it; "
                               + "run make reload, then add the key again with ley ai add openai")
            XCTAssertEqual(KeychainFailure.remedy(status: status, provider: "openai", executable: Self.reloadCopy),
                           "run make reload, then add the key again with ley ai add openai",
                           "an ad-hoc reload copy is a new program after the next reload too")
            XCTAssertEqual(KeychainFailure.remedy(status: status, provider: "openai", executable: Self.appHelper), "",
                           "the app's daemon has no make to run")
        }
        for status: Int32 in [-25300, -25299, -50, -34018, 0] {
            XCTAssertFalse(KeychainFailure.isIdentity(status), "\(status)")
            XCTAssertEqual(KeychainFailure.remedy(status: status, provider: "openai", executable: Self.buildTree), "",
                           "status \(status) is not about which program asked")
        }
    }

    func testAKeyTheStoreCannotReadIsMissingInTheStoresWords() async throws {
        let dir = try makeTempDir("credentials")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let refusal = KeychainFailure.error("cannot read the openai key from the keychain", provider: "openai",
                                            status: -25308, words: "User interaction is not allowed.",
                                            executable: Self.buildTree)
        let store = CredentialStore(path: dir + "/ai.json", secrets: UnreadableSecrets(error: refusal))
        _ = try await store.set(provider: "openai", secret: secret, label: "", endpoint: "")
        do {
            _ = try await store.pluginCredential("openai")
            XCTFail("an unreadable key was handed out")
        } catch let error as EngineError {
            XCTAssertEqual(error.code, EngineError.Code.credentialMissing)
            XCTAssertEqual(error.message,
                           "cannot read the openai key from the keychain: User interaction is not allowed. (OSStatus -25308); "
                               + "this leylined runs from a build directory that a rebuild replaces under it; "
                               + "run make reload, then add the key again with ley ai add openai")
        }

        let plain = UnreadableSecrets(error: KeychainFailure.error("cannot read the openai key from the keychain",
                                                                    provider: "openai", status: -25300, words: nil,
                                                                    executable: Self.appHelper))
        let other = CredentialStore(path: dir + "/other.json", secrets: plain)
        _ = try await other.set(provider: "openai", secret: secret, label: "", endpoint: "")
        do {
            _ = try await other.pluginCredential("openai")
            XCTFail("an unreadable key was handed out")
        } catch let error as EngineError {
            XCTAssertEqual(error.message,
                           "cannot read the openai key from the keychain: OSStatus -25300; add it again with ley ai add openai")
        }
    }

    func testNoKeyAtAllKeepsItsSentence() {
        XCTAssertEqual(EngineError.credentialMissing("openai").message, "no openai key is set; add one with ley ai add openai")
    }
}

/// A store that keeps what it is given and refuses to give it back, as the keychain does to a
/// daemon whose program it no longer recognises. Never the real keychain.
private struct UnreadableSecrets: SecretStore {
    let error: SecretStoreError
    func set(provider _: String, secret _: String) throws {}
    func get(provider _: String) throws -> String? { throw error }
    func remove(provider _: String) throws {}
}
