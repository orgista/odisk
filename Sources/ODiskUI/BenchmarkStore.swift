import AppKit
import Foundation
import Observation
import ODiskCore

/// Runs benchmarks and keeps their history (JSON in Application Support, inside the sandbox container).
@MainActor @Observable
public final class BenchmarkStore {
    public enum State: Equatable {
        case idle
        case running(BenchmarkPhase)
        case finished
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var liveRows: [BenchmarkRow] = []
    public private(set) var history: [BenchmarkResult] = []
    public private(set) var runningDriveID: Drive.ID?
    private var cancellation: BenchmarkCancellation?

    public init() { history = load() }

    public var isRunning: Bool { if case .running = state { true } else { false } }

    public func results(for drive: Drive) -> [BenchmarkResult] {
        history.filter { $0.driveModel == drive.model }.sorted { $0.date > $1.date }
    }

    public func cancel() { cancellation?.cancel() }

    public func deleteResult(_ result: BenchmarkResult) {
        history.removeAll { $0.id == result.id }
        save()
    }

    /// Runs against `volume`. The startup volume uses the app's own container; other volumes need a
    /// folder the person picked (security-scoped), which is remembered per volume.
    public func run(drive: Drive, volume: Volume, settings: BenchmarkSettings) {
        guard !isRunning else { return }
        guard let folder = folderForBenchmark(on: volume) else { return }
        let cancel = BenchmarkCancellation()
        cancellation = cancel
        runningDriveID = drive.id
        liveRows = settings.tests.map { BenchmarkRow(test: $0) }
        state = .running(.preparing(fraction: 0))

        Task {
            let outcome: Result<[BenchmarkRow], Error> = await Task.detached(priority: .userInitiated) {
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                return Result {
                    try BenchmarkEngine(settings: settings).run(in: folder, cancellation: cancel) { phase in
                        Task { @MainActor in self.update(phase) }
                    }
                }
            }.value
            switch outcome {
            case let .success(rows):
                let result = BenchmarkResult(date: Date(), driveName: drive.displayName, driveModel: drive.model,
                                             volumeName: volume.name, settings: settings, rows: rows)
                liveRows = rows
                history.append(result)
                save()
                state = .finished
            case let .failure(error as BenchmarkError) where error == .cancelled:
                state = .idle
                liveRows = []
            case let .failure(error):
                state = .failed(error.localizedDescription)
            }
            runningDriveID = nil
            cancellation = nil
        }
    }

    private func update(_ phase: BenchmarkPhase) {
        guard isRunning else { return }
        if case let .running(test, kind, _, live) = phase, let i = liveRows.firstIndex(where: { $0.test == test }) {
            // Show the live figure in the running cell; the best pass replaces it when the run ends.
            liveRows[i][kind] = BenchmarkMeasurement(bytesPerSecond: live, iops: live / Double(test.blockSize), averageLatencyMicroseconds: 0)
        }
        state = .running(phase)
    }

    // MARK: - Folder access

    private static let bookmarksKey = "benchmarkFolderBookmarksByVolume"

    /// A stable key for a volume: its UUID when available, else its mount path.
    static func volumeKey(_ volume: Volume) -> String {
        let url = URL(fileURLWithPath: volume.mountPath)
        return (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? volume.mountPath
    }

    /// True when `url` lives on the same volume as `volume`.
    static func isOnVolume(_ url: URL, _ volume: Volume) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeURLKey]
        let a = try? url.resourceValues(forKeys: keys)
        let b = try? URL(fileURLWithPath: volume.mountPath).resourceValues(forKeys: keys)
        if let ua = a?.volumeUUIDString, let ub = b?.volumeUUIDString { return ua == ub }
        return a?.volume?.standardizedFileURL == b?.volume?.standardizedFileURL
    }

    func folderForBenchmark(on volume: Volume) -> URL? {
        #if ODISK_DEBUG_HOOKS
        if let path = UserDefaults.standard.string(forKey: "ODiskBenchmarkFolder") { return URL(fileURLWithPath: path) }
        #endif
        if volume.isStartupDisk {
            return FileManager.default.temporaryDirectory // inside the container, on the startup volume
        }
        let key = Self.volumeKey(volume)
        var bookmarks = UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
        if let data = bookmarks[key] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path), Self.isOnVolume(url, volume) {
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    bookmarks[key] = fresh
                    UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
                }
                return url
            }
        }
        while true {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: volume.mountPath)
            panel.message = "Choose a folder on “\(volume.name)” for oDisk’s temporary test file. It is deleted when the test ends."
            panel.prompt = "Use This Folder"
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            guard Self.isOnVolume(url, volume) else {
                let alert = NSAlert()
                alert.messageText = "That folder isn’t on “\(volume.name)”"
                alert.informativeText = "Choose a folder on the drive you want to test."
                alert.runModal()
                continue
            }
            if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[key] = data
                UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
            }
            return url
        }
    }

    /// Removes test files left by older versions of oDisk (current ones unlink the file as soon as it's open).
    func sweepLeftoverTestFiles() {
        BenchmarkEngine.sweepLeftovers(in: FileManager.default.temporaryDirectory)
        let bookmarks = UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
        for data in bookmarks.values {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            BenchmarkEngine.sweepLeftovers(in: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    // MARK: - Persistence

    private var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if ODISK_DEBUG_HOOKS
        if UserDefaults.standard.bool(forKey: "ODiskResetOnLaunch") { return dir.appendingPathComponent("Benchmarks-e2e.json") }
        #endif
        return dir.appendingPathComponent("Benchmarks.json")
    }

    private func load() -> [BenchmarkResult] {
        #if ODISK_DEBUG_HOOKS
        if UserDefaults.standard.bool(forKey: "ODiskResetOnLaunch") { return [] }
        #endif
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BenchmarkResult].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
    }
}
