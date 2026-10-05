import AppKit
import CryptoKit
import Foundation
import Observation
import ODiskCore
import ServiceManagement
import UserNotifications

/// What the app knows about one drive's health right now.
public enum SMARTState: Equatable, Sendable {
    case loading
    case available(SMARTSnapshot)
    case unsupported
    case denied
    case failed(String)

    var snapshot: SMARTSnapshot? {
        if case let .available(s) = self { return s }
        return nil
    }
}

public struct TemperatureSample: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var celsius: Int
}

/// How often oDisk rereads health while it runs (window or menu bar).
public enum CheckInterval: Int, CaseIterable, Identifiable, Sendable {
    case halfMinute = 30, fiveMinutes = 300, fifteenMinutes = 900, hour = 3600
    public var id: Int { rawValue }
    var title: String {
        switch self {
        case .halfMinute: "Every 30 seconds"
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .hour: "Every hour"
        }
    }
}

@MainActor @Observable
public final class AppModel {
    public private(set) var drives: [Drive] = []
    public private(set) var smart: [Drive.ID: SMARTState] = [:]
    public private(set) var temperatureHistory: [Drive.ID: [TemperatureSample]] = [:]
    public private(set) var lastRefresh: Date?
    public var selection: Drive.ID?
    public let benchmarks = BenchmarkStore()
    public let history = HealthHistoryStore()

    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var alertMemory: [String: AlertPolicy.Memory] = [:]
    private static let liveHistoryLimit = 120

    public init() {
        if let data = UserDefaults.standard.data(forKey: "alertMemory"),
           let saved = try? JSONDecoder().decode([String: AlertPolicy.Memory].self, from: data) {
            alertMemory = saved
        }
    }

    public var selectedDrive: Drive? { drives.first { $0.id == selection } ?? drives.first }

    /// Worst status across drives, for the menu bar.
    public var overallStatus: HealthStatus {
        smart.values.compactMap { $0.snapshot?.assessment.status }.max() ?? .unknown
    }

    public func start() {
        if timer == nil {
            benchmarks.sweepLeftoverTestFiles()
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // Give IOKit a moment to settle after a mount before rescanning.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        self?.refresh()
                    }
                })
            }
            refresh()
        }
        reschedule()
    }

    /// Applies the check interval setting; called on start and when the setting changes.
    public func reschedule() {
        let interval = TimeInterval(UserDefaults.standard.object(forKey: "checkInterval") as? Int ?? CheckInterval.halfMinute.rawValue)
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func refresh() {
        Task {
            let (found, states) = await Task.detached(priority: .userInitiated) { () -> ([Drive], [Drive.ID: SMARTState]) in
                let drives = DriveScanner.scan()
                var states: [Drive.ID: SMARTState] = [:]
                for d in drives {
                    guard d.smartCapable else { states[d.id] = .unsupported; continue }
                    switch DriveScanner.readSMART(drive: d) {
                    case let .success(s): states[d.id] = .available(s)
                    case .failure(.notSupported): states[d.id] = .unsupported
                    case .failure(.accessDenied): states[d.id] = .denied
                    case let .failure(.failed(code)): states[d.id] = .failed(String(format: "IOKit error 0x%08x", UInt32(bitPattern: code)))
                    }
                }
                return (drives, states)
            }.value
            apply(drives: found, states: states)
        }
    }

    func apply(drives found: [Drive], states: [Drive.ID: SMARTState]) {
        drives = found
        smart = states
        let now = Date()
        for drive in found {
            guard let snapshot = states[drive.id]?.snapshot else { continue }
            if let c = snapshot.metrics.temperatureCelsius {
                var h = temperatureHistory[drive.id, default: []]
                h.append(TemperatureSample(date: now, celsius: c))
                if h.count > Self.liveHistoryLimit { h.removeFirst(h.count - Self.liveHistoryLimit) }
                temperatureHistory[drive.id] = h
            }
            history.record(snapshot, for: drive)
            notifyIfNeeded(drive: drive, snapshot: snapshot)
        }
        if selection == nil || !found.contains(where: { $0.id == selection }) { selection = found.first?.id }
        lastRefresh = now
    }

    // MARK: - Alerts

    private func notifyIfNeeded(drive: Drive, snapshot: SMARTSnapshot) {
        let defaults = UserDefaults.standard
        let settings = AlertPolicy.Settings(notifyHealth: defaults.object(forKey: "notifyHealth") as? Bool ?? true,
                                            notifyTemperature: defaults.object(forKey: "notifyTemperature") as? Bool ?? true)
        let key = HealthHistoryStore.key(for: drive)
        let (alerts, memory) = AlertPolicy.evaluate(driveName: drive.displayName, snapshot: snapshot,
                                                    memory: alertMemory[key] ?? .init(), settings: settings)
        alertMemory[key] = memory
        if let data = try? JSONEncoder().encode(alertMemory) { defaults.set(data, forKey: "alertMemory") }
        guard !alerts.isEmpty else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                content.sound = alert.kind == .health ? .defaultCritical : .default
                try? await center.add(UNNotificationRequest(identifier: "\(key)-\(alert.kind.rawValue)-\(Date().timeIntervalSince1970)",
                                                            content: content, trigger: nil))
            }
        }
    }

    // MARK: - Login item

    public static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message to show, or nil on success.
    public static func setOpensAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Long-term health history per drive, stored in the app's container (never leaves the Mac).
/// Files are keyed by a hash of the drive's identity so serial numbers aren't written in file names.
@MainActor @Observable
public final class HealthHistoryStore {
    /// Bumped on every recorded sample so views reading history redraw.
    public private(set) var revision = 0
    // Not observed: filled lazily from disk while views read it, which must not count as a mutation.
    @ObservationIgnored private var cache: [String: [HealthSample]] = [:]

    public init() {}

    nonisolated static func key(for drive: Drive) -> String {
        SHA256.hash(data: Data(drive.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public func samples(for drive: Drive) -> [HealthSample] {
        _ = revision
        return list(for: Self.key(for: drive))
    }

    private func list(for key: String) -> [HealthSample] {
        if let cached = cache[key] { return cached }
        let loaded = load(key)
        cache[key] = loaded
        return loaded
    }

    func record(_ snapshot: SMARTSnapshot, for drive: Drive) {
        let key = Self.key(for: drive)
        let current = list(for: key)
        let sample = HealthSample(snapshot)
        guard HealthHistoryPolicy.shouldRecord(sample, after: current.last) else { return }
        let updated = HealthHistoryPolicy.appending(sample, to: current)
        cache[key] = updated
        revision += 1
        save(updated, key)
    }

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("History")
    }

    private func load(_ key: String) -> [HealthSample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(key).json")) else { return [] }
        return (try? decoder.decode([HealthSample].self, from: data)) ?? []
    }

    private func save(_ list: [HealthSample], _ key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    }
}
