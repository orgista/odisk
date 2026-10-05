import SwiftUI
import ODiskCore

extension HealthStatus {
    var color: Color {
        switch self {
        case .good: .green
        case .caution: .orange
        case .bad: .red
        case .unknown: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

extension TemperatureStatus {
    var color: Color {
        switch self {
        case .normal: .green
        case .warm: .orange
        case .hot: .red
        case .unknown: .secondary
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var title: String { self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }

    func format(_ celsius: Int) -> String {
        self == .celsius ? "\(celsius) °C" : "\(Int((Double(celsius) * 9 / 5 + 32).rounded())) °F"
    }

    static var current: TemperatureUnit {
        TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: "temperatureUnit") ?? "")
            ?? (Locale.current.measurementSystem == .us ? .fahrenheit : .celsius)
    }
}

/// Small coloured capsule with the health verdict.
struct StatusBadge: View {
    var status: HealthStatus
    var text: String?

    var body: some View {
        Label(text ?? status.title, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.14), in: Capsule())
            .labelStyle(.titleAndIcon)
    }
}

/// The big ring on the health page: remaining life, coloured by verdict.
struct HealthRing: View {
    var fraction: Double?
    var status: HealthStatus
    var size: CGFloat = 132

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: fraction ?? 0)
                .stroke(status.color.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.8), value: fraction)
            VStack(spacing: 2) {
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(status.title)
                    .font(.headline)
                    .foregroundStyle(status.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health \(status.title), \(fraction.map { "\(Int(($0 * 100).rounded())) percent life remaining" } ?? "unknown")")
        .accessibilityIdentifier("healthRing")
    }
}

/// One metric on the health page, with a plain-language explanation behind the info button.
struct MetricTile: View {
    var title: String
    var value: String
    var detail: String?
    var symbol: String
    var tint: Color = .accentColor
    var help: String
    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { showingHelp.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("About \(title)")
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                        Text(help).font(.callout).padding(12).frame(width: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("metric.\(title)")
    }
}

/// Card container used for page sections.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Capacity bar for a volume.
struct UsageBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(fraction > 0.9 ? Color.orange.gradient : Color.accentColor.gradient)
                    .frame(width: max(6, geo.size.width * fraction))
            }
        }
        .frame(height: 8)
    }
}

/// Plain-language explanations shown behind every info button.
enum MetricHelp {
    static let health = "oDisk's overall verdict, based on the drive's own warnings, spare blocks, wear and error counts."
    static let lifeUsed = "The drive maker's estimate of how much of its rated write endurance is used. 100% is the rated end, not a failure."
    static let spare = "Reserve blocks the drive uses to replace worn ones. When this drops below the drive's limit, replace the drive."
    static let temperature = "The drive's own temperature reading. SSDs slow themselves down when they get too hot."
    static let written = "Total data written to the drive over its life. Write endurance is rated against this number."
    static let read = "Total data read from the drive over its life."
    static let powerOn = "How long the drive has been powered on over its life."
    static let powerCycles = "How many times the drive has been switched on."
    static let unsafeShutdowns = "Times power was cut without a clean shutdown, such as an unplugged external drive or a crash."
    static let mediaErrors = "Data errors the drive could not correct. Anything above zero is a reason to keep backups current."
    static let errorLog = "Entries in the drive's error log. Many are harmless command errors, so this is for reference only."
    static let busy = "Total minutes the drive's controller has spent busy with work."
    static let hostWrites = "Number of write commands your Mac has sent to the drive."
    static let hostReads = "Number of read commands your Mac has sent to the drive."
    static let reallocated = "Worn or damaged areas the drive has swapped for spare ones. A rising count means the drive is wearing out."
    static let pending = "Areas the drive couldn't read reliably and is waiting to remap. Anything above zero is a reason to back up."
    static let criticalWarning = "Warning flags the drive raises itself: spare blocks low, too hot, reliability degraded, or read-only."
}
