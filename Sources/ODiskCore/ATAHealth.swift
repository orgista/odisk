import Foundation

/// One row of the ATA SMART attribute table, as CrystalDiskInfo shows it.
public struct ATASMARTAttribute: Equatable, Sendable, Codable, Identifiable {
    public var id: UInt8
    public var name: String
    public var flags: UInt16
    /// Normalized value (usually 1...253, higher is better).
    public var current: Int
    public var worst: Int
    /// 0 when the drive reports no threshold for this attribute.
    public var threshold: Int
    /// 48-bit vendor raw value.
    public var raw: UInt64
    /// Flags bit 0: a value at or below threshold predicts failure.
    public var isPrefailure: Bool { flags & 0x1 != 0 }

    public init(id: UInt8, flags: UInt16, current: Int, worst: Int, threshold: Int, raw: UInt64) {
        self.id = id
        self.name = ATASMARTAttribute.name(for: id)
        self.flags = flags
        self.current = current
        self.worst = worst
        self.threshold = threshold
        self.raw = raw
    }

    /// Common attribute names. Vendors reuse IDs, so these follow the most widespread meaning.
    public static func name(for id: UInt8) -> String {
        switch id {
        case 0x01: "Read Error Rate"
        case 0x02: "Throughput Performance"
        case 0x03: "Spin-Up Time"
        case 0x04: "Start/Stop Count"
        case 0x05: "Reallocated Sectors Count"
        case 0x07: "Seek Error Rate"
        case 0x08: "Seek Time Performance"
        case 0x09: "Power-On Hours"
        case 0x0A: "Spin Retry Count"
        case 0x0B: "Recalibration Retries"
        case 0x0C: "Power Cycle Count"
        case 0x0D: "Soft Read Error Rate"
        case 0x16: "Current Helium Level"
        case 0xA0: "Uncorrectable Sectors (Read/Write)"
        case 0xA1: "Valid Spare Blocks"
        case 0xA3: "Initial Invalid Blocks"
        case 0xA4: "Total Erase Count"
        case 0xA5: "Maximum Erase Count"
        case 0xA6: "Minimum Erase Count"
        case 0xA7: "Average Erase Count"
        case 0xA8: "Max NAND Erase Count"
        case 0xA9: "Remaining Life"
        case 0xAA: "Available Reserved Space"
        case 0xAB: "Program Fail Count"
        case 0xAC: "Erase Fail Count"
        case 0xAD: "Wear Leveling Count"
        case 0xAE: "Unexpected Power Loss Count"
        case 0xAF: "Power Loss Protection Failure"
        case 0xB1: "Wear Range Delta"
        case 0xB3: "Used Reserved Block Count"
        case 0xB4: "Unused Reserved Block Count"
        case 0xB5: "Program Fail Count"
        case 0xB6: "Erase Fail Count"
        case 0xB7: "SATA Downshift Error Count"
        case 0xB8: "End-to-End Error"
        case 0xBB: "Reported Uncorrectable Errors"
        case 0xBC: "Command Timeout"
        case 0xBD: "High Fly Writes"
        case 0xBE: "Airflow Temperature"
        case 0xBF: "G-Sense Error Rate"
        case 0xC0: "Unsafe Shutdown Count"
        case 0xC1: "Load/Unload Cycle Count"
        case 0xC2: "Temperature"
        case 0xC3: "Hardware ECC Recovered"
        case 0xC4: "Reallocation Event Count"
        case 0xC5: "Current Pending Sector Count"
        case 0xC6: "Uncorrectable Sector Count"
        case 0xC7: "UltraDMA CRC Error Count"
        case 0xC8: "Write Error Rate"
        case 0xCA: "Percentage Lifetime Used"
        case 0xD2: "Successful RAIN Recovery Count"
        case 0xDC: "Disk Shift"
        case 0xDF: "Load/Unload Retry Count"
        case 0xE0: "Load Friction"
        case 0xE2: "Load-in Time"
        case 0xE6: "GMR Head Amplitude"
        case 0xE7: "SSD Life Left"
        case 0xE8: "Available Reserved Space"
        case 0xE9: "Media Wearout Indicator"
        case 0xEA: "Average/Max Erase Count"
        case 0xEB: "Good Block Count"
        case 0xF0: "Head Flying Hours"
        case 0xF1: "Total LBAs Written"
        case 0xF2: "Total LBAs Read"
        case 0xF9: "NAND Writes (1 GiB)"
        case 0xFA: "Read Error Retry Rate"
        case 0xFE: "Free Fall Protection"
        default: "Vendor Specific"
        }
    }
}

/// The ATA SMART READ DATA attribute table joined with READ THRESHOLDS.
public struct ATAHealthLog: Equatable, Sendable, Codable {
    public var attributes: [ATASMARTAttribute]
    /// SMART RETURN STATUS said a threshold was exceeded (the drive's own failure verdict).
    public var thresholdExceeded: Bool

    public init(data: [UInt8], thresholds: [UInt8], thresholdExceeded: Bool) throws {
        guard data.count >= 512 else { throw ATAParseError.shortBuffer(data.count) }
        guard thresholds.count >= 512 else { throw ATAParseError.shortBuffer(thresholds.count) }
        var limits: [UInt8: Int] = [:]
        for i in 0..<30 {
            let o = 2 + i * 12
            if thresholds[o] != 0 { limits[thresholds[o]] = Int(thresholds[o + 1]) }
        }
        var attrs: [ATASMARTAttribute] = []
        for i in 0..<30 {
            let o = 2 + i * 12
            let id = data[o]
            guard id != 0 else { continue }
            let flags = UInt16(data[o + 1]) | UInt16(data[o + 2]) << 8
            let raw = (0..<6).reduce(UInt64(0)) { $0 | UInt64(data[o + 5 + $1]) << (8 * UInt64($1)) }
            attrs.append(ATASMARTAttribute(id: id, flags: flags, current: Int(data[o + 3]), worst: Int(data[o + 4]),
                                           threshold: limits[id] ?? 0, raw: raw))
        }
        attributes = attrs
        self.thresholdExceeded = thresholdExceeded
    }

    public func attribute(_ id: UInt8) -> ATASMARTAttribute? { attributes.first { $0.id == id } }

    public var temperatureCelsius: Int? {
        for id: UInt8 in [0xC2, 0xBE] {
            if let a = attribute(id) {
                let c = Int(a.raw & 0xFF)
                if (1...99).contains(c) { return c }
            }
        }
        return nil
    }

    public var powerOnHours: Int? { attribute(0x09).map { Int($0.raw & 0xFFFF_FFFF) } }
    public var powerCycles: Int? { attribute(0x0C).map { Int($0.raw) } }
    public var reallocatedSectors: Int? { attribute(0x05).map { Int($0.raw) } }
    public var pendingSectors: Int? { attribute(0xC5).map { Int($0.raw) } }
    public var uncorrectableSectors: Int? { attribute(0xC6).map { Int($0.raw) } }
    public var unsafeShutdowns: Int? { (attribute(0xC0) ?? attribute(0xAE)).map { Int($0.raw) } }

    /// 0...100, from the first wear indicator the drive reports.
    public var lifeRemainingPercent: Int? {
        for id: UInt8 in [0xE7, 0xA9, 0xB1, 0xE9] {
            if let a = attribute(id) { return min(max(a.current, 0), 100) }
        }
        if let a = attribute(0xCA) { return 100 - Int(min(a.raw, 100)) }
        return nil
    }

    /// Total LBAs written / read × 512 bytes.
    public var hostBytesWritten: Double? { attribute(0xF1).map { Double($0.raw) * 512 } }
    public var hostBytesRead: Double? { attribute(0xF2).map { Double($0.raw) * 512 } }
}

/// The parts of ATA IDENTIFY DEVICE that a person cares about.
public struct ATAIdentify: Equatable, Sendable, Codable {
    public var serialNumber: String
    public var modelNumber: String
    public var firmwareRevision: String
    /// Word 217: 1 = non-rotating (SSD), 0 = not reported, otherwise RPM.
    public var rotationRate: Int
    public var isSolidState: Bool { rotationRate == 1 }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 512 else { return nil }
        // ATA strings hold two characters per 16-bit word, high byte first.
        func ata(words r: ClosedRange<Int>) -> String {
            var out: [UInt8] = []
            for w in r { out.append(bytes[w * 2 + 1]); out.append(bytes[w * 2]) }
            return String(decoding: out.filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        modelNumber = ata(words: 27...46)
        guard !modelNumber.isEmpty else { return nil }
        serialNumber = ata(words: 10...19)
        firmwareRevision = ata(words: 23...26)
        rotationRate = Int(bytes[434]) | Int(bytes[435]) << 8
    }
}

public enum ATAParseError: Error, Equatable {
    case shortBuffer(Int)
}

/// Turns ATA SMART attributes into a verdict, the way CrystalDiskInfo does. Pure, so it is unit tested.
public enum ATAHealthPolicy {
    public static let warmCelsius = 55
    public static let hotCelsius = 70

    public static func assess(_ log: ATAHealthLog) -> HealthAssessment {
        var findings: [HealthFinding] = []
        func add(_ s: HealthStatus, _ m: String) { findings.append(HealthFinding(status: s, message: m)) }
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

        if log.thresholdExceeded {
            add(.bad, "The drive's own self-check reports that it is failing. Back up now.")
        }
        for a in log.attributes where a.threshold > 0 && a.current <= a.threshold {
            add(.bad, "\(a.name) (\(String(format: "%02X", a.id))) is at \(a.current), at or below the drive's failure limit of \(a.threshold). Back up now.")
        }
        if let n = log.reallocatedSectors, n > 0 {
            add(.caution, "\(count(n, "bad sector has", "bad sectors have")) been replaced with spares.")
        }
        if let n = log.pendingSectors, n > 0 {
            add(.caution, "\(count(n, "sector is", "sectors are")) waiting to be remapped after read errors.")
        }
        if let n = log.uncorrectableSectors, n > 0 {
            add(.caution, "\(count(n, "sector", "sectors")) could not be read or corrected.")
        }
        let life = log.lifeRemainingPercent
        if let life, life <= 10 {
            add(.caution, "Only \(life)% of the drive's rated life remains. Keep backups current.")
        }

        let status = findings.map(\.status).max() ?? .good
        return HealthAssessment(status: status, lifeRemainingPercent: life, findings: findings,
                                temperature: temperatureStatus(log))
    }

    public static func temperatureStatus(_ log: ATAHealthLog) -> TemperatureStatus {
        guard let c = log.temperatureCelsius else { return .unknown }
        if c >= hotCelsius { return .hot }
        if c >= warmCelsius { return .warm }
        return .normal
    }
}
