// SPDX-License-Identifier: GPL-3.0-or-later

// Part of the engine contract (CoreProtocols.swift): hand-written, never generated.
// Radio devices and the registry that hosts them.

import Foundation

// MARK: - Devices

/// One physical or virtual SDR. Implementations: RTLSDRDevice, FilePlaybackDevice, and later
/// HackRFDevice, AirspyDevice, SDRplayDevice, CompositeDevice (coherent rigs presented as one).
/// TX, when it arrives, is a separate `TransmitCapableDevice` protocol composed onto devices that
/// support it — never widen RadioDevice with TX methods (AGENTS.md invariant 11).
package protocol RadioDevice: AnyObject, Sendable {
    var descriptor: DeviceDescriptor { get }
    /// Current setting of every gain element, in descriptor order.
    var gains: [GainState] { get }

    func open() async throws
    func close() async
    func tune(centerHz: UInt64) async throws
    /// Set the sample rate. A device may refuse the call while it is streaming with `DEVICE_BUSY`
    /// rather than restart itself under the caller (`RTLSDRDevice` does); the capture engine always
    /// stops streaming first, so both kinds work. `RTLTCPDevice` and `FilePlaybackDevice` accept a
    /// live change.
    func setSampleRate(_ hz: UInt64) async throws
    func setGain(element: String, value: GainValue) async throws

    /// Begin streaming on the given timeline. The device calls `deliver` from its own I/O context with
    /// engine-owned buffers in the device's native format; the callback must copy-or-consume before
    /// returning and must not block. `SampleTime.sampleIndex` counts samples since this call.
    func startStreaming(captureID: CaptureID, deliver: @escaping @Sendable (SampleBuffer, SampleTime) -> Void) async throws
    func stopStreaming() async

    /// Samples the driver has already asked the hardware for and not yet delivered.
    ///
    /// This is the settle window after a retune, and it is much larger than anything to do with
    /// the tuner: a PLL relocks in under a millisecond, while librtlsdr keeps 32 USB buffers of
    /// 16384 complex samples queued, which is 218 ms at 2.4 MSPS of already-captured air arriving
    /// after the new centre is set. `tune` does not flush them, and the spectrum ladder stamps
    /// every row with the centre in force when the row was computed -- so a sweep that does not
    /// discard this much after a hop attributes energy to a frequency the radio was not on.
    ///
    /// Zero for a device with no queue ahead of it. A bound, not a measurement: it is derived from
    /// the driver's own buffer geometry.
    var inFlightSamples: UInt64 { get }

    /// The level an element is actually at, in dB, even when it is in auto.
    ///
    /// `gains` reports `.auto` for an element under AGC, which is the mode, not the resulting
    /// level. A sweep has to pin the gain, because SNR against a moving reference is meaningless,
    /// and pinning it at anything other than what AGC had settled on changes the radio's
    /// sensitivity for the whole scan. nil when the driver cannot report it.
    func settledGainDB(element: String) async -> Double?
}

package extension RadioDevice {
    /// Devices with no driver queue -- file playback, synthetic sources -- deliver what they are
    /// asked for when they are asked for it.
    var inFlightSamples: UInt64 { 0 }

    /// Default: the dB level `gains` publishes for the element; nil when it is `.auto` or absent.
    func settledGainDB(element: String) async -> Double? {
        if case .db(let v)? = gains.first(where: { $0.element == element })?.value { return v }
        return nil
    }
}

/// Discovers devices, tracks hot-plug, maps serials to stable DeviceIDs across replug.
/// Also hosts virtual devices (file playback, rtl_tcp), which appear and disappear like hot-plugged hardware.
package protocol DeviceRegistry: AnyObject, Sendable {
    var devices: [DeviceDescriptor] { get async }
    func device(id: DeviceID) async -> (any RadioDevice)?
    /// Every subscriber gets every event from the moment of subscription.
    func events() -> AsyncStream<DeviceEvent>

    func attachFileDevice(path: String, loop: Bool) async throws -> DeviceDescriptor
    /// Hosts an already-constructed virtual device (network source, synthetic source). The registry
    /// assigns the stable id, installs its state-change hook and publishes `arrived`.
    func attachVirtualDevice(_ device: any RadioDevice, origin: VirtualDeviceOrigin) async throws -> VirtualAttachment
    /// Detaches any virtual device (file or `attachVirtualDevice`): closes it and publishes `removed`.
    func detachVirtualDevice(id: DeviceID) async throws
}

/// How a hosted virtual device arrived, which decides whether a client may let it go: a radio named
/// by `--rtltcp` is operator configuration and outlives every client, while one attached over the
/// protocol is the client's to detach. Attaching a flag-hosted endpoint over the protocol makes it
/// `client`, so it persists once the flag goes.
package enum VirtualDeviceOrigin: Sendable {
    /// Named on the daemon's command line (or its environment).
    case operatorFlag
    /// Attached over the protocol, or hosted on a client's behalf (file playback).
    case client
}

/// What hosting a virtual device produced: the descriptor it is known by, and whether that identity
/// was already hosted. An identity attached twice -- the same rtl_tcp endpoint named twice on the
/// command line -- keeps the first device and closes the second, so a caller that announces every
/// attach needs to know which of the two happened.
package struct VirtualAttachment: Sendable {
    package let descriptor: DeviceDescriptor
    package let alreadyHosted: Bool

    package init(descriptor: DeviceDescriptor, alreadyHosted: Bool) {
        self.descriptor = descriptor
        self.alreadyHosted = alreadyHosted
    }
}

package enum DeviceEvent: Sendable {
    case arrived(DeviceDescriptor)
    case removed(DeviceID)
    case changed(DeviceDescriptor)
}
