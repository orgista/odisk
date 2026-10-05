import Foundation
import Testing
@testable import ODiskCore

/// Builds a 512-byte NVMe health log with the given fields (little-endian).
func makeLog(warning: UInt8 = 0, tempK: Int = 310, spare: UInt8 = 100, threshold: UInt8 = 10, used: UInt8 = 3,
             unitsWritten: UInt64 = 0, powerOnHours: UInt64 = 0, mediaErrors: UInt64 = 0) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 512)
    b[0] = warning
    b[1] = UInt8(tempK & 0xff); b[2] = UInt8(tempK >> 8)
    b[3] = spare; b[4] = threshold; b[5] = used
    func put(_ v: UInt64, at o: Int) { for i in 0..<8 { b[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xff) } }
    put(unitsWritten, at: 48)
    put(powerOnHours, at: 128)
    put(mediaErrors, at: 160)
    return b
}

@Suite struct NVMeParsingTests {
    @Test func decodesFields() throws {
        let log = try NVMeHealthLog(bytes: makeLog(tempK: 307, used: 5, unitsWritten: 2_000_000, powerOnHours: 4132))
        #expect(log.compositeTemperatureCelsius == 34)
        #expect(log.percentageUsed == 5)
        #expect(log.powerOnHours == 4132)
        #expect(log.bytesWritten == 2_000_000 * 512_000)
    }

    @Test func decodes128BitCounterHighBytes() throws {
        var bytes = makeLog()
        bytes[48 + 8] = 1 // 2^64 data units
        let log = try NVMeHealthLog(bytes: bytes)
        #expect(log.dataUnitsWritten == 18_446_744_073_709_551_616)
    }

    @Test func rejectsShortBuffer() {
        #expect(throws: NVMeParseError.shortBuffer(10)) { try NVMeHealthLog(bytes: [UInt8](repeating: 0, count: 10)) }
    }

    @Test func zeroTemperatureMeansUnknown() throws {
        #expect(try NVMeHealthLog(bytes: makeLog(tempK: 0)).compositeTemperatureCelsius == nil)
    }

    @Test func identifyParsesStrings() {
        var b = [UInt8](repeating: 0x20, count: 4096)
        func put(_ s: String, _ o: Int) { for (i, c) in s.utf8.enumerated() { b[o + i] = c } }
        put("S123", 4); put("Samsung SSD 990 PRO 2TB", 24); put("4B2QJXD7", 64)
        b[266] = 0x5B; b[267] = 0x01 // 347 K
        let id = NVMeIdentify(bytes: b)
        #expect(id?.modelNumber == "Samsung SSD 990 PRO 2TB")
        #expect(id?.firmwareRevision == "4B2QJXD7")
        #expect(id?.serialNumber == "S123")
        #expect(id?.warningTemperatureKelvin == 347)
    }

    @Test func emptyIdentifyIsNil() {
        #expect(NVMeIdentify(bytes: [UInt8](repeating: 0, count: 4096)) == nil)
    }
}

@Suite struct HealthPolicyTests {
    func assess(_ bytes: [UInt8]) throws -> HealthAssessment { HealthPolicy.assess(try NVMeHealthLog(bytes: bytes)) }

    @Test func healthyDriveIsGood() throws {
        let a = try assess(makeLog(used: 5))
        #expect(a.status == .good)
        #expect(a.lifeRemainingPercent == 95)
        #expect(a.findings.isEmpty)
        #expect(a.temperature == .normal)
    }

    @Test func spareBelowThresholdIsBad() throws {
        #expect(try assess(makeLog(spare: 5, threshold: 10)).status == .bad)
    }

    @Test func readOnlyIsBad() throws {
        #expect(try assess(makeLog(warning: 1 << 3)).status == .bad)
    }

    @Test func wornOutIsCautionWithZeroLife() throws {
        let a = try assess(makeLog(used: 120))
        #expect(a.status == .caution)
        #expect(a.lifeRemainingPercent == 0)
    }

    @Test func mediaErrorsAreCaution() throws {
        let a = try assess(makeLog(mediaErrors: 2))
        #expect(a.status == .caution)
        #expect(a.findings.first?.message.contains("2 unrecovered") == true)
    }

    @Test func hotDriveUsesIdentifyThresholds() throws {
        var id = [UInt8](repeating: 0x20, count: 4096)
        id[24] = 0x41
        id[266] = UInt8(323 & 0xff); id[267] = UInt8(323 >> 8) // warn 50 °C
        id[268] = UInt8(333 & 0xff); id[269] = UInt8(333 >> 8) // crit 60 °C
        let log = try NVMeHealthLog(bytes: makeLog(tempK: 273 + 55))
        #expect(HealthPolicy.temperatureStatus(log, identify: NVMeIdentify(bytes: id)) == .warm)
        let hot = try NVMeHealthLog(bytes: makeLog(tempK: 273 + 61))
        #expect(HealthPolicy.assess(hot, identify: NVMeIdentify(bytes: id)).status == .caution)
    }

    @Test func statusOrdering() {
        #expect([HealthStatus.good, .bad, .caution].max() == .bad)
    }
}

@Suite struct FormatterTests {
    @Test func bytesAreDecimal() {
        #expect(Formatters.bytes(512_000_000_000.0) == "512 GB")
        #expect(Formatters.bytes(1_500_000_000_000.0) == "1.5 TB")
        #expect(Formatters.bytes(999.0) == "999 B")
    }

    @Test func throughputPrecision() {
        #expect(Formatters.throughput(7_123_400_000) == "7123")
        #expect(Formatters.throughput(45_670_000) == "45.67")
    }

    @Test func powerOnTime() {
        #expect(Formatters.powerOnTime(hours: 10) == "10 h")
        #expect(Formatters.powerOnTime(hours: 24 * 100) == "100 days")
        #expect(Formatters.powerOnTime(hours: 24 * 365.25 * 2) == "2 years")
    }

    @Test func testLabels() {
        #expect(BenchmarkTest.seq1MQ8.label == "SEQ1M Q8T1")
        #expect(BenchmarkTest.rnd4KQ32.label == "RND4K Q32T1")
    }
}

@Suite(.serialized) struct BenchmarkEngineTests {
    @Test func runsAllTestsAndCleansUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("odisk-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = BenchmarkSettings(fileSizeBytes: 16 << 20, passes: 1, secondsPerPass: 0.2)
        let rows = try BenchmarkEngine(settings: settings).run(in: dir, cancellation: BenchmarkCancellation()) { _ in }
        #expect(rows.map(\.test) == BenchmarkTest.standard)
        for row in rows {
            #expect((row.read?.bytesPerSecond ?? 0) > 0)
            #expect((row.write?.bytesPerSecond ?? 0) > 0)
            #expect((row.read?.averageLatencyMicroseconds ?? 0) > 0)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func cancellationStopsAndCleansUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("odisk-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cancel = BenchmarkCancellation()
        cancel.cancel()
        #expect(throws: BenchmarkError.cancelled) {
            try BenchmarkEngine(settings: BenchmarkSettings(fileSizeBytes: 16 << 20, passes: 1, secondsPerPass: 0.2))
                .run(in: dir, cancellation: cancel) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func shareTextHasEveryRow() {
        let m = BenchmarkMeasurement(bytesPerSecond: 3_000_000_000, iops: 3000, averageLatencyMicroseconds: 300)
        let result = BenchmarkResult(date: Date(), driveName: "X", driveModel: "Model", volumeName: "Vol",
                                     settings: .quick, rows: BenchmarkTest.standard.map { BenchmarkRow(test: $0, read: m, write: m) })
        for t in BenchmarkTest.standard { #expect(result.shareText.contains(t.label)) }
        #expect(result.shareText.contains("3000"))
    }
}

@Suite struct DriveScannerTests {
    /// Runs on real hardware: every Mac has at least its startup drive.
    @Test func findsStartupDrive() {
        let drives = DriveScanner.scan()
        #expect(!drives.isEmpty)
        #expect(drives.first?.volumes.contains(where: \.isStartupDisk) == true)
        #expect(drives.allSatisfy { $0.interconnect != "Virtual Interface" })
    }

    @Test func readsSMARTOnStartupDriveWhenCapable() throws {
        guard let d = DriveScanner.scan().first, d.smartCapable else { return }
        let snap = try DriveScanner.readSMART(registryEntryID: d.registryEntryID).get()
        #expect(snap.log.powerOnHours > 0)
        #expect(snap.assessment.lifeRemainingPercent != nil)
    }
}
