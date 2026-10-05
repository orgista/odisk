import Foundation
import Synchronization

/// One CrystalDiskMark-style test: block size, access pattern and queue depth.
/// Queue depth is emulated with that many threads issuing synchronous I/O, since macOS has no
/// user-visible submission queue (no io_uring/libaio).
public struct BenchmarkTest: Hashable, Sendable, Codable, Identifiable {
    public enum Pattern: String, Sendable, Codable { case sequential, random }
    public var pattern: Pattern
    public var blockSize: Int
    public var queueDepth: Int

    public init(_ pattern: Pattern, blockSize: Int, queueDepth: Int) {
        self.pattern = pattern; self.blockSize = blockSize; self.queueDepth = queueDepth
    }

    public var id: String { label }

    /// "SEQ1M Q8T1" / "RND4K Q32T1"
    public var label: String {
        let size = blockSize >= 1 << 20 ? "\(blockSize >> 20)M" : "\(blockSize >> 10)K"
        return "\(pattern == .sequential ? "SEQ" : "RND")\(size) Q\(queueDepth)T1"
    }

    public static let seq1MQ8 = BenchmarkTest(.sequential, blockSize: 1 << 20, queueDepth: 8)
    public static let seq1MQ1 = BenchmarkTest(.sequential, blockSize: 1 << 20, queueDepth: 1)
    public static let rnd4KQ32 = BenchmarkTest(.random, blockSize: 4 << 10, queueDepth: 32)
    public static let rnd4KQ1 = BenchmarkTest(.random, blockSize: 4 << 10, queueDepth: 1)
    public static let standard: [BenchmarkTest] = [.seq1MQ8, .seq1MQ1, .rnd4KQ32, .rnd4KQ1]
}

public struct BenchmarkSettings: Hashable, Sendable, Codable {
    public var fileSizeBytes: Int
    public var passes: Int
    public var secondsPerPass: Double
    public var tests: [BenchmarkTest]
    public var includeWrites: Bool

    public init(fileSizeBytes: Int = 1 << 30, passes: Int = 3, secondsPerPass: Double = 3,
                tests: [BenchmarkTest] = BenchmarkTest.standard, includeWrites: Bool = true) {
        self.fileSizeBytes = fileSizeBytes; self.passes = passes; self.secondsPerPass = secondsPerPass
        self.tests = tests; self.includeWrites = includeWrites
    }

    public static let quick = BenchmarkSettings(fileSizeBytes: 256 << 20, passes: 1, secondsPerPass: 2)
    public static let standard = BenchmarkSettings()
    public static let thorough = BenchmarkSettings(fileSizeBytes: 4 << 30, passes: 5, secondsPerPass: 5)
}

public struct BenchmarkMeasurement: Hashable, Sendable, Codable {
    public var bytesPerSecond: Double
    public var iops: Double
    public var averageLatencyMicroseconds: Double

    public init(bytesPerSecond: Double, iops: Double, averageLatencyMicroseconds: Double) {
        self.bytesPerSecond = bytesPerSecond; self.iops = iops; self.averageLatencyMicroseconds = averageLatencyMicroseconds
    }
}

public struct BenchmarkRow: Hashable, Sendable, Codable, Identifiable {
    public var id: String { test.id }
    public var test: BenchmarkTest
    public var read: BenchmarkMeasurement?
    public var write: BenchmarkMeasurement?

    public init(test: BenchmarkTest, read: BenchmarkMeasurement? = nil, write: BenchmarkMeasurement? = nil) {
        self.test = test; self.read = read; self.write = write
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
        var lines = ["oDisk benchmark — \(driveModel) (\(volumeName))",
                     "\(Formatters.bytes(Double(settings.fileSizeBytes))) test file, \(settings.passes) pass\(settings.passes == 1 ? "" : "es"), MB/s = 1,000,000 bytes/s",
                     "",
                     "Test          Read MB/s   Write MB/s"]
        for row in rows {
            let r = row.read.map { Formatters.throughput($0.bytesPerSecond) } ?? "—"
            let w = row.write.map { Formatters.throughput($0.bytesPerSecond) } ?? "—"
            lines.append(row.test.label.padding(toLength: 14, withPad: " ", startingAt: 0)
                         + r.leftPad(9) + w.leftPad(13))
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
    case running(test: BenchmarkTest, isWrite: Bool, pass: Int, liveBytesPerSecond: Double)
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
/// All I/O bypasses the unified buffer cache (F_NOCACHE) and uses incompressible random data.
public struct BenchmarkEngine: Sendable {
    public var settings: BenchmarkSettings

    public init(settings: BenchmarkSettings) { self.settings = settings }

    public func run(in folder: URL, cancellation: BenchmarkCancellation,
                    progress: @escaping @Sendable (BenchmarkPhase) -> Void) throws -> [BenchmarkRow] {
        let size = Int64(settings.fileSizeBytes)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init) ?? .max
        // Leave headroom so a benchmark never fills a nearly-full disk.
        if free < size + 512 << 20 { throw BenchmarkError.notEnoughSpace(needed: size + 512 << 20, available: free) }

        let file = folder.appendingPathComponent(".oDisk-benchmark-\(UUID().uuidString).tmp")
        let fd = open(file.path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        guard fd >= 0 else { throw BenchmarkError.io("Couldn't create the test file: \(String(cString: strerror(errno))).") }
        defer {
            progress(.cleaningUp)
            unlink(file.path)
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        do {
            try fill(fd: fd, size: size, cancellation: cancellation, progress: progress)
            close(fd)
        } catch {
            close(fd)
            throw error
        }

        var rows: [BenchmarkRow] = []
        for test in settings.tests {
            var row = BenchmarkRow(test: test)
            row.read = try measure(path: file.path, size: size, test: test, write: false, cancellation: cancellation, progress: progress)
            if settings.includeWrites {
                row.write = try measure(path: file.path, size: size, test: test, write: true, cancellation: cancellation, progress: progress)
            }
            rows.append(row)
        }
        return rows
    }

    private func fill(fd: Int32, size: Int64, cancellation: BenchmarkCancellation,
                      progress: @Sendable (BenchmarkPhase) -> Void) throws {
        let chunk = 8 << 20
        let buffer = AlignedBuffer(size: chunk, random: true)
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

    private func measure(path: String, size: Int64, test: BenchmarkTest, write: Bool, cancellation: BenchmarkCancellation,
                         progress: @escaping @Sendable (BenchmarkPhase) -> Void) throws -> BenchmarkMeasurement {
        var best: BenchmarkMeasurement?
        for pass in 1...max(1, settings.passes) {
            if cancellation.isCancelled { throw BenchmarkError.cancelled }
            let m = try runPass(path: path, size: size, test: test, write: write, cancellation: cancellation) { live in
                progress(.running(test: test, isWrite: write, pass: pass, liveBytesPerSecond: live))
            }
            if best == nil || m.bytesPerSecond > best!.bytesPerSecond { best = m }
        }
        return best!
    }

    private func runPass(path: String, size: Int64, test: BenchmarkTest, write: Bool, cancellation: BenchmarkCancellation,
                         live: @escaping @Sendable (Double) -> Void) throws -> BenchmarkMeasurement {
        let block = Int64(test.blockSize)
        let blocks = max(1, size / block)
        let threads = test.queueDepth
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

        for t in 0..<threads {
            group.enter()
            let thread = Thread {
                defer { group.leave() }
                // One descriptor per thread, opened read-only or write-only: on APFS a shared O_RDWR
                // descriptor halves random-read throughput at high queue depth.
                let fd = open(path, write ? O_WRONLY : O_RDONLY)
                guard fd >= 0 else { counters.failed.store(errno, ordering: .relaxed); return }
                defer { if write { fsync(fd) }; close(fd) }
                _ = fcntl(fd, F_NOCACHE, 1)
                _ = fcntl(fd, F_RDAHEAD, 0)
                let buffer = AlignedBuffer(size: Int(block), random: true)
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
                    let n = write ? pwrite(fd, buffer.pointer, Int(block), off) : pread(fd, buffer.pointer, Int(block), off)
                    if n != Int(block) { counters.failed.store(errno == 0 ? EIO : errno, ordering: .relaxed); return }
                    counters.ops.add(1, ordering: .relaxed)
                }
            }
            thread.start()
        }
        group.wait()
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
    init(size: Int, random: Bool) {
        var p: UnsafeMutableRawPointer?
        posix_memalign(&p, Int(getpagesize()), size)
        pointer = p!
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
