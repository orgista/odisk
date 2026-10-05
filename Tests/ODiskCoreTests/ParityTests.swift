import Foundation
import Testing
@testable import ODiskCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("odisk-parity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite(.serialized) struct BenchmarkSafetyTests {
    @Test func testFileIsUnlinkedWhileRunning() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = Atomic(0)
        _ = try BenchmarkEngine(settings: BenchmarkSettings(fileSizeBytes: 16 << 20, passes: 1, secondsPerPass: 0.1,
                                                            tests: [.rnd4KQ1]))
            .run(in: dir, cancellation: BenchmarkCancellation()) { phase in
                if case .running = phase {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                    seen.store(max(seen.load(), names.count))
                }
            }
        #expect(seen.load() == 0, "the test file name must be gone while the benchmark runs")
    }

    @Test func sweepRemovesOnlyOurRegularFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ours = dir.appendingPathComponent(".oDisk-benchmark-\(UUID().uuidString).tmp")
        let notUUID = dir.appendingPathComponent(".oDisk-benchmark-notes.tmp")
        let target = dir.appendingPathComponent("precious.txt")
        let link = dir.appendingPathComponent(".oDisk-benchmark-\(UUID().uuidString).tmp")
        try Data("x".utf8).write(to: ours)
        try Data("x".utf8).write(to: notUUID)
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(BenchmarkEngine.sweepLeftovers(in: dir) == 1)
        #expect(!FileManager.default.fileExists(atPath: ours.path))
        #expect(FileManager.default.fileExists(atPath: notUUID.path))
        #expect((try? String(contentsOf: target, encoding: .utf8)) == "keep")
    }

    @Test func mixedAndZeroFillMeasure() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = BenchmarkSettings(fileSizeBytes: 16 << 20, passes: 1, secondsPerPass: 0.15,
                                         tests: [.seq1MQ1, .rnd4KQ1], mixReadPercent: 70, dataPattern: .zeros)
        let rows = try BenchmarkEngine(settings: settings).run(in: dir, cancellation: BenchmarkCancellation()) { _ in }
        for row in rows {
            #expect((row.mix?.bytesPerSecond ?? 0) > 0)
            #expect((row.read?.bytesPerSecond ?? 0) > 0)
        }
    }

    @Test func intervalPausesAreCancellable() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cancel = BenchmarkCancellation()
        let settings = BenchmarkSettings(fileSizeBytes: 16 << 20, passes: 1, secondsPerPass: 0.1, intervalSeconds: 30,
                                         tests: [.rnd4KQ1])
        let start = Date()
        #expect(throws: BenchmarkError.cancelled) {
            try BenchmarkEngine(settings: settings).run(in: dir, cancellation: cancel) { phase in
                if case .waiting = phase { cancel.cancel() }
            }
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func notEnoughSpaceIsReported() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let huge = BenchmarkSettings(fileSizeBytes: Int.max / 4, passes: 1, secondsPerPass: 0.1)
        #expect(throws: (any Error).self) {
            try BenchmarkEngine(settings: huge).run(in: dir, cancellation: BenchmarkCancellation()) { _ in }
        }
    }

    @Test func peakLabelsAndOldSettingsDecode() throws {
        #expect(BenchmarkTest.rnd4KQ32T16.label == "RND4K Q32T16")
        #expect(BenchmarkTest.rnd4KQ32T16.inFlight == 512)
        #expect(BenchmarkTestSet.nvme.tests.map(\.label) == ["SEQ1M Q8T1", "SEQ128K Q32T1", "RND4K Q32T16", "RND4K Q1T1"])
        // History saved by 1.0 had no threads / interval / mix / pattern keys.
        let old = #"{"fileSizeBytes":1073741824,"passes":3,"secondsPerPass":3,"tests":[{"pattern":"random","blockSize":4096,"queueDepth":32}],"includeWrites":true}"#
        let s = try JSONDecoder().decode(BenchmarkSettings.self, from: Data(old.utf8))
        #expect(s.tests.first?.threads == 1)
        #expect(s.dataPattern == .random)
        #expect(s.mixReadPercent == nil)
    }
}

@Suite struct HistoryAndAlertTests {
    func snapshot(warning: UInt8 = 0, tempK: Int = 310, used: UInt8 = 3, mediaErrors: UInt64 = 0) throws -> SMARTSnapshot {
        SMARTSnapshot(date: Date(), log: try NVMeHealthLog(bytes: makeLog(warning: warning, tempK: tempK, used: used, mediaErrors: mediaErrors)),
                      identify: nil)
    }

    @Test func recordsEvery15MinutesOrOnChange() {
        let t0 = Date()
        let a = HealthSample(date: t0, status: .good, temperatureCelsius: 40, lifeUsedPercent: 3)
        #expect(HealthHistoryPolicy.shouldRecord(a, after: nil))
        #expect(!HealthHistoryPolicy.shouldRecord(HealthSample(date: t0.addingTimeInterval(60), status: .good, lifeUsedPercent: 3), after: a))
        #expect(HealthHistoryPolicy.shouldRecord(HealthSample(date: t0.addingTimeInterval(60), status: .caution, lifeUsedPercent: 3), after: a))
        #expect(HealthHistoryPolicy.shouldRecord(HealthSample(date: t0.addingTimeInterval(16 * 60), status: .good, lifeUsedPercent: 3), after: a))
    }

    @Test func historyThinsOldestHalfAtCap() {
        var list: [HealthSample] = []
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0...HealthHistoryPolicy.maximumSamples {
            list = HealthHistoryPolicy.appending(HealthSample(date: t0.addingTimeInterval(Double(i) * 900), status: .good), to: list)
        }
        #expect(list.count <= HealthHistoryPolicy.maximumSamples)
        #expect(list.last?.date == t0.addingTimeInterval(Double(HealthHistoryPolicy.maximumSamples) * 900))
        #expect(list.first?.date == t0)
    }

    @Test func alertsOnlyWhenHealthGetsWorse() throws {
        var mem = AlertPolicy.Memory()
        var r = AlertPolicy.evaluate(driveName: "SSD", snapshot: try snapshot(), memory: mem, settings: .init())
        #expect(r.alerts.isEmpty)
        mem = r.memory
        r = AlertPolicy.evaluate(driveName: "SSD", snapshot: try snapshot(warning: 1 << 3), memory: mem, settings: .init())
        #expect(r.alerts.map(\.kind) == [.health])
        #expect(r.alerts.first?.title == "Back up SSD now")
        // Same state again: no repeat.
        r = AlertPolicy.evaluate(driveName: "SSD", snapshot: try snapshot(warning: 1 << 3), memory: r.memory, settings: .init())
        #expect(r.alerts.isEmpty)
    }

    @Test func newMediaErrorsAlert() throws {
        let first = AlertPolicy.evaluate(driveName: "SSD", snapshot: try snapshot(), memory: .init(), settings: .init())
        let second = AlertPolicy.evaluate(driveName: "SSD", snapshot: try snapshot(mediaErrors: 3), memory: first.memory, settings: .init())
        #expect(second.alerts.contains { $0.kind == .errors && $0.body.contains("3 new") })
    }

    @Test func temperatureAlertHasCooldown() throws {
        let hot = try snapshot(tempK: 273 + 85)
        let now = Date()
        let a = AlertPolicy.evaluate(driveName: "SSD", snapshot: hot, memory: .init(), settings: .init(), now: now)
        #expect(a.alerts.contains { $0.kind == .temperature })
        let b = AlertPolicy.evaluate(driveName: "SSD", snapshot: hot, memory: a.memory, settings: .init(), now: now.addingTimeInterval(600))
        #expect(!b.alerts.contains { $0.kind == .temperature })
        let c = AlertPolicy.evaluate(driveName: "SSD", snapshot: hot, memory: a.memory, settings: .init(), now: now.addingTimeInterval(3700))
        #expect(c.alerts.contains { $0.kind == .temperature })
    }

    @Test func alertsRespectSettings() throws {
        let r = AlertPolicy.evaluate(driveName: "SSD", snapshot: try snapshot(warning: 1 << 3, tempK: 273 + 85), memory: .init(),
                                     settings: .init(notifyHealth: false, notifyTemperature: false))
        #expect(r.alerts.isEmpty)
    }
}

@Suite struct IdentifyFeatureTests {
    @Test func parsesVersionAndFeatureFlags() {
        var b = [UInt8](repeating: 0x20, count: 4096)
        b[24] = 0x41
        b[80] = 0; b[81] = 4; b[82] = 1; b[83] = 0      // NVMe 1.4
        b[520] = 0b0000_1100; b[521] = 0                 // DSM (TRIM) + Write Zeroes
        b[525] = 1                                       // volatile write cache
        b[328] = 0b010; b[329] = 0; b[330] = 0; b[331] = 0 // sanitize: block erase
        b[260] = 0b0000_0110                             // 3 firmware slots
        let id = NVMeIdentify(bytes: b)
        #expect(id?.nvmeVersion == "1.4")
        #expect(id?.featureList == ["TRIM", "Volatile Write Cache", "Write Zeroes", "Sanitize"])
        #expect(id?.firmwareSlots == 3)
    }

    @Test func metricsFromNVMe() throws {
        let s = SMARTSnapshot(date: Date(), log: try NVMeHealthLog(bytes: makeLog(tempK: 320, used: 7, powerOnHours: 100)), identify: nil)
        #expect(s.metrics.temperatureCelsius == 47)
        #expect(s.metrics.lifeUsedPercent == 7)
        #expect(s.metrics.powerOnHours == 100)
        #expect(s.smartProtocol == .nvme)
    }
}

/// Small lock-free max holder for the progress callback.
final class Atomic: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()
    init(_ v: Int) { value = v }
    func load() -> Int { lock.withLock { value } }
    func store(_ v: Int) { lock.withLock { value = v } }
}
