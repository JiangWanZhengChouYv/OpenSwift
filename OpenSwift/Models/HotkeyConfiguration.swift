import Foundation
import AppKit

enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case increaseSpeed = "increaseSpeed"
    case decreaseSpeed = "decreaseSpeed"
    case toggleSpeed = "toggleSpeed"
    case resetSpeed = "resetSpeed"
    case quickBoost = "quickBoost"
    case quickSlow = "quickSlow"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .increaseSpeed:
            return "增加速度"
        case .decreaseSpeed:
            return "减少速度"
        case .toggleSpeed:
            return "开关变速"
        case .resetSpeed:
            return "重置速度"
        case .quickBoost:
            return "快速加速"
        case .quickSlow:
            return "快速减速"
        }
    }

    var description: String {
        switch self {
        case .increaseSpeed:
            return "每次 +0.5x 速度"
        case .decreaseSpeed:
            return "每次 -0.5x 速度"
        case .toggleSpeed:
            return "启用/禁用速度控制"
        case .resetSpeed:
            return "恢复 1.0x 速度"
        case .quickBoost:
            return "设置为 2.0x 速度"
        case .quickSlow:
            return "设置为 0.5x 速度"
        }
    }
}

struct HotkeyConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var action: HotkeyAction
    var keyCode: UInt32
    var modifiers: UInt32
    var isEnabled: Bool

    init(id: UUID = UUID(), action: HotkeyAction, keyCode: UInt32, modifiers: UInt32, isEnabled: Bool = true) {
        self.id = id
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }

    var displayString: String {
        let modifierString = HotkeyConfig.modifiersToString(modifiers)
        let keyString = HotkeyConfig.keyCodeToString(keyCode)
        return modifierString + keyString
    }

    static func modifiersToString(_ modifiers: UInt32) -> String {
        var result = ""
        
        if (modifiers & UInt32(NSEvent.ModifierFlags.control.rawValue)) != 0 {
            result += "⌃"
        }
        if (modifiers & UInt32(NSEvent.ModifierFlags.option.rawValue)) != 0 {
            result += "⌥"
        }
        if (modifiers & UInt32(NSEvent.ModifierFlags.shift.rawValue)) != 0 {
            result += "⇧"
        }
        if (modifiers & UInt32(NSEvent.ModifierFlags.command.rawValue)) != 0 {
            result += "⌘"
        }
        
        if !result.isEmpty {
            result += "+"
        }
        
        return result
    }

    static func keyCodeToString(_ keyCode: UInt32) -> String {
        let keyCodeMap: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 118: "F4", 119: "F2", 120: "F1", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        
        return keyCodeMap[keyCode] ?? "键\(keyCode)"
    }

    static func defaultConfigurations() -> [HotkeyConfig] {
        let cmdOpt = UInt32(NSEvent.ModifierFlags.command.rawValue |
                           NSEvent.ModifierFlags.option.rawValue)
        return [
            HotkeyConfig(action: .increaseSpeed, keyCode: 126, modifiers: cmdOpt, isEnabled: true),
            HotkeyConfig(action: .decreaseSpeed, keyCode: 125, modifiers: cmdOpt, isEnabled: true),
            HotkeyConfig(action: .toggleSpeed, keyCode: 49, modifiers: cmdOpt, isEnabled: true),
            HotkeyConfig(action: .resetSpeed, keyCode: 15, modifiers: cmdOpt, isEnabled: true),
            HotkeyConfig(action: .quickBoost, keyCode: 11, modifiers: cmdOpt, isEnabled: false),
            HotkeyConfig(action: .quickSlow, keyCode: 1, modifiers: cmdOpt, isEnabled: false)
        ]
    }

    static func modifiersToFlags(hasCommand: Bool, hasOption: Bool, hasControl: Bool, hasShift: Bool) -> UInt32 {
        var modifiers: UInt32 = 0
        
        if hasCommand {
            modifiers |= UInt32(NSEvent.ModifierFlags.command.rawValue)
        }
        if hasOption {
            modifiers |= UInt32(NSEvent.ModifierFlags.option.rawValue)
        }
        if hasControl {
            modifiers |= UInt32(NSEvent.ModifierFlags.control.rawValue)
        }
        if hasShift {
            modifiers |= UInt32(NSEvent.ModifierFlags.shift.rawValue)
        }
        
        return modifiers
    }
}
