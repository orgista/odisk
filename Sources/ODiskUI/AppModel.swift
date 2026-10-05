import AppKit
import Foundation
import Observation
import ODiskCore

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

@MainActor @Observable
public final class AppModel {
    public private(set) var drives: [Drive] = []
    public private(set) var smart: [Drive.ID: SMARTState] = [:]
    public private(set) var temperatureHistory: [Drive.ID: [TemperatureSample]] = [:]
    public private(set) var lastRefresh: Date?
    public var selection: Drive.ID?
    public let benchmarks = BenchmarkStore()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private static let historyLimit = 120 // 1 hour at 30 s

    public init() {}

    public var selectedDrive: Drive? { drives.first { $0.id == selection } ?? drives.first }

    /// Worst status across drives, for the menu bar and Dock badge.
    public var overallStatus: HealthStatus {
        smart.values.compactMap { $0.snapshot?.assessment.status }.max() ?? .unknown
    }

    public func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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
    }

    public func refresh() {
        Task {
            let (found, states) = await Task.detached(priority: .userInitiated) { () -> ([Drive], [Drive.ID: SMARTState]) in
                let drives = DriveScanner.scan()
                var states: [Drive.ID: SMARTState] = [:]
                for d in drives {
                    guard d.smartCapable else { states[d.id] = .unsupported; continue }
                    switch DriveScanner.readSMART(registryEntryID: d.registryEntryID) {
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
        for (id, state) in states {
            guard let c = state.snapshot?.log.compositeTemperatureCelsius else { continue }
            var h = temperatureHistory[id, default: []]
            h.append(TemperatureSample(date: now, celsius: c))
            if h.count > Self.historyLimit { h.removeFirst(h.count - Self.historyLimit) }
            temperatureHistory[id] = h
        }
        if selection == nil || !found.contains(where: { $0.id == selection }) { selection = found.first?.id }
        lastRefresh = now
    }
}
