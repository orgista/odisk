import Foundation

public enum HealthStatus: String, Sendable, Codable, Comparable {
    case good, caution, bad, unknown

    private var rank: Int {
        switch self {
        case .good: 0
        case .unknown: 1
        case .caution: 2
        case .bad: 3
        }
    }
    public static func < (a: HealthStatus, b: HealthStatus) -> Bool { a.rank < b.rank }

    public var title: String {
        switch self {
        case .good: "Good"
        case .caution: "Caution"
        case .bad: "Bad"
        case .unknown: "Unknown"
        }
    }
}

public enum TemperatureStatus: String, Sendable, Codable {
    case normal, warm, hot, unknown
}

/// One plain-language reason behind a health verdict.
public struct HealthFinding: Equatable, Sendable, Codable, Identifiable {
    public var id: String { message }
    public var status: HealthStatus
    public var message: String
}

public struct HealthAssessment: Equatable, Sendable, Codable {
    public var status: HealthStatus
    /// 0…100 remaining life estimate, nil when the drive doesn't report wear.
    public var lifeRemainingPercent: Int?
    public var findings: [HealthFinding]
    public var temperature: TemperatureStatus
}

/// Turns raw NVMe counters into a verdict. Pure, so it is unit tested without hardware.
/// Thresholds follow CrystalDiskInfo's NVMe behaviour (MIT) with plain-language reasons added.
public enum HealthPolicy {
    public static let defaultWarningCelsius = 70
    public static let defaultCriticalCelsius = 80

    public static func assess(_ log: NVMeHealthLog, identify: NVMeIdentify? = nil) -> HealthAssessment {
        var findings: [HealthFinding] = []
        let w = log.criticalWarning
        func add(_ s: HealthStatus, _ m: String) { findings.append(HealthFinding(status: s, message: m)) }

        if w.contains(.readOnly) { add(.bad, "The drive has switched itself to read-only to protect your data. Back up now.") }
        if w.contains(.reliabilityDegraded) { add(.bad, "The drive reports that its reliability is degraded by media or internal errors. Back up now.") }
        if w.contains(.persistentMemoryReadOnly) { add(.bad, "Persistent memory has become read-only.") }
        if log.availableSpareThresholdPercent > 0, log.availableSparePercent < log.availableSpareThresholdPercent {
            add(.bad, "Spare blocks (\(log.availableSparePercent)%) are below the drive's safety limit (\(log.availableSpareThresholdPercent)%).")
        } else if w.contains(.spareBelowThreshold) {
            add(.bad, "The drive reports that its spare blocks are running out.")
        }
        if log.percentageUsed >= 100 {
            add(.caution, "The drive has used its rated write endurance (\(log.percentageUsed)%). It may keep working, but keep backups current.")
        } else if log.percentageUsed >= 90 {
            add(.caution, "\(log.percentageUsed)% of rated write endurance is used.")
        }
        if w.contains(.volatileBackupFailed) { add(.caution, "The drive's power-loss backup has failed.") }
        if log.mediaErrors > 0 {
            add(.caution, "\(Int(log.mediaErrors)) unrecovered data error\(log.mediaErrors == 1 ? "" : "s") recorded.")
        }
        let temp = temperatureStatus(log, identify: identify)
        if w.contains(.temperature) || temp == .hot {
            add(.caution, "The drive is running hotter than its rated limit.")
        }

        let status = findings.map(\.status).max() ?? .good
        let life = log.percentageUsed <= 100 ? 100 - log.percentageUsed : 0
        return HealthAssessment(status: status, lifeRemainingPercent: life, findings: findings, temperature: temp)
    }

    public static func temperatureStatus(_ log: NVMeHealthLog, identify: NVMeIdentify?) -> TemperatureStatus {
        guard let c = log.compositeTemperatureCelsius else { return .unknown }
        let warn = identify.flatMap { $0.warningTemperatureKelvin > 273 ? $0.warningTemperatureKelvin - 273 : nil } ?? defaultWarningCelsius
        let crit = identify.flatMap { $0.criticalTemperatureKelvin > 273 ? $0.criticalTemperatureKelvin - 273 : nil } ?? defaultCriticalCelsius
        if c >= crit { return .hot }
        if c >= warn { return .warm }
        return .normal
    }
}
