import KeyboardCore
import SwiftUI

// MARK: - Shared fixed candidate header surface (9 / 14 / 26)
//
// This file makes no claim that the 9/14/26 occlusions share one root cause. Two independent
// phenomena exist and are kept separate:
//
//  A. **idle (26/9, no input, no candidates)**: between the top of the keyboard's own rounded surface
//     and the first key row there is a fixed header band in the `panel` color. When idle it **draws no
//     content** (no fake description bar, no tools entry); under the system default its backing is
//     transparent and the iOS keyboard host surface shows through. It is a fixed vertical region that
//     never overlaps the key area, **not content overflowing**, and unrelated to candidate overflow.
//
//  B. **candidates (14/26, with candidates)**: each content branch of the old `compositionArea` owned its
//     own geometry with no single fitting owner; when a candidate cell was too tall for the budget
//     (comment line, large font, 36pt budget) it overflowed the fixed height and was covered by later
//     sibling layers. Now the budget is shared and fixed and the primary candidate fits at its native size.
//
// So this file's responsibility is limited to two provable things:
//   1. Make the header the **single geometry owner**: fixed height + fixed width + a background that the
//      system provides by default + content that **fits the budget** (no whole-block `.clipped()` hiding text).
//   2. Apply the z order **for real** (ZStack + `.zIndex`), not just declare constants.
//
// Blur/material/opacity<1/compositingGroup/mask are forbidden for normal candidates: this is a
// **visual constraint**, not a claim about the root cause of the idle phenomenon.

// MARK: Layout families (9/14/18/26)

/// Layout families the candidate top bar must distinguish. Production consumes them through
/// `offersAmbiguityPicker` / `usesPhoneShell` (see `KeyboardPanelView.compositionAreaContent`).
public enum CandidateHeaderLayout: String, CaseIterable, Identifiable, Sendable {
    case qwerty26
    case phone14
    case phone18
    case phone9

    public var id: String { rawValue }

    /// The 26-key layout never offers a composition disambiguation entry; it may appear only during nine/14-key Chinese composition.
    public var offersAmbiguityPicker: Bool { self != .qwerty26 }

    /// Nine-key uses the phone keyboard shell (left reading rail / right editing rail).
    public var usesPhoneShell: Bool { self == .phone9 }

    public init(layout: KeyboardLayoutKind) {
        switch layout {
        case .qwerty26: self = .qwerty26
        case .merged14: self = .phone14
        case .merged18: self = .phone18
        case .phone9: self = .phone9
        }
    }
}

// MARK: Content kinds (the pure result of layout x state)

/// The content kind the fixed top bar must present for this one "layout x state".
///
/// Composing without candidates is a real engine edge state: an actionable text hint within the fixed budget,
/// never fabricated candidates, raw code or a second input state.
public enum CandidateHeaderContent: String, CaseIterable, Sendable {
    /// No candidates, no status: a bare surface (only layout/disambiguation entries).
    case idle
    /// The engine still holds a composition but there are no candidates; hints to backspace and edit, never fabricates words from the raw code.
    case compositionWithoutCandidates
    /// Real candidates in a horizontal strip (collapsed).
    case candidates
    /// Expanded candidate browsing; the top bar still uses the same fixed budget and adds no height.
    case candidatesExpanded
    /// No candidates but a status hint: fills the same budget, no extra overlay.
    case status
}

// MARK: Single policy

public enum CandidateHeaderSurfacePolicy {
    /// Visual constraint: normal candidates are not drawn with blur/material/translucency.
    /// Production satisfies it by never calling blur/material and drawing the content layer fully opaque;
    /// tests verify candidate text opacity (alpha and luminance) on **real rendered pixels**, not just this constant.
    public static let forbidsBlurMaterialOpacityForNormalCandidates = true

    /// Real z order (`CandidateHeaderSurface` sets `.zIndex` from it). Only the two layers that are
    /// really drawn exist: background below content; candidates/status/controls all belong to the
    /// content layer and are ordered inside it.
    public static func zIndex(_ layer: CandidateHeaderLayer) -> Double {
        switch layer {
        case .background: return 0
        case .content: return 1
        }
    }

    /// When the definition needs a candidate area, the top bar always fills the configured budget: how much content there is,
    /// or whether composing, never changes the total keyboard height. The budget is topped up by `effectiveHeight` for the primary candidate font size, typically 36pt.
    public static func surfaceHeight(configured: Double, candidateSize: Double = 17) -> Double {
        CandidateBarDefinition.Collapsed.effectiveHeight(configured, candidateSize: candidateSize)
    }

    /// Layout x state -> content kind. Shared by the production panel and tests.
    ///
    /// `hasCandidates` is the gate for candidate content; when there are no candidates but the engine is still composing,
    /// a real status hint is shown, so leftover raw code after a partial commit does not look fully idle.
    public static func content(
        layout: CandidateHeaderLayout,
        isEnglish: Bool,
        isComposing: Bool,
        hasCandidates: Bool,
        hasStatus: Bool,
        isExpanded: Bool
    ) -> CandidateHeaderContent {
        if hasCandidates { return isExpanded ? .candidatesExpanded : .candidates }
        if hasStatus { return .status }
        if isEnglish { return .idle }
        return isComposing ? .compositionWithoutCandidates : .idle
    }
}

/// The layers actually drawn inside the top bar (used by `CandidateHeaderSurface`'s real `.zIndex`).
public enum CandidateHeaderLayer: Sendable {
    case background
    case content
}

// MARK: Explicit tools entry when the top bar is not visible (visible indicator + direct accessibility action)

/// Visible long-press menu indicator on the language key (a real drawn corner mark, not documentation).
///
/// Production (`CharacterButton.configure` in `KeyboardPanelView`) draws `indicatorGlyph`,
/// hinting that long-pressing the key opens the published keyboard switch list (ending with "更多工具").
public enum KeyboardToolsAffordance {
    /// The visible menu indicator on the language key (a real drawn corner mark, not documentation).
    public static let indicatorGlyph = "•••"
    /// Lower bound of the hit budget (same as core keys).
    public static let minimumHitTarget: Double = 44
}

// MARK: Top-bar visibility (production pure policy)

/// Input facts of top-bar visibility (all from real controller/host state).
public struct CandidateHeaderVisibilityInput: Equatable, Sendable {
    public var isEnglish: Bool
    public var hasCandidates: Bool
    public var hasStatus: Bool
    public var hasAmbiguityPicker: Bool
    /// In-keyboard preview of the whole composition when the host's marked text is unavailable (`keyboardCompositionFallback`).
    public var hasCompositionFallback: Bool
    /// Nine-key candidate reading filter in progress (the top bar shows the filter row).
    public var isReadingFiltering: Bool

    public init(
        isEnglish: Bool, hasCandidates: Bool, hasStatus: Bool,
        hasAmbiguityPicker: Bool, hasCompositionFallback: Bool,
        isReadingFiltering: Bool
    ) {
        self.isEnglish = isEnglish
        self.hasCandidates = hasCandidates
        self.hasStatus = hasStatus
        self.hasAmbiguityPicker = hasAmbiguityPicker
        self.hasCompositionFallback = hasCompositionFallback
        self.isReadingFiltering = isReadingFiltering
    }
}

/// The single pure policy deciding whether the top bar carries **real input content**
/// (candidates / status / disambiguation / composition fallback / reading filter).
///
/// This is **not** a decision about whether the bar takes height: the candidate/status band takes the same
/// fixed budget in every state (see `KeyboardPanelGeometry.fixedPanelHeight`), so the key area never jumps.
/// The policy only decides **what** is drawn inside that fixed budget: input content when there is real content,
/// nothing when fully idle (no fake description bar, no tools entry). It therefore never affects the keyboard shell height and never hides real state.
public enum CandidateHeaderVisibility {
    public static func showsHeader(_ input: CandidateHeaderVisibilityInput) -> Bool {
        if input.hasCandidates { return true }
        if input.hasStatus { return true }
        if input.hasAmbiguityPicker { return true }
        if input.hasCompositionFallback { return true }
        if input.isReadingFiltering { return true }
        // English idle: no real input content; nothing is drawn.
        _ = input.isEnglish
        return false
    }
}

// MARK: - Idle state (no candidates, no status, no disambiguation, no fallback, no reading filter)
//
// When fully idle, the keyboard draws no candidate/status band content (no fake description bar). The fixed budget is
// still reserved so the key area does not jump; under the system default that band's backing is transparent and the iOS keyboard host surface shows through.

// MARK: Shared fixed surface

/// The fixed candidate header surface shared by 9/14/26.
///
/// Invariants:
///  - **Fixed height**: `surfaceHeight(configured:)`.
///  - **Fixed width**: fills the parent, leading-aligned.
///  - **Background layer**: `backing` is a separate background layer (a real `.zIndex(0)`); under the
///    system default the caller passes `.clear` and the iOS keyboard host surface shows through.
///  - **Content fits the budget**: the caller makes content fit (`CandidateCollapsedFlow`'s
///    `estimatedBlockHeight`/`fittedBlockHeight`, **no whole-block scaling**); the fixed geometry does not
///    rely on clipping the content. Scrolling candidates must draw at their native font size and never hand text to an outer clip.
@available(iOS 17.0, macOS 14.0, *)
public struct CandidateHeaderSurface<Content: View>: View {
    public let height: Double
    public let candidateSize: Double
    public let backing: Color
    @ViewBuilder public var content: () -> Content

    public init(
        height: Double, candidateSize: Double = 17, backing: Color,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.height = height
        self.candidateSize = candidateSize
        self.backing = backing
        self.content = content
    }

    public var body: some View {
        // Content sits on the band's bottom edge, a fixed distance above the keys:
        // extra height the shell gives the band (`KeyboardPanelGeometry.fit`) opens
        // above the candidates instead of floating them away from the keyboard.
        ZStack(alignment: .bottomLeading) {
            // Real background layer: its zIndex is explicitly below the content, so it never competes with content for z order.
            backing
                .zIndex(CandidateHeaderSurfacePolicy.zIndex(.background))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .zIndex(CandidateHeaderSurfacePolicy.zIndex(.content))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .frame(
            height: max(
                CGFloat(height),
                CGFloat(
                    CandidateHeaderSurfacePolicy.surfaceHeight(
                        configured: height, candidateSize: candidateSize)))
        )
        // In addition to the leaf ScrollView, apply iOS 26's edge-effect policy
        // on its *container*. Nested candidate scrollers then inherit one
        // sharp edge policy regardless of the caller's layout or extra stacks.
        .sharpCandidateScrollEdges()
        // Content fits this budget in the renderer. Clipping a ZStack around a
        // nested ScrollView can force the glyphs through an offscreen surface;
        // keep only the fixed frame and let the scroll view own its viewport.
        .contentShape(Rectangle())
    }
}
