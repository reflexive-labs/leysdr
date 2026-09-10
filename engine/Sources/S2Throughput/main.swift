// S2 throughput spike: synthetic 20 MSPS source → DefaultCaptureEngine → one NFM channel → NullSink.
// Prints blocks, achieved sample rate, overruns and CPU time. See docs/build-order.md (S2).

import EngineCore
import Foundation

struct Options {
    var seconds = 10.0
    var rate: UInt64 = 20_000_000
    var channels = 1
}

func parse() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--seconds": o.seconds = Double(args.next() ?? "") ?? o.seconds
        case "--rate": o.rate = UInt64(args.next() ?? "") ?? o.rate
        case "--channels": o.channels = Int(args.next() ?? "") ?? o.channels
        default:
            usage()
        }
    }
    // A run of no time, no samples or a negative channel count has no measurement in it, and the
    // values go on to build durations and buffer sizes that would trap on the way.
    guard o.seconds > 0, o.rate > 0, o.channels >= 0 else { usage() }
    return o
}

func usage() -> Never {
    print("usage: s2-throughput [--seconds N] [--rate HZ] [--channels N]")
    exit(2)
}

func cpuSeconds() -> (user: Double, system: Double) {
    var ru = rusage()
    #if os(Linux)
    getrusage(RUSAGE_SELF.rawValue, &ru)
    #else
    getrusage(RUSAGE_SELF, &ru)
    #endif
    let u = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
    let s = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    return (u, s)
}

let options = parse()
let device = SyntheticDevice(rate: options.rate, centerHz: 100_000_000, toneOffsetHz: 100_000)
let capture = DefaultCaptureEngine(device: device, centerHz: 100_000_000, sampleRate: options.rate)
let sink = NullSink()

let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var exitCode: Int32 = 1
Task {
    do {
        for i in 0 ..< options.channels {
            let channel = try await capture.addChannel(ChannelConfig(offsetHz: 100_000 + Int64(i) * 25_000, bandwidthHz: 12_500, mode: .nfm))
            try await channel.attach(sink)
        }
        let cpu0 = cpuSeconds()
        let t0 = DispatchTime.now().uptimeNanoseconds
        try await capture.start()
        try await Task.sleep(nanoseconds: UInt64(options.seconds * 1e9))
        let stats = capture.stats
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let cpu1 = cpuSeconds()
        await capture.stop()
        let user = cpu1.user - cpu0.user
        let sys = cpu1.system - cpu0.system
        let achieved = Double(stats.samplesProcessed) / elapsed
        let offered = Double(options.rate)
        print("s2-throughput: rate \(options.rate) sps, \(options.channels) NFM channel(s), \(String(format: "%.2f", elapsed)) s")
        print("  blocks received  : \(stats.blocksReceived)")
        print("  blocks processed : \(stats.blocksProcessed)")
        print("  ring overruns    : \(stats.overruns)")
        print("  achieved rate    : \(String(format: "%.0f", achieved)) sps (\(String(format: "%.1f", 100 * achieved / offered))% of offered)")
        print("  audio frames     : \(sink.framesWritten)")
        print("  process CPU      : user \(String(format: "%.2f", user)) s, system \(String(format: "%.2f", sys)) s (\(String(format: "%.0f", 100 * (user + sys) / elapsed))% of one core; source + DSP threads)")
        #if canImport(Accelerate)
        print("  kernels          : Accelerate")
        #else
        print("  kernels          : Portable (plain-loop reference kernels; the macOS/vDSP number is the S2 gate)")
        #endif
        print("  note: on macOS, profile with Instruments > Allocations (mark generations across the run) to confirm zero hot-path allocation, and Instruments > os_signpost (SamplePath) for per-block timing.")
        let pass = stats.overruns == 0 && achieved >= 0.99 * offered
        print("  S2 verdict       : \(pass ? "PASS" : "FAIL") (threshold: no overruns and ≥ 99% of offered rate)")
        exitCode = pass ? 0 : 1
        semaphore.signal()
    } catch {
        print("s2-throughput failed: \(error)")
        semaphore.signal()
    }
}
semaphore.wait()
exit(exitCode)
