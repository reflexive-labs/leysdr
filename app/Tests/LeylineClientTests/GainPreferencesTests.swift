// SPDX-License-Identifier: Apache-2.0

import LeylineClient
import LeylineProto
import Testing

struct GainPreferencesTests {
    @Test func keysSeparateDevicesAndStages() {
        #expect(
            GainPreferences.storageKey(deviceID: "hackrf-a", element: "LNA") == "gain.hackrf-a.LNA")
        #expect(
            GainPreferences.storageKey(deviceID: "hackrf-a", element: "LNA")
                != GainPreferences.storageKey(deviceID: "hackrf-a", element: "VGA"))
        #expect(
            GainPreferences.storageKey(deviceID: "hackrf-a", element: "LNA")
                != GainPreferences.storageKey(deviceID: "hackrf-b", element: "LNA"))
    }

    @Test func missingMultiStagePreferenceLeavesDriverDefaultUntouched() {
        #expect(
            GainPreferences.write(element: stage("LNA", max: 40, step: 8), storedValue: nil) == nil)
    }

    @Test func valuesAreSnappedForTheNamedStage() throws {
        let lna = try #require(
            GainPreferences.write(
                element: stage("LNA", max: 40, step: 8), storedValue: "17"))
        #expect(lna.element == "LNA")
        #expect(lna.db == 16)

        let amp = try #require(
            GainPreferences.write(
                element: stage("AMP", max: 11, valid: [0, 11]), storedValue: "8"))
        #expect(amp.element == "AMP")
        #expect(amp.db == 11)
    }

    @Test func automaticRequiresStageSupport() throws {
        var tuner = stage("TUNER", max: 49.6, step: 0.1)
        tuner.supportsAuto = true
        let automatic = try #require(
            GainPreferences.write(element: tuner, storedValue: GainPreferences.automatic))
        #expect(automatic.auto)

        #expect(
            GainPreferences.write(
                element: stage("LNA", max: 40, step: 8),
                storedValue: GainPreferences.automatic) == nil)
    }

    @Test func oneStageDefaultIsClamped() throws {
        let write = try #require(
            GainPreferences.write(
                element: stage("TUNER", min: 0, max: 20, step: 1), storedValue: nil,
                defaultDB: 28))
        #expect(write.db == 20)
    }

    private func stage(
        _ name: String, min: Double = 0, max: Double, step: Double = 0,
        valid: [Double] = []
    ) -> Leyline_V1_GainElement {
        var element = Leyline_V1_GainElement()
        element.name = name
        element.minDb = min
        element.maxDb = max
        element.stepDb = step
        element.validDb = valid
        return element
    }
}
