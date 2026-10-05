import SwiftUI
import ODiskUI

@main
struct ODiskApp: App {
    @State private var model: AppModel
    @AppStorage("showMenuBarExtra") private var showMenuBar = true

    init() {
        // Start monitoring at launch, even when only the menu bar item is shown (e.g. opened at login).
        let model = AppModel()
        _model = State(initialValue: model)
        Task { @MainActor in model.start() }
    }

    var body: some Scene {
        Window("oDisk", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { ODiskCommands() }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}
