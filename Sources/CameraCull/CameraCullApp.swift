import SwiftUI

@main
struct CameraCullApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var shortcutSettings = ShortcutSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(shortcutSettings)
        }
        .commands { CameraCullCommands(store: store, shortcutSettings: shortcutSettings) }

        Settings {
            ShortcutSettingsView().environmentObject(shortcutSettings)
        }
    }
}

struct CameraCullCommands: Commands {
    @ObservedObject var store: SessionStore
    @ObservedObject var shortcutSettings: ShortcutSettings

    var body: some Commands {
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
