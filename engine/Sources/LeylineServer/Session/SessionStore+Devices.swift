// SPDX-License-Identifier: GPL-3.0-or-later

// The device table: mirroring the registry, and attaching and detaching file and rtl_tcp devices.

import EngineCore
import Foundation
import LeylineProto
import Logging

extension SessionStore {
    // MARK: Devices

    /// Starts mirroring the registry: hot-plug arrivals/removals become device events, captures are
    /// detached on loss and rebound on replug (stable ids by serial).
    func startDeviceMirror() async {
        for d in await registry.devices { devices[d.id] = d }
        let events = registry.events()
        deviceTask = Task { [weak self] in
            for await ev in events {
                guard let self else { return }
                await self.applyDeviceEvent(ev)
            }
        }
    }

    private func applyDeviceEvent(_ ev: DeviceEvent) async {
        switch ev {
        case .arrived(let d):
            // attachFileDevice already mirrored and announced its own device; skip the duplicate.
            if devices[d.id] != d {
                devices[d.id] = d
                emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: .daemon)
            }
            for (capID, entry) in captures where entry.deviceID == d.id {
                let detached = await entry.engine.snapshot.detached
                if detached, let device = await registry.device(id: d.id) {
                    do {
                        try await entry.engine.deviceRebound(device)
                        try? await registry.markInUse(id: d.id, true)
                        await emitCapture(capID, by: .daemon)
                    } catch {
                        log.warning("rebind of \(capID) to \(d.id) failed: \(error)")
                        if let e = error as? EngineError, e.code == EngineError.Code.deviceBusy {
                            await registry.markHeldExternally(id: d.id)
                        }
                    }
                }
            }
        case .changed(let d):
            let before = devices[d.id]
            devices[d.id] = d
            if before != d { emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: .daemon) }
            if d.state == .disconnected { await captureDeviceLost(d.id) }
        case .removed(let id):
            guard var d = devices[id] else { return }
            d.state = .disconnected
            if captures.values.contains(where: { $0.deviceID == id }) {
                devices[id] = d
            } else {
                devices[id] = nil
            }
            emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: .daemon)
            await captureDeviceLost(id)
        }
    }

    private func captureDeviceLost(_ deviceID: DeviceID) async {
        for (capID, entry) in captures where entry.deviceID == deviceID {
            let detached = await entry.engine.snapshot.detached
            if !detached {
                await entry.engine.deviceLost()
                await emitCapture(capID, by: .daemon)
            }
        }
    }

    func listDevices() -> [DeviceDescriptor] {
        devices.values.sorted { $0.id.string < $1.id.string }
    }

    func attachFileDevice(path: String, loop: Bool, by: ClientContext) async throws -> DeviceDescriptor {
        let d = try await registry.attachFileDevice(path: path, loop: loop)
        if devices[d.id] == nil {
            devices[d.id] = d
            emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: by)
        }
        return d
    }

    /// Attaches a dongle served by rtl_tcp and remembers the endpoint, so the radio is reattached
    /// when the daemon restarts. One endpoint is one radio: an endpoint already hosted hands back
    /// the device hosting it, and one another attach is still connecting to joins that attempt, so
    /// a second socket is never opened. A radio the operator's `--rtltcp` flag brought up becomes
    /// the client's, so it outlives the flag and can be detached. A server that cannot be reached is
    /// `DEVICE_IO` naming the endpoint, with nothing remembered.
    func attachRemoteDevice(host: String, port: UInt16, by: ClientContext) async throws -> DeviceDescriptor {
        let endpoint = "\(host):\(port)"
        if let existing = devices.values.first(where: { $0.driver == RTLTCPDevice.driverName && $0.serial == endpoint }) {
            await registry.claimVirtualDevice(id: existing.id)
            let saved = RememberedDevices.Endpoint(host: host, port: port)
            await remembered?.remember(saved)
            // A detach that landed while this was suspended takes precedence: remove the line
            // again so the next daemon does not bring back a radio a client detached.
            if devices[existing.id] == nil { await remembered?.forget(saved) }
            return existing
        }
        if let inFlight = attachingRemotes[endpoint] { return try await inFlight.value }
        let attach = Task<DeviceDescriptor, any Error> {
            defer { attachingRemotes[endpoint] = nil }
            return try await hostRemoteDevice(host: host, port: port, by: by)
        }
        attachingRemotes[endpoint] = attach
        return try await attach.value
    }

    /// The connect half of `attachRemoteDevice`, as one task per endpoint.
    private func hostRemoteDevice(host: String, port: UInt16, by: ClientContext) async throws -> DeviceDescriptor {
        let device = RTLTCPDevice(host: host, port: port)
        do {
            try await device.open()
        } catch {
            await device.close()
            throw error
        }
        let attachment: VirtualAttachment
        do {
            attachment = try await registry.attachVirtualDevice(device, origin: .client)
        } catch {
            // Nothing else holds the connection and its reader thread once hosting has failed.
            await device.close()
            throw error
        }
        let d = attachment.descriptor
        if devices[d.id] == nil {
            devices[d.id] = d
            emit(.device(ProtoMapping.descriptor(d)), captureID: nil, by: by)
        }
        let saved = RememberedDevices.Endpoint(host: host, port: port)
        await remembered?.remember(saved)
        // A detach that landed while the endpoint was being remembered takes precedence: remove the
        // line again so the next daemon does not bring back a radio a client detached.
        if devices[d.id] == nil { await remembered?.forget(saved) }
        return d
    }

    /// Detaches a device a client attached, file or remote radio, with any capture on it. Validates
    /// before mutating: unknown ids are `DEVICE_NOT_FOUND`, a dongle in this machine's port and a
    /// radio the daemon's own command line asked for are `INVALID_ARGUMENT`, a device whose capture
    /// is still starting is `DEVICE_BUSY`, and in every case no capture on that device is touched.
    /// An rtl_tcp endpoint is forgotten here, so it does not come back at the next start.
    ///
    /// `fileOnly` is `DetachFileDevice`, which accepts only a file device: any other device is
    /// `INVALID_ARGUMENT` there, whatever it is.
    func detachDevice(id: DeviceID, by: ClientContext, fileOnly: Bool = false) async throws {
        guard let d = devices[id] else { throw EngineError.deviceNotFound(id.string) }
        if fileOnly, d.driver != FilePlaybackDevice.driverName {
            throw EngineError.invalidArgument("\(d.model) is not a file the daemon plays; DetachDevice takes any device a client attached", target: id.string)
        }
        guard await registry.isDetachableVirtualDevice(id: id) else {
            throw EngineError.invalidArgument("\(d.model) is a radio plugged into this machine, not a device a client attached; unplug it", target: id.string)
        }
        if await registry.virtualDeviceOrigin(id: id) == .operatorFlag {
            throw EngineError.invalidArgument("\(d.model) is configured with --rtltcp on the daemon's command line; remove the flag", target: id.string)
        }
        // A capture opening this device holds it across an await; closing it under a starting
        // engine would leave the engine with a device nothing owns. The window is seconds at most.
        if startingDevices.contains(id) { throw EngineError.deviceStarting(id.string) }
        for (capID, entry) in captures where entry.deviceID == id {
            await destroyCapture(id: capID, by: by)
        }
        // Everything above suspends, so a second detach can have finished meanwhile: report the
        // device as gone rather than tear it down twice. Dropping it from the table here,
        // before anything else suspends, is also what an attach racing this detach looks for: it
        // re-checks the table after its own awaits and takes its `devices.json` line back out.
        guard var gone = devices.removeValue(forKey: id) else { throw EngineError.deviceNotFound(id.string) }
        try await registry.detachVirtualDevice(id: id)
        if d.driver == RTLTCPDevice.driverName, let endpoint = RememberedDevices.Endpoint(serial: d.serial) {
            await remembered?.forget(endpoint)
        }
        gone.state = .disconnected
        emit(.device(ProtoMapping.descriptor(gone)), captureID: nil, by: by)
    }
}
