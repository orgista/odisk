import SwiftUI
import ODiskCore

/// Menu bar glance: every drive's verdict and temperature.
public struct MenuBarContent: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("temperatureUnit") private var unitRaw = TemperatureUnit.current.rawValue

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ForEach(model.drives) { d in
            let s = model.smart[d.id]?.snapshot
            Button {
                model.selection = d.id
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Label {
                    Text("\(d.displayName): \(s?.assessment.status.title ?? "no health data")\(s?.metrics.temperatureCelsius.map { ", " + (TemperatureUnit(rawValue: unitRaw) ?? .celsius).format($0) } ?? "")")
                } icon: {
                    Image(systemName: s?.assessment.status.symbol ?? d.kind.symbolName)
                }
            }
        }
        Divider()
        Button("Open oDisk") { openWindow(id: "main"); NSApp.activate() }
        Button("Check Now") { model.refresh() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit oDisk") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The menu bar icon: a drive symbol that turns into a warning when any drive needs attention.
public struct MenuBarLabel: View {
    var model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        switch model.overallStatus {
        case .bad: Image(systemName: "externaldrive.badge.xmark")
        case .caution: Image(systemName: "externaldrive.badge.exclamationmark")
        default: Image(systemName: "internaldrive")
        }
    }
}

public struct SettingsView: View {
    var model: AppModel
    @AppStorage("temperatureUnit") private var unitRaw = TemperatureUnit.current.rawValue
    @AppStorage("showMenuBarExtra") private var showMenuBar = true
    @AppStorage("notifyHealth") private var notifyHealth = true
    @AppStorage("notifyTemperature") private var notifyTemperature = true
    @AppStorage("checkInterval") private var checkInterval = CheckInterval.halfMinute.rawValue
    @State private var opensAtLogin = AppModel.opensAtLogin
    @State private var loginError: String?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView {
            Form {
                Picker("Temperature", selection: $unitRaw) {
                    ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("oDisk reads health data and runs speed tests on this Mac only. It has no accounts and sends nothing over the network.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    Toggle("Open oDisk at login", isOn: Binding(get: { opensAtLogin }, set: { on in
                        loginError = AppModel.setOpensAtLogin(on)
                        opensAtLogin = AppModel.opensAtLogin
                    }))
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                    Toggle("Show drive health in the menu bar", isOn: $showMenuBar)
                    Picker("Check drives", selection: $checkInterval) {
                        ForEach(CheckInterval.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .onChange(of: checkInterval) { model.reschedule() }
                } footer: {
                    Text("oDisk checks while it's open or in the menu bar. With the menu bar on, closing the window keeps it running.")
                }
                Section("Notify me when") {
                    Toggle("A drive's health status gets worse or new data errors appear", isOn: $notifyHealth)
                    Toggle("A drive gets too hot", isOn: $notifyTemperature)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Monitoring", systemImage: "waveform.path.ecg") }

            ScrollView {
                Text(notices).font(.caption).textSelection(.enabled).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tabItem { Label("Acknowledgements", systemImage: "doc.text") }
        }
        .frame(width: 520, height: 360)
    }

    private var notices: String {
        guard let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }
}
