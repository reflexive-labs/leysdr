// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Credentials: the user's provider keys (docs/dev/engine-internals.md, "Credentials and
// usage"). The contract can write a key and never read one: no reply, event, error or log line
// carries the secret, only its last four characters. Every change publishes the whole `AIState`
// (invariant 6).
//
// A check's outcome is the reply, not an error. `SetCredential` and `CheckCredential` return the
// `Credential` with `last_check` set whether the provider accepted the key, refused it or could
// not be reached, because each of those is a fact about the key worth listing; `ley ai` turns a
// `REJECTED` outcome into `CREDENTIAL_REJECTED` for the person at the terminal. The RPCs fail only
// when there is nothing to check: no key for the provider is `CREDENTIAL_MISSING`.

import EngineCore
import Foundation
import GRPCCore
import LeylineProto
import Logging

struct CredentialsService: Leyline_V1_Credentials.SimpleServiceProtocol {
    let credentials: CredentialStore
    let worker: WorkerProcess
    let store: SessionStore
    let jobs: JobStore
    private let log = Logger(label: "leyline.ai")

    init(credentials: CredentialStore, worker: WorkerProcess, store: SessionStore, jobs: JobStore) {
        self.credentials = credentials
        self.worker = worker
        self.store = store
        self.jobs = jobs
    }

    /// Stores the key, publishes it, then checks it once and publishes the outcome. Surrounding
    /// whitespace is not part of a key: `echo $KEY | ley ai add` sends a newline after it.
    func setCredential(request: Leyline_V1_SetCredentialRequest, context _: ServerContext) async throws -> Leyline_V1_Credential {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors {
            let provider = try Self.provider(request.provider)
            let secret = request.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else {
                throw EngineError.invalidArgument("the \(provider) key is empty", target: provider)
            }
            let stored: Leyline_V1_Credential
            do {
                stored = try await credentials.set(provider: provider, secret: secret, label: request.label,
                                                   endpoint: request.endpoint.trimmingCharacters(in: .whitespaces))
            } catch let error as SecretStoreError {
                throw EngineError.internalError("the \(provider) key could not be stored: \(error.message)", target: provider)
            }
            log.info("stored a key for \(provider) for \(client.kind) \(client.label)")
            await store.publishAI(from: credentials, by: client)
            let checked = await check(stored, secret: secret, by: client)
            await setDefaults(after: checked, by: client)
            return checked
        }
    }

    /// Gives the features the key's provider serves, and that have no model chosen, the default
    /// table's (`ProviderDefaults`), so one added key is enough to start. A key the provider
    /// rejected sets nothing; one whose check could not run does, since the check is retried with
    /// `ley ai check` and nothing else would set them then. The reply is unchanged: a client sees
    /// what was set in the published `AIState`.
    private func setDefaults(after checked: Leyline_V1_Credential, by client: ClientContext) async {
        guard checked.lastCheck.outcome != .rejected else { return }
        let set = await credentials.setDefaults(for: checked.provider)
        guard !set.isEmpty else { return }
        log.info("\(set.map { "\($0.feature) now calls \($0.provider) \($0.model)" }.joined(separator: ", "))")
        await store.publishAI(from: credentials, by: client)
    }

    /// Removes the key and ends every job that uses it.
    func deleteCredential(request: Leyline_V1_CredentialRef, context _: ServerContext) async throws -> Leyline_V1_Empty {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors {
            let provider = try Self.provider(request.provider)
            let removed: Bool
            do {
                removed = try await credentials.remove(provider: provider)
            } catch let error as SecretStoreError {
                throw EngineError.internalError("the \(provider) key could not be removed: \(error.message)", target: provider)
            }
            guard removed else { throw EngineError.credentialMissing(provider) }
            log.info("deleted the key for \(provider) for \(client.kind) \(client.label)")
            await store.publishAI(from: credentials, by: client)
            await jobs.endJobs(usingCredential: provider)
            return Leyline_V1_Empty()
        }
    }

    /// Tries the stored key again. A rejected key is an outcome, not an error (the file header).
    func checkCredential(request: Leyline_V1_CredentialRef, context _: ServerContext) async throws -> Leyline_V1_Credential {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors {
            let provider = try Self.provider(request.provider)
            guard let credential = await credentials.credential(provider) else {
                throw EngineError.credentialMissing(provider)
            }
            let secret: String?
            do {
                secret = try await credentials.secret(provider: provider)
            } catch let error as SecretStoreError {
                // The keychain's own words: a daemon started outside the login session may not be
                // able to read its item, and this is where that shows.
                throw EngineError.credentialMissing(provider, detail: error.message)
            }
            guard let secret else {
                throw EngineError.credentialMissing(provider, detail: "the key list names it but the key itself is gone")
            }
            return await check(credential, secret: secret, by: client)
        }
    }

    func getAIState(request _: Leyline_V1_GetAIStateRequest, context _: ServerContext) async throws -> Leyline_V1_AIState {
        await store.touchUnary(ClientContext.current)
        return await credentials.snapshot()
    }

    func setFeatureModel(request: Leyline_V1_FeatureModel, context _: ServerContext) async throws -> Leyline_V1_FeatureModel {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors {
            guard CredentialStore.features.contains(request.feature) else {
                throw EngineError.invalidArgument("there is no feature called \"\(request.feature)\"; it is assistant or speech",
                                                  target: request.feature)
            }
            // A provider that cannot serve the feature is refused now rather than on its first
            // call. An empty provider and model clear the choice and need no check.
            if !(request.provider.isEmpty && request.model.isEmpty) {
                let decoders = jobs.decoders.scan().map(\.manifest)
                if let why = ProviderDefaults.refusal(feature: request.feature, provider: request.provider,
                                                      key: await credentials.credential(request.provider), decoders: decoders)
                {
                    throw EngineError.invalidArgument(why, target: request.provider)
                }
            }
            let set = await credentials.setFeature(request)
            await store.publishAI(from: credentials, by: client)
            return set
        }
    }

    /// Runs the check worker, records its outcome and publishes it. A key replaced while the check
    /// ran keeps no outcome from it, and the reply is then the checked key with the outcome.
    private func check(_ credential: Leyline_V1_Credential, secret: String, by client: ClientContext) async -> Leyline_V1_Credential {
        let outcome = await worker.check(provider: credential.provider, endpoint: credential.endpoint, secret: secret)
        log.info("checked the \(credential.provider) key: \(outcome.outcome)")
        guard let recorded = await credentials.recordCheck(provider: credential.provider, addedAtNs: credential.addedAtNs, outcome) else {
            var answered = credential
            answered.lastCheck = outcome
            return answered
        }
        await store.publishAI(from: credentials, by: client)
        return recorded
    }

    private static func provider(_ raw: String) throws -> String {
        let provider = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty else {
            throw EngineError.invalidArgument("name the provider the key is for, such as anthropic", target: "provider")
        }
        return provider
    }
}
