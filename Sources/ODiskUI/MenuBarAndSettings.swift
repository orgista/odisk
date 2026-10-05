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
                Text("\(d.displayName) — \(s?.assessment.status.title ?? "No health data")\(s?.log.compositeTemperatureCelsius.map { ", " + (TemperatureUnit(rawValue: unitRaw) ?? .celsius).format($0) } ?? "")")
            }
        }
        Divider()
        Button("Open oDisk") { openWindow(id: "main"); NSApp.activate() }
        Button("Refresh") { model.refresh() }
        Divider()
        Button("Quit oDisk") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

public struct SettingsView: View {
    @AppStorage("temperatureUnit") private var unitRaw = TemperatureUnit.current.rawValue
    @AppStorage("showMenuBarExtra") private var showMenuBar = true

    public init() {}

    public var body: some View {
        TabView {
            Form {
                Picker("Temperature", selection: $unitRaw) {
                    ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show drive health in the menu bar", isOn: $showMenuBar)
                Text("oDisk reads health data and runs speed tests on this Mac only. It has no accounts and sends nothing over the network.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            ScrollView {
                Text(notices).font(.caption).textSelection(.enabled).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tabItem { Label("Acknowledgements", systemImage: "doc.text") }
        }
        .frame(width: 480, height: 320)
    }

    private var notices: String {
        guard let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }
}
