// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

/// One test per rule of the daemon's allocator (`SessionCaptureAllocator`), as the app reads them
/// back before a decoder starts.
final class DecoderPlacementTests: XCTestCase {
    let me = "app_me"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func dongle(_ id: String = "dev_a", model: String = "RTL-SDR") -> Leyline_V1_DeviceDescriptor {
        var d = Leyline_V1_DeviceDescriptor()
        d.deviceID = id
        d.driver = "rtlsdr"
        d.model = model
        d.state = .available
        var r = Leyline_V1_FrequencyRange()
        r.minHz = 24_000_000
        r.maxHz = 1_766_000_000
        d.tuningRanges = [r]
        d.sampleRates = [1_024_000, 2_048_000, 2_400_000, 3_200_000]
        return d
    }

    func capture(
        _ id: String = "cap_1", device: String = "dev_a", centre: UInt64, rate: UInt64 = 2_400_000
    ) -> Leyline_V1_Capture {
        var c = Leyline_V1_Capture()
        c.captureID = id
        c.deviceID = device
        c.centerHz = centre
        c.sampleRate = rate
        c.state = .captureActive
        return c
    }

    func channel(on cap: String, offset: Int64, owner: String, kind: String = "app")
        -> Leyline_V1_Channel
    {
        var ch = Leyline_V1_Channel()
        ch.channelID = "chan_\(owner)"
        ch.captureID = cap
        ch.offsetHz = offset
        ch.state = .channelActive
        ch.owner.clientID = owner
        ch.owner.kind = kind
        return ch
    }

    func audio(_ hz: [UInt64], bw: UInt32 = 15_000) -> Leyline_V1_DecoderManifest {
        var m = Leyline_V1_DecoderManifest()
        m.name = "aprs"
        m.recipe.frequenciesHz = hz
        m.recipe.bandwidthHz = bw
        m.recipe.mode = .nfm
        m.input.signal = .signalAudio
        return m
    }

    func iq(_ hz: UInt64, rate: UInt64 = 2_400_000, dedicated: Bool = false)
        -> Leyline_V1_DecoderManifest
    {
        var m = Leyline_V1_DecoderManifest()
        m.name = "adsb"
        m.recipe.frequenciesHz = [hz]
        m.recipe.sampleRate = rate
        m.input.signal = .signalIq
        m.needsDedicatedCapture = dedicated
        return m
    }

    func predict(
        _ m: Leyline_V1_DecoderManifest, _ hz: UInt64, _ s: MirrorState, swept: Set<String> = []
    ) -> DecoderPlacement {
        DecoderPlacement.predict(m, frequencyHz: hz, state: s, swept: swept, selfID: me, now: now)
    }

    // MARK: Audio decoders

    func testACaptureWhoseSpanFitsTheChannelRunsAlongside() {
        var s = MirrorState()
        s.devices = [dongle()]
        s.captures = [capture(centre: 144_000_000)]
        s.channels = [channel(on: "cap_1", offset: 520_000, owner: me)]
        let p = predict(audio([144_390_000]), 144_390_000, s)
        XCTAssertEqual(p, .alongside(captureID: "cap_1", listening: true))
        XCTAssertEqual(p.words, "Runs alongside what you are listening to.")
        XCTAssertFalse(p.needsTakeOver)
    }

    func testAChannelTheWindowFollowedIsYoursToo() {
        var s = MirrorState()
        s.devices = [dongle()]
        s.captures = [capture(centre: 162_000_000)]
        s.channels = [channel(on: "cap_1", offset: 400_000, owner: "cli_x", kind: "cli")]
        let followed = DecoderPlacement.predict(
            audio([144_390_000]), frequencyHz: 144_390_000, state: s, selfID: me,
            windowChannel: "chan_cli_x", now: now)
        XCTAssertEqual(
            followed, .needsRadio(captureID: "cap_1", reason: "you are listening on 162.400 MHz"))
        let alongside = DecoderPlacement.predict(
            audio([162_400_000]), frequencyHz: 162_400_000, state: s, selfID: me,
            windowChannel: "chan_cli_x", now: now)
        XCTAssertEqual(alongside, .alongside(captureID: "cap_1", listening: true))
    }

    func testAChannelAtTheSpansEdgeDoesNotFit() {
        var s = MirrorState()
        s.devices = [dongle()]
        // 144.390 sits 1.195 MHz above a 143.195 centre: the channel's upper half is out.
        s.captures = [capture(centre: 143_195_000)]
        s.channels = [channel(on: "cap_1", offset: 0, owner: me)]
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, s),
            .needsRadio(captureID: "cap_1", reason: "you are listening on 143.195 MHz"))
    }

    func testASweptCaptureIsSkipped() {
        var s = MirrorState()
        s.devices = [dongle()]
        s.captures = [capture(centre: 144_000_000)]
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, s, swept: ["dev_a"]),
            .unreachable("no radio here can hear 144.390 MHz"))
    }

    func testADeviceWithNoCaptureIsTaken() {
        var s = MirrorState()
        s.devices = [dongle(model: "NESDR SMArt v5")]
        let p = predict(audio([144_390_000]), 144_390_000, s)
        XCTAssertEqual(p, .idleRadio(deviceID: "dev_a", model: "NESDR SMArt v5", retune: false))
        XCTAssertEqual(p.words, "Takes the idle radio, the NESDR SMArt v5.")
    }

    func testACaptureNobodyUsesIsRetuned() {
        var s = MirrorState()
        s.devices = [dongle()]
        s.captures = [capture(centre: 462_000_000)]
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, s),
            .idleRadio(deviceID: "dev_a", model: "RTL-SDR", retune: true))
    }

    func testAChannelOnTheCaptureNeedsTheRadio() {
        var s = MirrorState()
        s.devices = [dongle()]
        s.captures = [capture(centre: 462_000_000)]
        s.channels = [channel(on: "cap_1", offset: 562_500, owner: "cli_x", kind: "cli")]
        let p = predict(audio([144_390_000]), 144_390_000, s)
        XCTAssertEqual(
            p, .needsRadio(captureID: "cap_1", reason: "a terminal is listening on 462.5625 MHz"))
        XCTAssertTrue(p.needsTakeOver)
        XCTAssertEqual(
            p.words, "Needs the radio from you: a terminal is listening on 462.5625 MHz.")
    }

    func testLiveAudioNeedsTheRadio() {
        var s = MirrorState()
        s.devices = [dongle()]
        var c = capture(centre: 462_000_000)
        c.activity.liveAudioSinks = 1
        s.captures = [c]
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, s),
            .needsRadio(captureID: "cap_1", reason: "audio is playing from this radio"))
    }

    func testAWriteUnderAMinuteAgoNeedsTheRadioAndAnOlderOneDoesNot() {
        var s = MirrorState()
        s.devices = [dongle()]
        var c = capture(centre: 462_000_000)
        c.activity.lastInteractiveWriteNs = Int64((now.timeIntervalSince1970 - 12) * 1e9)
        s.captures = [c]
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, s),
            .needsRadio(captureID: "cap_1", reason: "somebody was tuning this radio 12 s ago"))
        c.activity.lastInteractiveWriteNs = Int64((now.timeIntervalSince1970 - 61) * 1e9)
        s.captures = [c]
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, s),
            .idleRadio(deviceID: "dev_a", model: "RTL-SDR", retune: true))
    }

    func testNoDeviceThatCanTuneItIsUnreachable() {
        var s = MirrorState()
        var d = dongle()
        d.tuningRanges[0].minHz = 400_000_000
        s.devices = [d]
        let p = predict(audio([144_390_000]), 144_390_000, s)
        XCTAssertEqual(p, .unreachable("RTL-SDR cannot tune 144.390 MHz"))
        XCTAssertEqual(p.words, "RTL-SDR cannot tune 144.390 MHz.")
        XCTAssertFalse(p.canStart)
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, MirrorState()),
            .unreachable("no radio here can hear 144.390 MHz"))
    }

    func testABusyRadioThatCannotTuneItIsUnreachableNotBusy() {
        var s = MirrorState()
        var d = dongle()
        d.tuningRanges[0].minHz = 400_000_000
        s.devices = [d]
        s.captures = [capture(centre: 462_000_000)]
        s.channels = [channel(on: "cap_1", offset: 0, owner: me)]
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, s),
            .unreachable("RTL-SDR cannot tune 144.390 MHz"))
    }

    func testAFileDeviceTunesOnlyItsOwnPoint() {
        var s = MirrorState()
        var d = dongle()
        d.driver = "file"
        d.tuningRanges[0].minHz = 144_390_000
        d.tuningRanges[0].maxHz = 144_390_000
        d.sampleRates = [960_000]
        s.devices = [d]
        XCTAssertEqual(
            predict(audio([144_390_000]), 144_390_000, s),
            .idleRadio(deviceID: "dev_a", model: "RTL-SDR", retune: false))
        XCTAssertEqual(
            predict(audio([162_400_000]), 162_400_000, s),
            .unreachable("RTL-SDR cannot tune 162.400 MHz"))
    }

    // MARK: IQ decoders

    func testAnIQDecoderReusesAnyCaptureWhoseSpanCoversIt() {
        var s = MirrorState()
        s.devices = [dongle()]
        s.captures = [capture(centre: 1_089_500_000)]
        s.channels = [channel(on: "cap_1", offset: 0, owner: me)]
        XCTAssertEqual(
            predict(iq(1_090_000_000), 1_090_000_000, s),
            .alongside(captureID: "cap_1", listening: true))
    }

    func testADedicatedIQDecoderReusesOnlyACentredCaptureAtItsRate() {
        var s = MirrorState()
        s.devices = [dongle()]
        s.captures = [capture(centre: 1_089_500_000)]
        s.channels = [channel(on: "cap_1", offset: 0, owner: me)]
        let m = iq(1_090_000_000, dedicated: true)
        XCTAssertEqual(
            predict(m, 1_090_000_000, s),
            .needsRadio(captureID: "cap_1", reason: "you are listening on 1089.500 MHz"))
        s.captures = [capture(centre: 1_090_000_500)]
        XCTAssertEqual(
            predict(m, 1_090_000_000, s), .alongside(captureID: "cap_1", listening: true))
        s.captures = [capture(centre: 1_090_000_000, rate: 2_048_000)]
        XCTAssertEqual(
            predict(m, 1_090_000_000, s),
            .needsRadio(captureID: "cap_1", reason: "you are listening on 1090.000 MHz"))
    }

    func testAnIQDecoderTakesAnIdleRadioOrRetunesAFreeCapture() {
        var s = MirrorState()
        s.devices = [dongle()]
        XCTAssertEqual(
            predict(iq(1_090_000_000), 1_090_000_000, s),
            .idleRadio(deviceID: "dev_a", model: "RTL-SDR", retune: false))
        s.captures = [capture(centre: 144_000_000)]
        XCTAssertEqual(
            predict(iq(1_090_000_000), 1_090_000_000, s),
            .idleRadio(deviceID: "dev_a", model: "RTL-SDR", retune: true))
    }

    // MARK: The frequency

    func testTheFrequencyIsTheFirstRecipeFrequencyInsideTheSpanElseTheFirst() {
        let m = audio([144_390_000, 144_800_000])
        XCTAssertEqual(
            DecoderPlacement.frequency(
                for: m, capture: capture(centre: 145_900_000), tunedHz: nil),
            144_800_000)
        XCTAssertEqual(
            DecoderPlacement.frequency(
                for: m, capture: capture(centre: 162_000_000), tunedHz: nil),
            144_390_000)
        XCTAssertEqual(DecoderPlacement.frequency(for: m, capture: nil, tunedHz: nil), 144_390_000)
    }

    func testADecoderWithNoFrequencyTakesTheTunedOne() {
        let m = audio([])
        XCTAssertEqual(
            DecoderPlacement.frequency(for: m, capture: nil, tunedHz: 146_940_000), 146_940_000)
        XCTAssertNil(DecoderPlacement.frequency(for: m, capture: nil, tunedHz: nil))
        let p = DecoderPlacement.predict(
            m, frequencyHz: nil, state: MirrorState(), selfID: me, now: now)
        XCTAssertEqual(p, .needsFrequency)
        XCTAssertFalse(p.canStart)
    }
}
