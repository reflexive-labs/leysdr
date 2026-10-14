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
}
