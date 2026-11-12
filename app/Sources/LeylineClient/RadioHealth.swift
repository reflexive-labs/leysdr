// SPDX-License-Identifier: Apache-2.0

import Foundation
import LeylineProto

/// A radio's health in the window's words: whether it can be used, what the device menu says of
/// it, and what the empty state says when its capture has gone quiet. The daemon decides all of
/// it (a radio NOT_ANSWERING after it failed to answer several times running, a capture
/// CAPTURE_STALLED after 5 s with no samples) and says what to do in `state_detail`; this only
/// picks the words for each place.
public enum RadioHealth {
    /// Whether the daemon will open the radio: not unplugged, and not left alone for not
    /// answering.
    public static func isUsable(_ d: Leyline_V1_DeviceDescriptor) -> Bool {
        d.state != .disconnected && d.state != .notAnswering
    }

    /// Whether the capture is on its radio, delivering or not: active or stalled, not detached
    /// and not a tombstone.
    public static func isAttached(_ c: Leyline_V1_Capture) -> Bool {
        c.state == .captureActive || c.state == .captureStalled
    }

    /// The device menu's state line under the radio's name.
    public static func stateWords(_ d: Leyline_V1_DeviceDescriptor) -> String {
        switch d.state {
        case .available: "connected"
        case .inUse: "connected, in use"
        case .disconnected: "unplugged"
        case .notAnswering: "not answering"
        default: "unknown"
        }
    }

    /// What to do about the radio, in the daemon's sentence: set for one NOT_ANSWERING, nil for
    /// every other.
    public static func advice(_ d: Leyline_V1_DeviceDescriptor) -> String? {
        guard d.state == .notAnswering else { return nil }
        if !d.stateDetail.isEmpty { return d.stateDetail }
        let name = d.model.isEmpty ? "The radio" : d.model
        return "\(name) is not answering: unplug it and plug it back in"
    }

    /// The device chip's tooltip: the radio's name, and what is wrong with it if anything is.
    public static func tooltip(name: String, device d: Leyline_V1_DeviceDescriptor?) -> String {
        guard let d else { return name }
        if let advice = advice(d) { return advice }
        return d.state == .disconnected ? name + ", unplugged" : name
    }

    /// The window's empty state for a capture that has stopped: a radio not answering, a stream
    /// stalled, a radio unplugged. nil while the capture streams.
    public static func emptyWords(
        capture c: Leyline_V1_Capture?, device d: Leyline_V1_DeviceDescriptor?
    ) -> (headline: String, detail: String)? {
        if let d, let advice = advice(d) {
            return ("The radio is not answering", advice)
        }
        guard let c else { return nil }
        switch c.state {
        case .captureStalled:
            // The daemon's words start lower case ("no samples from NESDR for 5 s"): a line of
            // the terminal's. Here it is a sentence of its own.
            let detail =
                c.stateDetail.isEmpty
                ? "No samples are coming from the radio."
                : c.stateDetail.prefix(1).uppercased() + c.stateDetail.dropFirst() + "."
            return ("The radio has stopped sending samples", detail)
        case .captureDetached:
            return (
                "The radio was unplugged", "Plug it back in and the capture rebinds on its own."
            )
        default:
            return nil
        }
    }
}
