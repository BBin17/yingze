import AppKit
import SwiftUI

enum CullKeyboardAction: String, CaseIterable, Codable, Identifiable {
    case pick
    case reject
    case restore = "undecided"
    case rating0
    case rating1
    case rating2
    case rating3
    case rating4
    case rating5
    case colorNone
    case colorRed
    case colorYellow
    case colorGreen
    case colorBlue
    case colorPurple
    case previous
    case next
    case undo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pick: "标记为精选"
        case .reject: "放入软件废片区"
        case .restore: "从废片区恢复"
        case .rating0: "清除星级"
        case .rating1: "1 星"
        case .rating2: "2 星"
        case .rating3: "3 星"
        case .rating4: "4 星"
        case .rating5: "5 星"
        case .colorNone: "清除颜色标签"
        case .colorRed: "红色标签"
        case .colorYellow: "黄色标签"
        case .colorGreen: "绿色标签"
        case .colorBlue: "蓝色标签"
        case .colorPurple: "紫色标签"
        case .previous: "上一张"
        case .next: "下一张"
        case .undo: "撤销"
        }
    }

    var rating: Int? {
        switch self {
        case .rating0: 0
        case .rating1: 1
        case .rating2: 2
        case .rating3: 3
        case .rating4: 4
        case .rating5: 5
        default: nil
        }
    }

    var colorLabel: ColorLabel? {
        switch self {
        case .colorNone: ColorLabel.none
        case .colorRed: ColorLabel.red
        case .colorYellow: ColorLabel.yellow
        case .colorGreen: ColorLabel.green
        case .colorBlue: ColorLabel.blue
        case .colorPurple: ColorLabel.purple
        default: nil
        }
    }

    static func action(for color: ColorLabel) -> CullKeyboardAction {
        switch color {
        case .none: .colorNone
        case .red: .colorRed
        case .yellow: .colorYellow
        case .green: .colorGreen
        case .blue: .colorBlue
        case .purple: .colorPurple
        }
    }
}

struct KeyBinding: Codable, Equatable {
    let keyCode: UInt16
    let modifiersRawValue: UInt

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiersRawValue) }

    var displayText: String {
        let flags = modifiers
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        value += Self.keyName(keyCode)
        return value
    }

    func matches(keyCode eventKeyCode: UInt16, modifiers eventModifiers: NSEvent.ModifierFlags) -> Bool {
        Self.normalizedKeyCode(eventKeyCode) == keyCode && Self.clean(eventModifiers) == modifiers
    }

    static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> KeyBinding? {
        let cleaned = clean(modifiers)
        return KeyBinding(keyCode: normalizedKeyCode(keyCode), modifiersRawValue: cleaned.rawValue)
    }

    private static func clean(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .control, .option, .shift])
    }

    private static func normalizedKeyCode(_ keyCode: UInt16) -> UInt16 {
        [82: 29, 83: 18, 84: 19, 85: 20, 86: 21, 87: 23][keyCode] ?? keyCode
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 49: "Space", 51: "⌫", 123: "←", 124: "→",
            125: "↓", 126: "↑"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

@MainActor
final class ShortcutSettings: ObservableObject {
    @Published private(set) var bindings: [CullKeyboardAction: KeyBinding]
    @Published var recordingAction: CullKeyboardAction?
    @Published var validationMessage: String?

    private static let storageKey = "Yingze.CustomKeyboardShortcuts.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = Self.defaultBindings
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            if !Self.isLegacyDefaultSet(stored), !Self.isPreviousDefaultSet(stored) {
                for (key, binding) in stored {
                    if let action = CullKeyboardAction(rawValue: key) { bindings[action] = binding }
                }
            }
        }
    }

    func binding(for action: CullKeyboardAction) -> KeyBinding { bindings[action] ?? Self.defaultBindings[action]! }

    func action(for event: NSEvent) -> CullKeyboardAction? {
        bindings.first { $0.value.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) }?.key
    }

    func beginRecording(_ action: CullKeyboardAction) {
        validationMessage = nil
        recordingAction = action
    }

    func capture(_ event: NSEvent) {
        guard let action = recordingAction else { return }
        if event.keyCode == 53 {
            recordingAction = nil
            validationMessage = nil
            return
        }
        guard let binding = KeyBinding.from(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return }
        if let conflict = bindings.first(where: { $0.key != action && $0.value == binding })?.key {
            validationMessage = "这个组合已用于“\(conflict.title)”。"
            return
        }
        bindings[action] = binding
        recordingAction = nil
        validationMessage = nil
        save()
    }

    func resetToDefaults() {
        bindings = Self.defaultBindings
        recordingAction = nil
        validationMessage = nil
        save()
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { defaults.set(data, forKey: Self.storageKey) }
    }

    private static let defaultBindings: [CullKeyboardAction: KeyBinding] = {
        func binding(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> KeyBinding {
            KeyBinding(keyCode: keyCode, modifiersRawValue: modifiers.rawValue)
        }
        return [
            .pick: binding(35, []), .reject: binding(7, []), .restore: binding(32, []),
            .rating0: binding(29, []), .rating1: binding(18, []), .rating2: binding(19, []),
            .rating3: binding(20, []), .rating4: binding(21, []), .rating5: binding(23, []),
            .colorNone: binding(12, []), .colorRed: binding(22, []), .colorYellow: binding(26, []),
            .colorGreen: binding(28, []), .colorBlue: binding(25, []), .colorPurple: binding(46, []),
            .previous: binding(123, []), .next: binding(124, []), .undo: binding(6, [])
        ]
    }()

    private static func isLegacyDefaultSet(_ stored: [String: KeyBinding]) -> Bool {
        func binding(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> KeyBinding {
            KeyBinding(keyCode: keyCode, modifiersRawValue: modifiers.rawValue)
        }
        let legacy: [String: KeyBinding] = [
            "keep": binding(40, .control), "reject": binding(7, .control), "undecided": binding(32, .control),
            "rating0": binding(29, .control), "rating1": binding(18, .control), "rating2": binding(19, .control),
            "rating3": binding(20, .control), "rating4": binding(21, .control), "rating5": binding(23, .control),
            "previous": binding(123, .control), "next": binding(124, .control), "undo": binding(6, .command)
        ]
        guard stored.count == legacy.count else { return false }
        return legacy.allSatisfy { key, value in
            stored[key] == value
        }
    }

    private static func isPreviousDefaultSet(_ stored: [String: KeyBinding]) -> Bool {
        func binding(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> KeyBinding {
            KeyBinding(keyCode: keyCode, modifiersRawValue: modifiers.rawValue)
        }
        let previous: [String: KeyBinding] = [
            "reject": binding(7), "undecided": binding(32),
            "rating0": binding(29), "rating1": binding(18), "rating2": binding(19),
            "rating3": binding(20), "rating4": binding(21), "rating5": binding(23),
            "colorNone": binding(8), "colorRed": binding(22), "colorYellow": binding(26),
            "colorGreen": binding(28), "colorBlue": binding(25), "colorPurple": binding(35),
            "previous": binding(123), "next": binding(124), "undo": binding(6)
        ]
        guard stored.count == previous.count else { return false }
        return previous.allSatisfy { key, value in stored[key] == value }
    }
}

struct KeyboardShortcutMonitor: NSViewRepresentable {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: ShortcutSettings

    func makeCoordinator() -> Coordinator { Coordinator(store: store, settings: settings) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.store = store
        context.coordinator.settings = settings
    }

    @MainActor
    final class Coordinator {
        var store: SessionStore
        var settings: ShortcutSettings
        private var monitor: Any?

        init(store: SessionStore, settings: ShortcutSettings) {
            self.store = store
            self.settings = settings
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if settings.recordingAction != nil {
                settings.capture(event)
                return nil
            }
            guard !store.showsProjectHome, !store.showingShortcutHelp else { return event }
            if event.window?.firstResponder is NSTextView { return event }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                switch event.keyCode {
                case 53:
                    if store.browserMode != .grid {
                        store.browserMode = .grid
                        return nil
                    }
                case 49:
                    store.browserMode = store.browserMode == .single ? .grid : .single
                    return nil
                case 5:
                    store.browserMode = .grid
                    return nil
                case 14:
                    store.browserMode = .single
                    return nil
                case 8:
                    store.browserMode = .compare
                    return nil
                case 45:
                    store.browserMode = .survey
                    return nil
                default:
                    break
                }
            }
            guard let action = settings.action(for: event) else { return event }
            if event.isARepeat, action != .previous, action != .next { return nil }
            if let rating = action.rating { store.setRating(rating) }
            else if let color = action.colorLabel { store.setColor(color) }
            else {
                switch action {
                case .pick: store.setPickState(.keep)
                case .reject: store.setPickState(.reject)
                case .restore: store.setPickState(.undecided)
                case .previous: store.moveSelection(by: -1)
                case .next: store.moveSelection(by: 1)
                case .undo: store.undo()
                default: break
                }
            }
            return nil
        }
    }
}

struct ShortcutSettingsView: View {
    @EnvironmentObject private var settings: ShortcutSettings

    var body: some View {
        Form {
            Section("选片") { rows([.pick, .reject, .restore, .previous, .next, .undo]) }
            Section("星级") { rows([.rating0, .rating1, .rating2, .rating3, .rating4, .rating5]) }
            Section("颜色标签") { rows([.colorNone, .colorRed, .colorYellow, .colorGreen, .colorBlue, .colorPurple]) }
            if let message = settings.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            HStack {
                Text("点击快捷键后，可直接按单键或组合键；按 Esc 取消。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") { settings.resetToDefaults() }
                    .appButton(.secondary, controlSize: .small)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 560, height: 690)
    }

    @ViewBuilder
    private func rows(_ actions: [CullKeyboardAction]) -> some View {
        ForEach(actions) { action in
            LabeledContent(action.title) {
                Button(settings.recordingAction == action ? "请按新快捷键…" : settings.binding(for: action).displayText) {
                    settings.beginRecording(action)
                }
                .appButton(.secondary)
                .font(.system(.body, design: .monospaced).bold())
                .frame(minWidth: 130)
            }
        }
    }
}
