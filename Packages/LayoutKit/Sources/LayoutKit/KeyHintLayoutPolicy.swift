import Foundation

/// One policy for the small secondary hint drawn on a keycap.
///
/// The hint is either:
///  - the **syllable hint** for a shuangpin layout (`KeyCap.subtitle`, e.g. the
///    Xiaohe “ong/iong”, “iang/uang” table). These are genuinely long and a
///    single truncated line (“iang/u…”) carries no information, so they may use
///    a second line;
///  - the first **long-press alternate** (the digit / accent shown in the corner,
///    or the T9 digit under the letters). These stay one line: splitting them
///    would be meaningless;
///  - the **phone-key letters** label, whose current semantics must not change.
///
/// Only the hint text is affected. The policy returns line counts and heights;
/// it never moves the primary label, the key frame or the touch target — the
/// caller keeps the primary label's frame exactly as before and only sizes the
/// hint label inside the space it already owns.
public enum KeyHintLayoutPolicy {

    /// A hint never takes more than two lines.
    public static let maximumLines = 2
    /// A wrapped hint uses this fraction of the natural hint size, so its two
    /// lines still fit inside the corner band of a normal-height key.
    public static let wrappedFontScale: Double = 0.85
    /// A wrapped hint may shrink this far before it is truncated.
    public static let minimumScaleFactor: Double = 0.75
    /// Extra leading added between wrapped hint lines (points).
    public static let wrappedLineSpacing: Double = 0
    /// The one-line hint height used by the existing keycaps (points).
    public static let singleLineHeight: Double = 12

    public enum Kind: Equatable, Sendable {
        /// `KeyCap.subtitle` on a shuangpin key: the only kind that may wrap.
        case syllableHint
        /// The first long-press alternate (digits, accents) — never wrapped.
        case alternate
        /// The T9 number key's digit sub-label — never wrapped.
        case phoneLetters
    }

    /// Whether `kind` may ever use a second line.
    public static func allowsWrapping(_ kind: Kind) -> Bool {
        kind == .syllableHint
    }

    /// Number of lines the hint needs.
    ///
    /// - Parameters:
    ///   - measuredWidth: the text's single-line width in the hint font.
    ///   - availableWidth: the width the hint label actually has.
    /// A short hint stays on one line even when wrapping is allowed.
    public static func lineCount(
        kind: Kind, measuredWidth: Double,
        availableWidth: Double
    ) -> Int {
        guard allowsWrapping(kind) else { return 1 }
        guard measuredWidth.isFinite, availableWidth.isFinite,
            availableWidth > 0, measuredWidth > availableWidth
        else { return 1 }
        return maximumLines
    }

    /// The font scale a `lines`-line hint uses: two-line hints step down slightly
    /// so the wrapped block stays compact.
    public static func fontScale(lines: Int) -> Double {
        lines > 1 ? wrappedFontScale : 1
    }

    /// The hint label's height for `lines`, never smaller than the existing
    /// single-line height so short hints keep their current geometry.
    public static func height(
        lines: Int, lineHeight: Double,
        minimumHeight: Double = singleLineHeight
    ) -> Double {
        guard lines > 1, lineHeight.isFinite, lineHeight > 0 else { return minimumHeight }
        let wrapped = Double(lines) * lineHeight + wrappedLineSpacing
        return max(minimumHeight, wrapped)
    }

    /// The font scale a `lines`-line hint needs so its text is not truncated,
    /// clamped to the policy floor. Returns 1 when it already fits.
    public static func requiredScaleFactor(
        measuredWidth: Double, availableWidth: Double,
        lines: Int
    ) -> Double {
        guard measuredWidth.isFinite, availableWidth.isFinite,
            availableWidth > 0, measuredWidth > 0, lines > 0
        else { return 1 }
        let capacity = availableWidth * Double(lines)
        guard measuredWidth > capacity else { return 1 }
        return min(1, max(minimumScaleFactor, capacity / measuredWidth))
    }
}

public extension KeyHintLayoutPolicy {
    /// Gap between the per-letter hint columns of a merged key (points).
    static let columnGap: Double = 2

    /// Width of one per-letter hint column when `total` is split into `columns`.
    static func columnWidth(total: Double, columns: Int, gap: Double = columnGap) -> Double {
        guard columns > 0, total.isFinite, total > 0 else { return 0 }
        return max(0, (total - gap * Double(columns - 1)) / Double(columns))
    }
}
