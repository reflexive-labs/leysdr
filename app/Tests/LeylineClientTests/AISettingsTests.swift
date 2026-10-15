// SPDX-License-Identifier: Apache-2.0

// Settings, AI without a daemon: the key rows on hand-made credentials, the feature rows and the
// privacy sentence for each kind of provider, K1's flag, the relative words, and the usage fold
// by UTC day and month with its total, each against the exact string the pane prints.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class AISettingsTests: XCTestCase {
    /// 2026-10-15 12:00:00 UTC.
    let now = Date(timeIntervalSince1970: 1_792_065_600)

    func ns(secondsBeforeNow s: Double) -> Int64 {
        Int64((now.timeIntervalSince1970 - s) * 1e9)
    }

    func credential(
        _ provider: String, lastFour: String = "0042",
        outcome: Leyline_V1_CredentialCheck.Outcome = .accepted, message: String = ""
    ) -> Leyline_V1_Credential {
        var c = Leyline_V1_Credential()
        c.provider = provider
        c.label = "home"
        c.lastFour = lastFour
        c.addedAtNs = ns(secondsBeforeNow: 3 * 86_400)
        c.lastUsedAtNs = 0
        c.lastCheck.outcome = outcome
        c.lastCheck.message = message
        c.lastCheck.atNs = ns(secondsBeforeNow: 125)
        return c
    }

    func feature(_ f: String, _ provider: String, _ model: String) -> Leyline_V1_FeatureModel {
        var fm = Leyline_V1_FeatureModel()
        fm.feature = f
        fm.provider = provider
        fm.model = model
        return fm
    }

    let onDevice = AIProvider(
        id: "apple", name: "On this Mac", features: ["speech"], models: ["speech"],
        reach: .onDevice, takesEndpoint: false)

    // MARK: Keys

    func testKeyRowShowsTheLastFourAndNeverMoreOfTheKey() {
        let row = KeyRow(credential("anthropic"), now: now)
        XCTAssertEqual(row.provider, "anthropic")
        XCTAssertEqual(row.providerName, "Anthropic")
        XCTAssertEqual(row.label, "home")
        XCTAssertEqual(row.maskedKey, "\u{2026}0042")
        XCTAssertEqual(row.added, "3 days ago")
        XCTAssertEqual(row.lastUsed, "never")
        XCTAssertEqual(row.lastChecked, "2 min ago")
        XCTAssertEqual(row.outcome, .accepted)
        XCTAssertEqual(row.outcome.word, "accepted")
    }

    func testKeyRowCarriesTheProvidersMessageOnOneLine() {
        let row = KeyRow(
            credential("openai", outcome: .rejected, message: "invalid\n  x-api-key "), now: now)
        XCTAssertEqual(row.providerName, "OpenAI-compatible")
        XCTAssertEqual(row.outcome.word, "rejected")
        XCTAssertEqual(row.message, "invalid x-api-key")
    }

    func testAKeyNeverCheckedSaysSoAndAShortKeyShowsADash() {
        var c = credential("deepgram", lastFour: "")
        c.lastCheck = Leyline_V1_CredentialCheck()
        let row = KeyRow(c, now: now)
        XCTAssertEqual(row.providerName, "deepgram", "an unknown provider is named as spelled")
        XCTAssertEqual(row.maskedKey, "—")
        XCTAssertEqual(row.outcome, .unchecked)
        XCTAssertEqual(row.outcome.word, "not checked")
        XCTAssertEqual(row.lastChecked, "never")
    }

    func testKeyRowsAreSortedByProvider() {
        var ai = Leyline_V1_AIState()
        ai.credentials = [credential("openai"), credential("anthropic")]
        XCTAssertEqual(AISettings.keyRows(ai, now: now).map(\.provider), ["anthropic", "openai"])
    }

    func testRelativeWordsAreCoarse() {
        XCTAssertEqual(AISettings.ago(ns: 0, now: now), "never")
        XCTAssertEqual(AISettings.ago(ns: ns(secondsBeforeNow: 59), now: now), "just now")
        XCTAssertEqual(
            AISettings.ago(ns: ns(secondsBeforeNow: -30), now: now), "just now",
            "a time after now (a clock step) is not a negative age")
        XCTAssertEqual(AISettings.ago(ns: ns(secondsBeforeNow: 60), now: now), "1 min ago")
        XCTAssertEqual(AISettings.ago(ns: ns(secondsBeforeNow: 3599), now: now), "59 min ago")
        XCTAssertEqual(AISettings.ago(ns: ns(secondsBeforeNow: 3600), now: now), "1 h ago")
        XCTAssertEqual(AISettings.ago(ns: ns(secondsBeforeNow: 86_399), now: now), "23 h ago")
        XCTAssertEqual(AISettings.ago(ns: ns(secondsBeforeNow: 86_400), now: now), "yesterday")
        XCTAssertEqual(AISettings.ago(ns: ns(secondsBeforeNow: 9 * 86_400), now: now), "9 days ago")
    }

    func testOutcomeWordsAfterAddAndCheck() {
        XCTAssertEqual(
            AISettings.addedWords(credential("anthropic")),
            "anthropic key \u{2026}0042 added; the provider accepted it.")
        XCTAssertEqual(
            AISettings.addedWords(credential("anthropic", outcome: .rejected, message: "bad key")),
            "anthropic key \u{2026}0042 added; the provider rejected it: bad key. Paste a working key."
        )
        XCTAssertEqual(
            AISettings.checkedWords(credential("anthropic", outcome: .unavailable)),
            "anthropic key \u{2026}0042: the check could not run: no reason given. Press Check to try it again."
        )
    }

    // MARK: Features and privacy

    func testPrivacySentencePerKindOfProvider() {
        XCTAssertEqual(
            AISettings.privacy(feature: "assistant", provider: "anthropic"),
            "Sends the conversation and tool results to api.anthropic.com.")
        XCTAssertEqual(
            AISettings.privacy(feature: "speech", provider: "deepgram"),
            "Sends squelch-open audio to deepgram's servers.")
        XCTAssertEqual(
            AISettings.privacy(
                feature: "speech", provider: "apple", providers: ProviderCatalog.all + [onDevice]),
            "Runs on this Mac; nothing leaves the Mac.")
        XCTAssertEqual(
            AISettings.privacy(feature: "assistant", provider: ""),
            "Sends nothing until a provider is chosen.")
    }

    func testAKeysEndpointReplacesTheProvidersHost() {
        XCTAssertEqual(
            AISettings.privacy(
                feature: "assistant", provider: "openai", endpoint: "http://gpu.lan:8080/v1"),
            "Sends the conversation and tool results to gpu.lan.")
        XCTAssertEqual(
            AISettings.privacy(feature: "assistant", provider: "openai"),
            "Sends the conversation and tool results to api.openai.com.")
    }

    func testEveryFeatureIsListedWhetherOrNotChosen() {
        var ai = Leyline_V1_AIState()
        ai.features = [feature("assistant", "anthropic", "claude-sonnet-5-5")]
        let rows = AISettings.featureRows(ai)
        XCTAssertEqual(rows.map(\.feature), ["assistant", "speech"])
        XCTAssertEqual(rows[0].title, "Assistant")
        XCTAssertEqual(rows[0].provider, "anthropic")
        XCTAssertEqual(rows[0].model, "claude-sonnet-5-5")
        XCTAssertEqual(
            rows[0].privacy, "Sends the conversation and tool results to api.anthropic.com.")
        XCTAssertEqual(rows[0].missingKey, "No anthropic key is set yet; add one under Keys.")
        XCTAssertEqual(rows[0].choices.map(\.provider.id), ["anthropic", "openai"])
        XCTAssertEqual(rows[1].provider, "")
        XCTAssertEqual(rows[1].privacy, "Sends nothing until a provider is chosen.")
        XCTAssertNil(rows[1].missingKey)
        XCTAssertTrue(rows[1].choices.isEmpty, "no speech provider is offered yet")
    }

    func testAFeatureWithItsKeySetNamesNoMissingKeyAndUsesTheKeysEndpoint() {
        var ai = Leyline_V1_AIState()
        var key = credential("openai")
        key.endpoint = "https://llm.example.org/v1"
        ai.credentials = [key]
        ai.features = [feature("assistant", "openai", "local-model")]
        let row = AISettings.featureRows(ai)[0]
        XCTAssertNil(row.missingKey)
        XCTAssertEqual(row.privacy, "Sends the conversation and tool results to llm.example.org.")
        XCTAssertEqual(
            row.choices.first { $0.provider.id == "openai" }?.privacy,
            "Sends the conversation and tool results to llm.example.org.")
    }

    func testTheCatalogOffersAnthropicsModelsAndAnEndpointForOpenAI() {
        XCTAssertEqual(
            ProviderCatalog.anthropic.models,
            ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertFalse(ProviderCatalog.anthropic.takesEndpoint)
        XCTAssertTrue(ProviderCatalog.openAICompatible.takesEndpoint)
        XCTAssertTrue(ProviderCatalog.speech.isEmpty)
    }

    // MARK: K1

    func testNoKeyAndNoOnDeviceEngineMeansNoAI() {
        var ai = Leyline_V1_AIState()
        XCTAssertFalse(AISettings.hasAnyAI(ai))
        ai.features = [feature("assistant", "anthropic", "claude-sonnet-5-5")]
        XCTAssertFalse(AISettings.hasAnyAI(ai), "a model chosen without its key enables nothing")
        ai.credentials = [credential("anthropic")]
        XCTAssertTrue(AISettings.hasAnyAI(ai))
    }

    func testAnOnDeviceEngineEnablesAIWithoutAKey() {
        var ai = Leyline_V1_AIState()
        ai.features = [feature("speech", "apple", "speech")]
        XCTAssertFalse(AISettings.hasAnyAI(ai), "the shipped catalog lists no on-device engine")
        XCTAssertTrue(AISettings.hasAnyAI(ai, providers: ProviderCatalog.all + [onDevice]))
    }

    // MARK: Usage

    func line(
        _ day: String, _ provider: String, _ model: String, _ feature: String, scope: String,
        requests: UInt64, input: UInt64 = 0, output: UInt64 = 0, audio: Double = 0
    ) -> Leyline_V1_UsageLine {
        var l = Leyline_V1_UsageLine()
        l.day = day
        l.provider = provider
        l.model = model
        l.feature = feature
        l.scopeID = scope
        l.requests = requests
        l.inputTokens = input
        l.outputTokens = output
        l.audioSeconds = audio
        return l
    }

    var ledger: [Leyline_V1_UsageLine] {
        [
            line(
                "2026-09-30", "anthropic", "claude-sonnet-5-5", "assistant", scope: "conv_a",
                requests: 2, input: 1000, output: 100),
            line(
                "2026-10-14", "anthropic", "claude-sonnet-5-5", "assistant", scope: "conv_b",
                requests: 3, input: 2000, output: 200),
            line(
                "2026-10-14", "anthropic", "claude-sonnet-5-5", "assistant", scope: "conv_c",
                requests: 1, input: 500, output: 50),
            line(
                "2026-10-14", "deepgram", "nova-3", "speech", scope: "job_x", requests: 4,
                audio: 90),
        ]
    }

    func testUsageSumsScopesWithinADayNewestDayFirst() {
        let fold = UsageFold(lines: ledger, by: .day)
        XCTAssertEqual(fold.rows.map(\.period), ["2026-10-14", "2026-10-14", "2026-09-30"])
        XCTAssertEqual(fold.rows.map(\.provider), ["anthropic", "deepgram", "anthropic"])
        XCTAssertEqual(fold.rows[0].requests, 4, "two conversations on one day are one row")
        XCTAssertEqual(fold.rows[0].inputTokens, 2500)
        XCTAssertEqual(fold.rows[1].audioSeconds, 90)
        XCTAssertEqual(fold.total.requests, 10)
        XCTAssertEqual(fold.total.inputTokens, 3500)
        XCTAssertEqual(fold.total.outputTokens, 350)
        XCTAssertEqual(fold.total.period, "total")
    }

    func testUsageByMonthSumsTheDaysOfAUTCMonth() {
        var lines = ledger
        lines.append(
            line(
                "2026-10-01", "anthropic", "claude-sonnet-5-5", "assistant", scope: "conv_d",
                requests: 5))
        let fold = UsageFold(lines: lines, by: .month)
        XCTAssertEqual(fold.rows.map(\.period), ["2026-10", "2026-10", "2026-09"])
        XCTAssertEqual(fold.rows[0].requests, 9)
        XCTAssertEqual(fold.total.requests, 15)
    }

    func testTheDayViewKeepsTheLastThirtyUTCDays() {
        XCTAssertEqual(UsageFold.sinceDay(now: now), "2026-09-16")
        let fold = UsageFold(lines: ledger, by: .day, sinceDay: "2026-10-01")
        XCTAssertEqual(fold.rows.map(\.period), ["2026-10-14", "2026-10-14"])
        XCTAssertEqual(fold.total.requests, 8)
    }

    func testAnEmptyLedgerFoldsToNoRowsAndAZeroTotal() {
        let fold = UsageFold(lines: [], by: .month)
        XCTAssertTrue(fold.rows.isEmpty)
        XCTAssertEqual(fold.total.requests, 0)
    }

    func testCountsAndMinutesPrintAsTheTableDoes() {
        XCTAssertEqual(UsageFold.count(0), "—")
        XCTAssertEqual(UsageFold.count(999), "999")
        XCTAssertEqual(UsageFold.count(1000), "1,000")
        XCTAssertEqual(UsageFold.count(1_234_567), "1,234,567")
        XCTAssertEqual(UsageFold.minutes(0), "—")
        XCTAssertEqual(UsageFold.minutes(90), "1.5")
        XCTAssertTrue(UsageFold.note.contains("UTC"))
        XCTAssertTrue(UsageFold.note.contains("what the workers reported"))
    }
}
