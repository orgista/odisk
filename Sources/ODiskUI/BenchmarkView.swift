import SwiftUI
import UniformTypeIdentifiers
import ODiskCore

enum BenchmarkUnit: String, CaseIterable, Identifiable {
    case throughput, iops, latency
    var id: String { rawValue }
    var title: String {
        switch self {
        case .throughput: "MB/s"
        case .iops: "IOPS"
        case .latency: "Latency"
        }
    }
}

struct BenchmarkView: View {
    var drive: Drive
    @Bindable var store: BenchmarkStore
    @AppStorage("benchmarkProfile") private var profileRaw = BenchmarkProfile.standard.rawValue
    @AppStorage("benchmarkUnit") private var unitRaw = BenchmarkUnit.throughput.rawValue
    @State private var volumePath: String?
    @State private var shownResult: BenchmarkResult?

    private var profile: BenchmarkProfile { BenchmarkProfile(rawValue: profileRaw) ?? .standard }
    private var unit: BenchmarkUnit { BenchmarkUnit(rawValue: unitRaw) ?? .throughput }
    private var writableVolumes: [Volume] { drive.volumes.filter { !$0.isReadOnly || $0.isStartupDisk } }
    private var volume: Volume? { writableVolumes.first { $0.mountPath == volumePath } ?? writableVolumes.first }
    private var runningHere: Bool { store.isRunning && store.runningDriveID == drive.id }
    private var busyElsewhere: Bool { store.isRunning && store.runningDriveID != drive.id }

    /// Rows to draw: live rows while running here, otherwise the picked or latest saved result.
    private var rows: [BenchmarkRow] {
        if runningHere { return store.liveRows }
        return (shownResult ?? latest)?.rows ?? BenchmarkTest.standard.map { BenchmarkRow(test: $0) }
    }

    private var latest: BenchmarkResult? { store.results(for: drive).first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DriveHeader(drive: drive)
                controls
                if case let .failed(message) = store.state, !store.isRunning {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("benchmarkError")
                }
                resultsGrid
                historyCard
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: store.state) { _, new in if new == .finished { shownResult = nil } }
    }

    private var controls: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                if writableVolumes.count > 1 {
                    Picker("Volume", selection: Binding(get: { volume?.mountPath ?? "" }, set: { volumePath = $0 })) {
                        ForEach(writableVolumes) { Text($0.name).tag($0.mountPath) }
                    }
                    .frame(maxWidth: 220)
                } else if let volume {
                    LabeledContent("Volume", value: volume.name)
                        .frame(maxWidth: 220, alignment: .leading)
                }
                Picker("Test", selection: $profileRaw) {
                    ForEach(BenchmarkProfile.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .disabled(store.isRunning)
                .accessibilityIdentifier("profilePicker")
                Spacer()
                if runningHere {
                    Button(role: .cancel) { store.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                        .controlSize(.large)
                        .accessibilityIdentifier("stopBenchmark")
                } else {
                    Button {
                        guard let volume else { return }
                        shownResult = nil
                        store.run(drive: drive, volume: volume, settings: settings)
                    } label: {
                        Label("Run Test", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(volume == nil || busyElsewhere)
                    .accessibilityIdentifier("runBenchmark")
                }
            }
            HStack {
                Text(statusLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("benchmarkStatus")
                Spacer()
                Picker("Show", selection: $unitRaw) {
                    ForEach(BenchmarkUnit.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            if case let .running(.preparing(fraction)) = store.state, runningHere {
                ProgressView(value: fraction).accessibilityIdentifier("prepareProgress")
            }
        }
    }

    private var settings: BenchmarkSettings {
        #if ODISK_DEBUG_HOOKS
        if UserDefaults.standard.bool(forKey: "ODiskTinyBenchmark") {
            return BenchmarkSettings(fileSizeBytes: 32 << 20, passes: 1, secondsPerPass: 0.3)
        }
        #endif
        return profile.settings
    }

    private var statusLine: String {
        if busyElsewhere { return "Another drive is being tested." }
        guard runningHere, case let .running(phase) = store.state else {
            if writableVolumes.isEmpty { return "This drive has no writable volume to test." }
            if let r = shownResult ?? latest { return "Last run \(r.date.formatted(date: .abbreviated, time: .shortened)) on \(r.volumeName)." }
            return "\(profile.summary). Reads and writes a temporary file, then deletes it."
        }
        switch phase {
        case let .preparing(f): return "Creating test file… \(Int(f * 100))%"
        case let .running(test, isWrite, pass, _):
            return "\(test.label) \(isWrite ? "write" : "read") · pass \(pass) of \(settings.passes)"
        case .cleaningUp: return "Cleaning up…"
        }
    }

    private var maxThroughput: Double {
        let all = rows.flatMap { [$0.read?.bytesPerSecond, $0.write?.bytesPerSecond] }.compactMap { $0 }
        return max(all.max() ?? 1, 1)
    }

    private var resultsGrid: some View {
        Card {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    Text("Read").font(.headline)
                    Text("Write").font(.headline)
                }
                ForEach(rows) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.test.label).font(.system(.body, design: .monospaced).weight(.semibold))
                            Text(caption(row.test)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 150, alignment: .leading)
                        cell(row.read, test: row.test, isWrite: false)
                        cell(row.write, test: row.test, isWrite: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("benchmarkGrid")
    }

    private func caption(_ t: BenchmarkTest) -> String {
        let kind = t.pattern == .sequential ? "Large files" : "Small random blocks"
        return t.queueDepth == 1 ? "\(kind), one at a time" : "\(kind), \(t.queueDepth) at once"
    }

    private func isActive(_ test: BenchmarkTest, isWrite: Bool) -> Bool {
        guard runningHere, case let .running(.running(t, w, _, _)) = store.state else { return false }
        return t == test && w == isWrite
    }

    private func cell(_ m: BenchmarkMeasurement?, test: BenchmarkTest, isWrite: Bool) -> some View {
        let active = isActive(test, isWrite: isWrite)
        let fraction = m.map { $0.bytesPerSecond / maxThroughput } ?? 0
        let tint: Color = isWrite ? .purple : .blue
        return VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Spacer(minLength: 0)
                Text(value(m))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(m == nil ? .tertiary : .primary)
                Text(unit == .latency ? "" : unit.title).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint.gradient).frame(width: geo.size.width * fraction)
                        .animation(.smooth, value: fraction)
                }
            }
            .frame(height: 6)
        }
        .padding(12)
        .frame(minWidth: 180, maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(active ? tint.opacity(0.12) : Color.clear)
            .stroke(active ? tint.opacity(0.5) : Color.secondary.opacity(0.15)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(test.label) \(isWrite ? "write" : "read")")
        .accessibilityValue(m == nil ? "not measured" : "\(value(m)) \(unit.title)")
        .accessibilityIdentifier("result.\(test.label).\(isWrite ? "write" : "read")")
    }

    private func value(_ m: BenchmarkMeasurement?) -> String {
        guard let m else { return "—" }
        switch unit {
        case .throughput: return Formatters.throughput(m.bytesPerSecond)
        case .iops: return Formatters.iops(m.iops)
        case .latency: return m.averageLatencyMicroseconds > 0 ? Formatters.latency(m.averageLatencyMicroseconds) : "…"
        }
    }

    private var historyCard: some View {
        let results = store.results(for: drive)
        return Card(title: "History") {
            if results.isEmpty {
                Text("Results are saved here so you can compare them over time, for example before and after a macOS update or when the drive gets full.")
                    .foregroundStyle(.secondary)
            }
            ForEach(results.prefix(20)) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.date.formatted(date: .abbreviated, time: .shortened))
                        Text("\(r.volumeName) · \(Formatters.bytes(Double(r.settings.fileSizeBytes))) · \(r.settings.passes)×")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let seq = r.rows.first {
                        Text("\(seq.read.map { Formatters.throughput($0.bytesPerSecond) } ?? "—") / \(seq.write.map { Formatters.throughput($0.bytesPerSecond) } ?? "—") MB/s")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button("Show") { shownResult = r }.buttonStyle(.borderless).disabled(store.isRunning)
                    ShareLink(item: r.shareText) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                        .help("Share these results as text")
                    Menu {
                        Button("Copy Results") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(r.shareText, forType: .string)
                        }
                        Button("Delete", role: .destructive) { store.deleteResult(r) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier("benchmarkHistory")
    }
}
