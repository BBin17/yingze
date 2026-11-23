import SwiftUI

@main
struct CameraCullApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var shortcutSettings = ShortcutSettings()
    @StateObject private var updater = AppUpdateController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(shortcutSettings)
                .environmentObject(updater)
        }
        .commands { CameraCullCommands(store: store, shortcutSettings: shortcutSettings, updater: updater) }

        Window("软件更新", id: AppUpdateView.windowID) {
            AppUpdateView(updater: updater)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            ShortcutSettingsView().environmentObject(shortcutSettings)
        }
    }
}

struct CameraCullCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: SessionStore
    @ObservedObject var shortcutSettings: ShortcutSettings
    let updater: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                openWindow(id: AppUpdateView.windowID)
                Task { await updater.check() }
            }
        }
        CommandMenu("选片") {
            Button("标记为精选（\(shortcutSettings.binding(for: .pick).displayText)）") { store.setPickState(.keep) }
            Button("移入废片（\(shortcutSettings.binding(for: .reject).displayText)）") { store.setPickState(.reject) }
            Button("恢复为未决定（\(shortcutSettings.binding(for: .restore).displayText)）") { store.setPickState(.undecided) }
            Divider()
            ForEach(1...5, id: \.self) { rating in
                Button("\(rating) 星") { store.setRating(rating) }
            }
            Button("清除星级") { store.setRating(0) }
            Divider()
            ForEach(ColorLabel.allCases, id: \.self) { color in
                let action = CullKeyboardAction.action(for: color)
                Button("\(color.title)（\(shortcutSettings.binding(for: action).displayText)）") { store.setColor(color) }
            }
            Divider()
            Button("上一张（\(shortcutSettings.binding(for: .previous).displayText)）") { store.moveSelection(by: -1) }
            Button("下一张（\(shortcutSettings.binding(for: .next).displayText)）") { store.moveSelection(by: 1) }
        }
        CommandGroup(replacing: .help) {
            Button("影择快捷键…") { store.showingShortcutHelp = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}
