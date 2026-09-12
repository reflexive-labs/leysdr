// SPDX-License-Identifier: GPL-3.0-or-later

// System audio output. `CoreAudioSink` is the product (AVAudioEngine + AVAudioSourceNode pulling
// from an SPSC `FloatRing`); on platforms without AVFoundation `SinkFactory.systemAudio` throws
// PLATFORM_UNSUPPORTED so the control plane still compiles and runs.

import Foundation
import Synchronization

/// Marker for sinks that only accept demodulated mono f32 audio (system audio output). The channel
/// engine refuses to attach one to a raw-IQ channel and refuses to switch a channel to raw IQ while
/// one is attached, so the cf32 channelized stream never reaches a PCM-only `write`.
public protocol PCMOnlyAudioSink: AudioSink {}

/// Builds platform audio sinks.
public enum SinkFactory {
    /// A sink that plays mono float32 audio at `rate` on the default (or `deviceUID`) output device.
    /// - Throws: `PLATFORM_UNSUPPORTED` where AVFoundation is unavailable; `DEVICE_IO` if the engine fails to start.
    public static func systemAudio(rate: UInt32, volume: Double, deviceUID: String?) throws -> any AudioSink {
        #if canImport(AVFoundation)
        return try CoreAudioSink(rate: rate, volume: volume, deviceUID: deviceUID)
        #else
        _ = (rate, volume, deviceUID)
        throw EngineError.platformUnsupported("system audio")
        #endif
    }
}

#if canImport(AVFoundation)
import AVFoundation
#if canImport(CoreAudio)
import CoreAudio
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#endif

/// Reference box for the underrun counter: `Atomic` is non-copyable, so it cannot be copied out of a
/// class stored property into the render block's captures; the block captures this box instead.
private final class UnderrunCounter: @unchecked Sendable {
    let value = Atomic<UInt64>(0)
}

/// Plays a channel's audio through CoreAudio. `write` pushes into a `FloatRing` (never blocks);
/// the render callback drains it and fills with zeros on underrun.
public final class CoreAudioSink: PCMOnlyAudioSink, @unchecked Sendable {
    public let id: SinkID
    public let rate: UInt32
    private let ring: FloatRing
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private let underrunBox = UnderrunCounter()

    /// - Parameters:
    ///   - rate: the channel's audio rate; AVAudioEngine converts to the device rate.
    ///   - volume: 0...1 applied at `mainMixerNode.outputVolume`.
    ///   - deviceUID: optional CoreAudio output device UID, applied best-effort.
    public init(id: SinkID = SinkID(), rate: UInt32, volume: Double, deviceUID: String?) throws {
        self.id = id
        self.rate = rate
        // ~0.5 s of buffering keeps the render callback fed across scheduling jitter.
        guard rate >= 2 else { throw EngineError.invalidArgument("unsupported audio rate \(rate) Hz") }
        let ring = FloatRing(capacity: Int(rate) / 2)
        self.ring = ring
        let box = underrunBox
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false) else {
            throw EngineError.invalidArgument("unsupported audio rate \(rate)")
        }
        source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData else { return noErr }
            let out = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            let got = ring.pop(into: out)
            if got < out.count {
                box.value.wrappingAdd(1, ordering: .relaxed)
                for i in got ..< out.count { out[i] = 0 }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(max(0, min(1, volume)))
        if let deviceUID { Self.selectOutputDevice(uid: deviceUID, engine: engine) }
        do {
            try engine.start()
        } catch {
            throw EngineError.deviceIO("AVAudioEngine.start failed: \(error)", target: id.description)
        }
    }

    /// Render-callback underruns so far.
    public var underruns: UInt64 { underrunBox.value.load(ordering: .relaxed) }

    /// Output volume 0...1.
    public var volume: Double {
        get { Double(engine.mainMixerNode.outputVolume) }
        set { engine.mainMixerNode.outputVolume = Float(max(0, min(1, newValue))) }
    }

    /// Hot path: one ring push; excess is dropped and counted by the ring. Non-f32 blocks (a raw-IQ
    /// channel that slipped past the attach guard) are ignored rather than trapping the DSP thread.
    public func write(_ audio: SampleBuffer, at time: SampleTime) {
        guard audio.format == .f32 else { return }
        let sp = Signpost.begin(.audioWrite)
        defer { Signpost.end(.audioWrite, sp) }
        let src = UnsafeBufferPointer(start: audio.base.assumingMemoryBound(to: Float.self), count: audio.count)
        _ = ring.push(src)
    }

    /// Drops buffered audio. The ring is consumer-flushed from the render callback so this never
    /// races it (`FloatRing.clear` is consumer-thread only).
    public func flush() async { ring.requestFlush() }

    public func closeSink() async {
        engine.stop()
        engine.detach(source)
    }

    /// Best-effort selection of a specific output device by UID (macOS only).
    private static func selectOutputDevice(uid: String, engine: AVAudioEngine) {
        #if os(macOS)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        guard status == noErr, deviceID != 0, let unit = engine.outputNode.audioUnit else { return }
        var dev = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        #endif
    }
}
#endif
