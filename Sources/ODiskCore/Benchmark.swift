import Foundation
import Synchronization

/// One CrystalDiskMark-style test: block size, access pattern, queue depth and threads.
/// macOS has no user-visible submission queue (no io_uring/libaio), so Q×T outstanding requests are
/// emulated with Q×T threads issuing synchronous, uncached I/O.
public struct BenchmarkTest: Hashable, Sendable, Codable, Identifiable {
    public enum Pattern: String, Sendable, Codable { case sequential, random }
    public var pattern: Pattern
    public var blockSize: Int
    public var queueDepth: Int
    public var threads: Int

    public init(_ pattern: Pattern, blockSize: Int, queueDepth: Int, threads: Int = 1) {
        self.pattern = pattern; self.blockSize = blockSize; self.queueDepth = queueDepth; self.threads = threads
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decode(Pattern.self, forKey: .pattern)
        blockSize = try c.decode(Int.self, forKey: .blockSize)
        queueDepth = try c.decode(Int.self, forKey: .queueDepth)
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? 1
    }

    public var id: String { label }

    /// Outstanding requests, capped so a Peak run can't spawn an unreasonable number of threads.
    public var inFlight: Int { min(512, max(1, queueDepth * threads)) }

    /// "SEQ1M Q8T1" / "RND4K Q32T16" / "SEQ128K Q32T1"
    public var label: String {
        let size = blockSize >= 1 << 20 ? "\(blockSize >> 20)M" : "\(blockSize >> 10)K"
        return "\(pattern == .sequential ? "SEQ" : "RND")\(size) Q\(queueDepth)T\(threads)"
    }

    public static let seq1MQ8 = BenchmarkTest(.sequential, blockSize: 1 << 20, queueDepth: 8)
    public static let seq1MQ1 = BenchmarkTest(.sequential, blockSize: 1 << 20, queueDepth: 1)
    public static let seq128KQ32 = BenchmarkTest(.sequential, blockSize: 128 << 10, queueDepth: 32)
    public static let rnd4KQ32 = BenchmarkTest(.random, blockSize: 4 << 10, queueDepth: 32)
    public static let rnd4KQ32T16 = BenchmarkTest(.random, blockSize: 4 << 10, queueDepth: 32, threads: 16)
    public static let rnd4KQ1 = BenchmarkTest(.random, blockSize: 4 << 10, queueDepth: 1)
    public static let standard: [BenchmarkTest] = [.seq1MQ8, .seq1MQ1, .rnd4KQ32, .rnd4KQ1]
}

/// The test lists CrystalDiskMark users know.
public enum BenchmarkTestSet: String, CaseIterable, Sendable, Codable, Identifiable {
    case standard, nvme, peak, realWorld
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .standard: "Default"
        case .nvme: "NVMe SSD"
        case .peak: "Peak"
        case .realWorld: "Real World"
        }
    }
    public var tests: [BenchmarkTest] {
        switch self {
        case .standard: BenchmarkTest.standard
        case .nvme: [.seq1MQ8, .seq128KQ32, .rnd4KQ32T16, .rnd4KQ1]
        case .peak: [.seq1MQ8, .rnd4KQ32T16]
        case .realWorld: [.seq1MQ1, .rnd4KQ1]
        }
    }
}

public enum BenchmarkDataPattern: String, CaseIterable, Sendable, Codable {
    /// Incompressible random bytes (default; what files look like on disk).
    case random
    /// All zeros, which some controllers compress and so report higher.
    case zeros
}

public struct BenchmarkSettings: Hashable, Sendable, Codable {
    public var fileSizeBytes: Int
    public var passes: Int
    public var secondsPerPass: Double
    /// Pause between measurements, letting the drive's cache and temperature settle.
    public var intervalSeconds: Double
    public var tests: [BenchmarkTest]
    public var includeWrites: Bool
    /// When set, also measures a mixed read/write load with this read share (CrystalDiskMark "Mix", e.g. 70).
    public var mixReadPercent: Int?
    public var dataPattern: BenchmarkDataPattern

    public init(fileSizeBytes: Int = 1 << 30, passes: Int = 3, secondsPerPass: Double = 3, intervalSeconds: Double = 0,
                tests: [BenchmarkTest] = BenchmarkTest.standard, includeWrites: Bool = true,
                mixReadPercent: Int? = nil, dataPattern: BenchmarkDataPattern = .random) {
        self.fileSizeBytes = fileSizeBytes; self.passes = passes; self.secondsPerPass = secondsPerPass
        self.intervalSeconds = intervalSeconds; self.tests = tests; self.includeWrites = includeWrites
        self.mixReadPercent = mixReadPercent; self.dataPattern = dataPattern
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileSizeBytes = try c.decode(Int.self, forKey: .fileSizeBytes)
        passes = try c.decode(Int.self, forKey: .passes)
        secondsPerPass = try c.decode(Double.self, forKey: .secondsPerPass)
        intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 0
        tests = try c.decode([BenchmarkTest].self, forKey: .tests)
        includeWrites = try c.decode(Bool.self, forKey: .includeWrites)
        mixReadPercent = try c.decodeIfPresent(Int.self, forKey: .mixReadPercent)
        dataPattern = try c.decodeIfPresent(BenchmarkDataPattern.self, forKey: .dataPattern) ?? .random
    }

    public static let quick = BenchmarkSettings(fileSizeBytes: 256 << 20, passes: 1, secondsPerPass: 2)
    public static let standard = BenchmarkSettings()
    public static let thorough = BenchmarkSettings(fileSizeBytes: 4 << 30, passes: 5, secondsPerPass: 5)

    /// Test file sizes offered in the UI, CrystalDiskMark's range.
    public static let fileSizeChoices: [Int] = [16 << 20, 32 << 20, 64 << 20, 128 << 20, 256 << 20, 512 << 20,
                                                1 << 30, 2 << 30, 4 << 30, 8 << 30, 16 << 30, 32 << 30, 64 << 30]
}

public struct BenchmarkMeasurement: Hashable, Sendable, Codable {
    public var bytesPerSecond: Double
    public var iops: Double
    public var averageLatencyMicroseconds: Double

    public init(bytesPerSecond: Double, iops: Double, averageLatencyMicroseconds: Double) {
        self.bytesPerSecond = bytesPerSecond; self.iops = iops; self.averageLatencyMicroseconds = averageLatencyMicroseconds
    }
}

public enum BenchmarkKind: String, Sendable, Codable, CaseIterable {
    case read, write, mix
}

public struct BenchmarkRow: Hashable, Sendable, Codable, Identifiable {
    public var id: String { test.id }
    public var test: BenchmarkTest
    public var read: BenchmarkMeasurement?
    public var write: BenchmarkMeasurement?
    public var mix: BenchmarkMeasurement?

    public init(test: BenchmarkTest, read: BenchmarkMeasurement? = nil, write: BenchmarkMeasurement? = nil,
                mix: BenchmarkMeasurement? = nil) {
        self.test = test; self.read = read; self.write = write; self.mix = mix
    }

    public subscript(kind: BenchmarkKind) -> BenchmarkMeasurement? {
        get {
            switch kind {
            case .read: read
            case .write: write
            case .mix: mix
            }
        }
        set {
            switch kind {
            case .read: read = newValue
            case .write: write = newValue
            case .mix: mix = newValue
            }
        }
    }
}

public struct BenchmarkResult: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var driveName: String
    public var driveModel: String
    public var volumeName: String
    public var settings: BenchmarkSettings
    public var rows: [BenchmarkRow]

    public init(id: UUID = UUID(), date: Date, driveName: String, driveModel: String, volumeName: String,
                settings: BenchmarkSettings, rows: [BenchmarkRow]) {
        self.id = id; self.date = date; self.driveName = driveName; self.driveModel = driveModel
        self.volumeName = volumeName; self.settings = settings; self.rows = rows
    }

    /// Plain-text summary for sharing (forums, Reddit), CrystalDiskMark layout.
    public var shareText: String {
        let s = settings
        let mix = s.mixReadPercent
        var lines = ["oDisk benchmark: \(driveModel) (\(volumeName))",
                     "\(Formatters.bytes(Double(s.fileSizeBytes))) test file, \(s.passes) pass\(s.passes == 1 ? "" : "es"), \(s.dataPattern == .random ? "random data" : "zero-filled data"), MB/s = 1,000,000 bytes/s",
                     "",
                     "Test          Read MB/s   Write MB/s" + (mix != nil ? "   Mix \(mix!)/\(100 - mix!)" : "")]
        for row in rows {
            let r = row.read.map { Formatters.throughput($0.bytesPerSecond) } ?? "-"
            let w = row.write.map { Formatters.throughput($0.bytesPerSecond) } ?? "-"
            var line = row.test.label.padding(toLength: 14, withPad: " ", startingAt: 0) + r.leftPad(9) + w.leftPad(13)
            if mix != nil { line += (row.mix.map { Formatters.throughput($0.bytesPerSecond) } ?? "-").leftPad(12) }
            lines.append(line)
        }
        lines.append("")
        lines.append(date.formatted(date: .abbreviated, time: .shortened))
        return lines.joined(separator: "\n")
    }
}

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}

public enum BenchmarkPhase: Equatable, Sendable {
    case preparing(fraction: Double)
    case running(test: BenchmarkTest, kind: BenchmarkKind, pass: Int, liveBytesPerSecond: Double)
    case waiting(seconds: Double)
    case cleaningUp
}

public enum BenchmarkError: Error, Equatable, Sendable, LocalizedError {
    case notEnoughSpace(needed: Int64, available: Int64)
    case io(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .notEnoughSpace(needed, available):
            "Not enough free space: the test needs \(Formatters.bytes(needed)) and \(Formatters.bytes(available)) is free."
        case let .io(message): message
        case .cancelled: "Benchmark cancelled."
        }
    }
}

/// Cancellation flag shared between the caller and I/O threads.
public final class BenchmarkCancellation: Sendable {
    private let flag = Atomic<Bool>(false)
    public init() {}
    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// Runs the benchmark against a temporary file in a folder on the target volume.
///
/// Safety: the file is created with O_EXCL|O_NOFOLLOW, the read and write descriptors are opened
/// immediately (also O_NOFOLLOW) and checked to be the same inode, then the name is unlinked. All
/// later I/O goes through those descriptors, so nothing can redirect writes to another file, and the
/// kernel frees the space when the process exits, even after a crash or a forced quit.
/// All I/O bypasses the unified buffer cache (F_NOCACHE).
public struct BenchmarkEngine: Sendable {
    public var settings: BenchmarkSettings

    public static let filePrefix = ".oDisk-benchmark-"

    public init(settings: BenchmarkSettings) { self.settings = settings }

    public func run(in folder: URL, cancellation: BenchmarkCancellation,
                    progress: @escaping @Sendable (BenchmarkPhase) -> Void) throws -> [BenchmarkRow] {
        let size = Int64(settings.fileSizeBytes)
        let headroom: Int64 = 512 << 20
        guard let free = Self.availableBytes(at: folder) else {
            throw BenchmarkError.io("Couldn't read the free space on this volume.")
        }
        // Leave headroom so a benchmark never fills a nearly-full disk.
        if free < size + headroom { throw BenchmarkError.notEnoughSpace(needed: size + headroom, available: free) }

        Self.sweepLeftovers(in: folder)
        let file = TestFile(folder: folder)
        let fds = try file.open()
        defer {
            progress(.cleaningUp)
            close(fds.read)
            close(fds.write)
        }

        try fill(fd: fds.write, size: size, cancellation: cancellation, progress: progress)

        var kinds: [BenchmarkKind] = [.read]
        if settings.includeWrites { kinds.append(.write) }
        if settings.mixReadPercent != nil { kinds.append(.mix) }

        var rows: [BenchmarkRow] = []
        var first = true
        for test in settings.tests {
            var row = BenchmarkRow(test: test)
            for kind in kinds {
                if !first { try pause(cancellation: cancellation, progress: progress) }
                first = false
                row[kind] = try measure(fds: fds, size: size, test: test, kind: kind, cancellation: cancellation, progress: progress)
            }
            rows.append(row)
        }
        return rows
    }

    /// Free bytes at `folder`, falling back to statfs when the resource value is unavailable.
    static func availableBytes(at folder: URL) -> Int64? {
        if let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
            return Int64(v)
        }
        var fs = statfs()
        guard statfs(folder.path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    /// Removes regular files left by older versions (which deleted the file by name at the end).
    /// Symlinks and anything not matching `.oDisk-benchmark-<UUID>.tmp` are never touched.
    @discardableResult
    public static func sweepLeftovers(in folder: URL) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(filePrefix) && name.hasSuffix(".tmp") {
            let uuid = name.dropFirst(filePrefix.count).dropLast(4)
            guard UUID(uuidString: String(uuid)) != nil else { continue }
            let path = folder.appendingPathComponent(name).path
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if unlink(path) == 0 { removed += 1 }
        }
        return removed
    }

    private func pause(cancellation: BenchmarkCancellation, progress: @Sendable (BenchmarkPhase) -> Void) throws {
        guard settings.intervalSeconds > 0 else { return }
        progress(.waiting(seconds: settings.intervalSeconds))
        let end = Date().addingTimeInterval(settings.intervalSeconds)
        while Date() < end {
            if cancellation.isCancelled { throw BenchmarkError.cancelled }
            usleep(100_000)
        }
    }

    private func fill(fd: Int32, size: Int64, cancellation: BenchmarkCancellation,
                      progress: @Sendable (BenchmarkPhase) -> Void) throws {
        let chunk = 8 << 20
        let buffer = try AlignedBuffer(size: chunk, random: settings.dataPattern == .random)
        defer { buffer.free() }
        var offset: Int64 = 0
        while offset < size {
            if cancellation.isCancelled { throw BenchmarkError.cancelled }
            let n = Int(min(Int64(chunk), size - offset))
            guard pwrite(fd, buffer.pointer, n, off_t(offset)) == n else {
                throw BenchmarkError.io("Writing the test file failed: \(String(cString: strerror(errno))).")
            }
            offset += Int64(n)
            progress(.preparing(fraction: Double(offset) / Double(size)))
        }
        fsync(fd)
    }

    private func measure(fds: TestFile.Descriptors, size: Int64, test: BenchmarkTest, kind: BenchmarkKind,
                         cancellation: BenchmarkCancellation,
                         progress: @escaping @Sendable (BenchmarkPhase) -> Void) throws -> BenchmarkMeasurement {
        var best: BenchmarkMeasurement?
        for pass in 1...max(1, settings.passes) {
            if cancellation.isCancelled { throw BenchmarkError.cancelled }
            let m = try runPass(fds: fds, size: size, test: test, kind: kind, cancellation: cancellation) { live in
                progress(.running(test: test, kind: kind, pass: pass, liveBytesPerSecond: live))
            }
            if best == nil || m.bytesPerSecond > best!.bytesPerSecond { best = m }
        }
        return best!
    }

    private func runPass(fds: TestFile.Descriptors, size: Int64, test: BenchmarkTest, kind: BenchmarkKind,
                         cancellation: BenchmarkCancellation,
                         live: @escaping @Sendable (Double) -> Void) throws -> BenchmarkMeasurement {
        let block = Int64(test.blockSize)
        let blocks = max(1, size / block)
        let threads = test.inFlight
        let readPercent = UInt64(settings.mixReadPercent ?? 70)
        let randomData = settings.dataPattern == .random
        let counters = PassCounters()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(settings.secondsPerPass * 1_000_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        let group = DispatchGroup()

        // Live readout ~5×/s.
        Thread.detachNewThread {
            while !counters.monitorStop.load(ordering: .relaxed) {
                usleep(200_000)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                if elapsed > 0 { live(Double(counters.ops.load(ordering: .relaxed)) * Double(block) / elapsed) }
            }
        }

        for _ in 0..<threads {
            group.enter()
            let thread = Thread {
                defer { group.leave() }
                guard let buffer = try? AlignedBuffer(size: Int(block), random: randomData) else {
                    counters.failed.store(ENOMEM, ordering: .relaxed)
                    return
                }
                defer { buffer.free() }
                // Independent seeds: SplitMix64 seeds spaced by its own increment would give every thread
                // the same offset sequence shifted by one step, collapsing the effective queue depth.
                var rng = SplitMix64(seed: UInt64.random(in: .min ... .max))
                while DispatchTime.now().uptimeNanoseconds < deadline, !cancellation.isCancelled {
                    let index: Int64
                    if test.pattern == .sequential {
                        index = Int64(counters.cursor.add(1, ordering: .relaxed).oldValue) % blocks
                    } else {
                        index = Int64(rng.next() % UInt64(blocks))
                    }
                    let off = off_t(index * block)
                    let isWrite = switch kind {
                    case .read: false
                    case .write: true
                    case .mix: rng.next() % 100 >= readPercent
                    }
                    // Shared read-only / write-only descriptors: a shared O_RDWR descriptor halves APFS
                    // random-read throughput, separate O_RDONLY and O_WRONLY ones don't.
                    let n = isWrite ? pwrite(fds.write, buffer.pointer, Int(block), off)
                                    : pread(fds.read, buffer.pointer, Int(block), off)
                    if n != Int(block) { counters.failed.store(errno == 0 ? EIO : errno, ordering: .relaxed); return }
                    counters.ops.add(1, ordering: .relaxed)
                }
            }
            thread.start()
        }
        group.wait()
        if kind != .read { fsync(fds.write) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        counters.monitorStop.store(true, ordering: .relaxed)

        if cancellation.isCancelled { throw BenchmarkError.cancelled }
        let err = counters.failed.load(ordering: .relaxed)
        if err != 0 { throw BenchmarkError.io("I/O failed during \(test.label): \(String(cString: strerror(err))).") }
        let count = Double(counters.ops.load(ordering: .relaxed))
        let iops = count / max(elapsed, 0.001)
        return BenchmarkMeasurement(bytesPerSecond: iops * Double(block), iops: iops,
                                    averageLatencyMicroseconds: count > 0 ? elapsed * 1e6 * Double(threads) / count : 0)
    }
}

/// The benchmark's scratch file: created exclusively, opened read-only and write-only, then unlinked.
struct TestFile {
    struct Descriptors: Sendable {
        let read: Int32
        let write: Int32
    }

    let path: String

    init(folder: URL) {
        path = folder.appendingPathComponent("\(BenchmarkEngine.filePrefix)\(UUID().uuidString).tmp").path
    }

    func open() throws -> Descriptors {
        let create = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard create >= 0 else {
            throw BenchmarkError.io("Couldn't create the test file: \(String(cString: strerror(errno))).")
        }
        defer { close(create) }
        let r = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let w = Darwin.open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        // Whatever happens next, the name goes away now; the descriptors keep the data alive.
        unlink(path)
        guard r >= 0, w >= 0, Self.sameFile(create, r), Self.sameFile(create, w) else {
            if r >= 0 { close(r) }
            if w >= 0 { close(w) }
            throw BenchmarkError.io("The test file changed while it was being opened. The test was stopped.")
        }
        for fd in [r, w] {
            _ = fcntl(fd, F_NOCACHE, 1)
            _ = fcntl(fd, F_RDAHEAD, 0)
        }
        return Descriptors(read: r, write: w)
    }

    static func sameFile(_ a: Int32, _ b: Int32) -> Bool {
        var sa = stat(), sb = stat()
        guard fstat(a, &sa) == 0, fstat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino && (sb.st_mode & S_IFMT) == S_IFREG
    }
}

/// Shared counters for one pass; a class so the I/O threads can share the atomics.
final class PassCounters: Sendable {
    let ops = Atomic<Int>(0)
    let failed = Atomic<Int32>(0)
    /// Shared sequential cursor, so QD>1 sequential access stays sequential overall.
    let cursor = Atomic<Int>(0)
    let monitorStop = Atomic<Bool>(false)
}

/// Page-aligned buffer, required for uncached I/O to stay on the fast path.
struct AlignedBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init(size: Int, random: Bool) throws {
        var p: UnsafeMutableRawPointer?
        guard posix_memalign(&p, Int(getpagesize()), size) == 0, let p else {
            throw BenchmarkError.io("Couldn't allocate memory for the test.")
        }
        pointer = p
        if random { arc4random_buf(pointer, size) } else { memset(pointer, 0, size) }
    }

    func free() { Foundation.free(pointer) }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
