// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Credentials over the socket: the key is written and never read back, a check's
// outcome is listed, every change is an event, and deleting a key ends the jobs that use it
// (docs/dev/engine-internals.md, "Credentials and usage").

import EngineCore
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import LeylineServer
import LeylineProto
import SwiftProtobuf
import XCTest

final class CredentialsServiceTests: XCTestCase {
    /// The suffix is what every assertion greps for, so it must appear nowhere else.
    static let secret = "sk-test-SECRETMARKER9f3"
    static let marker = "SECRETMARKER"

    private func setRequest(_ provider: String, secret: String = CredentialsServiceTests.secret,
                            label: String = "", endpoint: String = "") -> Leyline_V1_SetCredentialRequest
    {
        var request = Leyline_V1_SetCredentialRequest()
        request.provider = provider
        request.secret = secret
        request.label = label
        request.endpoint = endpoint
        return request
    }

    private func ref(_ provider: String) -> Leyline_V1_CredentialRef {
        var ref = Leyline_V1_CredentialRef()
        ref.provider = provider
        return ref
    }

    /// The text of a failed RPC as a client sees it: status message and the error trailer.
    private func failure(_ body: () async throws -> Void) async -> (code: String, text: String) {
        do {
            try await body()
            XCTFail("the call succeeded")
            return ("", "")
        } catch {
            let (code, detail) = errorCode(error)
            let trailer = (try? detail?.jsonString()) ?? ""
            return (code, "\(error) \(trailer)")
        }
    }

    func testTheKeyIsInNoReplyEventErrorOrLogLineAndItsLastFourAre() async throws {
        let dir = try makeTempDir("ley")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A worker that echoes the key back in its answer and on stderr, the worst a worker can do.
        let ley = try writeScriptedLey(in: dir, """
        read key
        echo "worker got $key" >&2
        printf '{"outcome": "accepted", "message": "ok %s"}\\n' "$key"
        """)
        try await withDaemon(leyPath: ley) { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            var seen: [String] = []
            let log = try await LogCapture.shared.capture {
                let set = try await c.credentials.setCredential(self.setRequest("anthropic", label: "home"), metadata: testMetadata)
                XCTAssertEqual(set.lastFour, "R9f3")
                XCTAssertEqual(set.lastCheck.outcome, .accepted)
                XCTAssertEqual(set.lastCheck.message, "ok [key]")
                seen.append(try set.jsonString())
                seen.append(try await c.credentials.checkCredential(self.ref("anthropic"), metadata: testMetadata).jsonString())
                seen.append(try await c.credentials.getAIState(Leyline_V1_GetAIStateRequest(), metadata: testMetadata).jsonString())
                seen.append(try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata).jsonString())
                // A second key whose secret is the first's, so a failure path has the marker to leak.
                let short = await self.failure {
                    _ = try await c.credentials.setCredential(self.setRequest("", secret: Self.secret), metadata: testMetadata)
                }
                XCTAssertEqual(short.code, EngineError.Code.invalidArgument)
                seen.append(short.text)
                _ = try await c.credentials.deleteCredential(self.ref("anthropic"), metadata: testMetadata)
                let missing = await self.failure {
                    _ = try await c.credentials.checkCredential(self.ref("anthropic"), metadata: testMetadata)
                }
                seen.append(missing.text)
                _ = await events.waitFor { if case .ai(let s)? = $0.body { return s.credentials.isEmpty } else { return false } }
            }
            await events.stop()
            let collected = await events.events
            XCTAssertTrue(collected.contains { if case .ai(let s)? = $0.body { return s.credentials.first?.lastFour == "R9f3" } else { return false } },
                          "the list on the event plane carries the last four")
            for event in collected { seen.append(try event.jsonString()) }
            for text in seen { XCTAssertFalse(text.contains(Self.marker), "the key reached a client: \(text)") }
            XCTAssertTrue(log.contains("stored a key for anthropic"), "the capture saw the daemon's log")
            XCTAssertFalse(log.contains(Self.marker), "the key reached the log")
            let listing = try String(contentsOfFile: c.dataPath + "/ai.json", encoding: .utf8)
            XCTAssertFalse(listing.contains(Self.marker))
        }
    }

    func testTheKeyFileIsTheUsersAlone() async throws {
        try await withDaemon { c in
            _ = try await c.credentials.setCredential(self.setRequest("anthropic"), metadata: testMetadata)
            let attributes = try FileManager.default.attributesOfItem(atPath: c.dataPath + "/secrets/credentials.json")
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testARejectedKeyIsAnOutcomeInTheReplyAndTheList() async throws {
        let dir = try makeTempDir("ley")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeScriptedLey(in: dir, outcome: "rejected", message: "invalid x-api-key")
        try await withDaemon(leyPath: ley) { c in
            let set = try await c.credentials.setCredential(self.setRequest("anthropic"), metadata: testMetadata)
            XCTAssertEqual(set.lastCheck.outcome, .rejected)
            XCTAssertEqual(set.lastCheck.message, "invalid x-api-key")
            let checked = try await c.credentials.checkCredential(self.ref("anthropic"), metadata: testMetadata)
            XCTAssertEqual(checked.lastCheck.outcome, .rejected, "a rejected key is a reply, not an error")
            let state = try await c.credentials.getAIState(Leyline_V1_GetAIStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.credentials.first?.lastCheck.outcome, .rejected)
        }
    }

    func testNoLeyIsAnUnavailableCheckAndNotAnError() async throws {
        try await withDaemon { c in
            let set = try await c.credentials.setCredential(self.setRequest("anthropic"), metadata: testMetadata)
            XCTAssertEqual(set.lastCheck.outcome, .unavailable)
            XCTAssertTrue(set.lastCheck.message.contains("no ley executable"), set.lastCheck.message)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.ai.credentials.map(\.provider), ["anthropic"], "GetState carries the keys")
            XCTAssertEqual(state.ai.credentials.first?.lastCheck.outcome, .unavailable)
        }
    }

    func testCallsWithNothingToActOnAreRefused() async throws {
        try await withDaemon { c in
            let check = await self.failure { _ = try await c.credentials.checkCredential(self.ref("anthropic"), metadata: testMetadata) }
            XCTAssertEqual(check.code, EngineError.Code.credentialMissing)
            XCTAssertTrue(check.text.contains("ley ai add anthropic"), check.text)
            let delete = await self.failure { _ = try await c.credentials.deleteCredential(self.ref("anthropic"), metadata: testMetadata) }
            XCTAssertEqual(delete.code, EngineError.Code.credentialMissing)
            let empty = await self.failure {
                _ = try await c.credentials.setCredential(self.setRequest("anthropic", secret: " \n"), metadata: testMetadata)
            }
            XCTAssertEqual(empty.code, EngineError.Code.invalidArgument)
            let noProvider = await self.failure { _ = try await c.credentials.checkCredential(self.ref(""), metadata: testMetadata) }
            XCTAssertEqual(noProvider.code, EngineError.Code.invalidArgument)
        }
    }

    func testAFeatureModelIsStoredPublishedAndChecked() async throws {
        try await withDaemon { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            var model = Leyline_V1_FeatureModel()
            model.feature = "assistant"
            model.provider = "anthropic"
            model.model = "claude-sonnet-5-5"
            let set = try await c.credentials.setFeatureModel(model, metadata: testMetadata)
            XCTAssertEqual(set, model)
            let event = await events.waitFor { if case .ai(let s)? = $0.body { return s.features == [model] } else { return false } }
            XCTAssertNotNil(event, "the change is on the event plane")
            XCTAssertEqual(event?.causedBy.clientID, testClientID)
            let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.ai.features, [model])
            var wrong = model
            wrong.feature = "translation"
            let refused = await self.failure { _ = try await c.credentials.setFeatureModel(wrong, metadata: testMetadata) }
            XCTAssertEqual(refused.code, EngineError.Code.invalidArgument)
            await events.stop()
        }
    }

    private func feature(_ name: String, _ provider: String, _ model: String) -> Leyline_V1_FeatureModel {
        var f = Leyline_V1_FeatureModel()
        f.feature = name
        f.provider = provider
        f.model = model
        return f
    }

    /// One added key is enough to start: the features its provider serves get the default table's
    /// models, a choice already made is kept, and the reply is the key as before.
    func testAnAddedKeySetsTheFeaturesItServesAndOverwritesNoChoice() async throws {
        let dir = try makeTempDir("ley")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeScriptedLey(in: dir, outcome: "accepted", message: "")
        try await withDaemon(leyPath: ley) { c in
            let events = await EventCollector.start(c.control, daemon: c.daemon)
            let anthropic = try await c.credentials.setCredential(self.setRequest("anthropic"), metadata: testMetadata)
            XCTAssertEqual(anthropic.provider, "anthropic")
            XCTAssertEqual(anthropic.lastCheck.outcome, .accepted)
            var state = try await c.credentials.getAIState(Leyline_V1_GetAIStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.features, [self.feature("assistant", "anthropic", "claude-sonnet-5-5")])
            XCTAssertEqual(state.credentials, [anthropic], "the reply is the key as the list has it")
            let published = await events.waitFor {
                if case .ai(let s)? = $0.body { return !s.features.isEmpty } else { return false }
            }
            XCTAssertNotNil(published, "the defaults are on the event plane")

            _ = try await c.credentials.setCredential(self.setRequest("openai"), metadata: testMetadata)
            state = try await c.credentials.getAIState(Leyline_V1_GetAIStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.features, [self.feature("assistant", "anthropic", "claude-sonnet-5-5"),
                                            self.feature("speech", "openai", "whisper-1")],
                           "the assistant keeps its choice; speech had none")
            await events.stop()
        }
    }

    func testARejectedKeySetsNoFeature() async throws {
        let dir = try makeTempDir("ley")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ley = try writeScriptedLey(in: dir, outcome: "rejected", message: "invalid api key")
        try await withDaemon(leyPath: ley) { c in
            _ = try await c.credentials.setCredential(self.setRequest("openai"), metadata: testMetadata)
            let state = try await c.credentials.getAIState(Leyline_V1_GetAIStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.features, [])
        }
    }

    /// A provider that cannot serve a feature is refused when it is chosen, naming the ones that can.
    func testAProviderThatCannotServeTheFeatureIsRefused() async throws {
        try await withDaemon { c in
            let refused = await self.failure {
                _ = try await c.credentials.setFeatureModel(self.feature("speech", "anthropic", "nova-3"), metadata: testMetadata)
            }
            XCTAssertEqual(refused.code, EngineError.Code.invalidArgument)
            XCTAssertTrue(refused.text.contains("anthropic does not serve speech; openai does: ley ai use speech openai"), refused.text)
            // A server the table does not know serves the assistant, before its key and at an endpoint.
            _ = try await c.credentials.setFeatureModel(self.feature("assistant", "ollama", "llama3"), metadata: testMetadata)
            _ = try await c.credentials.setCredential(self.setRequest("ollama"), metadata: testMetadata)
            let noEndpoint = await self.failure {
                _ = try await c.credentials.setFeatureModel(self.feature("assistant", "ollama", "llama3"), metadata: testMetadata)
            }
            XCTAssertEqual(noEndpoint.code, EngineError.Code.invalidArgument)
            XCTAssertTrue(noEndpoint.text.contains("ley ai add ollama --endpoint <url>"), noEndpoint.text)
            // Clearing a choice needs no provider.
            _ = try await c.credentials.setFeatureModel(self.feature("assistant", "", ""), metadata: testMetadata)
            let state = try await c.credentials.getAIState(Leyline_V1_GetAIStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.features, [])
        }
    }

    func testDeletingAKeyEndsTheJobsThatUseIt() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "paid", credentialProvider: "fakeprov")
        try writeFakePlugin(in: plugins, name: "free")
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            _ = try await c.credentials.setCredential(self.setRequest("fakeprov"), metadata: testMetadata)
            func start(_ decoder: String) async throws -> String {
                var config = Leyline_V1_DecodeConfig()
                config.decoder = decoder
                config.frequencyHz = decodeFrequencyHz
                var request = Leyline_V1_StartJobRequest()
                request.decode = config
                return try await c.jobs.startJob(request, metadata: testMetadata).jobID
            }
            let paid = try await start("paid")
            // The second job joins the capture the first one made; started together, both would
            // try to make one.
            for _ in 0..<100 {
                let job = try await c.jobs.getJob({ var r = Leyline_V1_JobRef(); r.jobID = paid; return r }(), metadata: testMetadata)
                if job.statusDetail != "starting" { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let free = try await start("free")
            _ = try await c.credentials.deleteCredential(self.ref("fakeprov"), metadata: testMetadata)
            var ended = Leyline_V1_Job()
            for _ in 0..<100 {
                ended = try await c.jobs.getJob({ var r = Leyline_V1_JobRef(); r.jobID = paid; return r }(), metadata: testMetadata)
                if ended.state == .failed { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(ended.state, .failed)
            XCTAssertEqual(ended.error.code, EngineError.Code.credentialMissing)
            XCTAssertTrue(ended.statusDetail.contains("ley ai add fakeprov"), ended.statusDetail)
            let other = try await c.jobs.getJob({ var r = Leyline_V1_JobRef(); r.jobID = free; return r }(), metadata: testMetadata)
            XCTAssertTrue(JobStore.isLive(other.state), "a job that needs no key carries on: \(other.state) \(other.statusDetail)")
            _ = try await c.jobs.cancelJob({ var r = Leyline_V1_JobRef(); r.jobID = free; return r }(), metadata: testMetadata)
        }
    }

    func testADecoderWhoseKeyWasRejectedIsRefusedAtStart() async throws {
        let plugins = try makeTempDir("decoders")
        let workers = try makeTempDir("ley")
        defer {
            try? FileManager.default.removeItem(atPath: plugins)
            try? FileManager.default.removeItem(atPath: workers)
        }
        try writeFakePlugin(in: plugins, name: "paid", credentialProvider: "fakeprov")
        let ley = try writeScriptedLey(in: workers, outcome: "rejected", message: "invalid x-api-key")
        try await withDaemon(decoderSearchPath: [plugins], leyPath: ley) { c in
            _ = try await c.credentials.setCredential(self.setRequest("fakeprov"), metadata: testMetadata)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "paid"
            config.frequencyHz = decodeFrequencyHz
            var request = Leyline_V1_StartJobRequest()
            request.decode = config
            let refused = await self.failure { _ = try await c.jobs.startJob(request, metadata: testMetadata) }
            XCTAssertEqual(refused.code, EngineError.Code.credentialRejected)
            XCTAssertTrue(refused.text.contains("invalid x-api-key; paste a working key with ley ai add fakeprov"), refused.text)
        }
    }

    func testTheLaterOfTwoRacingKeysKeepsItsOwnCheck() async throws {
        let dir = try makeTempDir("ley")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // The first key's check answers last, and would land on the second key if nothing stopped it.
        let ley = try writeScriptedLey(in: dir, """
        read key
        case "$key" in
          *first*) sleep 1; printf '%s\\n' '{"outcome": "rejected", "message": "first"}' ;;
          *) printf '%s\\n' '{"outcome": "accepted", "message": "second"}' ;;
        esac
        """)
        try await withDaemon(leyPath: ley) { c in
            async let first = c.credentials.setCredential(self.setRequest("anthropic", secret: "sk-first-0001"), metadata: testMetadata)
            try await Task.sleep(nanoseconds: 200_000_000)
            let second = try await c.credentials.setCredential(self.setRequest("anthropic", secret: "sk-second-0002"), metadata: testMetadata)
            XCTAssertEqual(second.lastCheck.message, "second")
            let firstReply = try await first
            XCTAssertEqual(firstReply.lastCheck.message, "first", "the first caller still hears its own check")
            let state = try await c.credentials.getAIState(Leyline_V1_GetAIStateRequest(), metadata: testMetadata)
            XCTAssertEqual(state.credentials.first?.lastFour, "0002")
            XCTAssertEqual(state.credentials.first?.lastCheck.outcome, .accepted)
            XCTAssertEqual(state.credentials.first?.lastCheck.message, "second", "the stored key keeps its own check")
        }
    }

    func testAPluginsRefusalHasItsKeyReplaced() async throws {
        let plugins = try makeTempDir("decoders")
        defer { try? FileManager.default.removeItem(atPath: plugins) }
        try writeFakePlugin(in: plugins, name: "paid", args: ["--refuse-after=2"], credentialProvider: "fakeprov")
        setenv("FAKE_DECODER_REFUSAL", "429 for key \(Self.secret)", 1)
        defer { unsetenv("FAKE_DECODER_REFUSAL") }
        try await withDaemon(decoderSearchPath: [plugins]) { c in
            var attach = Leyline_V1_AttachFileDeviceRequest()
            attach.path = fixturePath("nfm_tone.cf32")
            attach.loop = true
            _ = try await c.control.attachFileDevice(attach, metadata: testMetadata)
            _ = try await c.credentials.setCredential(self.setRequest("fakeprov"), metadata: testMetadata)
            var config = Leyline_V1_DecodeConfig()
            config.decoder = "paid"
            config.frequencyHz = decodeFrequencyHz
            var request = Leyline_V1_StartJobRequest()
            request.decode = config
            let id = try await c.jobs.startJob(request, metadata: testMetadata).jobID
            var job = Leyline_V1_Job()
            for _ in 0..<200 {
                job = try await c.jobs.getJob({ var r = Leyline_V1_JobRef(); r.jobID = id; return r }(), metadata: testMetadata)
                if job.state == .failed { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(job.error.code, EngineError.Code.providerRefused)
            XCTAssertTrue(job.error.message.contains("429 for key [key]"), job.error.message)
            XCTAssertFalse(try job.jsonString().contains(Self.marker), "the key reached the job")
        }
    }
}
