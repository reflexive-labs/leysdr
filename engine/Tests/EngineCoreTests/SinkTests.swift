import Foundation
import XCTest
@testable import EngineCore

final class SinkTests: XCTestCase {
    private let time = SampleTime(captureID: CaptureID(), sampleIndex: 0)

    func testNullSinkCounts() {
        let sink = NullSink()
        let storage = SampleStorage(capacity: 480, format: .f32)
        sink.write(storage.view(), at: time)
        sink.write(storage.view(count: 100), at: time)
        XCTAssertEqual(sink.framesWritten, 580)
        XCTAssertEqual(sink.writes, 2)
    }

    func testCallbackSinkDeliversUntilClosed() async {
        let received = LockedValue<[Int]>([])
        let sink = CallbackSink { buffer, time in
            XCTAssertEqual(time.sampleIndex, 0)
            received.value.append(buffer.count)
        }
        let storage = SampleStorage(capacity: 64, format: .f32)
        sink.write(storage.view(), at: time)
        sink.write(storage.view(count: 8), at: time)
        await sink.closeSink()
        sink.write(storage.view(), at: time)
        XCTAssertEqual(received.value, [64, 8])
    }

    func testSystemAudioFactory() {
        #if canImport(AVFoundation)
        // Real audio hardware may be absent on CI; only the error code contract is checked here.
        do { _ = try SinkFactory.systemAudio(rate: 48_000, volume: 0.5, deviceUID: nil) } catch let e as EngineError {
            XCTAssertTrue(["DEVICE_IO", "INVALID_ARGUMENT"].contains(e.code))
        } catch { XCTFail("unexpected error \(error)") }
        #else
        XCTAssertThrowsError(try SinkFactory.systemAudio(rate: 48_000, volume: 0.5, deviceUID: nil)) { error in
            XCTAssertEqual((error as? EngineError)?.code, "PLATFORM_UNSUPPORTED")
        }
        #endif
    }
}
