// IQ file format: raw samples (`<name>.cf32`, or `.cu8` for rtl_sdr captures) plus a JSON sidecar.
// See docs/fixtures.md. Everything Leyline writes is cf32; `.cu8` is read-only convenience.

import Foundation

/// The JSON sidecar next to an IQ file (`<name>.json`). Field names mirror docs/fixtures.md exactly.
public struct IQSidecar: Codable, Hashable, Sendable {
    /// Wall clock anchor of sample 0 (recordings); zeros for synthetic fixtures.
    public struct Anchor: Codable, Hashable, Sendable {
        public var hostTimeNs: Int64
        public var driftPpm: Double

        public init(hostTimeNs: Int64 = 0, driftPpm: Double = 0) {
            self.hostTimeNs = hostTimeNs
            self.driftPpm = driftPpm
        }

        enum CodingKeys: String, CodingKey {
            case hostTimeNs = "host_time_ns"
            case driftPpm = "drift_ppm"
        }
    }

    /// One acceptance expectation: a channel to create and what its output must satisfy.
    public struct Expectation: Codable, Hashable, Sendable {
        public struct Audio: Codable, Hashable, Sendable {
            public var toneHz: Double?
            public var minSnrDb: Double?

            public init(toneHz: Double? = nil, minSnrDb: Double? = nil) {
                self.toneHz = toneHz
                self.minSnrDb = minSnrDb
            }

            enum CodingKeys: String, CodingKey {
                case toneHz = "tone_hz"
                case minSnrDb = "min_snr_db"
            }
        }

        public struct Meter: Codable, Hashable, Sendable {
            public var powerDbfsMin: Double?
            public var squelchOpen: Bool?

            public init(powerDbfsMin: Double? = nil, squelchOpen: Bool? = nil) {
                self.powerDbfsMin = powerDbfsMin
                self.squelchOpen = squelchOpen
            }

            enum CodingKeys: String, CodingKey {
                case powerDbfsMin = "power_dbfs_min"
                case squelchOpen = "squelch_open"
            }
        }

        public var mode: String
        public var offsetHz: Int64
        public var bandwidthHz: UInt32?
        public var audio: Audio?
        public var meter: Meter?

        public init(mode: String, offsetHz: Int64, bandwidthHz: UInt32? = nil, audio: Audio? = nil, meter: Meter? = nil) {
            self.mode = mode
            self.offsetHz = offsetHz
            self.bandwidthHz = bandwidthHz
            self.audio = audio
            self.meter = meter
        }

        enum CodingKeys: String, CodingKey {
            case mode
            case offsetHz = "offset_hz"
            case bandwidthHz = "bandwidth_hz"
            case audio, meter
        }
    }

    /// "cf32" or "cu8".
    public var format: String
    public var sampleRate: UInt64
    public var centerHz: UInt64
    public var samples: UInt64?
    public var createdAtNs: Int64?
    public var anchor: Anchor?
    public var description: String?
    /// Opaque generator record (`leyfix` provenance); preserved verbatim on round trip.
    public var generator: JSONValue?
    public var expect: [Expectation]?
    public var metadata: [String: String]?

    public init(format: String = "cf32", sampleRate: UInt64, centerHz: UInt64, samples: UInt64? = nil,
                createdAtNs: Int64? = nil, anchor: Anchor? = nil, description: String? = nil,
                generator: JSONValue? = nil, expect: [Expectation]? = nil, metadata: [String: String]? = nil) {
        self.format = format
        self.sampleRate = sampleRate
        self.centerHz = centerHz
        self.samples = samples
        self.createdAtNs = createdAtNs
        self.anchor = anchor
        self.description = description
        self.generator = generator
        self.expect = expect
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case format
        case sampleRate = "sample_rate"
        case centerHz = "center_hz"
        case samples
        case createdAtNs = "created_at_ns"
        case anchor, description, generator, expect, metadata
    }

    /// Native sample format named by `format`; nil for anything but cf32/cu8.
    public var sampleFormat: SampleFormat? {
        switch format.lowercased() {
        case "cf32": return .cf32
        case "cu8": return .cu8
        default: return nil
        }
    }

    /// Sample rates the engine accepts from a sidecar (1 kSPS ... 100 MSPS). Anything outside is a
    /// malformed file: a zero rate divides by zero downstream, an absurd one overflows plans.
    public static let validSampleRates: ClosedRange<UInt64> = 1_000...100_000_000

    /// Largest sidecar the loader reads; real sidecars are a few hundred bytes.
    public static let maxSidecarBytes: UInt64 = 1 << 20

    /// - Throws: `INVALID_ARGUMENT` when `sampleRate` is outside `validSampleRates`.
    public func validate(target: String = "") throws {
        guard IQSidecar.validSampleRates.contains(sampleRate) else {
            throw EngineError.invalidArgument(
                "sample_rate \(sampleRate) is outside \(IQSidecar.validSampleRates.lowerBound)...\(IQSidecar.validSampleRates.upperBound)",
                target: target)
        }
    }

    /// Decode from a sidecar file. Accepts any member of the pair (`.cf32`, `.cu8` or `.json`).
    /// - Throws: `INVALID_ARGUMENT` when the sidecar is not a regular file, exceeds
    ///   `maxSidecarBytes`, fails to decode or carries an out-of-range `sample_rate`;
    ///   `DEVICE_IO` when it cannot be read.
    public static func load(path: String) throws -> IQSidecar {
        let path = IQFilePaths.sidecarPath(path)
        let size = try IQFilePaths.requireRegularFile(path, what: "sidecar")
        guard size <= maxSidecarBytes else {
            throw EngineError.invalidArgument("sidecar is \(size) bytes; limit is \(maxSidecarBytes)", target: path)
        }
        let url = URL(fileURLWithPath: path)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw EngineError.deviceIO("cannot read sidecar: \(error)", target: path)
        }
        let sc: IQSidecar
        do { sc = try JSONDecoder().decode(IQSidecar.self, from: data) } catch {
            throw EngineError.invalidArgument("malformed sidecar: \(error)", target: path)
        }
        try sc.validate(target: path)
        return sc
    }

    /// Encode to a sidecar file (pretty-printed, sorted keys for stable diffs).
    public func save(path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch {
            throw EngineError.deviceIO("cannot write sidecar: \(error)", target: path)
        }
    }
}

/// Opaque JSON tree, used for sidecar fields the engine preserves but does not interpret.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Paths

/// Path helpers for the `<name>.cf32|.cu8` + `<name>.json` pair.
public enum IQFilePaths {
    /// Strips a trailing `.cf32`, `.cu8` or `.json` from `path`, returning the shared stem.
    public static func stem(_ path: String) -> String {
        for ext in [".cf32", ".cu8", ".json"] where path.hasSuffix(ext) {
            return String(path.dropLast(ext.count))
        }
        return path
    }

    /// Sidecar path for any member of the pair.
    public static func sidecarPath(_ path: String) -> String { stem(path) + ".json" }

    /// Samples path for any member of the pair. When given the sidecar, prefers an existing `.cf32`,
    /// then `.cu8`, defaulting to `.cf32`.
    public static func samplesPath(_ path: String) -> String {
        if path.hasSuffix(".cf32") || path.hasSuffix(".cu8") { return path }
        let s = stem(path)
        let fm = FileManager.default
        if fm.fileExists(atPath: s + ".cf32") { return s + ".cf32" }
        if fm.fileExists(atPath: s + ".cu8") { return s + ".cu8" }
        return s + ".cf32"
    }

    /// Native format implied by the samples path extension; nil if unrecognised.
    public static func format(ofSamplesPath path: String) -> SampleFormat? {
        if path.hasSuffix(".cf32") { return .cf32 }
        if path.hasSuffix(".cu8") { return .cu8 }
        return nil
    }

    /// `stat`s `path` and returns its size in bytes.
    /// - Throws: `DEVICE_IO` when it does not exist or cannot be stat'ed; `INVALID_ARGUMENT` when
    ///   it exists but is not a regular file (a FIFO would block `open`, a directory cannot be read).
    @discardableResult
    static func requireRegularFile(_ path: String, what: String) throws -> UInt64 {
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw EngineError.deviceIO("cannot stat \(what): \(String(cString: strerror(errno)))", target: path)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw EngineError.invalidArgument("\(what) is not a regular file", target: path)
        }
        return UInt64(max(0, st.st_size))
    }

    /// Opens `path` read-only without ever blocking (`O_NONBLOCK`, then cleared so reads behave
    /// normally) and re-checks that the opened descriptor is a regular file, closing the race
    /// between the caller's `stat` and `open`.
    static func openRegularFileForReading(_ path: String, what: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw EngineError.deviceIO("cannot open \(what): \(String(cString: strerror(errno)))", target: path)
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw EngineError.invalidArgument("\(what) is not a regular file", target: path)
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        return fd
    }
}

// MARK: - Reader

/// Streams an IQ file block by block into a caller-provided cf32 `SampleBuffer`. `.cu8` sources are
/// converted on the fly through a fixed scratch buffer sized at init; reads never allocate.
/// Not thread-safe: one reader belongs to one I/O thread.
public final class IQFileReader: @unchecked Sendable {
    public let samplesPath: String
    public let sidecar: IQSidecar
    /// Format of the bytes on disk.
    public let sourceFormat: SampleFormat
    /// Total complex samples in the file (from the file size, not the sidecar).
    public let sampleCount: UInt64

    private let handle: FileHandle
    private let fd: Int32
    private var position: UInt64 = 0
    private let scratchCapacity: Int
    private let scratch: UnsafeMutableRawPointer

    /// Opens `path` (samples or sidecar path). `maxBlock` bounds a single `read` call.
    public init(path: String, maxBlock: Int = 16384) throws {
        // Whatever the caller named must be a regular file (or absent, in which case the pair
        // lookup below reports the missing member): a FIFO or directory is rejected up front.
        var st = stat()
        if stat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw EngineError.invalidArgument("IQ file is not a regular file", target: path)
        }
        let sp = IQFilePaths.samplesPath(path)
        let sc = try IQSidecar.load(path: IQFilePaths.sidecarPath(path))
        guard let fmt = IQFilePaths.format(ofSamplesPath: sp) ?? sc.sampleFormat else {
            throw EngineError.invalidArgument("unsupported IQ format \(sc.format)", target: path)
        }
        let bytes = try IQFilePaths.requireRegularFile(sp, what: "IQ file")
        let rawFD = try IQFilePaths.openRegularFileForReading(sp, what: "IQ file")
        samplesPath = sp
        sidecar = sc
        sourceFormat = fmt
        handle = FileHandle(fileDescriptor: rawFD, closeOnDealloc: false)
        fd = rawFD
        sampleCount = bytes / UInt64(fmt.bytesPerSample)
        scratchCapacity = max(1, maxBlock)
        scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchCapacity * fmt.bytesPerSample, alignment: 16)
    }

    deinit {
        scratch.deallocate()
        try? handle.close()
    }

    /// Sample index of the next read.
    public var sampleIndex: UInt64 { position }

    /// Sample rate and centre from the sidecar.
    public var sampleRate: UInt64 { sidecar.sampleRate }
    public var centerHz: UInt64 { sidecar.centerHz }

    /// Rewind to sample 0.
    public func rewind() throws {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw EngineError.deviceIO("lseek failed", target: samplesPath) }
        position = 0
    }

    /// Reads up to `into.count` complex samples (capped at the reader's `maxBlock`) as cf32 into `into`.
    /// Returns the number of samples read; 0 at EOF. Hot path: no allocation.
    public func read(into: SampleBuffer) throws -> Int {
        precondition(into.format == .cf32, "IQFileReader reads into cf32 buffers")
        let want = min(into.count, scratchCapacity)
        guard want > 0 else { return 0 }
        let dest: UnsafeMutableRawPointer = sourceFormat == .cf32 ? into.base : scratch
        var got = 0
        let wantBytes = want * sourceFormat.bytesPerSample
        while got < wantBytes {
            let n = Foundation.read(fd, dest + got, wantBytes - got)
            if n < 0 {
                if errno == EINTR { continue }
                throw EngineError.deviceIO("read failed: errno \(errno)", target: samplesPath)
            }
            if n == 0 { break }
            got += n
        }
        let samples = got / sourceFormat.bytesPerSample
        if sourceFormat == .cu8 {
            IQFileReader.convertCU8(scratch, count: samples, into: into.base)
        }
        position += UInt64(samples)
        return samples
    }

    /// `(u - 127.5) / 127.5` for interleaved I/Q bytes. Portable kernel; vDSP path lives in DSP/Kernels.
    @inline(__always)
    static func convertCU8(_ src: UnsafeMutableRawPointer, count: Int, into dst: UnsafeMutableRawPointer) {
        let s = src.assumingMemoryBound(to: UInt8.self)
        let d = dst.assumingMemoryBound(to: Float.self)
        let n = count * 2
        let scale: Float = 1.0 / 127.5
        var i = 0
        while i < n {
            d[i] = (Float(s[i]) - 127.5) * scale
            i += 1
        }
    }
}

// MARK: - Writer

/// Writes cf32 samples plus a sidecar. `write` appends raw bytes without allocation; `finish`
/// stamps `samples` and saves the sidecar. Not thread-safe: one writer per sink thread.
public final class IQFileWriter: @unchecked Sendable {
    public let samplesPath: String
    public let sidecarPath: String
    public private(set) var sidecar: IQSidecar
    public private(set) var samplesWritten: UInt64 = 0

    private let handle: FileHandle
    private let fd: Int32
    private var finished = false

    /// Creates (truncating) `<stem>.cf32` and remembers the sidecar to write on `finish`.
    public init(path: String, sidecar: IQSidecar) throws {
        let stem = IQFilePaths.stem(path)
        samplesPath = stem + ".cf32"
        sidecarPath = stem + ".json"
        var sc = sidecar
        sc.format = "cf32"
        self.sidecar = sc
        guard FileManager.default.createFile(atPath: samplesPath, contents: nil),
              let h = FileHandle(forWritingAtPath: samplesPath) else {
            throw EngineError.deviceIO("cannot create IQ file", target: samplesPath)
        }
        handle = h
        fd = h.fileDescriptor
    }

    deinit { if !finished { try? handle.close() } }

    /// Appends cf32 samples. Hot path: no allocation; a short write throws DEVICE_IO.
    public func write(_ buffer: SampleBuffer) throws {
        precondition(buffer.format == .cf32, "IQFileWriter writes cf32 only")
        var done = 0
        let total = buffer.byteCount
        while done < total {
            let n = Foundation.write(fd, buffer.base + done, total - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw EngineError.deviceIO("write failed: errno \(errno)", target: samplesPath)
            }
            done += n
        }
        samplesWritten += UInt64(buffer.count)
    }

    /// Closes the samples file and writes the sidecar with the final sample count.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        try? handle.close()
        sidecar.samples = samplesWritten
        try sidecar.save(path: sidecarPath)
    }
}
