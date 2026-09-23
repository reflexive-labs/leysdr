// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto

/// Pure policy for the app's remembered gain controls. Keeping the device/stage key and snapping
/// here makes the behavior testable without SwiftUI or UserDefaults.
public enum GainPreferences {
    public static let automatic = "auto"

    public static func storageKey(deviceID: String, element: String) -> String {
        "gain.\(deviceID).\(element)"
    }

    /// Turns a stored preference into a write for exactly one advertised stage. A nil preference
    /// produces no write, leaving a multi-stage driver's safe defaults untouched.
    public static func write(
        element: Leyline_V1_GainElement, storedValue: String?, defaultDB: Double? = nil
    ) -> Leyline_V1_GainWrite? {
        guard let value = storedValue ?? defaultDB.map({ String($0) }) else { return nil }

        var write = Leyline_V1_GainWrite()
        write.element = element.name
        if value == automatic, element.supportsAuto {
            write.auto = true
            return write
        }

        guard let requested = Double(value) ?? defaultDB else { return nil }
        if !element.validDb.isEmpty {
            write.db =
                element.validDb.min {
                    abs($0 - requested) < abs($1 - requested)
                } ?? requested
            return write
        }

        let low = min(element.minDb, element.maxDb)
        let high = max(element.minDb, element.maxDb)
        let clamped = min(max(requested, low), high)
        write.db =
            element.stepDb > 0
            ? min(
                max(low + ((clamped - low) / element.stepDb).rounded() * element.stepDb, low), high)
            : clamped
        return write
    }
}
