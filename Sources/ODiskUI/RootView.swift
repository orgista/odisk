import SwiftUI
import ODiskCore

public enum DetailTab: String, CaseIterable, Identifiable {
    case health, benchmark, details
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .health: "Health"
        case .benchmark: "Speed Test"
        case .details: "Details"
        }
    }
}

public struct RootView: View {
    @Bindable var model: AppModel
    @SceneStorage("detailTab") private var tabRaw = DetailTab.health.rawValue

    public init(model: AppModel) { self.model = model }

    private var tab: DetailTab { DetailTab(rawValue: tabRaw) ?? .health }

    public var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Drives") {
                    ForEach(model.drives) { drive in
                        DriveRow(drive: drive, state: model.smart[drive.id] ?? .loading,
                                 testing: model.benchmarks.runningDriveID == drive.id)
                            .tag(drive.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            .accessibilityIdentifier("driveList")
            .overlay {
                if model.drives.isEmpty && model.lastRefresh != nil {
                    ContentUnavailableView("No Drives", systemImage: "externaldrive.badge.questionmark")
                }
            }
        } detail: {
            if let drive = model.selectedDrive {
                Group {
                    switch tab {
                    case .health:
                        DriveHealthView(drive: drive, state: model.smart[drive.id] ?? .loading,
                                        history: model.temperatureHistory[drive.id] ?? [],
                                        longHistory: model.history.samples(for: drive))
                    case .benchmark:
                        BenchmarkView(drive: drive, store: model.benchmarks)
                    case .details:
                        DriveDetailsView(drive: drive, state: model.smart[drive.id] ?? .loading)
                    }
                }
                .navigationTitle(drive.displayName)
                .navigationSubtitle(drive.model)
            } else {
                ProgressView().navigationTitle("oDisk")
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tabRaw) {
                    ForEach(DetailTab.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("tabPicker")
            }
            ToolbarItem {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Rescan drives and reread health")
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .task {
            model.start()
            #if ODISK_DEBUG_HOOKS
            if E2EDriver.isEnabled { await E2EDriver.run(model: model) { tabRaw = $0.rawValue } }
            #endif
        }
        .focusedSceneValue(\.detailTab, $tabRaw)
    }
}

struct DriveRow: View {
    var drive: Drive
    var state: SMARTState
    var testing: Bool
    @AppStorage("temperatureUnit") private var unitRaw = TemperatureUnit.current.rawValue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: drive.kind.symbolName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.displayName).lineLimit(1)
                Text("\(Formatters.bytes(drive.capacityBytes)) · \(drive.isInternal ? "Internal" : drive.interconnect)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if testing {
                ProgressView().controlSize(.small)
            } else if let s = state.snapshot {
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: s.assessment.status.symbol).foregroundStyle(s.assessment.status.color)
                    if let c = s.metrics.temperatureCelsius {
                        Text((TemperatureUnit(rawValue: unitRaw) ?? .celsius).format(c))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("driveRow.\(drive.bsdName)")
    }
}

struct DetailTabKey: FocusedValueKey { typealias Value = Binding<String> }
extension FocusedValues {
    var detailTab: Binding<String>? {
        get { self[DetailTabKey.self] }
        set { self[DetailTabKey.self] = newValue }
    }
}

/// View menu commands: ⌘1/⌘2/⌘3 switch tabs.
public struct ODiskCommands: Commands {
    @FocusedValue(\.detailTab) private var tab
    public init() {}
    public var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { i, t in
                Button(t.title) { tab?.wrappedValue = t.rawValue }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .disabled(tab == nil)
            }
            Divider()
        }
    }
}
