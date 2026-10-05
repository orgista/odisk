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
                LabeledContent("Firmware", value: state.snapshot?.identify?.firmwareRevision ?? (drive.firmware.isEmpty ? "—" : drive.firmware))
                LabeledContent("Serial number") {
                    HStack {
                        Text(revealSerial ? serial : String(repeating: "•", count: min(12, max(4, serial.count))))
                            .textSelection(.enabled)
                            .monospaced()
                        Button(revealSerial ? "Hide" : "Show") { revealSerial.toggle() }.buttonStyle(.borderless)
                    }
                }
                LabeledContent("Capacity", value: "\(Formatters.bytes(drive.capacityBytes)) (\(Formatters.count(Double(drive.capacityBytes))) bytes)")
                LabeledContent("Connection", value: drive.connectionDescription)
                LabeledContent("Type", value: drive.isSolidState ? "Solid state" : "Hard disk")
                LabeledContent("BSD name", value: drive.bsdName)
                if let id = state.snapshot?.identify {
                    if id.warningTemperatureKelvin > 273 { LabeledContent("Warning temperature", value: TemperatureUnit.current.format(id.warningTemperatureKelvin - 273)) }
                    if id.criticalTemperatureKelvin > 273 { LabeledContent("Critical temperature", value: TemperatureUnit.current.format(id.criticalTemperatureKelvin - 273)) }
                }
            }
            if let s = state.snapshot {
                Section("S.M.A.R.T. values (NVMe log 02h)") {
                    ForEach(rows(s.log), id: \.0) { name, value, help in
                        LabeledContent {
                            Text(value).monospacedDigit().textSelection(.enabled)
                        } label: {
                            Text(name).help(help)
                        }
                    }
                }
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
        let s = state.snapshot?.identify?.serialNumber ?? drive.serial
        return s.isEmpty ? "—" : s
    }

    private func rows(_ l: NVMeHealthLog) -> [(String, String, String)] {
        var r: [(String, String, String)] = [
            ("Critical warning", l.criticalWarning.rawValue == 0 ? "None (0x00)" : String(format: "0x%02X", l.criticalWarning.rawValue), MetricHelp.criticalWarning),
            ("Composite temperature", l.compositeTemperatureCelsius.map { "\(TemperatureUnit.current.format($0)) (\(l.compositeTemperatureKelvin) K)" } ?? "—", MetricHelp.temperature),
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
            r.append(("Temperature sensor \(i + 1)", TemperatureUnit.current.format(k - 273), MetricHelp.temperature))
        }
        return r
    }

    private func report(_ s: SMARTSnapshot) -> String {
        var lines = ["oDisk health report — \(s.date.formatted(date: .abbreviated, time: .shortened))",
                     "\(drive.model) · \(Formatters.bytes(drive.capacityBytes)) · \(drive.connectionDescription)",
                     "Firmware \(s.identify?.firmwareRevision ?? drive.firmware)",
                     "Health: \(s.assessment.status.title)\(s.assessment.lifeRemainingPercent.map { " (\($0)% life remaining)" } ?? "")"]
        lines += s.assessment.findings.map { "  • \($0.message)" }
        lines.append("")
        lines += rows(s.log).map { "\($0.0): \($0.1)" }
        return lines.joined(separator: "\n")
    }
}
