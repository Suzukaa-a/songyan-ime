import Foundation

/// Runtime identity of a physical layout definition: proven (content-level, deterministic), unproven, or absent.
///
/// Unprovable identities never compare equal to anything (fail-closed):
///  - `.absent`: the call site has no definition (distinct from a definition that cannot be encoded);
///  - `.proven(canonical)`: deterministic content encoding succeeded (stable across calls and processes);
///  - `.unproven(id:)`: a definition exists but encoding failed.
///
/// `isProvablySame` is true only when both sides are `.proven` with identical content.
/// Any comparison involving `.unproven` or `.absent` is false, including `.absent` vs `.absent`,
/// so callers treat it as a change and never revive stale state.
public enum LayoutRuntimeIdentity: Equatable, Sendable {
    /// No definition (e.g. English mode, or none resolved).
    case absent
    /// Content-level identity derived from a deterministic encoding.
    case proven(String)
    /// A definition exists but its identity cannot be proven (encoding failed). The id is kept for diagnostics only, never for equality.
    case unproven(id: String)

    public init(proven canonical: String) {
        self = .proven(canonical)
    }

    /// Derives from an optional definition (`nil` becomes `.absent`).
    public init(_ definition: LayoutDefinition?) {
        guard let definition else {
            self = .absent
            return
        }
        self = definition.runtimeIdentity
    }

    /// The only entry point allowed to decide equality: true only when both sides are proven and identical.
    /// `.absent`, `.unproven` and mixed pairs are always false (unprovable counts as changed).
    public func isProvablySame(as other: LayoutRuntimeIdentity) -> Bool {
        guard case .proven(let lhs) = self, case .proven(let rhs) = other else { return false }
        return lhs == rhs
    }

    /// Diagnostics only: whether the identity is proven.
    public var isProven: Bool {
        if case .proven = self { return true }
        return false
    }
}

/// Deterministic content-level identity encoder (failure is injectable so tests can cover fail-closed).
public enum LayoutIdentityEncoder {
    /// Encoding unavailable.
    public struct EncodingUnavailable: Error {}

    /// Fields that affect key behavior (`name` / `note` are display-only and excluded).
    private struct Canonical: Encodable {
        let id: String
        let input: LayoutInput
        let rows: [LayoutRow]
        let auxiliaryAreas: [LayoutAuxiliaryArea]?
        let candidateArea: LayoutCandidateArea?
        let longPressDelay: Double?
        let split: LayoutSplitConfiguration?
    }

    /// The only identity entry point. `encode` is injectable; a throw yields `.unproven(id:)`,
    /// never an id posing as content identity and never a failure treated as equal.
    public static func identity(
        for definition: LayoutDefinition,
        encode: (LayoutDefinition) throws -> String = canonicalEncode
    ) -> LayoutRuntimeIdentity {
        do { return .proven(try encode(definition)) } catch { return .unproven(id: definition.id) }
    }

    /// Deterministic encoding: `.sortedKeys` plus non-finite floats as strings. No randomness, `Hasher` or `UUID`.
    public static func canonicalEncode(_ definition: LayoutDefinition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let canonical = Canonical(
            id: definition.id, input: definition.input,
            rows: definition.rows,
            auxiliaryAreas: definition.auxiliaryAreas,
            candidateArea: definition.candidateArea,
            longPressDelay: definition.longPressDelay, split: definition.split)
        let data = try encoder.encode(canonical)
        return String(decoding: data, as: UTF8.self)
    }
}

public extension LayoutDefinition {
    /// Stable, content-level runtime identity, consistent across calls and processes.
    ///
    /// Derived from the behavior-affecting content (id / input / rows including actions,
    /// long-press alternates and width weights / auxiliaryAreas / longPressDelay);
    /// `name` / `note` changes do not alter it.
    var runtimeIdentity: LayoutRuntimeIdentity {
        LayoutIdentityEncoder.identity(for: self)
    }
}
