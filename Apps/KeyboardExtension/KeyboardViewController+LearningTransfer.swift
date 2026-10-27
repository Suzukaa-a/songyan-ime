import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import OSLog
import SwiftUI
import UIKit

extension KeyboardViewController {
    // MARK: - Learning-data transfer (visible-period poll)

    /// Starts the visible-period poll for learning-data transfer.
    ///
    /// Rules:
    ///   * Runs only while this controller is visible and active; started in `viewDidAppear`, cancelled in
    ///     `viewWillDisappear` / `deinit`.
    ///   * After each sleep it reads only in-memory permission/ownership (`isBoundHost`, visibility, Full
    ///     Access); all disk I/O is done by `KeyboardLearningTransfer` on a dedicated background queue, so the
    ///     main thread never reads disk.
    ///   * Cancelling this task does not cancel a backup/merge already running (owned by the service's
    ///     process-wide worker); it only stops starting new checks.
    ///   * The ready phase is decided inside the service (session ready + no composition + no pending English
    ///     input + no input-recovery error), so no new ready observer is needed; if not satisfied now, it stays
    ///     pending until the next round.
    func startLearningTransferPolling() {
        guard learningTransferPollTask == nil else { return }
        learningTransferPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                // Re-evaluate after every sleep; never reuse the previous round's conclusion.
                guard isBoundHost, !self.hostInBackground,
                    self.viewIfLoaded?.window != nil,
                    self.pollFullAccess
                else { continue }
                // Both closures are evaluated live, with separate meanings:
                //   * visible + current controller: only for claiming new work (a hidden keyboard must not hold the engine);
                //   * Full Access only: for re-checking before each shared write of a running task, so the view disappearing
                //     mid-run does not interrupt completion while a revoked permission stops further shared writes at once.
                KeyboardLearningTransfer.check(
                    session: self.session,
                    isVisibleController: { [weak self] in
                        guard let self else { return false }
                        return isBoundHost
                            && self.viewIfLoaded?.window != nil
                    },
                    isFullAccessGranted: { [weak self] in self?.hasFullAccess ?? false })
            }
        }
    }

    func hostMovedToBackground(_ background: Bool) {
        hostInBackground = background
        if background {
            stopLearningTransferPolling()
            KeyboardFeedbackService.shared.stopKeyHaptics()
        } else if isBoundHost, viewIfLoaded?.window != nil {
            startLearningTransferPolling()
        }
    }

    /// Stops the poll (idempotent). Does not affect a backup/merge already running.
    func stopLearningTransferPolling() {
        learningTransferPollTask?.cancel()
        learningTransferPollTask = nil
    }
}
