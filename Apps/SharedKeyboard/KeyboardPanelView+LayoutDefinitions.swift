import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardPanelView {
    /// The physical layout a definition explicitly declares (builtinLayout only; schema-only definitions return nil).
    private func builtinKind(_ definition: LayoutDefinition) -> KeyboardLayoutKind? {
        return definition.input.builtinLayout.flatMap { KeyboardLayoutKind(rawValue: $0.rawValue) }
    }

    /// Resolves the physical KeyboardLayoutKind for a definition.
    ///  - With builtinLayout: it wins (an unknown builtin value newly added to LayoutKit -> nil,
    ///    the definition is not offered and no encoding is invented);
    ///  - schema-only (a valid LayoutKit form): key positions come from the definition's own rows, and the physical kind
    ///    resolves to the current controller.layout, inventing no new encoding;
    ///  - neither (rejected by LayoutKit validation): nil.
    /// An explicit schemaID is never reinterpreted as a builtinLayout: physical kind and schema binding
    /// are handled separately by this function and selectDefinition's joint switch.
    private func resolvedKind(_ definition: LayoutDefinition) -> KeyboardLayoutKind? {
        if let kind = builtinKind(definition) { return kind }
        return definition.input.schemaID == nil ? nil : controller.layout
    }

    private func supports(_ definition: LayoutDefinition) -> Bool {
        supports(definition, combinations: { controller.availableCombinations })
    }

    /// `availableCombinations` is derived on every access; a resolution pass
    /// hands in one lazily computed copy instead of rebuilding it per definition.
    private func supports(
        _ definition: LayoutDefinition,
        combinations: () -> [KeyboardResourceSet.Combination]
    ) -> Bool {
        guard let kind = resolvedKind(definition) else { return false }
        if let schemaID = definition.input.schemaID {
            return combinations().contains { $0.schemaID == schemaID && $0.layout == kind }
        }
        return controller.availableLayouts.contains(kind)
    }

    private var usableDefinitions: [LayoutDefinition] { definitionFacts.usable }

    var activeDefinition: LayoutDefinition? { definitionFacts.active }

    /// The resolved definition and every fact the renderer derives from it,
    /// memoized on exactly the inputs the resolution reads (see
    /// `DefinitionResolutionMemo`). Nearly every key consults these several
    /// times per render; recomputing them re-filtered all usable definitions and
    /// deep-compared the whole definition against each bundled layout per call.
    var definitionFacts: DefinitionResolutionMemo.Facts {
        definitionMemo.facts(
            for: .init(
                controller: ObjectIdentifier(controller),
                registry: layoutRegistry,
                preferredID: preferredDefinitionID,
                inputsRevision: controller.definitionInputsRevision)
        ) {
            resolveDefinitions()
        }
    }

    private func resolveDefinitions() -> (usable: [LayoutDefinition], active: LayoutDefinition?) {
        var combinations: [KeyboardResourceSet.Combination]?
        let lazyCombinations = {
            if let combinations { return combinations }
            let value = controller.availableCombinations
            combinations = value
            return value
        }
        let isSupported = { (definition: LayoutDefinition) in
            supports(definition, combinations: lazyCombinations)
        }
        var usable = layoutRegistry?.usableLayouts(where: isSupported) ?? BuiltinLayouts.all.filter(isSupported)
        if let id = selectedComposition?.mainLayoutID, let selected = layoutRegistry?.layout(id: id),
            isSupported(selected), !usable.contains(where: { $0.id == id })
        {
            usable.append(selected)
        }
        let selectable = usable.filter { definition in
            guard let bound = definition.input.schemaID else { return true }
            let source = controller.session.resourceSet?.sourceSchemaID(bound) ?? bound
            return source == controller.selectedSchemaID
        }
        if let selected = selectable.first(where: { $0.id == preferredDefinitionID }),
            resolvedKind(selected) == controller.layout
        {
            return (usable, selected)
        }
        // Without an explicit selection, a schema-only definition resolves to exactly the current kind; it must not
        // displace the builtin definition of the current physical layout by list order. Schema-only applies only when explicitly selected,
        // or when no builtin definition matches the current kind.
        return (
            usable,
            selectable.first(where: { builtinKind($0) == controller.layout })
                ?? selectable.first(where: { resolvedKind($0) == controller.layout })
        )
    }

    /// Applies a layout definition (lifecycle reconciliation and published-keyboard switching both go through here).
    /// There is **no** persistent write here: the keyboard has no "choose layout" user action; definitions are driven only by lifecycle
    /// state and the published list, and never written back to the host app's persisted selection.
    private func selectDefinition(_ definition: LayoutDefinition) {
        guard supports(definition), let kind = resolvedKind(definition) else { return }
        let schemaID = definition.input.schemaID
        let needsSchemaSwitch = schemaID != nil && schemaID != controller.selectedSchemaID
        // **Content-level** difference: the same id with changed rows/key action/input is a different physical definition
        // (comparing ids alone would let a stale lock keep working across definitions).
        let changesDefinition = !definition.runtimeIdentity
            .isProvablySame(as: LayoutRuntimeIdentity(activeDefinition))
        let transitionsLayout = kind != controller.layout || needsSchemaSwitch

        // **A true no-op returns before any side effect**: reselecting the current definition (same layout/schema/**content**)
        // does not clear eligibility or the picker lock.
        if !transitionsLayout, !changesDefinition {
            controller.updateCompactSpellingContext(
                eligible: CandidateReadingRowPolicy.needsEngineSpelling(definition),
                numericTransport: PhoneKeypadStructure.matches(definition),
                definitionIdentity: definition.runtimeIdentity,
                readingKeys: CompactSpellingLayout.readingKeyMap(for: definition))
            page = .letters
            showsAllCandidates = false
            return
        }

        // **Register the expected migration**: this old->target change is caused by the panel itself and the observation callback only consumes it,
        // instead of opening a second transaction (which would confirm one user selection twice).
        let fromIdentity = LayoutRuntimeIdentity(activeDefinition)
        let toIdentity = definition.runtimeIdentity
        definitionObservation.expect(from: fromIdentity, to: toIdentity)

        if transitionsLayout {
            // Core preflights the target schema and compatibility before confirming
            // the composition; failure keeps the current layout/schema.
            // An explicit schema binding (schema-only, or a schema change within the same kind) always uses the joint-switch
            // entry: layout and schema go to the session together, never silently falling back to a layout-only selection.
            if let schemaID {
                if let onSelectLayoutBound {
                    onSelectLayoutBound(kind, schemaID)
                } else {
                    controller.selectLayout(kind, boundSchemaID: schemaID)
                }
                // Adopt the local definition only after the joint switch succeeded (both layout and schema in place).
                guard controller.layout == kind, controller.selectedSchemaID == schemaID else {
                    definitionObservation.clear()
                    return
                }
            } else {
                if let onSelectLayout {
                    onSelectLayout(kind)
                } else {
                    controller.selectLayout(kind)
                }
                guard controller.layout == kind else {
                    definitionObservation.clear()
                    return
                }
            }
        } else if changesDefinition {
            // Same layout/schema but changed **content**: still must go through config-change confirmation; on failure the original
            // composition and definition are kept.
            guard controller.prepareForConfigurationChange() else {
                definitionObservation.clear()
                return
            }
        }
        // Success: the old picker is gone; authorize for the **target definition**.
        localLayoutID = definition.id
        // A local selection can update the rendered keys before SwiftUI observes the
        // derived report; hand the committed definition to the host in this transaction.
        onReadingRowReport?(
            CandidateReadingRowReport(
                eligible: CandidateReadingRowPolicy.isEligible(definition),
                definitionID: definition.id,
                resolvedFromRegistry: layoutRegistry != nil,
                candidateAreaRequired: definition.effectiveCandidateArea.candidates))
        controller.updateCompactSpellingContext(
            eligible: CandidateReadingRowPolicy.needsEngineSpelling(definition),
            numericTransport: PhoneKeypadStructure.matches(definition),
            definitionIdentity: definition.runtimeIdentity,
            readingKeys: CompactSpellingLayout.readingKeyMap(for: definition))
        page = .letters
        showsAllCandidates = false
    }

    /// Active definition changed: first ask the coordinator whether this is the explicit migration it just registered.
    ///  - yes -> consume only, open no transaction (the explicit path already settled once);
    ///  - no -> handle as a **real external change** (in-place content replacement under the same registry id, etc.).
    func handleActiveDefinitionObservation(
        from old: LayoutDefinition?,
        to new: LayoutDefinition?
    ) {
        let fromIdentity = LayoutRuntimeIdentity(old)
        let toIdentity = LayoutRuntimeIdentity(new)
        if definitionObservation.consume(from: fromIdentity, to: toIdentity) { return }
        handleExternalDefinitionContentChange(from: old, to: new)
    }

    /// External (registry) hot update: the **physical content** of the same id was replaced. It must use the same transaction as
    /// `selectDefinition`, and must never just flip a Bool and leave a stale lock usable under the new definition.
    ///
    /// On failure we cannot continue under the new definition: the composition is kept, but physical eligibility / picker fail closed and the old
    /// lock is **not** revived (a confirm failure is already surfaced via `session.onError -> controller.inputError`).
    private func handleExternalDefinitionContentChange(
        from old: LayoutDefinition?,
        to new: LayoutDefinition?
    ) {
        let previousIdentity = LayoutRuntimeIdentity(old)
        let newIdentity = LayoutRuntimeIdentity(new)
        // Only **provably identical content** counts as the same physical definition; `.unproven` / `.absent` are always treated as a change.
        guard !previousIdentity.isProvablySame(as: newIdentity) else { return }  // name/comment-only change
        if controller.prepareForConfigurationChange() {
            controller.updateCompactSpellingContext(
                eligible: new.map { CandidateReadingRowPolicy.needsEngineSpelling($0) } == true,
                numericTransport: new.map(PhoneKeypadStructure.matches) == true,
                definitionIdentity: newIdentity,
                readingKeys: CompactSpellingLayout.readingKeyMap(for: new))
        } else {
            // Failure: the registry already holds the new content, so the old qualification must not carry over
            // (a confirm failure is already surfaced via `session.onError -> controller.inputError`).
            controller.updateCompactSpellingContext(
                eligible: false,
                numericTransport: new.map(PhoneKeypadStructure.matches) == true,
                definitionIdentity: newIdentity)
        }
    }

    func reconcileDefinition() {
        let definitions = usableDefinitions
        let preferred = definitions.first { definition in
            guard definition.id == preferredDefinitionID,
                let kind = resolvedKind(definition)
            else { return false }
            // All lifecycle updates (including delayed defaults/registry loads)
            // restore appearance only. User actions call selectDefinition directly.
            guard kind == controller.layout else { return false }
            if let bound = definition.input.schemaID {
                let source = controller.session.resourceSet?.sourceSchemaID(bound) ?? bound
                guard source == controller.selectedSchemaID else { return false }
            }
            guard let resources = controller.session.resourceSet else { return true }
            guard let targetID = definition.input.schemaID ?? resources.schemaID(for: kind) else { return false }
            let schemaID = resources.sourceSchemaID(targetID)
            return resources.incompatibilityReason(layout: kind, schemaID: schemaID) == nil
                && resources.enabledMembershipReason(
                    schemaID: schemaID,
                    engineSchemas: controller.availableSchemas) == nil
        }
        if let definition = preferred ?? activeDefinition {
            let boundSchema = definition.input.schemaID
            if resolvedKind(definition) != controller.layout
                || boundSchema != nil && boundSchema != controller.selectedSchemaID
                || localLayoutID != definition.id
            {
                selectDefinition(definition)
            } else {
                // A lifecycle refresh (late registry, window relayout) must also keep eligibility and identity consistent with the current definition.
                controller.updateCompactSpellingContext(
                    eligible: CandidateReadingRowPolicy.needsEngineSpelling(definition),
                    numericTransport: PhoneKeypadStructure.matches(definition),
                    definitionIdentity: definition.runtimeIdentity,
                    readingKeys: CompactSpellingLayout.readingKeyMap(for: definition))
            }
        }
    }

    // MARK: User layout definitions
    var definitionControlRow: LayoutRow? { definitionFacts.controlRow }

    var isBundledDefinition: Bool { definitionFacts.isBundled }

    var definitionMainRows: [LayoutRow] { definitionFacts.mainRows }

    var configuredKeypad: some View {
        HStack(spacing: 4) {
            auxiliaryColumn(.leading)
            VStack(spacing: 4) {
                ForEach(Array(definitionMainRows.enumerated()), id: \.offset) { index, row in
                    definitionRow(
                        row, id: "row-\(index)", inset: definitionInset(row, index: index),
                        split: activeSplit, rowIndex: index)
                }
            }
            auxiliaryColumn(.trailing)
        }
    }
}

// MARK: - Physical definition resolution cache

/// Memo for `KeyboardPanelView.definitionFacts`.
///
/// The key holds exactly what the resolution reads: the controller (its
/// session, resource set and available layouts are fixed for its lifetime), the
/// published registry, the preferred definition id, and the live layout/schema.
/// Comparing an unchanged registry is O(1) because `Array ==` short-circuits on
/// shared storage, so a hit costs a few comparisons instead of a re-resolution.
/// Imperative paths (a layout switch followed by a rollback in the same call)
/// change the layout/schema part of the key and therefore always re-resolve.
final class DefinitionResolutionMemo {
    struct Key: Equatable {
        let controller: ObjectIdentifier
        let registry: LayoutRegistry?
        let preferredID: String?
        /// Assignment count of the controller's `layout` / `selectedSchemaID` (see `definitionInputsRevision`).
        let inputsRevision: UInt64
    }

    struct Facts {
        let usable: [LayoutDefinition]
        let active: LayoutDefinition?
        let isBundled: Bool
        let isBuiltinPhonePad: Bool
        /// Known bundled phone9 primary-gesture semantics, independent of the visual shell. Only
        /// first-key cycling / digit up-flick / declared alternates may read it; it must never gate
        /// the injected control row or rails.
        let isKnownPhone9Primary: Bool
        /// Structural main-shell identity for the bundled 26-key (letters + synthesized Shift/Delete).
        let isBundledQwertyMainShell: Bool
        /// Structural main-shell identity for the bundled 14/18-key merged pads (geometry + synthesized separator/Delete).
        let isBundledMergedPad: Bool
        /// The bundled footer policy draws its own control row; true only while the declared control
        /// row is still the preset (any footer edit falls back to the author row).
        let isBundledControlRowPolicy: Bool
        let isPhone: Bool
        let needsEngineSpelling: Bool
        let readingRowEligible: Bool
        let candidateAreaRequired: Bool
        let controlRow: LayoutRow?
        let mainRows: [LayoutRow]
        let hasGlobe: Bool

        init(usable: [LayoutDefinition], active: LayoutDefinition?) {
            self.usable = usable
            self.active = active
            let bundled = active.flatMap { definition in
                BuiltinLayouts.all.first {
                    $0.input.builtinLayout == definition.input.builtinLayout
                        && $0.rows == definition.rows && $0.auxiliaryAreas == definition.auxiliaryAreas
                }
            }
            let isBundled = bundled != nil
            self.isBundled = isBundled
            // Shell/chrome identity stays narrow: only the rendered main-row long-press menus may
            // differ, because injecting the fixed control row/rails would otherwise cover up authored
            // edits there. Primary gestures are a separate, shell-free predicate.
            isBuiltinPhonePad = active.map(BuiltinLayouts.matchesPhone9VisualShell) == true
            isKnownPhone9Primary = active.map(BuiltinLayouts.matchesPhone9PrimarySemantics) == true
            // The 26/14/18 shells are structural: main-row long-press, label and title edits keep
            // the native columns/Shift/Delete/separator geometry, while the footer identity below
            // stays separate so an edited control row is rendered instead of covered up.
            isBundledQwertyMainShell = active.map { BuiltinLayouts.matchesMainShell($0, as: .qwerty26) } == true
            switch active?.input.builtinLayout {
            case .some(.merged14):
                isBundledMergedPad = active.map { BuiltinLayouts.matchesMainShell($0, as: .merged14) } == true
                isBundledControlRowPolicy =
                    active.map { BuiltinLayouts.matchesControlRowPolicy($0, as: .merged14) } == true
            case .some(.merged18):
                isBundledMergedPad = active.map { BuiltinLayouts.matchesMainShell($0, as: .merged18) } == true
                isBundledControlRowPolicy =
                    active.map { BuiltinLayouts.matchesControlRowPolicy($0, as: .merged18) } == true
            case .some(.qwerty26):
                isBundledMergedPad = false
                isBundledControlRowPolicy =
                    active.map { BuiltinLayouts.matchesControlRowPolicy($0, as: .qwerty26) } == true
            default:
                isBundledMergedPad = false
                isBundledControlRowPolicy = false
            }
            isPhone = active.map(PhoneKeypadStructure.matches) == true
            needsEngineSpelling = CandidateReadingRowPolicy.needsEngineSpelling(active)
            readingRowEligible = CandidateReadingRowPolicy.isEligible(active)
            candidateAreaRequired = active?.effectiveCandidateArea.candidates ?? true
            // The bundled-style control row filter belongs to the visible bundled shell, not only to
            // the strict content identity: a long-press-only copy renders the same shell. When the
            // footer falls back to the author row the declaration must stay unfiltered.
            let controlRow = Self.controlRow(
                of: active,
                isBundled: isBundled || isBuiltinPhonePad || isBundledControlRowPolicy)
            self.controlRow = controlRow
            let rows = active?.rows ?? []
            mainRows = controlRow == nil ? rows : Array(rows.dropLast())
            hasGlobe =
                active.map { definition in
                    (definition.rows.flatMap(\.keys)
                        + (definition.auxiliaryAreas ?? [])
                        .filter { !$0.requiresEngineDisambiguation }.flatMap(\.keys))
                        .contains { $0.action.type == .globe }
                } ?? false
        }

        private static func controlRow(of definition: LayoutDefinition?, isBundled: Bool) -> LayoutRow? {
            guard let last = definition?.rows.last,
                last.keys.allSatisfy({ $0.action.type != .code && $0.action.type != .literal })
            else { return nil }
            if isBundled {
                let sideActions = (definition?.auxiliaryAreas ?? [])
                    .filter { !$0.requiresEngineDisambiguation }.flatMap(\.keys).map(\.action.type)
                return LayoutRow(
                    keys: last.keys.filter { key in
                        key.action.type != .modeSwitch && !sideActions.contains(key.action.type)
                    })
            }
            return last
        }
    }

    var key: Key?
    private var cached: Facts?

    func facts(
        for key: Key,
        resolve: () -> (usable: [LayoutDefinition], active: LayoutDefinition?)
    ) -> Facts {
        if let cached, self.key == key { return cached }
        let resolved = resolve()
        let facts = Facts(usable: resolved.usable, active: resolved.active)
        self.key = key
        cached = facts
        return facts
    }
}
