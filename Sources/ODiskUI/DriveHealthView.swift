import Charts
import SwiftUI
import ODiskCore

struct DriveHealthView: View {
    var drive: Drive
    var state: SMARTState
    var history: [TemperatureSample]
    var longHistory: [HealthSample]
    @AppStorage("temperatureUnit") private var unitRaw = TemperatureUnit.current.rawValue
    private var unit: TemperatureUnit { TemperatureUnit(rawValue: unitRaw) ?? .celsius }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DriveHeader(drive: drive)
                switch state {
                case .loading:
                    Card { ProgressView("Reading drive health…").frame(maxWidth: .infinity) }
                case let .available(snapshot):
                    hero(snapshot)
                    metrics(snapshot)
                    if longHistory.count > 1 { HealthHistoryCard(samples: longHistory, unit: unit) }
                case .unsupported:
                    noHealthCard(
                        title: "This drive doesn’t share health data",
                        message: "Its connection doesn’t pass S.M.A.R.T. through to macOS. That is common for some USB enclosures and for SD cards. You can still run a speed test.")
                case .denied:
                    noHealthCard(
                        title: "macOS didn’t allow reading health data",
                        message: "oDisk couldn’t open this drive’s health interface. Try reconnecting the drive, or restart your Mac.")
                case let .failed(message):
                    noHealthCard(title: "Couldn’t read health data", message: message)
                }
                VolumesCard(volumes: drive.volumes)
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
    }

    private func hero(_ s: SMARTSnapshot) -> some View {
        let a = s.assessment
        return Card {
            HStack(alignment: .center, spacing: 28) {
                HealthRing(fraction: a.lifeRemainingPercent.map { Double($0) / 100 }, status: a.status)
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline(a)).font(.title3.weight(.semibold))
                    if a.findings.isEmpty {
                        Label("No warnings. The drive’s own checks, error counts and temperature are all within its limits.", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(a.findings) { f in
                            Label(f.message, systemImage: f.status.symbol)
                                .foregroundStyle(f.status == .bad ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                    if let estimate = lifeEstimate(s.metrics) {
                        Text(estimate).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("healthHero")
    }

    private func headline(_ a: HealthAssessment) -> String {
        switch a.status {
        case .good: "This drive is healthy"
        case .caution: "Keep an eye on this drive"
        case .bad: "Back up this drive now"
        case .unknown: "Health unknown"
        }
    }

    /// "At the current pace … about 9 more years." Only when wear is measurable.
    private func lifeEstimate(_ m: HealthMetrics) -> String? {
        guard let usedInt = m.lifeUsedPercent, let poh = m.powerOnHours else { return nil }
        let used = Double(usedInt)
        guard used >= 1, used < 100, poh > 24 * 30 else { return nil }
        let years = poh / used * (100 - used) / 24 / 365.25
        guard years >= 0.5 else { return nil }
        return "At the current pace of use, the rated endurance lasts about \(years >= 20 ? "20+" : Formatters.trim(years, digits: 0)) more years of powered-on time."
    }

    @ViewBuilder
    private func metrics(_ s: SMARTSnapshot) -> some View {
        let m = s.metrics
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            temperatureTile(m, status: s.assessment.temperature)
            if let used = m.lifeUsedPercent {
                MetricTile(title: "Life used", value: "\(used)%", detail: "Rated write endurance", symbol: "gauge.with.dots.needle.33percent",
                           tint: used >= 90 ? .orange : .accentColor, help: MetricHelp.lifeUsed)
            }
            if let w = m.bytesWritten {
                MetricTile(title: "Data written", value: Formatters.bytes(w), detail: "Total host writes", symbol: "square.and.arrow.down", help: MetricHelp.written)
            }
            if let r = m.bytesRead {
                MetricTile(title: "Data read", value: Formatters.bytes(r), detail: "Total host reads", symbol: "square.and.arrow.up", help: MetricHelp.read)
            }
            if let poh = m.powerOnHours {
                MetricTile(title: "Powered on", value: Formatters.powerOnTime(hours: poh), detail: "\(Formatters.count(poh)) power on hours",
                           symbol: "clock", help: MetricHelp.powerOn)
            }
            if let pc = m.powerCycles {
                MetricTile(title: "Power cycles", value: Formatters.count(pc), detail: "Power on count", symbol: "power", help: MetricHelp.powerCycles)
            }
            if let spare = m.availableSparePercent {
                let threshold = m.availableSpareThresholdPercent ?? 0
                MetricTile(title: "Spare blocks", value: "\(spare)%", detail: "Replace below \(threshold)%",
                           symbol: "square.stack.3d.up", tint: spare < threshold ? .red : .accentColor, help: MetricHelp.spare)
            }
            if let realloc = m.reallocatedSectors {
                MetricTile(title: "Reallocated sectors", value: Formatters.count(realloc), detail: realloc == 0 ? "None" : "Worn areas replaced",
                           symbol: "arrow.triangle.swap", tint: realloc > 0 ? .orange : .green, help: MetricHelp.reallocated)
            }
            if let pending = m.pendingSectors {
                MetricTile(title: "Pending sectors", value: Formatters.count(pending), detail: pending == 0 ? "None" : "Waiting to be remapped",
                           symbol: "hourglass", tint: pending > 0 ? .orange : .green, help: MetricHelp.pending)
            }
            if let unsafe = m.unsafeShutdowns {
                MetricTile(title: "Unsafe shutdowns", value: Formatters.count(unsafe), symbol: "bolt.slash", help: MetricHelp.unsafeShutdowns)
            }
            if let errors = m.mediaErrors {
                MetricTile(title: "Media errors", value: Formatters.count(errors), detail: errors == 0 ? "None recorded" : "Keep backups current",
                           symbol: "exclamationmark.shield", tint: errors > 0 ? .orange : .green, help: MetricHelp.mediaErrors)
            }
        }
    }

    private func temperatureTile(_ m: HealthMetrics, status: TemperatureStatus) -> some View {
        let text = m.temperatureCelsius.map { unit.format($0) } ?? "—"
        let detail: String? = switch status {
        case .normal: "Normal"
        case .warm: "Warm"
        case .hot: "Too hot"
        case .unknown: nil
        }
        return MetricTile(title: "Temperature", value: text, detail: detail, symbol: "thermometer.medium", tint: status.color, help: MetricHelp.temperature)
            .overlay(alignment: .bottomTrailing) {
                if history.count > 1 {
                    Chart(history) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("°C", sample.celsius))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(status.color)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(width: 80, height: 28)
                    .padding(12)
                    .accessibilityHidden(true)
                }
            }
    }

    private func noHealthCard(title: String, message: String) -> some View {
        Card {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(message).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("noHealthCard")
    }
}

/// Long-term history: temperature, data written and wear over days and weeks.
struct HealthHistoryCard: View {
    var samples: [HealthSample]
    var unit: TemperatureUnit
    @AppStorage("historyMetric") private var metricRaw = Metric.temperature.rawValue
    @AppStorage("historyRange") private var rangeDays = 7

    enum Metric: String, CaseIterable, Identifiable {
        case temperature, written, lifeUsed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .temperature: "Temperature"
            case .written: "Data written"
            case .lifeUsed: "Life used"
            }
        }
    }

    private var metric: Metric { Metric(rawValue: metricRaw) ?? .temperature }

    private var points: [(Date, Double)] {
        let start = rangeDays == 0 ? Date.distantPast : Date().addingTimeInterval(-Double(rangeDays) * 86_400)
        return samples.filter { $0.date >= start }.compactMap { s in
            switch metric {
            case .temperature:
                return s.temperatureCelsius.map { (s.date, unit == .celsius ? Double($0) : Double($0) * 9 / 5 + 32) }
            case .written: return s.bytesWritten.map { (s.date, $0 / 1e12) }
            case .lifeUsed: return s.lifeUsedPercent.map { (s.date, Double($0)) }
            }
        }
    }

    private var axisLabel: String {
        switch metric {
        case .temperature: unit == .celsius ? "°C" : "°F"
        case .written: "TB"
        case .lifeUsed: "%"
        }
    }

    var body: some View {
        Card {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Picker("Value", selection: $metricRaw) {
                    ForEach(Metric.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Range", selection: $rangeDays) {
                    Text("Day").tag(1)
                    Text("Week").tag(7)
                    Text("Month").tag(30)
                    Text("All").tag(0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            let pts = points
            if pts.count < 2 {
                Text("oDisk records a reading every 15 minutes while it runs. Leave it in the menu bar to build a history.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(pts, id: \.0) { p in
                    LineMark(x: .value("Date", p.0), y: .value(axisLabel, p.1))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", p.0), y: .value(axisLabel, p.1))
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: .automatic(includesZero: metric != .temperature))
                .chartYAxisLabel(axisLabel)
                .frame(height: 160)
                .accessibilityLabel("\(metric.title) history")
            }
        }
        .accessibilityIdentifier("healthHistory")
    }
}

struct DriveHeader: View {
    var drive: Drive

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: drive.kind.symbolName)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .frame(width: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.displayName).font(.title.weight(.semibold))
                Text([drive.model, Formatters.bytes(drive.capacityBytes), drive.connectionDescription].joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("driveHeader")
    }
}

struct VolumesCard: View {
    var volumes: [Volume]

    var body: some View {
        Card(title: "Volumes") {
            if volumes.isEmpty {
                Text("No mounted volumes on this drive.").foregroundStyle(.secondary)
            }
            ForEach(volumes) { v in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(v.name).font(.body.weight(.medium))
                        if v.isStartupDisk { Text("Startup").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(Formatters.bytes(v.availableBytes)) free of \(Formatters.bytes(v.totalBytes))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    UsageBar(fraction: v.usedFraction)
                        .accessibilityLabel("\(Int(v.usedFraction * 100)) percent used")
                    Text(v.fileSystem).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
