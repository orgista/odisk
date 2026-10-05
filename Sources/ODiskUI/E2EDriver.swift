#if ODISK_DEBUG_HOOKS
import AppKit
import Foundation
import ODiskCore

/// Debug-only self-driving end-to-end run (`-ODiskE2E YES`). Used where XCUITest can't get automation mode.
/// Walks Health → Speed Test → Details in the real sandboxed app, writes JSON reports and `<step>.ready`
/// markers to `<container>/tmp/e2e/` so a shell script can screenshot each step, then quits.
@MainActor
enum E2EDriver {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "ODiskE2E") }

    static func run(model: AppModel, setTab: @escaping (DetailTab) -> Void) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("e2e")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report: [String: Any] = ["started": Date().formatted(.iso8601)]
        func write() {
            if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: dir.appendingPathComponent("report.json"))
            }
        }
        func mark(_ step: String) async {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("\(step).ready").path, contents: nil)
            try? await Task.sleep(for: .seconds(3))
        }

        // 1. Health
        for _ in 0..<80 where model.drives.isEmpty || model.drives.contains(where: { model.smart[$0.id] == nil }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        report["drives"] = model.drives.map { d -> [String: Any] in
            var r: [String: Any] = ["name": d.displayName, "model": d.model, "connection": d.connectionDescription,
                                    "capacity": Formatters.bytes(d.capacityBytes), "volumes": d.volumes.map(\.name)]
            switch model.smart[d.id] ?? .loading {
            case let .available(s):
                r["health"] = s.assessment.status.title
                r["lifeRemaining"] = s.assessment.lifeRemainingPercent ?? -1
                r["temperatureC"] = s.metrics.temperatureCelsius ?? -1
                r["written"] = Formatters.bytes(s.metrics.bytesWritten ?? 0)
                r["powerOnHours"] = s.metrics.powerOnHours ?? -1
            case .unsupported: r["health"] = "unsupported"
            case .denied: r["health"] = "DENIED"
            case let .failed(m): r["health"] = "failed: \(m)"
            case .loading: r["health"] = "loading"
            }
            return r
        }
        if UserDefaults.standard.bool(forKey: "ODiskStoreScreenshots"), let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            // 1440×900 pt = 2880×1800 px, an accepted Mac App Store screenshot size.
            w.setFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        }
        setTab(.health)
        write()
        await mark("1-health")
        if model.drives.count > 1 {
            model.selection = model.drives[1].id
            await mark("1b-health-external")
        }
        // Select the startup drive (List selection can lag a run-loop turn, so set it until it sticks).
        for _ in 0..<10 where model.selection != model.drives.first?.id {
            model.selection = model.drives.first?.id
            try? await Task.sleep(for: .milliseconds(300))
        }

        // 2. Speed test on the startup volume
        if let drive = model.drives.first, let volume = drive.volumes.first(where: \.isStartupDisk) ?? drive.volumes.first {
            setTab(.benchmark)
            try? await Task.sleep(for: .seconds(1))
            model.benchmarks.run(drive: drive, volume: volume,
                                 settings: BenchmarkSettings(fileSizeBytes: 256 << 20, passes: 1, secondsPerPass: 1, mixReadPercent: 70))
            for _ in 0..<600 where model.benchmarks.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
            switch model.benchmarks.state {
            case .finished:
                let latest = model.benchmarks.results(for: drive).first
                report["benchmark"] = latest?.rows.map { row -> [String: Any] in
                    ["test": row.test.label,
                     "readMBps": (row.read?.bytesPerSecond ?? 0) / 1e6,
                     "writeMBps": (row.write?.bytesPerSecond ?? 0) / 1e6,
                     "mixMBps": (row.mix?.bytesPerSecond ?? 0) / 1e6]
                } ?? []
                report["shareText"] = latest?.shareText ?? ""
            case let .failed(m): report["benchmark"] = "failed: \(m)"
            default: report["benchmark"] = "unexpected state"
            }
            report["historySamples"] = model.history.samples(for: drive).count
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix(".oDisk-benchmark") } ?? []
            report["leftoverTestFiles"] = leftovers.count
            write()
            await mark("2-benchmark")
        }

        // 3. Details
        setTab(.details)
        report["finished"] = Date().formatted(.iso8601)
        write()
        await mark("3-details")
        NSApp.terminate(nil)
    }
}
#endif
