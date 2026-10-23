import Combine
import Foundation

@main struct ExternalInsertMemoryChecks {
    @MainActor static func main() {
        let core = QuickInsertCore()
        let state = QuickInsertState(core: core)
        precondition(!state.hasRepeatableText && state.repeatPreview == nil)
        let ordinary = "ordinary\nuser commit"
        state.recordCommitted(ordinary)
        precondition(core.lastCommittedText == ordinary)
        precondition(state.hasRepeatableText && state.repeatPreview == "ordinary user commit")
        print("PASS: ordinary commits update the real Core and published repeat state")

        var previews: [String?] = []
        let observation = state.$repeatPreview.dropFirst().sink { previews.append($0) }
        let beforeFormat = state.selectedFormat
        var acceptedPayloads: [String] = []
        let external = "external successful payload"
        let accepted = state.withoutRecordingCommits {
            acceptedPayloads.append(external)
            state.recordCommitted(external)
            return true
        }
        precondition(accepted && acceptedPayloads == [external])
        precondition(core.lastCommittedText == ordinary && state.repeatPreview == "ordinary user commit")
        precondition(previews.isEmpty && state.selectedFormat == beforeFormat)
        print("PASS: accepted external payloads never replace repeat memory or publish a preview")

        let refused = state.withoutRecordingCommits {
            state.recordCommitted("external rejected payload")
            return false
        }
        precondition(!refused && core.lastCommittedText == ordinary && previews.isEmpty)
        state.recordCommitted("ordinary after refusal")
        precondition(core.lastCommittedText == "ordinary after refusal")
        precondition(previews == ["ordinary after refusal"])
        print("PASS: rejected external operations suppress callbacks and restore ordinary recording")

        let retained = core.lastCommittedText
        previews.removeAll()
        let outer = state.withoutRecordingCommits {
            state.recordCommitted("outer before nested operation")
            let innerSuccess = state.withoutRecordingCommits {
                state.recordCommitted("inner successful payload")
                return true
            }
            precondition(innerSuccess)
            state.recordCommitted("outer after successful inner operation")
            let innerFailure = state.withoutRecordingCommits {
                state.recordCommitted("inner refused payload")
                return false
            }
            precondition(!innerFailure)
            state.recordCommitted("outer after refused inner operation")
            return false
        }
        precondition(!outer && core.lastCommittedText == retained && previews.isEmpty)
        state.recordCommitted("ordinary after nested scope")
        precondition(core.lastCommittedText == "ordinary after nested scope")
        precondition(previews == [QuickInsertRecentText.preview(for: "ordinary after nested scope")])
        print("PASS: nested success and failure cannot prematurely restore commit recording")

        let emptyCore = QuickInsertCore()
        let empty = QuickInsertState(core: emptyCore)
        for result in [true, false] {
            let returned = empty.withoutRecordingCommits {
                empty.recordCommitted("external payload with no previous user commit")
                return result
            }
            precondition(returned == result)
            precondition(emptyCore.lastCommittedText == nil && !empty.hasRepeatableText && empty.repeatPreview == nil)
        }
        var repeatCalls = 0
        emptyCore.dispatchInsert = { _ in
            repeatCalls += 1
            return true
        }
        precondition(!empty.performRepeat() && repeatCalls == 0)
        print("PASS: external text cannot create a repeat target in an empty session")

        var repeatedTexts: [String] = []
        core.dispatchInsert = { text in
            repeatedTexts.append(text)
            state.recordCommitted(text)
            return true
        }
        let beforeExternal = core.lastCommittedText
        precondition(
            state.withoutRecordingCommits {
                state.recordCommitted("external text must not be repeated")
                return true
            })
        precondition(state.performRepeat())
        precondition(repeatedTexts == [beforeExternal!])
        precondition(core.lastCommittedText == beforeExternal)
        print("PASS: repeat still dispatches the previous ordinary commit, not external text")

        let resetResult = state.withoutRecordingCommits {
            state.resetContext()
            state.recordCommitted("external payload after focus reset")
            let nested = state.withoutRecordingCommits {
                state.recordCommitted("nested payload after focus reset")
                return true
            }
            precondition(nested)
            return false
        }
        precondition(!resetResult && core.lastCommittedText == nil)
        precondition(!state.hasRepeatableText && state.repeatPreview == nil)
        state.recordCommitted("ordinary in new field")
        precondition(core.lastCommittedText == "ordinary in new field" && state.hasRepeatableText)
        print("PASS: lifecycle reset clears old memory without lifting the active suppression scope")

        let separate = QuickInsertState(core: QuickInsertCore())
        precondition(
            state.withoutRecordingCommits {
                separate.recordCommitted("ordinary in separate session")
                state.recordCommitted("suppressed external text")
                return true
            })
        precondition(separate.core.lastCommittedText == "ordinary in separate session")
        precondition(state.core.lastCommittedText == "ordinary in new field")
        print("PASS: suppression is instance-local and does not affect another session")
        withExtendedLifetime(observation) {}
    }
}
