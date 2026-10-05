import SwiftUI
import ODiskCore

/// Every raw value, for people who want the full table, plus a copyable report.
struct DriveDetailsView: View {
    var drive: Drive
    var state: SMARTState
    @State private var revealSerial = false

    var body: some View {
        Form {
            Section("Drive") {
                LabeledContent("Model", value: drive.model)
                LabeledContent("Firmware", value: state.snapshot?.firmware ?? (drive.firmware.isEmpty ? "—" : drive.firmware))
                LabeledContent("Serial number") {
                    HStack {
                        Text(revealSerial ? serial : String(repeating: "•", count: min(12, max(4, serial.count))))
                            .textSelection(.enabled)
                            .monospaced()
                            .accessibilityLabel(revealSerial ? serial : "Hidden")
                        Button(revealSerial ? "Hide" : "Show") { revealSerial.toggle() }.buttonStyle(.borderless)
                    }
                }
                LabeledContent("Capacity", value: "\(Formatters.bytes(drive.capacityBytes)) (\(Formatters.count(Double(drive.capacityBytes))) bytes)")
                LabeledContent("Connection", value: drive.connectionDescription)
                LabeledContent("Type", value: drive.isSolidState ? "Solid state" : "Hard disk")
                LabeledContent("Interface", value: drive.smartProtocol.map { $0 == .nvme ? "NVM Express" : "Serial ATA" } ?? drive.interconnect)
                LabeledContent("BSD name", value: drive.bsdName)
                if let s = state.snapshot {
                    if let w = s.metrics.warningTemperatureCelsius { LabeledContent("Warning temperature", value: TemperatureUnit.current.format(w)) }
                    if let c = s.metrics.criticalTemperatureCelsius { LabeledContent("Critical temperature", value: TemperatureUnit.current.format(c)) }
                }
            }
            if let id = state.snapshot?.nvmeIdentify {
                Section("Features") {
                    if let v = id.nvmeVersion { LabeledContent("NVMe version", value: v) }
                    LabeledContent("Supported", value: (["S.M.A.R.T."] + id.featureList).joined(separator: ", "))
                    if id.firmwareSlots > 0 { LabeledContent("Firmware slots", value: "\(id.firmwareSlots)") }
                }
            }
            if let s = state.snapshot, let log = s.nvme {
                Section("S.M.A.R.T. values (NVMe log 02h)") {
                    ForEach(nvmeRows(log), id: \.0) { name, value, help in
                        LabeledContent {
                            Text(value).monospacedDigit().textSelection(.enabled)
                        } label: {
                            Text(name).help(help)
                        }
                    }
                }
            }
            if let s = state.snapshot, let log = s.ata {
                Section("S.M.A.R.T. attributes") {
                    ATAAttributeTable(attributes: log.attributes)
                }
            }
            if let s = state.snapshot {
                Section {
                    Button("Copy Health Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report(s), forType: .string)
                    }
                    .accessibilityIdentifier("copyReport")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var serial: String {
        let s = state.snapshot?.serial ?? drive.serial
        return s.isEmpty ? "—" : s
    }

    private func nvmeRows(_ l: NVMeHealthLog) -> [(String, String, String)] {
        let unit = TemperatureUnit.current
        var r: [(String, String, String)] = [
            ("Critical warning", l.criticalWarning.rawValue == 0 ? "None (0x00)" : String(format: "0x%02X", l.criticalWarning.rawValue), MetricHelp.criticalWarning),
            ("Composite temperature", l.compositeTemperatureCelsius.map { "\(unit.format($0)) (\(l.compositeTemperatureKelvin) K)" } ?? "—", MetricHelp.temperature),
            ("Available spare", "\(l.availableSparePercent)%", MetricHelp.spare),
            ("Available spare threshold", "\(l.availableSpareThresholdPercent)%", MetricHelp.spare),
            ("Percentage used", "\(l.percentageUsed)%", MetricHelp.lifeUsed),
            ("Data units read", "\(Formatters.count(l.dataUnitsRead)) (\(Formatters.bytes(l.bytesRead)))", MetricHelp.read),
            ("Data units written", "\(Formatters.count(l.dataUnitsWritten)) (\(Formatters.bytes(l.bytesWritten)))", MetricHelp.written),
            ("Host read commands", Formatters.count(l.hostReadCommands), MetricHelp.hostReads),
            ("Host write commands", Formatters.count(l.hostWriteCommands), MetricHelp.hostWrites),
            ("Controller busy time", "\(Formatters.count(l.controllerBusyMinutes)) min", MetricHelp.busy),
            ("Power cycles", Formatters.count(l.powerCycles), MetricHelp.powerCycles),
            ("Power-on hours", Formatters.count(l.powerOnHours), MetricHelp.powerOn),
            ("Unsafe shutdowns", Formatters.count(l.unsafeShutdowns), MetricHelp.unsafeShutdowns),
            ("Media and data integrity errors", Formatters.count(l.mediaErrors), MetricHelp.mediaErrors),
            ("Error log entries", Formatters.count(l.errorLogEntries), MetricHelp.errorLog),
            ("Warning temperature time", "\(l.warningTemperatureMinutes) min", MetricHelp.temperature),
            ("Critical temperature time", "\(l.criticalTemperatureMinutes) min", MetricHelp.temperature),
        ]
        for (i, k) in l.sensorTemperaturesKelvin.enumerated() {
            r.append(("Temperature sensor \(i + 1)", unit.format(k - 273), MetricHelp.temperature))
        }
        return r
    }

    private func report(_ s: SMARTSnapshot) -> String {
        var lines = ["oDisk health report, \(s.date.formatted(date: .abbreviated, time: .shortened))",
                     "\(drive.model) · \(Formatters.bytes(drive.capacityBytes)) · \(drive.connectionDescription)",
                     "Firmware \(s.firmware ?? drive.firmware)",
                     "Health status: \(s.assessment.status.title)\(s.assessment.lifeRemainingPercent.map { " (\($0)%)" } ?? "")"]
        lines += s.assessment.findings.map { "  - \($0.message)" }
        lines.append("")
        if let log = s.nvme {
            lines += nvmeRows(log).map { "\($0.0): \($0.1)" }
        }
        if let log = s.ata {
            lines.append("ID  Attribute                         Cur Wor Thr  Raw")
            for a in log.attributes {
                lines.append(String(format: "%02X  %@ %3d %3d %3d  %llu", a.id,
                                    a.name.padding(toLength: 32, withPad: " ", startingAt: 0), a.current, a.worst, a.threshold, a.raw))
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// CrystalDiskInfo-style attribute table for SATA drives.
struct ATAAttributeTable: View {
    var attributes: [ATASMARTAttribute]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("ID"); Text("Attribute"); Text("Current"); Text("Worst"); Text("Threshold"); Text("Raw")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(attributes) { a in
                GridRow {
                    Text(String(format: "%02X", a.id)).monospaced()
                    HStack(spacing: 4) {
                        Circle().fill(color(a)).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(a.name)
                    }
                    Text("\(a.current)").monospacedDigit()
                    Text("\(a.worst)").monospacedDigit()
                    Text("\(a.threshold)").monospacedDigit()
                    Text("\(a.raw)").monospacedDigit().textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.callout)
    }

    private func color(_ a: ATASMARTAttribute) -> Color {
        if a.threshold > 0, a.current <= a.threshold { return .red }
        if [0x05, 0xC5, 0xC6].contains(a.id), a.raw > 0 { return .orange }
        return .green
    }
}
