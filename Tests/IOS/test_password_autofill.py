"""Native AutoFill setup: truthful navigation state and ephemeral form data."""
import sys
import unittest

from swift_probe import ROOT, run_swift, section

SOURCE = ROOT / "Apps/HostApp/PasswordAutoFillView.swift"


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class PasswordAutoFillModelTests(unittest.TestCase):
    def test_busy_errors_and_late_results_use_production_model(self):
        source = SOURCE.read_text()
        model = section(source, "@MainActor\nfinal class PasswordAutoFillModel:",
                        "// MARK: - Native AutoFill view")
        checks = r'''
import Foundation
import Combine

@MainActor final class PendingSettings {
    var callbacks: [PasswordAutoFillModel.Completion] = []
    let entered = DispatchSemaphore(value: 0)

    func open(_ completion: @escaping PasswordAutoFillModel.Completion) {
        precondition(Thread.isMainThread, "system navigation must start on MainActor")
        callbacks.append(completion)
        entered.signal()
    }

    func complete(_ index: Int, error: Error? = nil) {
        let callback = callbacks[index]
        DispatchQueue.global().async {
            precondition(!Thread.isMainThread)
            callback(error)
        }
    }
}

func waitForSignal(_ semaphore: DispatchSemaphore) async {
    let signaled = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
    precondition(signaled, "navigation request did not arrive")
}

@main struct Main {
    @MainActor static func main() async {
        let requests = PendingSettings()
        let model = PasswordAutoFillModel(openSettings: requests.open)
        let observer = model.objectWillChange.sink {
            precondition(Thread.isMainThread, "completed outcomes must be mirrored on main")
        }
        precondition(!model.isBusy && model.error == nil && requests.callbacks.isEmpty)
        precondition(model.openAutoFillSettings() == nil, "inactive view must not launch Settings")
        model.activate()
        let first = model.openAutoFillSettings()!
        precondition(model.isBusy && model.error == nil)
        precondition(model.openAutoFillSettings() == nil, "busy gate must register synchronously")
        await waitForSignal(requests.entered)
        precondition(requests.callbacks.count == 1 && model.isBusy)
        requests.complete(0)
        await first.value
        precondition(!model.isBusy && model.error == nil)
        print("PASS A1 initialization performs no navigation; busy gate prevents duplicate requests; successful completion adds no enabled/provider state")

        let failed = model.openAutoFillSettings()!
        await waitForSignal(requests.entered)
        let cancelled = NSError(domain: "AutoFillSettingsProbe", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Navigation cancelled"])
        requests.complete(1, error: cancelled)
        await failed.value
        precondition(!model.isBusy && model.error?.contains("Navigation cancelled") == true)
        precondition(model.error?.contains("无法打开密码自动填充设置") == true)
        let retry = model.openAutoFillSettings()!
        precondition(model.isBusy && model.error == nil)
        await waitForSignal(requests.entered)
        requests.complete(2)
        await retry.value
        precondition(!model.isBusy && model.error == nil)
        print("PASS A2 errors/cancellation report failure; retry clears stale error; callbacks from background publish only on MainActor")

        let stale = model.openAutoFillSettings()!
        await waitForSignal(requests.entered)
        model.deactivate()
        precondition(!model.isBusy && model.error == nil && model.openAutoFillSettings() == nil)
        model.activate()
        let current = model.openAutoFillSettings()!
        await waitForSignal(requests.entered)
        precondition(model.isBusy && requests.callbacks.count == 5)
        requests.complete(3, error: cancelled)
        await stale.value
        precondition(model.isBusy && model.error == nil, "old completion must not change a reappeared view/new request")
        requests.complete(4)
        await current.value
        precondition(!model.isBusy && model.error == nil)
        print("PASS A3 leaving cancels mirror publication, not already-started navigation; late old results cannot reset a new pending request")

        let leftImmediately = model.openAutoFillSettings()!
        model.deactivate()
        await leftImmediately.value
        precondition(requests.callbacks.count == 5, "leaving before the task starts must not send a navigation")
        precondition(!model.isBusy && model.error == nil)
        model.activate()
        let final = model.openAutoFillSettings()!
        await waitForSignal(requests.entered)
        requests.complete(5)
        await final.value
        precondition(requests.callbacks.count == 6 && !model.isBusy && model.error == nil)
        _ = observer
        print("PASS A4 a pre-dispatch lifecycle exit prevents navigation; reactivation remains usable")
    }
}
'''
        output = run_swift("import Foundation\nimport Combine\n" + model, checks,
                           prefix="password-autofill", library=True)
        print(output, end="")


if __name__ == "__main__":
    unittest.main()
