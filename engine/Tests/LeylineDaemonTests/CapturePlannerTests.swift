// SPDX-License-Identifier: GPL-3.0-or-later

// `plan` (docs/design/claims.md, "One decision: plan"): requests against hand-built ledgers. The
// planner is pure, so every case is a state snapshot, a request and the answer.

import EngineCore
import Foundation
@testable import LeylineServer
import LeylineProto
import XCTest

final class CapturePlannerTests: XCTestCase {
    // MARK: Building a ledger

    private static let now: Int64 = 1_000_000_000_000_000_000
    private static let devA = DeviceID().string
    private static let devB = DeviceID().string
    private static let devF = DeviceID().string

    private func dongle(_ id: String = CapturePlannerTests.devA, model: String = "NESDR SMArt v5") -> Leyline_V1_DeviceDescriptor {
        .with {
            $0.deviceID = id
            $0.driver = "rtlsdr"
            $0.model = model
            $0.state = .available
            $0.tuningRanges = [.with { $0.minHz = 24_000_000; $0.maxHz = 1_766_000_000 }]
            $0.sampleRates = [1_024_000, 2_048_000, 2_400_000, 3_200_000]
        }
    }

    private func fileRadio(_ id: String = CapturePlannerTests.devF, at hz: UInt64 = 146_520_000) -> Leyline_V1_DeviceDescriptor {
        .with {
            $0.deviceID = id
            $0.driver = FilePlaybackDevice.driverName
            $0.model = "File"
            $0.state = .available
            $0.tuningRanges = [.with { $0.minHz = hz; $0.maxHz = hz }]
            $0.sampleRates = [2_400_000]
        }
    }

    private func capture(_ id: String = "cap_a", on device: String = CapturePlannerTests.devA, at hz: UInt64, rate: UInt64 = 2_400_000,
                         claims: [Leyline_V1_Claim] = [], wroteAgoS: Int64? = nil, sinks: UInt32 = 0) -> Leyline_V1_Capture
    {
        .with {
            $0.captureID = id
            $0.deviceID = device
            $0.centerHz = hz
            $0.sampleRate = rate
            $0.state = .captureActive
            $0.claims = claims
            if let ago = wroteAgoS { $0.activity.lastInteractiveWriteNs = Self.now - ago * 1_000_000_000 }
            $0.activity.liveAudioSinks = sinks
        }
    }

    private func holder(_ kind: String, _ id: String) -> Leyline_V1_ClientInfo {
        .with {
            $0.kind = kind
            $0.clientID = id
        }
    }

    private func channelClaim(_ id: String, by: Leyline_V1_ClientInfo, at hz: UInt64, bw: UInt32 = 12_500,
                              priority: Leyline_V1_ClaimPriority) -> Leyline_V1_Claim
    {
        .with {
            $0.claimID = id
            $0.holder = by
            $0.kind = .claimChannel
            $0.priority = priority
            $0.covers = .with {
                $0.frequencyHz = hz
                $0.bandwidthHz = bw
            }
        }
    }

    private func iqClaim(_ id: String, job: String, centred hz: UInt64? = nil, covers: UInt64? = nil,
                         rate: UInt64 = 0) -> Leyline_V1_Claim
    {
        .with {
            $0.claimID = id
            $0.holder = holder("job", job)
            $0.kind = .claimIq
            $0.priority = .priorityJob
            $0.sampleRateHz = rate
            if let hz { $0.centred = .with { $0.frequencyHz = hz; $0.toleranceHz = 1_000 } }
            if let covers { $0.covers = .with { $0.frequencyHz = covers } }
        }
    }

    private func bare(_ id: String, _ kind: Leyline_V1_ClaimKind, _ priority: Leyline_V1_ClaimPriority,
                      by: Leyline_V1_ClientInfo) -> Leyline_V1_Claim
    {
        .with {
            $0.claimID = id
            $0.holder = by
            $0.kind = kind
            $0.priority = priority
        }
    }

    private func state(_ devices: [Leyline_V1_DeviceDescriptor], _ captures: [Leyline_V1_Capture] = [],
                       jobs: [Leyline_V1_Job] = []) -> Leyline_V1_GetStateResponse
    {
        .with {
            $0.devices = devices
            $0.captures = captures
            $0.jobs = jobs
        }
    }

    private func decodeJob(_ id: String, decoder: String) -> Leyline_V1_Job {
        .with {
            $0.jobID = id
            $0.state = .running
            $0.decode = .with { $0.decoder = decoder }
        }
    }

    private func channel(_ hz: UInt64, takeOver: Bool = false, device: String? = nil) -> PlanRequest {
        .channel(frequencyHz: hz, bandwidthHz: 0, mode: .nfm, deviceID: device, takeOver: takeOver)
    }

    private func iq(_ hz: UInt64, rate: UInt64 = 0, takeOver: Bool = false, dedicated: Bool = false) -> PlanRequest {
        .iq(frequencyHz: hz, sampleRateHz: rate, deviceID: nil, takeOver: takeOver, dedicated: dedicated)
    }

    // MARK: The table

    func testPlansAgainstLedgers() {
        let app = holder("app", "cli_app")
        let me = holder("cli", "cli_me")
        let personsChannel = channelClaim("clm_p", by: app, at: 146_520_000, priority: .priorityPerson)
        let jobsChannel = channelClaim("clm_j", by: holder("job", "job_rec"), at: 146_520_000, priority: .priorityJob)
        let view = bare("clm_v", .claimSpectrum, .priorityView, by: me)
        let presence = bare("clm_l", .claimListen, .priorityPerson, by: app)
        let sweep = Leyline_V1_Claim.with {
            $0.claimID = "clm_s"
            $0.holder = holder("job", "job_scan")
            $0.kind = .claimSweep
            $0.priority = .priorityJob
            $0.covers = .with { $0.frequencyHz = 146_000_000; $0.bandwidthHz = 4_000_000 }
        }
        let adsbReader = iqClaim("clm_i", job: "job_iq", covers: 100_100_000)

        struct Case {
            let name: String
            let state: Leyline_V1_GetStateResponse
            let request: PlanRequest
            let want: Plan
        }
        let cases: [Case] = [
            // Shares, then an idle radio, then a retune.
            Case(name: "an idle radio is opened a quarter-span below the channel",
                 state: state([dongle()]), request: channel(144_390_000),
                 want: .create(deviceID: Self.devA, centerHz: 144_090_000, sampleRateHz: 2_400_000)),
            Case(name: "a capture that covers the channel is shared, whoever is on it",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [personsChannel, presence])]),
                 request: channel(146_520_000), want: .share(captureID: "cap_a")),
            Case(name: "an idle radio comes before a retune",
                 state: state([dongle(), dongle(Self.devB)], [capture(at: 100_000_000)]),
                 request: channel(144_390_000),
                 want: .create(deviceID: Self.devB, centerHz: 144_090_000, sampleRateHz: 2_400_000)),
            Case(name: "a capture with only a view is retuned; the view follows and is not displaced",
                 state: state([dongle()], [capture(at: 100_000_000, claims: [view])]), request: channel(144_390_000),
                 want: .retune(captureID: "cap_a", centerHz: 144_090_000, sampleRateHz: 2_400_000, displacing: [])),

            // The don't-disturb test, as today.
            Case(name: "a person's channel declines a job",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [personsChannel, presence])]),
                 request: channel(1_090_000_000),
                 want: .decline(code: "DEVICE_BUSY", reason: "the app is listening on 146.520 MHz",
                                blocking: [personsChannel, presence])),
            Case(name: "another job's channel declines a job",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [jobsChannel])]), request: channel(1_090_000_000),
                 want: .decline(code: "DEVICE_BUSY", reason: "another job is listening on 146.520 MHz", blocking: [jobsChannel])),
            Case(name: "take_over displaces the person's channel",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [personsChannel, presence, view])]),
                 request: channel(1_090_000_000, takeOver: true),
                 want: .retune(captureID: "cap_a", centerHz: 1_089_700_000, sampleRateHz: 2_400_000,
                               displacing: [personsChannel])),
            Case(name: "a write in the last minute declines a job",
                 state: state([dongle()], [capture(at: 100_000_000, claims: [presence], wroteAgoS: 5)]),
                 request: channel(144_390_000),
                 want: .decline(code: "DEVICE_BUSY", reason: "somebody was tuning this radio 5 s ago", blocking: [presence])),
            Case(name: "a presence whose write is older than the window is no reason",
                 state: state([dongle()], [capture(at: 100_000_000, claims: [presence], wroteAgoS: 90)]),
                 request: channel(144_390_000),
                 want: .retune(captureID: "cap_a", centerHz: 144_090_000, sampleRateHz: 2_400_000, displacing: [])),
            Case(name: "a live audio sink declines a job",
                 state: state([dongle()], [capture(at: 100_000_000, claims: [presence], sinks: 1)]),
                 request: channel(144_390_000),
                 want: .decline(code: "DEVICE_BUSY", reason: "audio is playing from this radio", blocking: [presence])),
            Case(name: "a sweep's capture is no candidate, take_over or not",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [sweep])]),
                 request: channel(146_520_000, takeOver: true),
                 want: .decline(code: "NO_DEVICE", reason: "no radio here can hear 146.520 MHz", blocking: [])),
            Case(name: "a radio that cannot reach the frequency says so",
                 state: state([dongle()]), request: channel(2_400_000_000),
                 want: .decline(code: "DEVICE_BUSY", reason: "NESDR SMArt v5 cannot tune 2400.000 MHz", blocking: [])),
            Case(name: "no radio at all",
                 state: state([]), request: channel(146_520_000),
                 want: .decline(code: "NO_DEVICE", reason: "no radio here can hear 146.520 MHz", blocking: [])),

            // IQ.
            Case(name: "an IQ reader shares any span that covers it",
                 state: state([dongle()], [capture(at: 100_000_000, claims: [personsChannel])]), request: iq(100_900_000),
                 want: .share(captureID: "cap_a")),
            Case(name: "an IQ reader is created centred on the frequency",
                 state: state([dongle()]), request: iq(1_090_000_000, rate: 2_000_000),
                 want: .create(deviceID: Self.devA, centerHz: 1_090_000_000, sampleRateHz: 2_400_000)),
            Case(name: "another IQ reader declines a dedicated decoder",
                 state: state([dongle()], [capture(at: 100_000_000, claims: [adsbReader])],
                              jobs: [decodeJob("job_iq", decoder: "iqstat")]),
                 request: iq(1_090_000_000, rate: 2_400_000, dedicated: true),
                 want: .decline(code: "DEVICE_BUSY", reason: "another job is reading this radio (decode iqstat)",
                                blocking: [adsbReader])),
            Case(name: "a dedicated decoder takes over, at its rate, and displaces the reader",
                 state: state([dongle()], [capture(at: 100_000_000, rate: 2_048_000, claims: [adsbReader, view])]),
                 request: iq(1_090_000_000, rate: 2_400_000, takeOver: true, dedicated: true),
                 want: .retune(captureID: "cap_a", centerHz: 1_090_000_000, sampleRateHz: 2_400_000,
                               displacing: [adsbReader])),
            Case(name: "a dedicated decoder shares only a centred capture at its rate",
                 state: state([dongle()], [capture(at: 1_090_000_400, claims: [iqClaim("clm_c", job: "job_x", centred: 1_090_000_000, rate: 2_400_000)])]),
                 request: iq(1_090_000_000, rate: 2_400_000, dedicated: true), want: .share(captureID: "cap_a")),
            Case(name: "a file radio cannot be centred elsewhere (4535377)",
                 state: state([fileRadio()]), request: iq(146_620_000, rate: 2_400_000, takeOver: true, dedicated: true),
                 want: .decline(code: "NO_DEVICE",
                                reason: "File cannot tune to 146.620 MHz (a file radio plays what it recorded)", blocking: [])),
            Case(name: "a radio whose span cannot reach the frequency at all is DEVICE_BUSY, as today",
                 state: state([fileRadio()]), request: iq(1_090_000_000, rate: 2_400_000, takeOver: true, dedicated: true),
                 want: .decline(code: "DEVICE_BUSY", reason: "File cannot tune 1090.000 MHz", blocking: [])),
            Case(name: "a file radio's capture is passed over with its reason, take_over or not",
                 state: state([fileRadio()], [capture(on: Self.devF, at: 146_520_000)]),
                 request: iq(146_000_000, rate: 2_400_000, takeOver: true, dedicated: true),
                 want: .decline(code: "NO_DEVICE",
                                reason: "File cannot tune to 146.000 MHz (a file radio plays what it recorded)", blocking: [])),

            // Sweeps.
            Case(name: "a sweep opens an idle radio in the middle of its range at the fastest rate",
                 state: state([dongle()]), request: .sweep(rangeHz: 144_000_000 ... 148_000_000, deviceID: nil, takeOver: false),
                 want: .create(deviceID: Self.devA, centerHz: 146_000_000, sampleRateHz: 3_200_000)),
            Case(name: "a sweep is declined by a person's channel",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [personsChannel])]),
                 request: .sweep(rangeHz: 144_000_000 ... 148_000_000, deviceID: nil, takeOver: false),
                 want: .decline(code: "DEVICE_BUSY", reason: "the app is listening on 146.520 MHz", blocking: [personsChannel])),
            Case(name: "a sweep that takes over displaces every claim that needs the tuning",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [personsChannel, presence, view])]),
                 request: .sweep(rangeHz: 144_000_000 ... 148_000_000, deviceID: nil, takeOver: true),
                 want: .retune(captureID: "cap_a", centerHz: 146_000_000, sampleRateHz: 2_400_000,
                               displacing: [personsChannel])),
            Case(name: "take_over never displaces another sweep",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [sweep])]),
                 request: .sweep(rangeHz: 144_000_000 ... 148_000_000, deviceID: nil, takeOver: true),
                 want: .decline(code: "DEVICE_BUSY", reason: "another scan already has NESDR SMArt v5", blocking: [sweep])),
            Case(name: "a sweep no radio can tune",
                 state: state([dongle()]), request: .sweep(rangeHz: 5_000_000_000 ... 5_100_000_000, deviceID: nil, takeOver: false),
                 want: .decline(code: "NO_DEVICE", reason: "no radio here can tune 5000.000 MHz to 5100.000 MHz", blocking: [])),

            // Retunes.
            Case(name: "a person's retune is applied, and names the job it pauses but not their own channel",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [channelClaim("clm_mine", by: me, at: 146_520_000, priority: .priorityPerson), jobsChannel, view])]),
                 request: .retune(captureID: "cap_a", centerHz: 162_400_000, sampleRateHz: 0, by: me,
                                  priority: .priorityPerson, takeOver: false),
                 want: .retune(captureID: "cap_a", centerHz: 162_400_000, sampleRateHz: 2_400_000, displacing: [jobsChannel])),
            Case(name: "a retune that keeps every claim in span displaces nothing",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [jobsChannel])]),
                 request: .retune(captureID: "cap_a", centerHz: 146_100_000, sampleRateHz: 0, by: me,
                                  priority: .priorityPerson, takeOver: false),
                 want: .retune(captureID: "cap_a", centerHz: 146_100_000, sampleRateHz: 2_400_000, displacing: [])),
            Case(name: "a sweep refuses a person's retune",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [sweep])]),
                 request: .retune(captureID: "cap_a", centerHz: 162_400_000, sampleRateHz: 0, by: me,
                                  priority: .priorityPerson, takeOver: true),
                 want: .decline(code: "DEVICE_SWEEPING", reason: "a scan is sweeping this radio; it is free again when the scan ends",
                                blocking: [sweep])),
            Case(name: "a job's retune is declined by a person's channel without take_over",
                 state: state([dongle()], [capture(at: 146_000_000, claims: [personsChannel])]),
                 request: .retune(captureID: "cap_a", centerHz: 162_400_000, sampleRateHz: 0, by: holder("job", "job_x"),
                                  priority: .priorityJob, takeOver: false),
                 want: .decline(code: "DEVICE_BUSY", reason: "the app is listening on 146.520 MHz", blocking: [personsChannel])),
            Case(name: "a rate the radio does not offer",
                 state: state([dongle()], [capture(at: 146_000_000)]),
                 request: .retune(captureID: "cap_a", centerHz: 146_000_000, sampleRateHz: 9_000_000, by: me,
                                  priority: .priorityPerson, takeOver: false),
                 want: .decline(code: "RATE_UNSUPPORTED", reason: "9000000 sps is not a supported sample rate", blocking: [])),
        ]
        for c in cases {
            XCTAssertEqual(CapturePlanner.plan(c.request, state: c.state, nowNs: Self.now), c.want, c.name)
        }
    }

    /// The walk the allocator carries out keeps every candidate in order, so a radio that will not
    /// open moves it on to the next one.
    func testTheWalkKeepsEveryCandidateInOrder() {
        let walk = CapturePlanner.walk(channel(144_390_000),
                                       state: state([dongle(), dongle(Self.devB)], [capture(at: 100_000_000)]),
                                       nowNs: Self.now)
        XCTAssertEqual(walk.steps, [
            .attempt(.create(deviceID: Self.devB, centerHz: 144_090_000, sampleRateHz: 2_400_000)),
            .attempt(.retune(captureID: "cap_a", centerHz: 144_090_000, sampleRateHz: 2_400_000, displacing: [])),
        ])
    }
}
