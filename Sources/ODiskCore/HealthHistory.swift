import Foundation

/// One point in a drive's long-term health history.
public struct HealthSample: Equatable, Sendable, Codable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var status: HealthStatus
    public var temperatureCelsius: Int?
    public var lifeUsedPercent: Int?
    public var bytesWritten: Double?
    public var bytesRead: Double?
    public var powerOnHours: Double?
    public var mediaErrors: Double?

    public init(date: Date, status: HealthStatus, temperatureCelsius: Int? = nil, lifeUsedPercent: Int? = nil,
                bytesWritten: Double? = nil, bytesRead: Double? = nil, powerOnHours: Double? = nil, mediaErrors: Double? = nil) {
        self.date = date; self.status = status; self.temperatureCelsius = temperatureCelsius
        self.lifeUsedPercent = lifeUsedPercent; self.bytesWritten = bytesWritten; self.bytesRead = bytesRead
        self.powerOnHours = powerOnHours; self.mediaErrors = mediaErrors
    }

    public init(_ snapshot: SMARTSnapshot) {
        let m = snapshot.metrics
        self.init(date: snapshot.date, status: snapshot.assessment.status, temperatureCelsius: m.temperatureCelsius,
                  lifeUsedPercent: m.lifeUsedPercent, bytesWritten: m.bytesWritten, bytesRead: m.bytesRead,
                  powerOnHours: m.powerOnHours, mediaErrors: m.mediaErrors)
    }
}

public enum HealthHistoryPolicy {
    /// Keep a point every 15 minutes, or immediately when something that matters changed.
    public static let minimumInterval: TimeInterval = 15 * 60
    /// About 40 days at full density; older points are thinned instead of dropped.
    public static let maximumSamples = 4000

    public static func shouldRecord(_ new: HealthSample, after last: HealthSample?) -> Bool {
        guard let last else { return true }
        if new.status != last.status || new.mediaErrors != last.mediaErrors || new.lifeUsedPercent != last.lifeUsedPercent {
            return true
        }
        return new.date.timeIntervalSince(last.date) >= minimumInterval
    }

    /// Appends and, past the cap, keeps every other point of the oldest half, so years of history fit
    /// while recent data stays at full resolution.
    public static func appending(_ sample: HealthSample, to samples: [HealthSample]) -> [HealthSample] {
        var all = samples
        all.append(sample)
        guard all.count > maximumSamples else { return all }
        let half = all.count / 2
        let thinned = all[..<half].enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        return thinned + all[half...]
    }
}

/// A notification oDisk should post.
public struct DriveAlert: Equatable, Sendable {
    public enum Kind: String, Sendable { case health, temperature, errors }
    public var kind: Kind
    public var title: String
    public var body: String
}

/// Decides when to notify. Pure, so the rules are tested without the notification center.
public enum AlertPolicy {
    public struct Settings: Equatable, Sendable {
        public var notifyHealth: Bool
        public var notifyTemperature: Bool
        public init(notifyHealth: Bool = true, notifyTemperature: Bool = true) {
            self.notifyHealth = notifyHealth; self.notifyTemperature = notifyTemperature
        }
    }

    /// What was last notified for a drive, so the same problem isn't repeated every refresh.
    public struct Memory: Equatable, Sendable, Codable {
        public var status: HealthStatus?
        public var mediaErrors: Double?
        public var lastTemperatureAlert: Date?
        public init(status: HealthStatus? = nil, mediaErrors: Double? = nil, lastTemperatureAlert: Date? = nil) {
            self.status = status; self.mediaErrors = mediaErrors; self.lastTemperatureAlert = lastTemperatureAlert
        }
    }

    public static let temperatureCooldown: TimeInterval = 60 * 60

    public static func evaluate(driveName: String, snapshot: SMARTSnapshot, memory: Memory, settings: Settings,
                                now: Date = Date()) -> (alerts: [DriveAlert], memory: Memory) {
        var alerts: [DriveAlert] = []
        var mem = memory
        let a = snapshot.assessment
        let m = snapshot.metrics

        if settings.notifyHealth {
            // Only when it gets worse than what was last seen; the first reading just sets the baseline
            // unless the drive is already in trouble.
            let previous = memory.status ?? .good
            if a.status > previous, a.status == .caution || a.status == .bad {
                let reason = a.findings.first(where: { $0.status == a.status })?.message ?? ""
                alerts.append(DriveAlert(kind: .health,
                                         title: a.status == .bad ? "Back up \(driveName) now" : "\(driveName) needs attention",
                                         body: reason))
            }
            if let errors = m.mediaErrors, let before = memory.mediaErrors, errors > before {
                alerts.append(DriveAlert(kind: .errors, title: "New data errors on \(driveName)",
                                         body: "The drive recorded \(Int(errors - before)) new unrecovered error\(errors - before == 1 ? "" : "s"). Keep your backups current."))
            }
        }
        mem.status = a.status
        mem.mediaErrors = m.mediaErrors

        if settings.notifyTemperature, a.temperature == .hot, let c = m.temperatureCelsius {
            if memory.lastTemperatureAlert.map({ now.timeIntervalSince($0) >= temperatureCooldown }) ?? true {
                alerts.append(DriveAlert(kind: .temperature, title: "\(driveName) is too hot",
                                         body: "It's at \(c) °C, above the drive's rated limit. It may slow itself down until it cools."))
                mem.lastTemperatureAlert = now
            }
        }
        return (alerts, mem)
    }
}
