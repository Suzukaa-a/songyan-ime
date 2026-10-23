import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    // MARK: ABC word guessing (the current input scheme's own English candidates, read-only session)

    static let englishSuggestionLimit = 3
    /// Raw candidates scanned per query: a pinyin scheme mixes Chinese results in.
    nonisolated static let englishCandidateScan = 40

    /// The scheme the user installed, not a layout adapter or a fixed recipe id:
    /// whatever English translator that source mounts is what ABC suggests from.
    private var englishSourceSchemaID: String {
        session.resourceSet?.sourceSchemaID(selectedSchemaID) ?? selectedSchemaID
    }

    func releaseWordSession() {
        englishQueryTask?.cancel()
        // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
        nonisolated(unsafe) let engine = session.engine
        Task { @MainActor in try? await EngineOpQueue.async { engine.releaseWordCompletions() } }
    }

    func probeEnglishSuggestions() {
        let source = englishSourceSchemaID
        // Probed on ABC entry only: the probe opens a second engine session, which
        // Chinese-only use of the keyboard should never pay for.
        guard !retired, isEnglishMode, !source.isEmpty, englishProbeSchemaID != source else { return }
        englishProbeSchemaID = source
        // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
        nonisolated(unsafe) let engine = session.engine
        Task { @MainActor in
            let chosen: String?
            do {
                chosen = try await EngineOpQueue.async {
                    for schemaID in try engine.wordCompletionSchemas(sourceSchemaID: source) {
                        let words =
                            try engine.wordCompletions(
                                prefix: "th", schemaID: schemaID,
                                limit: Self.englishCandidateScan) ?? []
                        if Self.englishWords(words).count >= 2 { return schemaID }
                    }
                    return nil
                }
            } catch {
                // Engine not ready / session suspended: not evidence of "unsupported".
                // The next ABC entry probes again.
                if englishProbeSchemaID == source { englishProbeSchemaID = nil }
                return
            }
            guard !retired, session.engine === engine, englishSourceSchemaID == source else {
                if englishProbeSchemaID == source { englishProbeSchemaID = nil }
                return
            }
            englishWordSchemaID = chosen
            let supported = englishWordSchemaID != nil
            if englishSuggestionsSupported != supported { englishSuggestionsSupported = supported }
            // Input may have arrived while the capability probe was outstanding.
            // Reconcile the current word (or prediction slots), never the probe's prefix.
            if isEnglishMode { scheduleEnglishSuggestions() }
        }
    }

    /// Letters (and inner apostrophes, `I've`) extend the word; a space finishes it
    /// and makes it the context for next-word guesses; anything else ends both.
    func noteCommitForEnglishWord(_ text: String) {
        guard isEnglishMode, !text.isEmpty else {
            englishWord = ""
            previousEnglishWord = nil
            scheduleEnglishSuggestions()
            return
        }
        for character in text {
            if character.isASCII && character.isLetter
                || (character == "'" || character == "’") && !englishWord.isEmpty
            {
                englishWord.append(character)
            } else if character == " " {
                guard !englishWord.isEmpty else { continue }
                if let previous = previousEnglishWord { nextWords.learn(previous, englishWord) }
                previousEnglishWord = englishWord
                englishWord = ""
            } else {
                englishWord = ""
                previousEnglishWord = nil
            }
        }
        scheduleEnglishSuggestions()
    }

    /// The host moved the insertion point or changed the document.
    public func resetEnglishWord() {
        englishDocumentGeneration &+= 1
        // These flags belong to the old insertion point even when no word or
        // suggestions are buffered (for example after an English digit + space).
        lastEnglishInputWasWordChar = false
        doubleSpaceArmedAt = nil
        guard !englishWord.isEmpty || previousEnglishWord != nil || !englishSuggestions.isEmpty else { return }
        englishWord = ""
        previousEnglishWord = nil
        scheduleEnglishSuggestions()
    }

    /// Next-word guesses shaped for the position: capitalized when the host armed
    /// automatic capitalization (sentence start).
    private func nextWordSuggestions() -> [String] {
        guard let previous = previousEnglishWord else { return [] }
        let capitalize = shiftState != .off
        return nextWords.predictions(after: previous, limit: Self.englishSuggestionLimit).map { word in
            capitalize ? word.prefix(1).uppercased() + word.dropFirst() : word
        }
    }

    func scheduleEnglishSuggestions() {
        englishQueryTask?.cancel()
        let word = englishWord
        if isEnglishMode, word.isEmpty {
            englishQueryTask = nil
            let slots = ABCSuggestionSlots.enginePredictions(session.snapshot, limit: Self.englishSuggestionLimit)
            englishEnginePredictionTexts = slots.map(\.text)
            if !slots.isEmpty {
                // Right after an engine commit: the engine's own predictions.
                englishEnginePredictionIndices = slots.map(\.index)
                englishSuggestionsArePredictions = true
                if englishSuggestions != englishEnginePredictionTexts {
                    englishSuggestions = englishEnginePredictionTexts
                }
                return
            }
            // Between words: guess the next one from the word just finished.
            englishEnginePredictionIndices = []
            let guesses = nextWordSuggestions()
            englishSuggestionsArePredictions = !guesses.isEmpty
            if englishSuggestions != guesses { englishSuggestions = guesses }
            return
        }
        englishEnginePredictionIndices = []
        guard englishSuggestionsSupported == true, isEnglishMode, !word.isEmpty,
            let schemaID = englishWordSchemaID
        else {
            englishQueryTask = nil
            englishSuggestionsArePredictions = false
            if !englishSuggestions.isEmpty { englishSuggestions = [] }
            return
        }
        // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
        nonisolated(unsafe) let engine = session.engine
        // The previous row stays until the new one is ready: one row swap, no blank.
        englishQueryTask = Task { @MainActor in
            // Coalesce fast typing: only the word the user pauses on is queried, so
            // the serial engine queue is not filled ahead of the next key.
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
            let words = try? await EngineOpQueue.async {
                try engine.wordCompletions(
                    prefix: word.lowercased(), schemaID: schemaID,
                    limit: Self.englishCandidateScan)
            }
            guard !Task.isCancelled, !retired, session.engine === engine, englishWord == word else { return }
            let shaped = Self.shapeEnglishSuggestions(Self.englishWords(words ?? []), typed: word)
            englishSuggestionsArePredictions = false
            if englishSuggestions != shaped { englishSuggestions = shaped }
        }
    }

    /// Keep only single English words (letters with inner apostrophes/hyphens).
    nonisolated static func englishWords(_ candidates: [String]) -> [String] {
        candidates.filter { word in
            guard let first = word.first, first.isASCII, first.isLetter else { return false }
            return word.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'" || $0 == "-") }
        }
    }

    /// Match the typed capitalization, drop duplicates, keep engine order.
    static func shapeEnglishSuggestions(_ words: [String], typed: String) -> [String] {
        let allCaps = typed.count > 1 && typed.allSatisfy(\.isUppercase)
        let capitalized = typed.first?.isUppercase == true
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            let shaped =
                allCaps
                ? word.uppercased()
                : capitalized ? word.prefix(1).uppercased() + word.dropFirst() : word
            guard seen.insert(shaped.lowercased()).inserted else { continue }
            result.append(shaped)
            if result.count == englishSuggestionLimit { break }
        }
        return result
    }

    /// Replace the word being typed with a suggestion and a trailing space.
    /// A next-word guess is inserted as is, then guesses continue from it.
    public func selectEnglishSuggestion(_ word: String) {
        guard isEnglishMode, let slot = englishSuggestions.firstIndex(of: word) else { return }
        if !englishEnginePredictionIndices.isEmpty, englishWord.isEmpty {
            // An engine prediction: select it there, so it commits and predicts again.
            guard slot < englishEnginePredictionIndices.count, session.snapshot.isPrediction else { return }
            session.selectCandidate(englishEnginePredictionIndices[slot])
            return
        }
        if englishSuggestionsArePredictions, englishWord.isEmpty {
            _ = dispatchCommit(word + " ")
            return
        }
        let typedWord = englishWord
        let documentGeneration = englishDocumentGeneration
        guard !typedWord.isEmpty else { return }
        // Reading the host may discover a new document and reset our word. Keep
        // that rejection inside this operation; never retry through delete/commit.
        guard let context = onReadDocumentContext?(),
            englishDocumentGeneration == documentGeneration, englishWord == typedWord,
            context.hasSuffix(typedWord),
            onReplaceLiteralSuffix?(
                String(context.suffix(T9PunctuationCycle.contextLimit)),
                typedWord, word + " ") == true
        else {
            resetEnglishWord()
            return
        }
        deleteSequence += typedWord.count
        commitSequence += 1
        englishWord = ""
        lastEnglishInputWasWordChar = false
        doubleSpaceArmedAt = nil
        punctuationCycle.reset()
        noteCommitForEnglishWord(word + " ")
    }
}
