import Foundation
import KeyboardCore

public extension CompactSchemaAdapter {
    /// Everything needed to generate the compact companions of one source, computed once per
    /// source. The app's keyboard preparation and the bundled built-in companions both go
    /// through this, so a built-in scheme gets exactly what an installed scheme would.
    struct CompanionPlan {
        public let sourceID: String
        let compiled: Data
        let projection: SourceProjection
        /// Letter-group display: the source's unique normal codes; nil keeps the native display.
        let letterGroupDisplay: DisplayCapability?
        /// Phone-digit display: canonical pinyin, granted only to explicitly declared sources.
        let phoneDisplay: DisplayCapability?

        /// Throws when the source code display cannot be computed for a reason other than
        /// every token being ambiguous (that case is an evaluated native display).
        public init(
            compiled: Data, sourceID: String, projection: SourceProjection,
            sourceDelimiter: String?
        ) throws {
            self.sourceID = sourceID
            self.compiled = compiled
            self.projection = projection
            // Table (shape-code) sources keep a native display: there is no pinyin-canonical
            // display to make and a code display is not claimed.
            let isTableSource = CompactSchemaAdapter.autoAdaptableProducer(inCompiled: compiled)?.klass == .table
            do {
                letterGroupDisplay =
                    isTableSource
                    ? nil
                    : try CompactSchemaAdapter
                        .makeDisplayCapability(from: projection, displaySeparator: "'").capability
            } catch DisplayCapabilityError.emptyResolvedDomain {
                letterGroupDisplay = nil
            }
            if !isTableSource,
                CompactSchemaAdapter.declaresCanonicalPinyinSource(projection: projection),
                CompactSchemaAdapter.isCanonicalPinyinDomainAllowingBenignExtras(projection.syllables.map(\.token))
            {
                phoneDisplay = CompactSchemaAdapter.canonicalDisplayCapability(
                    sourceSchema: sourceID, separator: String(sourceDelimiter?.first ?? " "))
            } else {
                phoneDisplay = nil
            }
        }

        /// The companion schema for `fold`, or nil when the fold cannot type this source's own
        /// alphabet (a numeric key space only fits the 9-key layout), so the layout is skipped.
        public func companion(fold: CompactFold) throws -> Data? {
            guard CompactSchemaAdapter.physicalFold(sourceAlphabet: projection.alphabet, fold: fold) != nil else {
                return nil
            }
            return try CompactSchemaAdapter.generate(
                compiled: compiled, sourceID: sourceID, fold: fold,
                displayCapability: fold.isPhoneDigits ? phoneDisplay : letterGroupDisplay,
                sourceProjection: projection)
        }
    }
}
