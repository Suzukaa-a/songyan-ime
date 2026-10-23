import Foundation

/// Key code in librime's own keycode space.
///
/// librime's `process_key` takes an X11-keysym-style code (see the vendored
/// `X11/keysymdef.h` inside librime): printable ASCII passes through as the
/// character value ('a' = 0x61, space = 0x20), named editing keys use the
/// classic X11 values. Modifiers are librime `RimeModifier` bits.
public enum RimeKeyCode {
    // --- printable ASCII -------------------------------------------------
    public static let space: Int32 = 0x20
    public static let exclamation: Int32 = 0x21
    public static let quoteDouble: Int32 = 0x22
    public static let hash: Int32 = 0x23
    public static let dollar: Int32 = 0x24
    public static let percent: Int32 = 0x25
    public static let ampersand: Int32 = 0x26
    public static let apostrophe: Int32 = 0x27
    public static let leftParenthesis: Int32 = 0x28
    public static let rightParenthesis: Int32 = 0x29
    public static let asterisk: Int32 = 0x2A
    public static let plus: Int32 = 0x2B
    public static let comma: Int32 = 0x2C
    public static let hyphen: Int32 = 0x2D
    public static let period: Int32 = 0x2E
    public static let slash: Int32 = 0x2F
    public static let digit0: Int32 = 0x30
    public static let digit1: Int32 = 0x31
    public static let digit2: Int32 = 0x32
    public static let digit3: Int32 = 0x33
    public static let digit4: Int32 = 0x34
    public static let digit5: Int32 = 0x35
    public static let digit6: Int32 = 0x36
    public static let digit7: Int32 = 0x37
    public static let digit8: Int32 = 0x38
    public static let digit9: Int32 = 0x39
    public static let colon: Int32 = 0x3A
    public static let semicolon: Int32 = 0x3B
    public static let lessThan: Int32 = 0x3C
    public static let equal: Int32 = 0x3D
    public static let greaterThan: Int32 = 0x3E
    public static let question: Int32 = 0x3F
    public static let at: Int32 = 0x40
    public static let A: Int32 = 0x41
    public static let B: Int32 = 0x42
    public static let C: Int32 = 0x43
    public static let D: Int32 = 0x44
    public static let E: Int32 = 0x45
    public static let F: Int32 = 0x46
    public static let G: Int32 = 0x47
    public static let H: Int32 = 0x48
    public static let I: Int32 = 0x49
    public static let J: Int32 = 0x4A
    public static let K: Int32 = 0x4B
    public static let L: Int32 = 0x4C
    public static let M: Int32 = 0x4D
    public static let N: Int32 = 0x4E
    public static let O: Int32 = 0x4F
    public static let P: Int32 = 0x50
    public static let Q: Int32 = 0x51
    public static let R: Int32 = 0x52
    public static let S: Int32 = 0x53
    public static let T: Int32 = 0x54
    public static let U: Int32 = 0x55
    public static let V: Int32 = 0x56
    public static let W: Int32 = 0x57
    public static let X: Int32 = 0x58
    public static let Y: Int32 = 0x59
    public static let Z: Int32 = 0x5A
    public static let leftBracket: Int32 = 0x5B
    public static let backslash: Int32 = 0x5C
    public static let rightBracket: Int32 = 0x5D
    public static let caret: Int32 = 0x5E
    public static let underscore: Int32 = 0x5F
    public static let grave: Int32 = 0x60
    public static let a: Int32 = 0x61
    public static let b: Int32 = 0x62
    public static let c: Int32 = 0x63
    public static let d: Int32 = 0x64
    public static let e: Int32 = 0x65
    public static let f: Int32 = 0x66
    public static let g: Int32 = 0x67
    public static let h: Int32 = 0x68
    public static let i: Int32 = 0x69
    public static let j: Int32 = 0x6A
    public static let k: Int32 = 0x6B
    public static let l: Int32 = 0x6C
    public static let m: Int32 = 0x6D
    public static let n: Int32 = 0x6E
    public static let o: Int32 = 0x6F
    public static let p: Int32 = 0x70
    public static let q: Int32 = 0x71
    public static let r: Int32 = 0x72
    public static let s: Int32 = 0x73
    public static let t: Int32 = 0x74
    public static let u: Int32 = 0x75
    public static let v: Int32 = 0x76
    public static let w: Int32 = 0x77
    public static let x: Int32 = 0x78
    public static let y: Int32 = 0x79
    public static let z: Int32 = 0x7A
    public static let leftBrace: Int32 = 0x7B
    public static let pipe: Int32 = 0x7C
    public static let rightBrace: Int32 = 0x7D
    public static let tilde: Int32 = 0x7E
    public static let backspace: Int32 = 0x7F  // ASCII DEL; librime ignores this

    // --- X11 keysym editing keys (matches librime's keysymdef.h) ---------
    public static let keyBackspace: Int32 = 0xFF08
    public static let keyTab: Int32 = 0xFF09
    public static let keyReturn: Int32 = 0xFF0D  // Return / Enter
    public static let keyEscape: Int32 = 0xFF1B
    public static let keyDelete: Int32 = 0xFFFF  // forward delete
    public static let keyHome: Int32 = 0xFF50
    public static let keyLeft: Int32 = 0xFF51
    public static let keyUp: Int32 = 0xFF52
    public static let keyRight: Int32 = 0xFF53
    public static let keyDown: Int32 = 0xFF54
    public static let keyPageUp: Int32 = 0xFF55
    public static let keyPageDown: Int32 = 0xFF56
    public static let keyEnd: Int32 = 0xFF57

    /// Keycode for a printable ASCII character.
    public static func character(_ ch: Character) -> Int32? {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
            scalar.value >= 0x20, scalar.value <= 0x7E
        else { return nil }
        return Int32(scalar.value)
    }

    /// Lowercase ASCII keycode for a letter; passes other ASCII through.
    public static func baseKeycode(for printable: Character) -> Int32? {
        guard let code = character(printable) else { return nil }
        if code >= A, code <= Z { return code + 0x20 }
        return code
    }
}

/// librime modifier bits (`RimeModifier` in librime key_table.h).
public struct RimeModifier: OptionSet, Hashable, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let shift = RimeModifier(rawValue: 1 << 0)
    public static let lock = RimeModifier(rawValue: 1 << 1)
    public static let control = RimeModifier(rawValue: 1 << 2)
    public static let alt = RimeModifier(rawValue: 1 << 3)  // kMod1Mask
    public static let meta = RimeModifier(rawValue: 1 << 28)
}

/// One key press delivered to the engine.
public struct RimeKey: Hashable, Sendable {
    public let keycode: Int32
    public let modifiers: RimeModifier

    public init(keycode: Int32, modifiers: RimeModifier = []) {
        self.keycode = keycode
        self.modifiers = modifiers
    }

    /// Key from a printable ASCII character (letter keys are sent lowercase).
    public init?(character: Character, modifiers: RimeModifier = []) {
        guard let code = RimeKeyCode.baseKeycode(for: character) else {
            return nil
        }
        self.init(keycode: code, modifiers: modifiers)
    }
}

extension RimeKey {
    /// Convenience constants for the editing keys keyboards send.
    public static let backspace = RimeKey(keycode: RimeKeyCode.keyBackspace)
    public static let `return` = RimeKey(keycode: RimeKeyCode.keyReturn)
    public static let tab = RimeKey(keycode: RimeKeyCode.keyTab)
    public static let space = RimeKey(keycode: RimeKeyCode.space)
}
