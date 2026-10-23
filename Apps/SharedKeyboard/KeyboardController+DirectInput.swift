import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    // MARK: Input mode and direct input (common entry for digit/symbol keys and English mode)

    /// Sets the input mode (中/英). Switching to English first confirms the composition, so typed text is not lost.
    public func setInputMode(_ mode: InputMode) {
        if mode == .english && inputMode != .english {
            guard confirmReadingTarget() else { return }
        }
        session.setMode(mode)
        if inputMode == .english { reconcileAutomaticShift() }
    }

    /// Enabled only for front-end English direct input, outside composition, in fields that are not URL/email/numeric.
    var doubleSpacePeriodAllowed: Bool {
        guard inputMode == .english, !snapshot.isComposing else { return false }
        switch HostKeyboardTypeKind(keyboardType) {
        case .url, .emailAddress, .webSearch, .numberPad, .decimalPad, .asciiCapableNumberPad,
            .phonePad, .numbersAndPunctuation:
            return false
        default: return true
        }
    }

    public func toggleInputMode() {
        hostRestoredMode = nil
        automaticShiftArmed = false
        if inputMode == .english {
            setInputMode(.chinese)
        } else if snapshot.isAsciiMode {
            setOption("ascii_mode", value: false)
        } else {
            // Same as the system pinyin keyboard: switching to English during 26-key composition commits the typed letters
            // (hand return to the engine; Rime's default commit_raw_input), not the top candidate. On 14/9-key the raw code is
            // merged key codes, so keep confirming the candidate.
            if snapshot.isComposing, !session.compactSpellingLayout, !session.numericTransportLayout {
                inputError = nil
                session.tap(.enter)
            }
            setInputMode(.english)
        }
    }

    /// The UI's real English state: both front-end direct input and `ascii_mode` entered by Rime via
    /// key_binder/options. The latter still hands code keys to Rime; the front end only mirrors it and does not pose as owner.
    public var isEnglishMode: Bool { inputMode == .english || snapshot.isAsciiMode }

    /// Main key row for English direct input (standalone 26-key QWERTY); key-cap case follows the current Shift state,
    /// and the action is always lowercase `.code`. For Chinese mode use `KeyboardLayoutTable.mainRows(for:)`.
    public var englishLetterRows: [KeyboardRow] {
        KeyboardLayoutTable.englishRows(displayShift: shiftState)
    }

    // MARK: Shift (English direct-input three states; tap/double-tap timing is recognized in the UI, which then calls this controller)

    /// Shift only changes case within an already-English session. Chinese
    /// composition and its engine mode remain untouched; the explicit ABC/中文
    /// control is the sole language switch.
    public func handleShiftTap() {
        automaticShiftArmed = false
        session.tapShift()
    }

    /// Shift double-tap = English Caps Lock on/off.
    public func handleShiftDoubleTap() {
        automaticShiftArmed = false
        session.doubleTapShift()
    }

    // MARK: Cursor movement (relative offset; the host consumes it via onMoveCursor)

    /// Requests a relative cursor move of `offset` characters (negative = left). With an empty composition it
    /// forwards straight to `onMoveCursor`; while composing it first commits the current composition with
    /// confirm semantics, then moves (nothing is silently dropped). If `onMoveCursor` is nil it does nothing:
    /// the main app omits the callback when it cannot move the selection precisely, rather than pretending.
    public func moveCursor(by offset: Int) {
        // The tracked English word belongs to the old insertion point.
        resetEnglishWord()
        session.moveCursor(by: offset)
    }

    /// Inserts a piece of text directly (digit/symbol page keys and English-mode letters all come here):
    /// while composing it first confirms (`session.commitComposition`), then commits the text without going through the engine.
    /// True only when this literal reached a live host outlet. Partial composition
    /// commits do not count; public proxy APIs do not promise document acceptance.
    @discardableResult
    public func insertLiteral(_ text: String) -> Bool {
        punctuationCycle.reset()
        guard !text.isEmpty, confirmReadingTarget() else { return false }
        let completed = session.insertLiteral(text)
        if completed { ambiguityPicker.clear() }
        return completed
    }

    /// External clipboard/credential text reaches the same outlet but never seeds ABC learning.
    @discardableResult
    public func insertExternalLiteral(_ text: String) -> Bool {
        externalLiteralDepth += 1
        defer { externalLiteralDepth -= 1 }
        resetEnglishWord()
        return insertLiteral(text)
    }

    @discardableResult
    func dispatchCommit(_ text: String) -> Bool {
        guard !retired else { return false }
        let dispatched: Bool
        if let onDispatchCommit {
            dispatched = onDispatchCommit(text)
        } else if let onCommit {
            onCommit(text)
            dispatched = true
        } else {
            dispatched = false
        }
        if dispatched {
            commitSequence += 1
            if externalLiteralDepth == 0 { noteCommitForEnglishWord(text) }
        }
        return dispatched
    }
}
