import SwiftUI
import ODiskUI

@main
struct ODiskApp: App {
    @State private var model = AppModel()
    @AppStorage("showMenuBarExtra") private var showMenuBar = true

    var body: some Scene {
        Window("oDisk", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { ODiskCommands() }

        Settings {
            SettingsView()
        }

        MenuBarExtra("oDisk", systemImage: "internaldrive", isInserted: $showMenuBar) {
            MenuBarContent(model: model)
                .task { model.start() }
        }
    }
}
