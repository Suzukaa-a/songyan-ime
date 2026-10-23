import Foundation

/// Information architecture of input configuration (shared by Host and keyboard).
///
/// A selection has two independent dimensions:
///  - Input method: a schema in the resource snapshot's enabled list (dynamic, any count, any name).
///  - Keyboard layout: a front-end keyboard capability (26 / 14 / 9 / custom key layout).
///
/// Availability is decided only by the resource set's real capabilities
/// (`availableCombinations` / `incompatibilityReason`); it is not tied to source identity and
/// hard-codes no schema ID or layout default.
///
/// A layout has only two states for an input method (fail-closed):
///  1. `isAvailable`: the combination can really run now (a capability the install
///     transaction generated and verified, or one the author bound explicitly).
///  2. Otherwise: not selectable, with a plain-language reason shown in place.
///
/// There is no third "tick now, prepare later" state, so `isSelectable == isAvailable`.
/// Adding a new compact keyboard is done by the separate "add keyboard" transaction
/// (published only after generation and verification succeed).
public struct InputConfigurationChoices: Equatable, Sendable {

    /// One keyboard layout option under an input method.
    public struct LayoutChoice: Equatable, Sendable, Identifiable {
        public let layout: KeyboardLayoutKind
        /// The combination is usable right now (capability generated and verified by the install
        /// transaction, or bound explicitly by the author). Only when true is it "available" and selectable.
        public let isAvailable: Bool
        /// Plain-language reason shown when unavailable; nil when available.
        public let reason: String?

        public var id: String { layout.rawValue }
        public var name: String { UserTerminology.layoutName(layout) }

        public init(layout: KeyboardLayoutKind, isAvailable: Bool, reason: String?) {
            self.layout = layout
            self.isAvailable = isAvailable
            self.reason = reason
        }

        /// Whether the user can select the combination. Selectable once installed; there is no "select first, probe later" path.
        public var isSelectable: Bool { isAvailable }
    }

    /// An input method (a schema in the resource snapshot) and the availability of each layout.
    public struct InputMethod: Equatable, Sendable, Identifiable {
        public let schema: KeyboardSchemaDescriptor
        public let layouts: [LayoutChoice]

        public var id: String { schema.id }
        public var name: String { UserTerminology.inputMethodName(schema) }
        /// Keyboard layouts that are really usable for this input method now.
        public var availableLayouts: [KeyboardLayoutKind] {
            layouts.filter(\.isAvailable).map(\.layout)
        }
    }

    public let inputMethods: [InputMethod]

    public init(resourceSet: KeyboardResourceSet) {
        inputMethods = Self.enabledDescriptors(resourceSet).map { schema in
            // Judge capability with the resource identity as if this input method were selected: it
            // matches the publication path used on start-using (`selecting(schemaID:)` plus the
            // same-source publication selection), so older resources do not under-report a directly usable 26-key.
            let scoped = resourceSet.selecting(schemaID: schema.id)
            let layouts = KeyboardLayoutKind.allCases.map { layout in
                let reason = scoped.incompatibilityReason(layout: layout, schemaID: schema.id)
                return LayoutChoice(layout: layout, isAvailable: reason == nil, reason: reason)
            }
            return InputMethod(schema: schema, layouts: layouts)
        }
    }

    /// Input methods in the enabled list. When `schemas` is empty but `layoutEntries` declare
    /// some (older resources / built-in package), the enabled list is those declared schemas, in
    /// the resource's declared display order; never hard-coded.
    private static func enabledDescriptors(_ resourceSet: KeyboardResourceSet) -> [KeyboardSchemaDescriptor] {
        if !resourceSet.schemas.isEmpty { return resourceSet.inputSchemeChoices }
        var seen = Set<String>()
        return resourceSet.layoutEntries
            .map(\.schemaID)
            .filter { seen.insert($0).inserted }
            .map { KeyboardSchemaDescriptor(id: $0, name: "") }
    }

    public var isEmpty: Bool { inputMethods.isEmpty }

    public func inputMethod(id: String) -> InputMethod? { inputMethods.first { $0.id == id } }

    public func layouts(for schemaID: String) -> [LayoutChoice] {
        inputMethod(id: schemaID)?.layouts ?? []
    }

    /// Really usable now (an installed fact). Unavailable means unselectable.
    public func isAvailable(schemaID: String, layout: KeyboardLayoutKind) -> Bool {
        layouts(for: schemaID).first { $0.layout == layout }?.isAvailable ?? false
    }

    public func reason(schemaID: String, layout: KeyboardLayoutKind) -> String? {
        layouts(for: schemaID).first { $0.layout == layout }?.reason
    }

    /// Supported keyboard layouts: the union of layouts really usable across all input methods (in built-in order).
    public var supportedLayouts: [KeyboardLayoutKind] {
        KeyboardLayoutKind.allCases.filter { layout in
            inputMethods.contains { method in
                method.layouts.contains { $0.layout == layout && $0.isAvailable }
            }
        }
    }

    /// First selectable layout for an input method: the preferred one if usable, otherwise the
    /// first available. Unavailable combinations never participate.
    public func firstAvailableLayout(
        for schemaID: String,
        preferred: KeyboardLayoutKind? = nil
    ) -> KeyboardLayoutKind? {
        let choices = layouts(for: schemaID)
        if let preferred, choices.contains(where: { $0.layout == preferred && $0.isSelectable }) {
            return preferred
        }
        return choices.first(where: \.isAvailable)?.layout
    }

    /// First input method that has a selectable layout (otherwise the first input method).
    public func firstUsableInputMethod() -> InputMethod? {
        inputMethods.first { !$0.availableLayouts.isEmpty } ?? inputMethods.first
    }

    /// Whether "start using" is enabled: a non-empty input method whose combination is already usable.
    public func canStartUsing(schemaID: String, layout: KeyboardLayoutKind) -> Bool {
        guard !schemaID.isEmpty else { return false }
        return layouts(for: schemaID).first { $0.layout == layout }?.isSelectable ?? false
    }
}
