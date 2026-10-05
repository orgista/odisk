import Foundation

/// The NVMe SMART / Health Information log (page 02h), decoded per NVMe Base Spec 2.0 §5.16.1.3.
public struct NVMeHealthLog: Equatable, Sendable, Codable {
    public struct CriticalWarning: OptionSet, Equatable, Sendable, Codable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let spareBelowThreshold = CriticalWarning(rawValue: 1 << 0)
        public static let temperature = CriticalWarning(rawValue: 1 << 1)
        public static let reliabilityDegraded = CriticalWarning(rawValue: 1 << 2)
        public static let readOnly = CriticalWarning(rawValue: 1 << 3)
        public static let volatileBackupFailed = CriticalWarning(rawValue: 1 << 4)
        public static let persistentMemoryReadOnly = CriticalWarning(rawValue: 1 << 5)
    }

    public var criticalWarning: CriticalWarning
    /// Composite temperature in Kelvin (0 when the drive doesn't report it).
    public var compositeTemperatureKelvin: Int
    public var availableSparePercent: Int
    public var availableSpareThresholdPercent: Int
    /// Vendor estimate of life used. May exceed 100.
    public var percentageUsed: Int
    /// In units of 1000 × 512 bytes, as the spec defines.
    public var dataUnitsRead: Double
    public var dataUnitsWritten: Double
    public var hostReadCommands: Double
    public var hostWriteCommands: Double
    public var controllerBusyMinutes: Double
    public var powerCycles: Double
    public var powerOnHours: Double
    public var unsafeShutdowns: Double
    public var mediaErrors: Double
    public var errorLogEntries: Double
    public var warningTemperatureMinutes: Int
    public var criticalTemperatureMinutes: Int
    /// Extra sensors 1–8 in Kelvin, only the ones that report.
    public var sensorTemperaturesKelvin: [Int]

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 512 else { throw NVMeParseError.shortBuffer(bytes.count) }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[o + $1]) << (8 * $1) } }
        // 128-bit little-endian counters; Double keeps them exact up to 2^53, far beyond any real drive.
        func u128(_ o: Int) -> Double {
            (0..<16).reversed().reduce(0.0) { $0 * 256 + Double(bytes[o + $1]) }
        }
        criticalWarning = CriticalWarning(rawValue: bytes[0])
        compositeTemperatureKelvin = u16(1)
        availableSparePercent = Int(bytes[3])
        availableSpareThresholdPercent = Int(bytes[4])
        percentageUsed = Int(bytes[5])
        dataUnitsRead = u128(32)
        dataUnitsWritten = u128(48)
        hostReadCommands = u128(64)
        hostWriteCommands = u128(80)
        controllerBusyMinutes = u128(96)
        powerCycles = u128(112)
        powerOnHours = u128(128)
        unsafeShutdowns = u128(144)
        mediaErrors = u128(160)
        errorLogEntries = u128(176)
        warningTemperatureMinutes = u32(192)
        criticalTemperatureMinutes = u32(196)
        sensorTemperaturesKelvin = (0..<8).map { u16(200 + $0 * 2) }.filter { $0 > 0 }
    }

    public var compositeTemperatureCelsius: Int? {
        compositeTemperatureKelvin > 0 ? compositeTemperatureKelvin - 273 : nil
    }
    /// One data unit is 512,000 bytes.
    public var bytesRead: Double { dataUnitsRead * 512_000 }
    public var bytesWritten: Double { dataUnitsWritten * 512_000 }
}

/// The parts of NVMe Identify Controller (CNS 01h) that a person cares about.
public struct NVMeIdentify: Equatable, Sendable, Codable {
    public var serialNumber: String
    public var modelNumber: String
    public var firmwareRevision: String
    /// Warning / critical composite temperature thresholds in Kelvin (0 = not reported).
    public var warningTemperatureKelvin: Int
    public var criticalTemperatureKelvin: Int
    /// Total NVM capacity in bytes (0 = not reported).
    public var totalCapacityBytes: Double
    /// NVMe specification version the controller implements, e.g. "1.4" (nil before 1.2, where it was optional).
    public var nvmeVersion: String?
    /// Dataset Management (TRIM / deallocate) support.
    public var supportsTRIM: Bool
    public var supportsWriteZeroes: Bool
    /// Volatile write cache present.
    public var hasVolatileWriteCache: Bool
    /// Sanitize (crypto erase, block erase or overwrite) support.
    public var supportsSanitize: Bool
    /// Number of firmware slots.
    public var firmwareSlots: Int

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 512, bytes[24..<64].contains(where: { $0 != 0 }) else { return nil }
        func ascii(_ r: Range<Int>) -> String {
            String(decoding: bytes[r].filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        serialNumber = ascii(4..<24)
        modelNumber = ascii(24..<64)
        firmwareRevision = ascii(64..<72)
        warningTemperatureKelvin = u16(266)
        criticalTemperatureKelvin = u16(268)
        totalCapacityBytes = (0..<16).reversed().reduce(0.0) { $0 * 256 + Double(bytes[280 + $1]) }
        let major = u16(82), minor = Int(bytes[81])
        nvmeVersion = major > 0 ? "\(major).\(minor)" + (bytes[80] > 0 ? ".\(bytes[80])" : "") : nil
        let oncs = u16(520)
        supportsTRIM = oncs & (1 << 2) != 0
        supportsWriteZeroes = oncs & (1 << 3) != 0
        hasVolatileWriteCache = bytes[525] & 1 != 0
        supportsSanitize = (bytes[328] & 0b111) != 0
        firmwareSlots = Int((bytes[260] >> 1) & 0b111)
    }

    /// Feature list for the Details page, CrystalDiskInfo "Features" style.
    public var featureList: [String] {
        var f: [String] = []
        if supportsTRIM { f.append("TRIM") }
        if hasVolatileWriteCache { f.append("Volatile Write Cache") }
        if supportsWriteZeroes { f.append("Write Zeroes") }
        if supportsSanitize { f.append("Sanitize") }
        return f
    }
}

public enum NVMeParseError: Error, Equatable {
    case shortBuffer(Int)
}
