import Foundation

public enum SkinAppearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

public struct SkinError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct SkinDefinition: Codable, Equatable, Identifiable, Sendable {
    public var formatVersion = 1
    public var id: String
    public var name: String
    public var author: String?
    public var variants = Variants()
    public var typography = Typography()
    public var keycap = Keycap()
    public var spacing = Spacing()
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
    public static let systemDefault: SkinDefinition = {
        var skin = SkinDefinition(id: "system-default", name: "系统默认")
        skin.typography.weight = "regular"
        skin.typography.keySize = 22
        skin.typography.secondarySize = 10
        skin.typography.candidateSize = 21
        skin.keycap.shadow = "none"
        skin.spacing.visualInsetX = 0
        skin.spacing.visualInsetY = 1
        var light = Variant()
        light.colors = [
            "panel": "#DFE2E7", "key": "#FAFBFC", "control": "#CBD0D8",
            "accent": "#CCDBEE", "accentText": "#284D7A", "text": "#252930",
            "secondaryText": "#505863", "selected": "#CCDBEE", "pressed": "#BEC8D6",
        ]
        var dark = Variant()
        dark.colors = [
            "panel": "#25272C", "key": "#44474E", "control": "#363940",
            "accent": "#3B536F", "accentText": "#F0F5FC", "text": "#F4F5F7",
            "secondaryText": "#BDC3CD", "selected": "#3B536F", "pressed": "#5A626F",
        ]
        skin.variants.light = light
        skin.variants.dark = dark
        return skin
    }()
    public struct Variants: Codable, Equatable, Sendable {
        public var light: Variant?
        public var dark: Variant?
        public init() {}
    }
    public struct Variant: Codable, Equatable, Sendable {
        public var colors: [String: String]?
        public var background: Background?
        public init() {}
    }
    public struct Background: Codable, Equatable, Sendable {
        public var type = "solid"
        public var color: String?
        public var from: String?
        public var to: String?
        public var direction: String?
        public init() {}
    }
    public struct Typography: Codable, Equatable, Sendable {
        public var family = "system"
        public var weight = "medium"
        public var keySize: Double = 22
        public var secondarySize: Double = 11
        public var candidateSize: Double = 20
        public init() {}
    }
    public struct Keycap: Codable, Equatable, Sendable {
        public var cornerRadius: Double = 6
        public var borderWidth: Double = 0
        public var shadow = "subtle"
        public init() {}
    }
    public struct Spacing: Codable, Equatable, Sendable {
        public var visualInsetX: Double = 2
        public var visualInsetY: Double = 2
        public init() {}
    }
    public static let colorNames = [
        "panel", "key", "control", "accent", "text", "secondaryText", "accentText", "pressed", "selected", "border",
    ]
    public func copy() -> Self {
        var copy = self
        copy.id = UUID().uuidString.lowercased()
        copy.name += " 副本"
        return copy
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 128 * 1024 else { throw SkinError("$: JSON 超过 128KB") }
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkinError("$: 需要对象")
        }
        // Imported skins retain the format's original omitted-field defaults.
        var defaults =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(SkinDefinition(id: "", name: "")))
            as! [String: Any]
        defaults.removeValue(forKey: "id")
        defaults.removeValue(forKey: "name")
        func merge(_ input: [String: Any], _ base: [String: Any], _ path: String) throws -> [String: Any] {
            let allowed: Set<String>
            switch path {
            case "$":
                allowed = ["formatVersion", "id", "name", "author", "variants", "typography", "keycap", "spacing"]
            case "$.variants": allowed = ["light", "dark"]
            case "$.variants.light", "$.variants.dark": allowed = ["colors", "background"]
            case let p where p.hasSuffix(".colors"): allowed = Set(colorNames)
            case let p where p.hasSuffix(".background"): allowed = ["type", "color", "from", "to", "direction"]
            default: allowed = Set(base.keys)
            }
            var result = base
            for (key, value) in input {
                guard allowed.contains(key) else { throw SkinError("\(path).\(key): 未知字段") }
                if let object = value as? [String: Any] {
                    result[key] = try merge(object, base[key] as? [String: Any] ?? [:], "\(path).\(key)")
                } else {
                    result[key] = value
                }
            }
            return result
        }
        guard source["formatVersion"] as? Int == 1 else { throw SkinError("$.formatVersion: 只支持 1") }
        let skin = try JSONDecoder().decode(
            Self.self, from: JSONSerialization.data(withJSONObject: merge(source, defaults, "$")))
        try skin.validate()
        return skin.normalized()
    }
    public func validate() throws {
        func require(_ test: Bool, _ path: String) throws { if !test { throw SkinError("\(path): 值无效") } }
        try require(formatVersion == 1, "$.formatVersion")
        try require(
            !id.isEmpty
                && id.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                }, "$.id")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "$.name")
        try require(["system", "rounded", "serif", "monospaced"].contains(typography.family), "$.typography.family")
        try require(["regular", "medium", "semibold"].contains(typography.weight), "$.typography.weight")
        for (path, value, range) in [
            ("typography.keySize", typography.keySize, 16.0...28.0),
            ("typography.secondarySize", typography.secondarySize, 10...16),
            ("typography.candidateSize", typography.candidateSize, 16...30),
            ("keycap.cornerRadius", keycap.cornerRadius, 0...16), ("keycap.borderWidth", keycap.borderWidth, 0...2),
            ("spacing.visualInsetX", spacing.visualInsetX, 0...6),
            ("spacing.visualInsetY", spacing.visualInsetY, 0...6),
        ] {
            try require(value.isFinite && range.contains(value), "$.\(path)")
        }
        try require(["none", "subtle"].contains(keycap.shadow), "$.keycap.shadow")
        for (mode, variant) in [("light", variants.light), ("dark", variants.dark)] {
            for (key, value) in variant?.colors ?? [:] {
                try require(
                    Self.colorNames.contains(key) && SkinColor(hex: value) != nil, "$.variants.\(mode).colors.\(key)")
            }
            if let b = variant?.background {
                let valid =
                    b.type == "solid"
                    ? (b.color.flatMap(SkinColor.init(hex:)) != nil && b.from == nil && b.to == nil
                        && b.direction == nil)
                    : (b.type == "linearGradient" && b.from.flatMap(SkinColor.init(hex:)) != nil
                        && b.to.flatMap(SkinColor.init(hex:)) != nil && b.direction == "vertical" && b.color == nil)
                try require(valid, "$.variants.\(mode).background")
            }
        }
    }
    public func normalized() -> Self {
        var result = self
        for dark in [false, true] {
            var variant = (dark ? variants.dark : variants.light) ?? Variant()
            variant.colors = resolvedColors(dark: dark).mapValues(\.hex)
            if dark { result.variants.dark = variant } else { result.variants.light = variant }
        }
        return result
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized())
        guard data.count <= 128 * 1024 else { throw SkinError("$: JSON 超过 128KB") }
        return data
    }
    public func resolvedColors(dark: Bool) -> [String: SkinColor] {
        let values =
            dark
            ? [
                "#202124", "#38393C", "#55565A", "#286CD8", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#65666A", "#55565A",
                "#808080",
            ]
            : [
                "#D1D3D9", "#FFFFFF", "#ADB2BC", "#145ACC", "#000000", "#333333", "#FFFFFF", "#C2C5CC", "#ADB2BC",
                "#777777",
            ]
        var colors = Dictionary(uniqueKeysWithValues: zip(Self.colorNames, values).map { ($0, SkinColor(hex: $1)!) })
        for (key, value) in (dark ? variants.dark : variants.light)?.colors ?? [:] {
            if let color = SkinColor(hex: value) { colors[key] = color }
        }
        colors["text"] = colors["text"]!.contrasting(on: colors["key"]!)
        colors["secondaryText"] = colors["secondaryText"]!.contrasting(on: colors["key"]!)
        colors["accentText"] = colors["accentText"]!.contrasting(on: colors["accent"]!)
        return colors
    }
}
public struct SkinColor: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double
    public init?(hex: String) {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        red = Double((value >> 16) & 255) / 255
        green = Double((value >> 8) & 255) / 255
        blue = Double(value & 255) / 255
    }
    public var hex: String {
        String(
            format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
            Int((blue * 255).rounded()))
    }
    private var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    public func contrast(on background: Self) -> Double {
        (max(luminance, background.luminance) + 0.05) / (min(luminance, background.luminance) + 0.05)
    }
    public func contrasting(on background: Self) -> Self {
        if contrast(on: background) >= 4.5 { return self }
        let black = Self(hex: "#000000")!, white = Self(hex: "#FFFFFF")!
        return black.contrast(on: background) >= white.contrast(on: background) ? black : white
    }
}
