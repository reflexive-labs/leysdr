// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import LeylineClient

final class ViewWindowTests: XCTestCase {
    // scene_vhf20: 21 MSPS on 153.2 MHz, 142.7 to 163.7 MHz. scene_2m: 2.88 MSPS on 146.4 MHz.
    let wideCentre: UInt64 = 153_200_000
    let wideRate: UInt64 = 21_000_000
    let rtlCentre: UInt64 = 146_400_000
    let rtlRate: UInt64 = 2_880_000
    let twoMetres: ClosedRange<UInt64> = 144_000_000...148_000_000

    func testTheNarrowestSpanHoldsSixtyFourBins() {
        XCTAssertEqual(ViewWindow.narrowest(sampleRate: 2_048_000, bins: 2048), 64_000)
        XCTAssertEqual(ViewWindow.narrowest(sampleRate: wideRate, bins: 2048), 656_250)
        // A spectrum of 64 bins or fewer cannot be narrowed.
        XCTAssertEqual(ViewWindow.narrowest(sampleRate: rtlRate, bins: 64), rtlRate)
        XCTAssertEqual(ViewWindow.narrowest(sampleRate: rtlRate, bins: 0), rtlRate)
    }

    func testZoomHalvesAndDoublesBetweenTheNarrowestAndTheCapture() {
        XCTAssertEqual(
            ViewWindow.zoomedIn(spanHz: 4_000_000, sampleRate: wideRate, bins: 2048), 2_000_000)
        XCTAssertEqual(
            ViewWindow.zoomedIn(spanHz: 1_000_000, sampleRate: wideRate, bins: 2048), 656_250)
        XCTAssertEqual(
            ViewWindow.zoomedOut(spanHz: 4_000_000, sampleRate: wideRate, bins: 2048), 8_000_000)
        XCTAssertEqual(
            ViewWindow.zoomedOut(spanHz: 16_000_000, sampleRate: wideRate, bins: 2048), wideRate)
        XCTAssertEqual(
            ViewWindow.zoomedOut(spanHz: .max, sampleRate: wideRate, bins: 2048), wideRate)
    }

    func testTheViewStaysInsideTheCapture() {
        XCTAssertEqual(
            ViewWindow.visible(
                centerHz: 146_000_000, sampleRate: 2_400_000, spanHz: 2_400_000, focusHz: 0),
            144_800_000...147_200_000)
        XCTAssertEqual(
            ViewWindow.visible(
                centerHz: 146_000_000, sampleRate: 2_400_000, spanHz: 600_000,
                focusHz: 147_200_000),
            146_600_000...147_200_000)
        XCTAssertEqual(
            ViewWindow.visible(
                centerHz: 146_000_000, sampleRate: 2_400_000, spanHz: 600_000,
                focusHz: 146_520_000),
            146_220_000...146_820_000)
        // Wider than the capture is the capture.
        XCTAssertEqual(
            ViewWindow.visible(
                centerHz: 1_000_000, sampleRate: 2_400_000, spanHz: 9_000_000, focusHz: 0),
            0...2_200_000)
        XCTAssertNil(ViewWindow.visible(centerHz: 1, sampleRate: 0, spanHz: 1, focusHz: 0))
    }

    func testAWideCaptureFitsTheViewToTheBand() {
        let shown = ViewWindow.shown(
            centerHz: wideCentre, sampleRate: wideRate, bins: 2048, band: twoMetres, spanHz: nil,
            centreHz: nil, tunedHz: 146_520_000)
        XCTAssertEqual(shown, twoMetres)
    }

    func testACaptureNarrowerThanTheBandShowsWhole() {
        let shown = ViewWindow.shown(
            centerHz: rtlCentre, sampleRate: rtlRate, bins: 2048, band: twoMetres, spanHz: nil,
            centreHz: nil, tunedHz: 146_520_000)
        XCTAssertEqual(shown, 144_960_000...147_840_000)
        // Between bands, the whole capture.
        XCTAssertEqual(
            ViewWindow.shown(
                centerHz: rtlCentre, sampleRate: rtlRate, bins: 2048, band: nil, spanHz: nil,
                centreHz: nil, tunedHz: nil),
            144_960_000...147_840_000)
    }

    func testAChosenSpanCentresOnTheTunedFrequencyUntilACentreIsChosen() {
        XCTAssertEqual(
            ViewWindow.shown(
                centerHz: rtlCentre, sampleRate: rtlRate, bins: 2048, band: twoMetres,
                spanHz: 720_000, centreHz: nil, tunedHz: 146_520_000),
            146_160_000...146_880_000)
        XCTAssertEqual(
            ViewWindow.shown(
                centerHz: rtlCentre, sampleRate: rtlRate, bins: 2048, band: twoMetres,
                spanHz: 720_000, centreHz: 145_500_000, tunedHz: 146_520_000),
            145_140_000...145_860_000)
        // Narrower than the bins allow is held at the narrowest.
        let narrow = ViewWindow.shown(
            centerHz: rtlCentre, sampleRate: rtlRate, bins: 2048, band: twoMetres,
            spanHz: 1_000, centreHz: nil, tunedHz: 146_520_000)
        XCTAssertEqual(narrow.map { $0.upperBound - $0.lowerBound }, 90_000)
    }

    func testATuneInsideTheViewLeavesItAndOneOutsideBringsItThere() {
        let shown: ClosedRange<UInt64> = 145_000_000...146_000_000
        XCTAssertEqual(
            ViewWindow.followed(centreHz: 145_500_000, shown: shown, tunedHz: 145_900_000),
            145_500_000)
        XCTAssertNil(ViewWindow.followed(centreHz: nil, shown: shown, tunedHz: 145_900_000))
        XCTAssertEqual(
            ViewWindow.followed(centreHz: 145_500_000, shown: shown, tunedHz: 146_940_000),
            146_940_000)
        XCTAssertEqual(
            ViewWindow.followed(centreHz: 145_500_000, shown: shown, tunedHz: nil), 145_500_000)
    }

    func testTheEdgeMarkerNamesTheSideTheTunedChannelIsOn() {
        let shown: ClosedRange<UInt64> = 145_000_000...146_000_000
        XCTAssertNil(ViewWindow.edge(of: 145_500_000, in: shown))
        XCTAssertNil(ViewWindow.edge(of: nil, in: shown))
        XCTAssertEqual(ViewWindow.edge(of: 146_940_000, in: shown), .above)
        XCTAssertEqual(ViewWindow.edge(of: 144_390_000, in: shown), .below)
        XCTAssertEqual(ViewWindow.edgeWords(.above, hz: 146_940_000), "146.940 ▸")
        XCTAssertEqual(ViewWindow.edgeWords(.below, hz: 462_562_500), "◂ 462.5625")
    }

    func testTheThumbIsTheViewOnTheRail() {
        XCTAssertEqual(
            ViewWindow.thumb(145_000_000...146_000_000, on: twoMetres), 145_000_000...146_000_000)
        XCTAssertEqual(
            ViewWindow.thumb(143_000_000...145_000_000, on: twoMetres), 144_000_000...145_000_000)
        XCTAssertNil(ViewWindow.thumb(150_000_000...151_000_000, on: twoMetres))
        XCTAssertNil(ViewWindow.thumb(nil, on: twoMetres))
    }

    func testADragInsideTheCaptureMovesOnlyTheView() {
        // A 2 MHz view of 2 m inside scene_vhf20's capture, dragged down 1 MHz.
        let d = ViewWindow.dragged(
            viewCentreHz: 146_520_000, byHz: -1_000_000, spanHz: 2_000_000,
            captureCentreHz: Int64(wideCentre), sampleRate: wideRate, within: twoMetres)
        XCTAssertEqual(d.viewCentreHz, 145_520_000)
        XCTAssertEqual(d.captureCentreHz, Int64(wideCentre))
        // Held inside the band, so the capture holding the whole band never moves.
        let far = ViewWindow.dragged(
            viewCentreHz: 146_520_000, byHz: -9_000_000, spanHz: 2_000_000,
            captureCentreHz: Int64(wideCentre), sampleRate: wideRate, within: twoMetres)
        XCTAssertEqual(far.viewCentreHz, 145_000_000)
        XCTAssertEqual(far.captureCentreHz, Int64(wideCentre))
    }

    func testADragPastTheCaptureEdgePushesTheCapture() {
        // scene_2m at a 720 kHz view centred on Calling: the capture's top is 147.84 MHz, so
        // the view's top reaches it at a centre of 147.48 MHz.
        let inside = ViewWindow.dragged(
            viewCentreHz: 146_520_000, byHz: 900_000, spanHz: 720_000,
            captureCentreHz: Int64(rtlCentre), sampleRate: rtlRate, within: twoMetres)
        XCTAssertEqual(inside.captureCentreHz, Int64(rtlCentre))
        let past = ViewWindow.dragged(
            viewCentreHz: 146_520_000, byHz: 1_100_000, spanHz: 720_000,
            captureCentreHz: Int64(rtlCentre), sampleRate: rtlRate, within: twoMetres)
        XCTAssertEqual(past.viewCentreHz, 147_620_000)
        XCTAssertEqual(past.captureCentreHz, Int64(rtlCentre) + 140_000)
        // Coming back leaves the capture where it was pushed.
        let back = ViewWindow.dragged(
            viewCentreHz: 146_520_000, byHz: 0, spanHz: 720_000,
            captureCentreHz: past.captureCentreHz, sampleRate: rtlRate, within: twoMetres)
        XCTAssertEqual(back.captureCentreHz, past.captureCentreHz)
        // A view as wide as the capture pushes it from the first point of travel.
        let whole = ViewWindow.dragged(
            viewCentreHz: Int64(rtlCentre), byHz: -100_000, spanHz: rtlRate,
            captureCentreHz: Int64(rtlCentre), sampleRate: rtlRate, within: twoMetres)
        XCTAssertEqual(whole.captureCentreHz, Int64(rtlCentre) - 100_000)
        // Between bands nothing holds the view, so the capture follows it.
        let free = ViewWindow.dragged(
            viewCentreHz: Int64(rtlCentre), byHz: 5_000_000, spanHz: rtlRate,
            captureCentreHz: Int64(rtlCentre), sampleRate: rtlRate)
        XCTAssertEqual(free.captureCentreHz, Int64(rtlCentre) + 5_000_000)
    }

    func testTheShowBandFitIsTheRangeInsideTheCapture() throws {
        // A 2.4 MSPS capture on 146 MHz covers 144.8 to 147.2 MHz.
        let calling = try XCTUnwrap(
            ViewWindow.fit(
                lowHz: 146_400_000, highHz: 146_600_000, centerHz: 146_000_000,
                sampleRate: 2_400_000, bins: 2048))
        XCTAssertEqual(calling.spanHz, 200_000)
        XCTAssertEqual(calling.focusHz, 146_500_000)
        XCTAssertEqual(calling.shown, 146_400_000...146_600_000)
        XCTAssertTrue(calling.whole)

        let wide = try XCTUnwrap(
            ViewWindow.fit(
                lowHz: 144_000_000, highHz: 148_000_000, centerHz: 146_000_000,
                sampleRate: 2_400_000, bins: 2048))
        XCTAssertEqual(wide.spanHz, 2_400_000)
        XCTAssertEqual(wide.shown, 144_800_000...147_200_000)
        XCTAssertFalse(wide.whole)

        // A range narrower than the bins allow is shown at the narrowest, centred on it.
        let one = try XCTUnwrap(
            ViewWindow.fit(
                lowHz: 146_520_000, highHz: 146_530_000, centerHz: 146_000_000,
                sampleRate: 2_400_000, bins: 2048))
        XCTAssertEqual(one.spanHz, 75_000)

        XCTAssertNil(
            ViewWindow.fit(
                lowHz: 118_000_000, highHz: 137_000_000, centerHz: 146_000_000,
                sampleRate: 2_400_000, bins: 2048))
        XCTAssertNil(
            ViewWindow.fit(lowHz: 1, highHz: 2, centerHz: 146_000_000, sampleRate: 0, bins: 2048))
    }

    func testTheSpanIsWordedForTheZoomHelp() {
        XCTAssertEqual(ViewWindow.spanWords(2_000_000), "2 MHz")
        XCTAssertEqual(ViewWindow.spanWords(2_880_000), "2.88 MHz")
        XCTAssertEqual(ViewWindow.spanWords(656_250), "656 kHz")
        XCTAssertEqual(ViewWindow.spanWords(7_500), "7.5 kHz")
        XCTAssertEqual(ViewWindow.spanWords(500), "500 Hz")
    }

    func testAClickTunesTheNearestTickWithinAFewPoints() {
        let xs = [10.0, 11.0, 12.5, 40.0]
        XCTAssertEqual(RailTicks.nearest(to: 12.0, among: xs), 2)
        XCTAssertEqual(RailTicks.nearest(to: 11.0, among: xs), 1)
        XCTAssertEqual(RailTicks.nearest(to: 44.0, among: xs), 3)
        XCTAssertNil(RailTicks.nearest(to: 25.0, among: xs))
        // A tie goes to the earlier, so a bookmark listed first wins over a channel under it.
        XCTAssertEqual(RailTicks.nearest(to: 20.0, among: [20.0, 20.0]), 0)
    }

    func testTicksTooCloseToTellApartDrawAsAStrip() {
        XCTAssertEqual(
            RailTicks.denseRuns([12.0, 10.0, 11.0, 40.0, 41.0, 80.0]), [10.0...12.0, 40.0...41.0])
        XCTAssertEqual(RailTicks.denseRuns([10.0, 20.0, 30.0]), [])
        XCTAssertEqual(RailTicks.denseRuns([]), [])
    }
}
