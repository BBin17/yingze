import AppKit
import Testing
@testable import CameraCull

@Suite("可自定义快捷键")
@MainActor
struct KeyboardShortcutTests {
    @Test("默认快捷键都是单键")
    func defaultsUseSingleKeys() {
        let defaults = isolatedDefaults()
        let settings = ShortcutSettings(defaults: defaults)
        for action in CullKeyboardAction.allCases {
            let modifiers = settings.binding(for: action).modifiers
            #expect(modifiers.isEmpty)
        }
    }

    @Test("颜色默认快捷键为单键")
    func colorDefaultsUseBridgeStyleKeys() {
        let settings = ShortcutSettings(defaults: isolatedDefaults())
        #expect(settings.binding(for: .colorRed).displayText == "6")
        #expect(settings.binding(for: .colorYellow).displayText == "7")
        #expect(settings.binding(for: .colorGreen).displayText == "8")
        #expect(settings.binding(for: .colorBlue).displayText == "9")
        #expect(settings.binding(for: .colorPurple).displayText == "M")
        #expect(settings.binding(for: .colorNone).displayText == "Q")
        #expect(CullKeyboardAction.colorRed.colorLabel == .red)
    }

    @Test("主键盘和数字小键盘能匹配同一个评分单键")
    func keypadUsesRatingBinding() {
        let settings = ShortcutSettings(defaults: isolatedDefaults())
        let binding = settings.binding(for: .rating1)
        #expect(binding.matches(keyCode: 18, modifiers: []))
        #expect(binding.matches(keyCode: 83, modifiers: .numericPad))
        #expect(!binding.matches(keyCode: 18, modifiers: .control))
    }

    @Test("可录制新组合并持久化")
    func recordsAndPersistsCustomBinding() throws {
        let defaults = isolatedDefaults()
        let settings = ShortcutSettings(defaults: defaults)
        settings.beginRecording(.restore)
        settings.capture(try #require(keyEvent(keyCode: 15, modifiers: [.option, .shift], characters: "R")))

        #expect(settings.binding(for: .restore).displayText == "⌥⇧R")
        let reloaded = ShortcutSettings(defaults: defaults)
        #expect(reloaded.binding(for: .restore) == settings.binding(for: .restore))
    }

    @Test("可录制单键")
    func recordsSingleKey() throws {
        let settings = ShortcutSettings(defaults: isolatedDefaults())
        settings.beginRecording(.restore)
        settings.capture(try #require(keyEvent(keyCode: 15, modifiers: [], characters: "r")))
        #expect(settings.binding(for: .restore).displayText == "R")
        #expect(settings.recordingAction == nil)
    }

    @Test("拒绝与其他操作冲突的单键")
    func rejectsConflictingBindings() throws {
        let settings = ShortcutSettings(defaults: isolatedDefaults())
        settings.beginRecording(.restore)
        settings.capture(try #require(keyEvent(keyCode: 7, modifiers: [], characters: "x")))
        #expect(settings.recordingAction == .restore)
        #expect(settings.validationMessage?.contains("废片") == true)
    }

    @Test("旧版默认组合键自动迁移为单键")
    func migratesLegacyDefaults() throws {
        let defaults = isolatedDefaults()
        let legacy: [String: KeyBinding] = [
            "keep": KeyBinding(keyCode: 40, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "reject": KeyBinding(keyCode: 7, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "undecided": KeyBinding(keyCode: 32, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "rating0": KeyBinding(keyCode: 29, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "rating1": KeyBinding(keyCode: 18, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "rating2": KeyBinding(keyCode: 19, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "rating3": KeyBinding(keyCode: 20, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "rating4": KeyBinding(keyCode: 21, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "rating5": KeyBinding(keyCode: 23, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "previous": KeyBinding(keyCode: 123, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "next": KeyBinding(keyCode: 124, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue),
            "undo": KeyBinding(keyCode: 6, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue)
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "Yingze.CustomKeyboardShortcuts.v1")

        let settings = ShortcutSettings(defaults: defaults)
        #expect(settings.binding(for: .restore).displayText == "U")
        #expect(settings.binding(for: .undo).displayText == "Z")
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "YingzeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
