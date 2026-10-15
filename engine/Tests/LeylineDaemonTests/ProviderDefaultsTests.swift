// SPDX-License-Identifier: GPL-3.0-or-later

// The default table and the sentences built from it, word for word as go/pkg/leyline's
// providers_test.go has them, so the daemon and the fake say the same thing
// (docs/dev/engine-internals.md, "Credentials and usage").

@testable import LeylineServer
import LeylineProto
import XCTest

final class ProviderDefaultsTests: XCTestCase {
    private func key(_ provider: String, endpoint: String = "") -> Leyline_V1_Credential {
        var c = Leyline_V1_Credential()
        c.provider = provider
        c.endpoint = endpoint
        return c
    }

    private func speechDecoder(_ provider: String, mode: Leyline_V1_InputMode = .segmented) -> Leyline_V1_DecoderManifest {
        var m = Leyline_V1_DecoderManifest()
        m.name = "speech-" + provider
        m.credentialProvider = provider
        m.input.mode = mode
        return m
    }

    func testTheTable() {
        XCTAssertEqual(ProviderDefaults.tableFeatures("openai"), ["assistant", "speech"])
        XCTAssertEqual(ProviderDefaults.tableFeatures("anthropic"), ["assistant"])
        XCTAssertEqual(ProviderDefaults.tableFeatures("ollama"), [])
        XCTAssertEqual(ProviderDefaults.defaultModel("openai", "speech"), "whisper-1")
        XCTAssertEqual(ProviderDefaults.defaultModel("openai", "assistant"), "gpt-5")
        XCTAssertEqual(ProviderDefaults.defaultModel("anthropic", "assistant"), "claude-sonnet-5-5")
        XCTAssertNil(ProviderDefaults.defaultModel("anthropic", "speech"))
    }

    func testRefusals() {
        let none: [Leyline_V1_DecoderManifest] = []
        XCTAssertNil(ProviderDefaults.refusal(feature: "speech", provider: "openai", key: nil, decoders: none))
        XCTAssertNil(ProviderDefaults.refusal(feature: "assistant", provider: "anthropic", key: nil, decoders: none))
        XCTAssertEqual(ProviderDefaults.refusal(feature: "speech", provider: "anthropic", key: nil, decoders: none),
                       "anthropic does not serve speech; openai does: ley ai use speech openai")
        XCTAssertNil(ProviderDefaults.refusal(feature: "speech", provider: "deepgram", key: nil,
                                              decoders: [speechDecoder("deepgram")]))
        XCTAssertEqual(
            ProviderDefaults.refusal(feature: "speech", provider: "mapco", key: nil,
                                     decoders: [speechDecoder("deepgram"), speechDecoder("mapco", mode: .continuous)]),
            "mapco does not serve speech; openai and deepgram do: ley ai use speech openai")
        XCTAssertNil(ProviderDefaults.refusal(feature: "assistant", provider: "ollama", key: nil, decoders: none))
        XCTAssertNil(ProviderDefaults.refusal(feature: "assistant", provider: "ollama",
                                              key: key("ollama", endpoint: "http://localhost:11434"), decoders: none))
        XCTAssertEqual(
            ProviderDefaults.refusal(feature: "assistant", provider: "ollama", key: key("ollama"), decoders: none),
            "ollama serves the assistant only as an OpenAI-compatible server, and its key names no endpoint; "
                + "add it again with ley ai add ollama --endpoint <url>")
    }

    func testTheMissingModelMessageNamesAPasteableCommand() {
        XCTAssertEqual(ProviderDefaults.missingModelMessage("assistant", keys: []),
                       "no model is chosen for the assistant, and no key is set for a provider that serves it; "
                           + "add one with ley ai add openai (or anthropic)")
        XCTAssertEqual(ProviderDefaults.missingModelMessage("assistant", keys: [key("anthropic")]),
                       "no model is chosen for the assistant; choose one with ley ai use assistant anthropic")
        XCTAssertEqual(ProviderDefaults.missingModelMessage("assistant", keys: [key("anthropic"), key("openai")]),
                       "no model is chosen for the assistant; choose one with ley ai use assistant openai")
        XCTAssertEqual(
            ProviderDefaults.missingModelMessage("assistant", keys: [key("ollama", endpoint: "http://localhost:11434")]),
            "no model is chosen for the assistant; choose one with ley ai use assistant ollama <model>")
        XCTAssertEqual(ProviderDefaults.chooseCommand("speech", keys: [key("anthropic")]), "ley ai add openai")
    }
}
