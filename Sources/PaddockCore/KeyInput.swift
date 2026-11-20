import Carbon.HIToolbox

/// One key press for a VM's virtual keyboard: a hardware key code on a US ANSI keyboard, with the
/// modifier keys held while it is pressed. The guest turns key codes into characters with its own
/// keyboard layout, so text comes out as typed only when the guest uses a US layout.
public struct KeyStroke: Equatable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable {
        case shift, control, option, command
    }

    public var keyCode: UInt16
    public var modifiers: Set<Modifier>

    public init(_ keyCode: Int, _ modifiers: Set<Modifier> = []) {
        self.keyCode = UInt16(keyCode)
        self.modifiers = modifiers
    }
}

public enum KeyInput {
    /// The key strokes that type `text`. Throws for a character a US keyboard can't type, such as
    /// "é" or an emoji.
    public static func strokes(typing text: String) throws -> [KeyStroke] {
        try text.map { character in
            guard let stroke = characters[character] else {
                throw PaddockError("can't type \(character.debugDescription): only characters on a US keyboard can be typed")
            }
            return stroke
        }
    }

    /// The key stroke a combination names: modifiers and one key joined by "+", such as "cmd+s",
    /// "cmd+shift+z" or "return". Modifiers are cmd, ctrl, opt and shift (or command, control,
    /// option and alt); the key is a character a US keyboard types, `plus` for "+", which separates
    /// the parts, or a name from `namedKeys`.
    public static func stroke(_ combination: String) throws -> KeyStroke {
        let parts = combination.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty, parts.dropLast().allSatisfy({ !$0.isEmpty }) else {
            throw PaddockError("\(combination.debugDescription) isn't a key combination, such as cmd+s or return")
        }
        var modifiers: Set<KeyStroke.Modifier> = []
        for name in parts.dropLast() {
            guard let modifier = modifierNames[name] else {
                throw PaddockError("\(name.debugDescription) in \(combination.debugDescription) isn't a modifier: use cmd, ctrl, opt or shift")
            }
            modifiers.insert(modifier)
        }
        if let code = namedKeys[keyName] {
            return KeyStroke(code, modifiers)
        }
        let character = keyName == "plus" ? "+" : keyName
        guard character.count == 1, let typed = characters[Character(character)] else {
            throw PaddockError("\(keyName.debugDescription) in \(combination.debugDescription) isn't a key")
        }
        return KeyStroke(Int(typed.keyCode), modifiers.union(typed.modifiers))
    }

    static let modifierNames: [String: KeyStroke.Modifier] = [
        "cmd": .command, "command": .command, "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option, "shift": .shift,
    ]

    /// The modifier a Mac's modifier key holds, left or right: what a view's key events say
    /// when a modifier goes down or up. Nil for any other key.
    public static func modifier(forKeyCode code: Int) -> KeyStroke.Modifier? {
        switch code {
        case kVK_Shift, kVK_RightShift: .shift
        case kVK_Control, kVK_RightControl: .control
        case kVK_Option, kVK_RightOption: .option
        case kVK_Command, kVK_RightCommand: .command
        default: nil
        }
    }

    /// Keys that type no character, by name.
    public static let namedKeys: [String: Int] = [
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
        "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "escape": kVK_Escape, "esc": kVK_Escape,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    /// Every character a US ANSI keyboard types, with the key and whether Shift is held.
    static let characters: [Character: KeyStroke] = {
        var table: [Character: KeyStroke] = [:]
        let letters: [(Character, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
        ]
        for (letter, code) in letters {
            table[letter] = KeyStroke(code)
            table[Character(letter.uppercased())] = KeyStroke(code, [.shift])
        }
        // Each key with its character, then the character Shift gives it.
        let keys: [(Int, Character, Character)] = [
            (kVK_ANSI_1, "1", "!"), (kVK_ANSI_2, "2", "@"), (kVK_ANSI_3, "3", "#"), (kVK_ANSI_4, "4", "$"),
            (kVK_ANSI_5, "5", "%"), (kVK_ANSI_6, "6", "^"), (kVK_ANSI_7, "7", "&"), (kVK_ANSI_8, "8", "*"),
            (kVK_ANSI_9, "9", "("), (kVK_ANSI_0, "0", ")"), (kVK_ANSI_Minus, "-", "_"), (kVK_ANSI_Equal, "=", "+"),
            (kVK_ANSI_LeftBracket, "[", "{"), (kVK_ANSI_RightBracket, "]", "}"), (kVK_ANSI_Backslash, "\\", "|"),
            (kVK_ANSI_Semicolon, ";", ":"), (kVK_ANSI_Quote, "'", "\""), (kVK_ANSI_Comma, ",", "<"),
            (kVK_ANSI_Period, ".", ">"), (kVK_ANSI_Slash, "/", "?"), (kVK_ANSI_Grave, "`", "~"),
        ]
        for (code, plain, shifted) in keys {
            table[plain] = KeyStroke(code)
            table[shifted] = KeyStroke(code, [.shift])
        }
        table[" "] = KeyStroke(kVK_Space)
        table["\t"] = KeyStroke(kVK_Tab)
        table["\n"] = KeyStroke(kVK_Return)
        return table
    }()
}
