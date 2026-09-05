import CRTLSDR
import Foundation
import XCTest
@testable import EngineCore

/// Registry probe caching: a dongle first seen while busy (degraded probe) is refreshed once a real
/// probe arrives, and a later degraded probe never downgrades it. Drives `applyProbes` directly
/// because the stub librtlsdr enumerates no hardware.
final class RegistryProbeTests: XCTestCase {
    private func probe(tuner: String, gains: [Double]) -> RTLSDRProbe {
        RTLSDRProbe(index: 0, name: "Generic RTL2832U", manufacturer: "Realtek", product: "RTL2838UHIDIR",
                    serial: "00000001", tuner: tuner, gainsDB: gains,
                    tuningRanges: RTLSDRDevice.tunerInfo(tuner == "unknown" ? RTLSDR_TUNER_UNKNOWN : RTLSDR_TUNER_R820T).ranges)
    }

    func testDegradedProbeIsRefreshedThenCached() async throws {
        let reg = DefaultDeviceRegistry(pollIntervalMs: 1000)
        var events = reg.events().makeAsyncIterator()

        await reg.applyProbes([probe(tuner: "unknown", gains: [])])
        guard case .arrived(let first)? = await events.next() else { return XCTFail("expected arrived") }
        XCTAssertEqual(first.features["tuner"], .text("unknown"))
        XCTAssertEqual(first.gainElements.first?.validDB, [])

        // A successful probe on a later pass rebuilds the descriptor and publishes `changed`.
        await reg.applyProbes([probe(tuner: "R820T", gains: [0, 0.9, 49.6])])
        guard case .changed(let refreshed)? = await events.next() else { return XCTFail("expected changed") }
        XCTAssertEqual(refreshed.id, first.id)
        XCTAssertEqual(refreshed.features["tuner"], .text("R820T"))
        XCTAssertEqual(refreshed.gainElements.first?.validDB, [0, 0.9, 49.6])
        XCTAssertEqual(refreshed.tuningRanges, RTLSDRDevice.tunerInfo(RTLSDR_TUNER_R820T).ranges)
        let found = await reg.device(id: first.id)
        let device = try XCTUnwrap(found as? RTLSDRDevice)
        XCTAssertEqual(device.probe.tuner, "R820T")

        // Once probed, a degraded (skipped-open) probe keeps the cached data and is not a change.
        await reg.applyProbes([probe(tuner: "unknown", gains: [])])
        let after = await reg.devices
        XCTAssertEqual(after.first?.gainElements.first?.validDB, [0, 0.9, 49.6])
        XCTAssertEqual(device.probe.tuner, "R820T")
    }

    func testIdentityBaseStripsCollisionSuffix() {
        XCTAssertEqual(DefaultDeviceRegistry.identityBase(of: "s|m|p"), "s|m|p")
        XCTAssertEqual(DefaultDeviceRegistry.identityBase(of: "s|m|p#1"), "s|m|p")
    }
}
