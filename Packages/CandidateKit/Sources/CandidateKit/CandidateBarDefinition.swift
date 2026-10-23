import Foundation
import KeyboardCore

// MARK: - Errors

public struct CandidateBarError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Candidate area config (v1, frozen minimal schema)

/// Candidate area presentation config. It only describes "how to draw", never "which candidates to draw":
/// candidate data always comes from EngineSnapshot, and the renderer forwards `candidate.index` as-is.
///
/// Defaults are the cleanest current UX:
///   - no composition row without input (no placeholder, no schema technical info, no large raw-text confirm button);
///   - collapsed = a single horizontal row, paging at both ends and expand on the right;
///   - expanded current page = adaptive flow (laid out left to right by actual candidate text width, wrapping when full;
///     long words/comments take their own row to stay readable), not a fixed two-column grid.
public struct CandidateBarDefinition: Codable, Equatable, Identifiable, Sendable {
    public var formatVersion = 1
    public var id: String
    public var name: String
    public var author: String?
    public var compositionRow = CompositionRow()
    public var collapsed = Collapsed()
    public var expanded = Expanded()
    public var controls = Controls()

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let systemDefaultID = "system-default"

    /// The built-in system default: a 40pt collapsed strip. The text block of the 21pt default primary candidate
    /// is about 30pt, and 40pt already leaves about 5pt of touch margin above and below; the 44pt version leaves about
    /// 7pt each side, which on 14-key (which also has a reading row) adds up to a large empty top margin.
    public static let systemDefault: CandidateBarDefinition = {
        var bar = CandidateBarDefinition(id: systemDefaultID, name: "系统默认")
        bar.collapsed.height = 40
        bar.collapsed.cellPaddingX = 7
        bar.collapsed.cellSpacing = 0
        bar.collapsed.fillsAvailableWidth = false
        bar.expanded.rowSpacing = 0
        bar.expanded.columnSpacing = 0
        return bar
    }()

    // MARK: Composition row (preedit + raw code)

    /// Visibility rule of the composition row. Default `composingOnly`: the whole row is hidden without input (no placeholder text).
    public struct CompositionRow: Codable, Equatable, Sendable {
        public enum Visibility: String, Codable, CaseIterable, Sendable {
            /// Shown only while composing (default, the cleanest UX).
            case composingOnly
            /// Shown while composing; when the composition is empty, shows a faded raw-code row (optional for advanced users).
            case composingWithIdleRaw
            /// Never shown (compact).
            case hidden
        }
        public var visible = Visibility.composingOnly
        public init() {}
    }

    // MARK: Collapsed strip

    /// Parameters of the collapsed candidate strip. The height is the "full touch budget" and does not shrink with visual insets.
    public struct Collapsed: Codable, Equatable, Sendable {
        /// Strip height (pt). 36...56; the struct default is 44, while the built-in `systemDefault` uses 40.
        public var height: Double = 44
        /// Horizontal padding of a candidate cell (pt). 4...24; default 12.
        public var cellPaddingX: Double = 12
        /// Spacing between adjacent candidates (pt). 0...16; default 4.
        public var cellSpacing: Double = 4
        /// nil is the legacy config's even-split strategy; false uses natural text width. Preserved through copy/save.
        public var fillsAvailableWidth: Bool? = nil
        public init() {}
    }

    // MARK: Expanded list / grid

    /// Parameters of the "expand current page candidates" area. The expanded area replaces the main key row area (as today).
    public struct Expanded: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, CaseIterable, Sendable {
            /// Adaptive flow (default): lays candidates out left to right by actual text width, wrapping when a row is full;
            /// overly long candidates/comments take their own row. Short candidates are not spread out by fixed column widths.
            case adaptive
            /// One-column compact list (left-aligned, comments follow).
            case list
            /// Fixed column-count grid (respects an explicitly configured column count).
            case grid
        }
        /// Expanded layout mode. Default `adaptive` (flows by actual text width).
        public var mode = Mode.adaptive
        /// Grid column count 1...4 (used only by `grid`: `list` is always 1, `adaptive` ignores it). Default 2.
        public var columns: Int = 2
        /// Row spacing (pt). 0...16; default 4.
        public var rowSpacing: Double = 4
        /// Column spacing (pt). 0...16; default 4.
        public var columnSpacing: Double = 4
        /// A candidate whose text length exceeds this threshold (or whose comment exceeds 3x) takes its own row so long phrases stay readable;
        /// under `adaptive`, a candidate whose estimated width exceeds the available width also takes its own row. 1...40; default 8.
        public var fullRowTextLength: Int = 8
        public init() {}

        /// Whether the expanded layout adapts to text width (not a fixed column count).
        public var isAdaptive: Bool { mode == .adaptive }

        var effectiveColumns: Int { mode == .list ? 1 : columns }
    }

    // MARK: Paging / expand controls

    /// Placement rule for the paging and expand controls. The degradation order when space is short is
    /// decided by the default renderer; the config only expresses intent.
    public struct Controls: Codable, Equatable, Sendable {
        public enum PagePosition: String, Codable, CaseIterable, Sendable {
            /// Previous on the left, next on the right (default, symmetric at both ends).
            case both
            /// Only "previous/next page" on the right.
            case trailing
            /// Left side only.
            case leading
        }
        public var pagePosition = PagePosition.both
        /// Whether to show the "expand/collapse current page candidates" button. Default true.
        public var showsExpand = true
        public init() {}
    }

    // MARK: Derived (render budget)

    /// Layout budget of the collapsed strip (consumed by the renderer; invalid values are already rejected by
    /// decode/validate, this clamps once more as a guard against runtime writes). Shares its **source** with the
    /// surface/reported height (`effectiveHeight`), so configs of 36...43 cannot diverge across the three.
    public var collapsedHeightBudget: Double {
        Collapsed.effectiveHeight(collapsed.height)
    }

    /// The height when the expanded area replaces the main key area is decided by the host geometry; only content spacing is given here.
    public var expandedRowSpacing: Double { min(max(expanded.rowSpacing, 0), 16) }
    public var expandedColumnSpacing: Double { min(max(expanded.columnSpacing, 0), 16) }
    public var expandedEffectiveColumns: Int { min(max(expanded.effectiveColumns, 1), 4) }

    public func copy() -> Self {
        var copy = self
        copy.id = UUID().uuidString.lowercased()
        copy.name += " 副本"
        return copy
    }

    // MARK: Coding (strict fields + default filling, same discipline as SkinKit)

    private static let topLevelFields: Set<String> = [
        "formatVersion", "id", "name", "author", "compositionRow", "collapsed", "expanded", "controls",
    ]
    private static let compositionRowFields: Set<String> = ["visible"]
    private static let collapsedFields: Set<String> = ["height", "cellPaddingX", "cellSpacing", "fillsAvailableWidth"]
    private static let expandedFields: Set<String> = [
        "mode", "columns", "rowSpacing", "columnSpacing", "fullRowTextLength",
    ]
    private static let controlsFields: Set<String> = ["pagePosition", "showsExpand"]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 128 * 1024 else { throw CandidateBarError("$: JSON 超过 128KB") }
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CandidateBarError("$: 需要对象")
        }
        // V1 imports that omit height retain their original 44pt default.
        var defaults =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(CandidateBarDefinition(id: "", name: ""))) as! [String: Any]
        if var collapsed = defaults["collapsed"] as? [String: Any] {
            collapsed["height"] = 44
            defaults["collapsed"] = collapsed
        }
        defaults.removeValue(forKey: "id")
        defaults.removeValue(forKey: "name")
        func merge(
            _ input: [String: Any], _ base: [String: Any], _ path: String,
            _ allowed: (String) -> Set<String>
        ) throws -> [String: Any] {
            var result = base
            for (key, value) in input {
                guard allowed(path).contains(key) else { throw CandidateBarError("\(path).\(key): 未知字段") }
                if let object = value as? [String: Any] {
                    result[key] = try merge(object, base[key] as? [String: Any] ?? [:], "\(path).\(key)", allowed)
                } else {
                    result[key] = value
                }
            }
            return result
        }
        func allowedFields(at path: String) -> Set<String> {
            switch path {
            case "$": return topLevelFields
            case "$.compositionRow": return compositionRowFields
            case "$.collapsed": return collapsedFields
            case "$.expanded": return expandedFields
            case "$.controls": return controlsFields
            default: return []
            }
        }
        guard source["formatVersion"] as? Int == 1 else { throw CandidateBarError("$.formatVersion: 只支持 1") }
        let bar = try JSONDecoder().decode(
            Self.self,
            from: JSONSerialization.data(withJSONObject: merge(source, defaults, "$", allowedFields))
        )
        try bar.validate()
        return bar
    }

    public func validate() throws {
        func require(_ test: Bool, _ path: String) throws { if !test { throw CandidateBarError("\(path): 值无效") } }
        try require(formatVersion == 1, "$.formatVersion")
        try require(
            !id.isEmpty
                && id.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                }, "$.id")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "$.name")
        try require(collapsed.height.isFinite && (36...56).contains(collapsed.height), "$.collapsed.height")
        try require(
            collapsed.cellPaddingX.isFinite && (4...24).contains(collapsed.cellPaddingX), "$.collapsed.cellPaddingX")
        try require(
            collapsed.cellSpacing.isFinite && (0...16).contains(collapsed.cellSpacing), "$.collapsed.cellSpacing")
        try require(expanded.columns >= 1 && expanded.columns <= 4, "$.expanded.columns")
        try require(expanded.rowSpacing.isFinite && (0...16).contains(expanded.rowSpacing), "$.expanded.rowSpacing")
        try require(
            expanded.columnSpacing.isFinite && (0...16).contains(expanded.columnSpacing), "$.expanded.columnSpacing")
        try require(expanded.fullRowTextLength >= 1 && expanded.fullRowTextLength <= 40, "$.expanded.fullRowTextLength")
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 128 * 1024 else { throw CandidateBarError("$: JSON 超过 128KB") }
        return data
    }
}

extension CandidateBarDefinition.Collapsed {
    /// Render-time height clamp (a safety net after validate, not used to rewrite config).
    /// This is the legal range of the **config value** (36...56); it is not yet a usable surface height,
    /// see `effectiveHeight(_:)`.
    public static func clampedHeight(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 36), 56) : 36
    }

    /// The candidate top bar's base height is 36pt; larger primary candidate font sizes top up the budget by text line height.
    public static let minimumSurfaceHeight: Double = 36

    /// The configured range is then topped up for the primary candidate font size: candidate text line (1.25x font size) + underline and spacing.
    /// An explicit 44...56 config is unchanged while the font size needs no more than the configured value; larger font sizes may exceed 56.
    public static func effectiveHeight(_ value: Double, candidateSize: Double = 17) -> Double {
        let safeCandidateSize = candidateSize.isFinite ? max(0, candidateSize) : 17
        return max(clampedHeight(value), max(ceil(safeCandidateSize * 1.25 + 3), minimumSurfaceHeight))
    }
}
