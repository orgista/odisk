import SwiftUI
import UniformTypeIdentifiers
import ODiskCore

enum BenchmarkUnit: String, CaseIterable, Identifiable {
    case megabytes, gigabytes, iops, latency
    var id: String { rawValue }
    var title: String {
        switch self {
        case .megabytes: "MB/s"
        case .gigabytes: "GB/s"
        case .iops: "IOPS"
        case .latency: "μs"
        }
    }

    func format(_ m: BenchmarkMeasurement?) -> String {
        guard let m else { return "-" }
        switch self {
        case .megabytes: return Formatters.throughput(m.bytesPerSecond)
        case .gigabytes: return String(format: "%.3f", m.bytesPerSecond / 1e9)
        case .iops: return Formatters.iops(m.iops)
        case .latency: return m.averageLatencyMicroseconds > 0 ? String(format: "%.0f", m.averageLatencyMicroseconds) : "…"
        }
    }
}

/// The speed test options, persisted between runs.
struct BenchmarkOptions: DynamicProperty {
    @AppStorage("bench.testSet") var testSetRaw = BenchmarkTestSet.standard.rawValue
    @AppStorage("bench.fileSize") var fileSize = 1 << 30
    @AppStorage("bench.passes") var passes = 3
    @AppStorage("bench.seconds") var seconds = 3.0
    @AppStorage("bench.interval") var interval = 0.0
    @AppStorage("bench.zeros") var zeros = false
    @AppStorage("bench.mix") var mix = false
    @AppStorage("bench.mixRead") var mixRead = 70

    var testSet: BenchmarkTestSet { BenchmarkTestSet(rawValue: testSetRaw) ?? .standard }

    var settings: BenchmarkSettings {
        BenchmarkSettings(fileSizeBytes: fileSize, passes: passes, secondsPerPass: seconds, intervalSeconds: interval,
                          tests: testSet.tests, includeWrites: true, mixReadPercent: mix ? mixRead : nil,
                          dataPattern: zeros ? .zeros : .random)
    }

    var estimatedMinutes: Int {
        let s = settings
        let kinds = 2 + (s.mixReadPercent == nil ? 0 : 1)
        let measured = Double(s.tests.count * kinds * s.passes) * s.secondsPerPass
        let pauses = Double(s.tests.count * kinds - 1) * s.intervalSeconds
        let fill = Double(s.fileSizeBytes) / 1_000_000_000 * 2 // rough: 2 s per GB to write the file
        return max(1, Int(((measured + pauses + fill) / 60).rounded(.up)))
    }
}

struct BenchmarkView: View {
    var drive: Drive
    @Bindable var store: BenchmarkStore
    @AppStorage("benchmarkUnit") private var unitRaw = BenchmarkUnit.megabytes.rawValue
    @AppStorage("bench.testSet") private var testSetRaw = BenchmarkTestSet.standard.rawValue
    private var options = BenchmarkOptions()
    @State private var volumePath: String?
    @State private var shownResult: BenchmarkResult?
    @State private var showingOptions = false

    init(drive: Drive, store: BenchmarkStore) {
        self.drive = drive
        self.store = store
    }

    private var unit: BenchmarkUnit { BenchmarkUnit(rawValue: unitRaw) ?? .megabytes }
    private var writableVolumes: [Volume] { drive.volumes.filter { !$0.isReadOnly || $0.isStartupDisk } }
    private var volume: Volume? { writableVolumes.first { $0.mountPath == volumePath } ?? writableVolumes.first }
    private var runningHere: Bool { store.isRunning && store.runningDriveID == drive.id }
    private var busyElsewhere: Bool { store.isRunning && store.runningDriveID != drive.id }
    private var latest: BenchmarkResult? { store.results(for: drive).first }
    private var displayed: BenchmarkResult? { shownResult ?? latest }

    /// Rows to draw: live rows while running here, otherwise the picked or latest saved result.
    private var rows: [BenchmarkRow] {
        if runningHere { return store.liveRows }
        return displayed?.rows ?? options.testSet.tests.map { BenchmarkRow(test: $0) }
    }

    private var mixPercent: Int? {
        if runningHere { return options.mix ? options.mixRead : nil }
        if let displayed { return displayed.settings.mixReadPercent }
        return options.mix ? options.mixRead : nil
    }

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
                ResultsGrid(rows: rows, unit: unit, mixReadPercent: mixPercent, active: activeCell)
                    .padding(16)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("benchmarkGrid")
                historyCard
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: store.state) { _, new in if new == .finished { shownResult = nil } }
    }

    private var activeCell: (BenchmarkTest, BenchmarkKind)? {
        guard runningHere, case let .running(.running(t, k, _, _)) = store.state else { return nil }
        return (t, k)
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
                Picker("Tests", selection: $testSetRaw) {
                    ForEach(BenchmarkTestSet.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                .disabled(store.isRunning)
                .accessibilityLabel("Test set")
                .accessibilityIdentifier("testSetPicker")
                Button { showingOptions.toggle() } label: { Label("Options", systemImage: "slider.horizontal.3") }
                    .disabled(store.isRunning)
                    .popover(isPresented: $showingOptions, arrowEdge: .bottom) { OptionsForm() }
                    .accessibilityIdentifier("benchmarkOptions")
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
                .frame(width: 260)
                .accessibilityLabel("Units")
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
        return options.settings
    }

    private var statusLine: String {
        if busyElsewhere { return "Another drive is being tested." }
        guard runningHere, case let .running(phase) = store.state else {
            if writableVolumes.isEmpty { return "This drive has no writable volume to test." }
            if let r = displayed {
                return "Run \(r.date.formatted(date: .abbreviated, time: .shortened)) on \(r.volumeName), \(Formatters.bytes(Double(r.settings.fileSizeBytes))) × \(r.settings.passes)."
            }
            return "\(Formatters.bytes(Double(options.fileSize))) × \(options.passes), about \(options.estimatedMinutes) min. Uses a temporary file that's removed afterwards."
        }
        switch phase {
        case let .preparing(f): return "Creating test file… \(Int(f * 100))%"
        case let .running(test, kind, pass, _): return "\(test.label) \(kind.rawValue) · pass \(pass) of \(settings.passes)"
        case let .waiting(seconds): return "Pausing \(Int(seconds)) s between tests…"
        case .cleaningUp: return "Cleaning up…"
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
                        Text("\(seq.read.map { Formatters.throughput($0.bytesPerSecond) } ?? "-") / \(seq.write.map { Formatters.throughput($0.bytesPerSecond) } ?? "-") MB/s")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button("Show") { shownResult = r }.buttonStyle(.borderless).disabled(store.isRunning)
                    ShareLink(item: r.shareText) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                        .help("Share these results as text")
                        .accessibilityLabel("Share results")
                    Menu {
                        Button("Copy Results as Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(r.shareText, forType: .string)
                        }
                        Button("Copy Results as Image") { ResultImage.copy(r, unit: unit) }
                        Button("Save Results as Image…") { ResultImage.save(r, unit: unit) }
                        Divider()
                        Button("Delete", role: .destructive) { store.deleteResult(r) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More actions")
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier("benchmarkHistory")
    }
}

/// Read / write (/ mix) grid, shared by the live view and the exported image.
struct ResultsGrid: View {
    var rows: [BenchmarkRow]
    var unit: BenchmarkUnit
    var mixReadPercent: Int?
    var active: (BenchmarkTest, BenchmarkKind)?

    private var kinds: [BenchmarkKind] { mixReadPercent == nil ? [.read, .write] : [.read, .write, .mix] }

    private var maxThroughput: Double {
        let all = rows.flatMap { row in kinds.compactMap { row[$0]?.bytesPerSecond } }
        return max(all.max() ?? 1, 1)
    }

    private func title(_ k: BenchmarkKind) -> String {
        if k == .mix, let p = mixReadPercent { return "Mix \(p)/\(100 - p)" }
        return k.rawValue.capitalized
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("")
                ForEach(kinds, id: \.self) { k in Text(title(k)).font(.headline) }
            }
            ForEach(rows) { row in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.test.label).font(.system(.body, design: .monospaced).weight(.semibold))
                        Text(caption(row.test)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 150, alignment: .leading)
                    ForEach(kinds, id: \.self) { k in cell(row[k], test: row.test, kind: k) }
                }
            }
        }
    }

    private func caption(_ t: BenchmarkTest) -> String {
        let kind = t.pattern == .sequential ? "Large files" : "Small random blocks"
        return t.inFlight == 1 ? "\(kind), one at a time" : "\(kind), \(t.inFlight) at once"
    }

    private func cell(_ m: BenchmarkMeasurement?, test: BenchmarkTest, kind: BenchmarkKind) -> some View {
        let isActive = active.map { $0.0 == test && $0.1 == kind } ?? false
        let fraction = m.map { $0.bytesPerSecond / maxThroughput } ?? 0
        let tint: Color = switch kind {
        case .read: .blue
        case .write: .purple
        case .mix: .teal
        }
        return VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Spacer(minLength: 0)
                Text(unit.format(m))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(m == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit.title).font(.caption).foregroundStyle(.secondary)
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
        .frame(minWidth: 150, maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isActive ? tint.opacity(0.12) : Color.clear)
            .stroke(isActive ? tint.opacity(0.5) : Color.secondary.opacity(0.15)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(test.label) \(kind.rawValue)")
        .accessibilityValue(m == nil ? "not measured" : "\(unit.format(m)) \(unit.title)")
        .accessibilityIdentifier("result.\(test.label).\(kind.rawValue)")
    }
}

struct OptionsForm: View {
    private var options = BenchmarkOptions()
    @AppStorage("bench.fileSize") private var fileSize = 1 << 30
    @AppStorage("bench.passes") private var passes = 3
    @AppStorage("bench.seconds") private var seconds = 3.0
    @AppStorage("bench.interval") private var interval = 0.0
    @AppStorage("bench.zeros") private var zeros = false
    @AppStorage("bench.mix") private var mix = false
    @AppStorage("bench.mixRead") private var mixRead = 70

    var body: some View {
        Form {
            Picker("Test file size", selection: $fileSize) {
                ForEach(BenchmarkSettings.fileSizeChoices, id: \.self) { Text(Formatters.bytes(Double($0))).tag($0) }
            }
            Stepper("Passes: \(passes)", value: $passes, in: 1...9)
                .help("Each test runs this many times and the best result is kept.")
            Picker("Measure each pass for", selection: $seconds) {
                ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            Picker("Pause between tests", selection: $interval) {
                ForEach([0.0, 1, 3, 5, 10, 30], id: \.self) { Text($0 == 0 ? "None" : "\(Int($0)) s").tag($0) }
            }
            Picker("Test data", selection: $zeros) {
                Text("Random (realistic)").tag(false)
                Text("Zeros (0Fill)").tag(true)
            }
            Toggle("Add a mixed read/write test", isOn: $mix)
            if mix {
                Picker("Read share", selection: $mixRead) {
                    ForEach([50, 60, 70, 80, 90], id: \.self) { Text("\($0)% read / \(100 - $0)% write").tag($0) }
                }
            }
            Text("About \(options.estimatedMinutes) min with these settings.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding(.vertical, 4)
    }
}

/// Renders a result as a PNG card for sharing (forums, Reddit), like CrystalDiskMark's screenshot export.
@MainActor
enum ResultImage {
    static func render(_ r: BenchmarkResult, unit: BenchmarkUnit) -> NSImage? {
        let card = VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.driveModel).font(.title2.weight(.semibold))
                    Text("\(r.volumeName) · \(Formatters.bytes(Double(r.settings.fileSizeBytes))) × \(r.settings.passes) · \(r.settings.dataPattern == .random ? "random data" : "0Fill") · \(r.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("oDisk").font(.headline).foregroundStyle(.secondary)
            }
            ResultsGrid(rows: r.rows, unit: unit, mixReadPercent: r.settings.mixReadPercent, active: nil)
        }
        .padding(24)
        .frame(width: r.settings.mixReadPercent == nil ? 640 : 840)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        return renderer.nsImage
    }

    static func copy(_ r: BenchmarkResult, unit: BenchmarkUnit) {
        guard let image = render(r, unit: unit) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func save(_ r: BenchmarkResult, unit: BenchmarkUnit) {
        guard let image = render(r, unit: unit),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "oDisk \(r.driveModel) \(r.date.formatted(.iso8601.year().month().day())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}
