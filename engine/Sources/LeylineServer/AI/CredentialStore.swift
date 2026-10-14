// SPDX-License-Identifier: GPL-3.0-or-later

// The keys the daemon holds and the model each feature calls (docs/dev/engine-internals.md,
// "Credentials and usage").
//
// What a listing shows -- the provider, the label, the last four characters, the times and the
// last check -- is `ai.json` in the data directory, the proto3 JSON form of `AIState`, so listing
// the keys never opens the keychain. The secret itself sits behind a `SecretStore` and leaves this
// actor only through `secret(provider:)`, for a worker's stdin. Like `RememberedDevices`, the file
// is rewritten on every change and read once, and an unreadable one is read as empty: the keys
// can be added again, and a daemon that refuses to serve radios over its key list is worse.

import EngineCore
import Foundation
import LeylineProto
import Logging
import SwiftProtobuf

actor CredentialStore {
    /// The features a model can be chosen for (ai.proto, `FeatureModel`).
    static let features: Set<String> = ["assistant", "speech"]

    private let path: String
    private let secrets: any SecretStore
    private var state = Leyline_V1_AIState()
    private var loaded = false
    /// Counts changes, so a publisher holding an older state can tell that a newer one is already
    /// out (`SessionStore.publishAI`).
    private(set) var version: UInt64 = 0
    private let log = Logger(label: "leyline.ai")

    init(path: String, secrets: any SecretStore) {
        self.path = path
        self.secrets = secrets
    }

    /// `ai.json` in a data directory.
    static func path(inData dataPath: String) -> String { dataPath + "/ai.json" }

    /// Every key and every feature's model, keys sorted by provider and features by name.
    func snapshot() -> Leyline_V1_AIState {
        loadIfNeeded()
        return state
    }

    /// The state with the version it is at, for `SessionStore.publishAI(from:by:)`.
    func versioned() -> (Leyline_V1_AIState, UInt64) {
        loadIfNeeded()
        return (state, version)
    }

    func credential(_ provider: String) -> Leyline_V1_Credential? {
        loadIfNeeded()
        return state.credentials.first { $0.provider == provider }
    }

    /// Stores `secret` for `provider`, replacing any key it had, and returns what a listing now
    /// shows for it. The check outcome starts empty: the key has not been tried yet.
    func set(provider: String, secret: String, label: String, endpoint: String) throws -> Leyline_V1_Credential {
        loadIfNeeded()
        try secrets.set(provider: provider, secret: secret)
        var credential = Leyline_V1_Credential()
        credential.provider = provider
        credential.label = label
        credential.lastFour = Self.lastFour(of: secret)
        credential.endpoint = endpoint
        credential.addedAtNs = WallClock.nowNs()
        state.credentials.removeAll { $0.provider == provider }
        state.credentials.append(credential)
        state.credentials.sort { $0.provider < $1.provider }
        changed()
        return credential
    }

    /// The secret, for a worker's stdin and nothing else. Nil when the provider has no key.
    func secret(provider: String) throws -> String? {
        loadIfNeeded()
        guard state.credentials.contains(where: { $0.provider == provider }) else { return nil }
        return try secrets.get(provider: provider)
    }

    /// Records a check of the key that was added at `addedAtNs`. A key replaced while its check
    /// ran keeps no outcome from the old one; nil then, and when the key has gone.
    func recordCheck(provider: String, addedAtNs: Int64, _ check: Leyline_V1_CredentialCheck) -> Leyline_V1_Credential? {
        loadIfNeeded()
        guard let i = state.credentials.firstIndex(where: { $0.provider == provider && $0.addedAtNs == addedAtNs }) else {
            return nil
        }
        state.credentials[i].lastCheck = check
        changed()
        return state.credentials[i]
    }

    /// Notes that a worker used the provider's key. False when there is no such key.
    func markUsed(provider: String, atNs: Int64) -> Bool {
        loadIfNeeded()
        guard let i = state.credentials.firstIndex(where: { $0.provider == provider }) else { return false }
        state.credentials[i].lastUsedAtNs = atNs
        changed()
        return true
    }

    /// Removes the key and its secret. False when the provider had none.
    func remove(provider: String) throws -> Bool {
        loadIfNeeded()
        guard state.credentials.contains(where: { $0.provider == provider }) else { return false }
        try secrets.remove(provider: provider)
        state.credentials.removeAll { $0.provider == provider }
        changed()
        return true
    }

    /// Sets the provider and model a feature calls. An empty provider and model clears the choice.
    func setFeature(_ feature: Leyline_V1_FeatureModel) -> Leyline_V1_FeatureModel {
        loadIfNeeded()
        state.features.removeAll { $0.feature == feature.feature }
        if !(feature.provider.isEmpty && feature.model.isEmpty) {
            state.features.append(feature)
            state.features.sort { $0.feature < $1.feature }
        }
        changed()
        return feature
    }

    /// The secret's last four characters, so a person can tell keys apart. A secret of fewer than
    /// eight characters shows none: four of them would be half of it or more.
    static func lastFour(of secret: String) -> String {
        secret.count >= 8 ? String(secret.suffix(4)) : ""
    }

    private func changed() {
        version += 1
        save()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = FileManager.default.contents(atPath: path) else { return }
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        do {
            state = try Leyline_V1_AIState(jsonUTF8Bytes: data, options: options)
        } catch {
            log.warning("\(path) is not a key list; starting with none")
        }
    }

    private func save() {
        do {
            var data = try state.jsonUTF8Data()
            data.append(0x0a)
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            log.error("cannot write \(path): \(error)")
        }
    }
}
