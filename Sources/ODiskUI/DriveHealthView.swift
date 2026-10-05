import Charts
import SwiftUI
import ODiskCore

struct DriveHealthView: View {
    var drive: Drive
    var state: SMARTState
    var history: [TemperatureSample]
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
                case .unsupported:
                    noHealthCard(
                        title: "This drive doesn’t share health data",
                        message: "Its connection doesn’t pass S.M.A.R.T. through to macOS. That is common for USB enclosures with SATA bridges and for SD cards. You can still run a speed test.")
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
                        Label("No warnings. Spare blocks, error counts and temperature are all within the drive’s limits.", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(a.findings) { f in
                            Label(f.message, systemImage: f.status.symbol)
                                .foregroundStyle(f.status == .bad ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                                .symbolRenderingMode(.multicolor)
                        }
                    }
                    if let estimate = lifeEstimate(s) {
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

    /// "At your pace so far, ~12 years of rated endurance remain." Only when wear is measurable.
    private func lifeEstimate(_ s: SMARTSnapshot) -> String? {
        let used = Double(s.log.percentageUsed)
        guard used >= 1, used < 100, s.log.powerOnHours > 24 * 30 else { return nil }
        let hoursLeft = s.log.powerOnHours / used * (100 - used)
        let years = hoursLeft / 24 / 365.25
        guard years >= 0.5 else { return nil }
        return "At the current pace of use, the rated endurance lasts about \(years >= 20 ? "20+" : Formatters.trim(years, digits: 0)) more years of powered-on time."
    }

    private func metrics(_ s: SMARTSnapshot) -> some View {
        let log = s.log
        let tempText = log.compositeTemperatureCelsius.map { unit.format($0) } ?? "—"
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            temperatureTile(text: tempText, status: s.assessment.temperature)
            MetricTile(title: "Life used", value: "\(log.percentageUsed)%", detail: "Rated write endurance", symbol: "gauge.with.dots.needle.33percent",
                       tint: log.percentageUsed >= 90 ? .orange : .accentColor, help: MetricHelp.lifeUsed)
            MetricTile(title: "Data written", value: Formatters.bytes(log.bytesWritten), detail: "Over the drive’s life", symbol: "square.and.arrow.down", help: MetricHelp.written)
            MetricTile(title: "Data read", value: Formatters.bytes(log.bytesRead), detail: "Over the drive’s life", symbol: "square.and.arrow.up", help: MetricHelp.read)
            MetricTile(title: "Powered on", value: Formatters.powerOnTime(hours: log.powerOnHours), detail: "\(Formatters.count(log.powerOnHours)) hours",
                       symbol: "clock", help: MetricHelp.powerOn)
            MetricTile(title: "Power cycles", value: Formatters.count(log.powerCycles), symbol: "power", help: MetricHelp.powerCycles)
            MetricTile(title: "Spare blocks", value: "\(log.availableSparePercent)%", detail: "Replace below \(log.availableSpareThresholdPercent)%",
                       symbol: "square.stack.3d.up", tint: log.availableSparePercent < log.availableSpareThresholdPercent ? .red : .accentColor, help: MetricHelp.spare)
            MetricTile(title: "Unsafe shutdowns", value: Formatters.count(log.unsafeShutdowns), symbol: "bolt.slash", help: MetricHelp.unsafeShutdowns)
            MetricTile(title: "Media errors", value: Formatters.count(log.mediaErrors), detail: log.mediaErrors == 0 ? "None recorded" : "Keep backups current",
                       symbol: "exclamationmark.shield", tint: log.mediaErrors > 0 ? .orange : .green, help: MetricHelp.mediaErrors)
        }
    }

    private func temperatureTile(text: String, status: TemperatureStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MetricTile(title: "Temperature", value: text, detail: status == .normal ? "Normal" : (status == .warm ? "Warm" : (status == .hot ? "Too hot" : nil)),
                       symbol: "thermometer.medium", tint: status.color, help: MetricHelp.temperature)
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

struct DriveHeader: View {
    var drive: Drive

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: drive.kind.symbolName)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .frame(width: 48)
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
                    Text(v.fileSystem).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
