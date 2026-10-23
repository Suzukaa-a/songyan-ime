"""One-action scheme update: compiles the production update chain out of the center and drives
it with a scripted downloader, installer and source steps (success, failure, cancel, changed state).
"""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section

CENTER = "Apps/HostApp/SchemeImportCenter+Update.swift"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class SchemeUpdateDirectTests(unittest.TestCase):
    def test_update_flow_decides_from_real_install_state(self):
        text = (ROOT / CENTER).read_text()
        outcome = section(text, "    enum SchemeUpdateOutcome",
                          "\n    /// Update an installed scheme from its recorded download address")
        update = section(text, "    /// Update an installed scheme from its recorded download address",
                         "\n    /// The publication the keyboard used when an update started")
        capture = section(text, "    /// The publication the keyboard used when an update started",
                          "\n    /// Update an installed scheme that came from a Rime source expression")
        source_update = section(text, "    /// Update an installed scheme that came from a Rime source expression",
                                "\n}\n")
        harness = SOURCE
        for marker, block in (("// OUTCOME", outcome), ("// UPDATE", update), ("// CAPTURE", capture),
                              ("// SOURCE_UPDATE", source_update)):
            if "func " not in block and "enum " not in block and "struct " not in block:
                raise AssertionError("production block not found: " + marker)
            harness = harness.replace(marker, block)
        with scratch_directory("scheme-update-direct") as directory:
            generated = directory / "SchemeUpdateProbe.swift"
            generated.write_text(harness)
            binary = compile_swift(directory, [generated], library=True)
            print(run([str(binary)]), end="")

SOURCE = r'''
import Foundation

// MARK: - Types the production block talks to

enum RecipeInstallError: Error { case invalidResource(String), deployment(String), busy }

enum OperationFailureState { case nothingCommitted, installedNotApplied, unknown }

enum UserTerminology {}

enum HostLog { static func append(_ line: String) {} }

struct Installed { let generation: String; let revision: String }
struct ActiveRecipe { let installation: Installed }
struct InstalledPackage: Identifiable { let id: String; let name: String; let active: ActiveRecipe }
struct PublishedKeyboard: Equatable { let schemaID: String; let layout: String }
struct KeyboardSchemaDescriptor { let id: String; let name: String }

enum KeyboardRecipeStore {
    struct Activation {
        let kind: Kind
        let packageID: String?
        let revision: String
        /// False models a disabled recipe (the keyboard fell back to the built-in scheme).
        var recipeEnabled: Bool = true
        enum Kind { case userScheme, userDictionary }
        init(kind: Kind, packageID: String?, revision: String) {
            self.kind = kind
            self.packageID = packageID
            self.revision = revision
        }
        init(kind: Kind, packageID: String?, revision: String, recipeEnabled: Bool) {
            self.kind = kind
            self.packageID = packageID
            self.revision = revision
            self.recipeEnabled = recipeEnabled
        }
    }
    struct PublishBaseline {}
    struct StoreError: Error { let message: String }
}

enum AppliedSelectionLoader {
    /// Scripted shared publication record: what the keyboard uses right now.
    static var activation: KeyboardRecipeStore.Activation?
    static func loadActivation() async throws -> KeyboardRecipeStore.Activation? { activation }
}

/// Scripted download: a failure carries a user-facing message, a cancel delivers nothing.
final class SchemeURLDownloadService {
    static let shared = SchemeURLDownloadService()
    enum Outcome: Equatable { case success, failure(String), cancelled }
    struct Result { let localFileURL: URL; let requestedURL: URL }
    struct CancelHandle { let generation: Int }

    var outcome: Outcome = .failure("未设置")
    var requestedAddresses: [String] = []
    /// Runs mid-download so the probe can change state while the bytes travel.
    var duringDownload: (() -> Void)?
    /// Holds the download open so the probe can act while an update is in flight.
    var gateDownloads = false
    var downloadStarted = false
    private var downloadGate: CheckedContinuation<Void, Never>?
    /// A cancel can arrive before the gate registers; registration re-checks this flag.
    private var cancelRequested = false
    private var activeHandles: [CancelHandle] = []

    func openDownloadGate() {
        let gate = downloadGate
        downloadGate = nil
        gate?.resume()
    }

    func download(address: String) async throws -> Result {
        requestedAddresses.append(address)
        duringDownload?()
        let handle = CancelHandle(generation: requestedAddresses.count)
        if gateDownloads {
            cancelRequested = false
            activeHandles.append(handle)
            await withTaskCancellationHandler(operation: { () async -> Void in
                if self.cancelRequested { self.downloadStarted = true; return }
                await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                    if self.cancelRequested { gate.resume(); return }
                    self.downloadGate = gate
                    // Set only once the gate exists, so openDownloadGate() always has one.
                    self.downloadStarted = true
                }
            }, onCancel: {
                self.cancelHandle(handle)
            })
            activeHandles.removeAll { $0.generation == handle.generation }
            if outcome == .cancelled { throw CancellationError() }
        }
        switch outcome {
        case .success:
            return Result(localFileURL: URL(fileURLWithPath: "/tmp/fake-scheme.zip"),
                          requestedURL: URL(string: address)!)
        case .failure(let message): throw Failure(message: message)
        case .cancelled: throw CancellationError()
        }
    }

    /// Ends the gated transfer of exactly this handle as cancelled.
    func cancelHandle(_ handle: CancelHandle) {
        activeHandles.removeAll { $0.generation == handle.generation }
        cancelRequested = true
        let gate = downloadGate
        downloadGate = nil
        outcome = .cancelled
        gate?.resume()
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
}

actor FakeManager {
    let generation: String
    init(generation: String) { self.generation = generation }
    func activeInstallation() -> ActiveRecipe? {
        ActiveRecipe(installation: Installed(generation: generation, revision: "rev"))
    }
}

@MainActor
final class UpdateProbeCenter {
    var busy = false
    var error: String? {
        didSet { if error == nil { failureState = nil } }
    }
    var failureState: OperationFailureState?
    var userNotice: String?
    var prepared: Recognized?
    var preparedSourceURL: URL?
    var diagnostics: [String] = []
    var installedPackages: [InstalledPackage] = []
    var schemeUpdateActive = false
    /// The ownership handle production assigns; the probe cancels updates through it.
    var schemeUpdateTask: Task<SchemeUpdateOutcome, Never>?

    /// Recorded calls, with the values the production code decided to use.
    var recognizedCalls: [(target: String?, sourceURL: URL?)] = []
    var installCalls: [(revision: String, baseline: String?)] = []
    var applyCalls = 0
    var storedGeneration = "generation-1"
    var scriptedRecognition = true
    var scriptedRevision: String? = "revision-2"
    var recognizedRevision = "revision-2"
    var scriptedApplyFailure: Error?

    /// Effects applied, in order, by the scripted source steps.
    var sourceSteps: [() -> Void] = []
    var sourceStepCalls: [String] = []
    var sourceTask: Task<Void, Never>?
    var sourcePackageID: String?
    var acquiredSources: [String] = []
    struct FakePlan { let expectedGeneration: String? }
    var sourcePlan: FakePlan?
    var lastInstalledPackageID: String?
    var revisionAfterSourceInstall = "revision-2"

    struct ImportCapture { let target: InstalledPackage?; let sourceURL: URL? }
    struct FakeManifest { let revision: String }
    struct Recognized { let localFileURL: URL; let manifest: FakeManifest }

    func manager(_ id: String) -> FakeManager { FakeManager(generation: storedGeneration) }

    nonisolated static func rosterKey(packageID: String?) -> String? { packageID.map { "userScheme/" + $0 } }

    func publishedKeyboards(packageID: String) async throws -> [PublishedKeyboard] { attachedRoster }

    func performReplaceKeyboards(packageID: String, requested: [PublishedKeyboard],
                                viewedActivation: KeyboardRecipeStore.Activation?,
                                viewedRoster: [PublishedKeyboard],
                                viewedSourceKey: String?) async throws -> [PublishedKeyboard] {
        replaceCalls.append((requested, viewedSourceKey))
        if let scriptedApplyFailure { throw scriptedApplyFailure }
        return requested
    }
    var attachedRoster: [PublishedKeyboard] = [PublishedKeyboard(schemaID: "main", layout: "qwerty26")]
    var replaceCalls: [([PublishedKeyboard], String?)] = []

    func fail(_ state: OperationFailureState, _ detail: String) { failureState = state; error = detail }

    func fail(_ state: OperationFailureState, _ failure: Error) {
        failureState = state
        error = (failure as? SchemeURLDownloadService.Failure)?.message ?? "更新未完成，请重试。"
    }

    @discardableResult
    func prepareRecognizedImport(_ urls: [URL], capture: ImportCapture) async -> Bool {
        recognizedCalls.append((capture.target?.id, capture.sourceURL))
        guard scriptedRecognition else {
            fail(.nothingCommitted, "所选文件属于另一个输入方案，请从「导入方案」添加。")
            return false
        }
        prepared = Recognized(localFileURL: urls[0], manifest: FakeManifest(revision: recognizedRevision))
        return true
    }

    func performInstall(_ sourcePrepared: Recognized, expectedGeneration: String?) async -> String? {
        installCalls.append((sourcePrepared.manifest.revision, expectedGeneration))
        return scriptedRevision
    }

    /// Like production, each entry point returns its own step handle.
    @discardableResult
    func acquireSource(_ target: String, updatingPackageID: String?) -> Task<Void, Never>? {
        guard !busy else { return nil }
        return startStep("acquire")
    }
    @discardableResult
    func checkSourcePlan(entrySchemaID: String) -> Task<Void, Never>? {
        guard !busy, !acquiredSources.isEmpty else { return nil }
        return startStep("plan")
    }
    @discardableResult
    func installSourcePlan() -> Task<Void, Never>? {
        guard !busy, sourcePlan != nil else { return nil }
        return startStep("install")
    }
    func cancelSourceOperation() { sourceTask?.cancel() }

    func cancelUpdateTarget() { schemeUpdateTask?.cancel() }

    private func startStep(_ name: String) -> Task<Void, Never> {
        sourceStepCalls.append(name)
        let effect = sourceSteps.isEmpty ? nil : sourceSteps.removeFirst()
        let step = Task<Void, Never> { @MainActor in
            effect?()
        }
        sourceTask = step
        return step
    }

// OUTCOME
// UPDATE
// CAPTURE
// SOURCE_UPDATE
}
// MARK: - Probe

@main @MainActor struct Probe {
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static func makeCenter(revision: String = "revision-1") -> UpdateProbeCenter {
        let center = UpdateProbeCenter()
        center.installedPackages = [InstalledPackage(id: "pkg", name: "我的方案",
            active: ActiveRecipe(installation: Installed(generation: "generation-1", revision: revision)))]
        return center
    }

    /// The keyboard currently uses this scheme (recipe enabled).
    static func keyboardUsesScheme() {
        AppliedSelectionLoader.activation = KeyboardRecipeStore.Activation(
            kind: .userScheme, packageID: "pkg", revision: "revision-1", recipeEnabled: true)
    }

    static func keyboardUsesSchemeDisabled() {
        AppliedSelectionLoader.activation = KeyboardRecipeStore.Activation(
            kind: .userScheme, packageID: "pkg", revision: "revision-1", recipeEnabled: false)
    }

    static func keyboardUsesAnotherSource() { AppliedSelectionLoader.activation = nil }

    static func main() async {
        let service = SchemeURLDownloadService.shared
        let address = "https://example.com/scheme.zip"

        // 1) A download that fails installs nothing and reports why.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .failure("无网络连接，请检查你的网络设置。")
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .unchanged, "a failed download must not install")
            check(center.installCalls.isEmpty, "a failed download must not reach the installer")
            check(center.error == "无网络连接，请检查你的网络设置。", "a failed download must report the reason")
            check(center.userNotice == nil, "a failed download must not claim success")
        }

        // 2) Cancelling the download is not a failure and installs nothing.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .cancelled
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .unchanged, "a cancelled download must not install")
            check(center.installCalls.isEmpty, "a cancelled download must not reach the installer")
            check(center.error == nil, "cancelling is not a failure")
        }

        // 3) A package that declares another scheme is refused before the installer runs, and the
        //    address that was recorded travels with the recognition.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            center.scriptedRecognition = false
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .unchanged, "another scheme's package must not install")
            check(center.installCalls.isEmpty, "another scheme's package must not reach the installer")
            check(center.recognizedCalls.first?.target == "pkg", "recognition must target the package being updated")
            check(center.recognizedCalls.first?.sourceURL?.absoluteString == address,
                  "the recorded address must travel with the recognition")
            keyboardUsesScheme()
        }

        // 4) A failed install reports failure and never moves the keyboard.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            center.scriptedRevision = nil
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .unchanged, "a failed install must report no new version")
            check(center.installCalls.count == 1, "the installer is attempted once")
            check(center.applyCalls == 0, "a failed install must not move the keyboard")
        }

        // 5) Content the installation already has is never written again: the comparison happens
        //    before the installer, so a re-download cannot create an empty new version.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            center.recognizedRevision = "revision-1"
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .unchanged, "unchanged content is not an update")
            check(center.installCalls.isEmpty, "unchanged content must not reach the installer")
            check(center.userNotice == "已是最新版本，无需更新。", "unchanged content must say so")
            check(center.applyCalls == 0, "unchanged content must not move the keyboard")
            center.recognizedRevision = "revision-2"
        }


        // 6) A new version of the scheme the keyboard uses is installed and used, and the installer
        //    compares against the generation that was current before the download.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .applied, "a new version of the scheme in use must be applied")
            check(center.installCalls.count == 1 && center.installCalls[0].baseline == "generation-1",
                  "the installer must compare against the pre-download generation")
            check(center.replaceCalls.count == 1, "the keyboard roster must be republished once")
            check(center.replaceCalls.first?.1 == "userScheme/pkg", "the publication must be bound to this source")
        }

        // 7) State that changes while the bytes travel cannot become the comparison value: the
        //    baseline was captured before the download started.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            service.duringDownload = { center.storedGeneration = "generation-changed" }
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            service.duringDownload = nil
            check(outcome == .applied, "the update still installs against its own baseline")
            check(center.installCalls.count == 1 && center.installCalls[0].baseline == "generation-1",
                  "the baseline must stay the pre-download generation")
        }

        // 8) A keyboard that uses another scheme is left alone.
        do {
            keyboardUsesAnotherSource()
            let center = makeCenter()
            service.outcome = .success
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .installedOnly, "another scheme in use means install only")
            check(center.replaceCalls.isEmpty, "another scheme in use must not be replaced")
        }

        // 9) When the keyboard cannot be moved, the install stands and the notice says exactly that
        //    and points at the existing way forward.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            center.scriptedApplyFailure = RecipeInstallError.deployment("无法发布")
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .installedOnly, "a failed move still keeps the new version installed")
            check(center.replaceCalls.count == 1, "the move is attempted once")
            check(center.userNotice == "方案已更新。要让键盘改用新版本，请轻点「使用新版本」。",
                  "the notice must state the fact without claiming which version the keyboard runs")
            center.scriptedApplyFailure = nil
        }

        // 10) A caller that only wants the new version installed gets exactly that.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address,
                                                              applyingAfterInstall: false)
            check(outcome == .installedOnly, "install only must not apply")
            check(center.replaceCalls.isEmpty, "install only must not move the keyboard")
        }

        // 11) A second update for the same package, started while the first is inside its download,
        //     is refused: only one update may write that package's store slot.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            service.gateDownloads = true
            service.downloadStarted = false
            let first = Task { await center.updateInstalledPackage(packageID: "pkg", address: address) }
            var spins = 0
            while !service.downloadStarted && spins < 10_000 { await Task.yield(); spins += 1 }
            check(service.downloadStarted, "the first update must reach its download")
            let downloadsBefore = service.requestedAddresses.count
            let second = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(second == .busy, "a second update in flight must be refused as busy")
            check(center.error == "另一项操作正在进行，请稍后再试。", "the refusal must say why")
            service.openDownloadGate()
            let firstOutcome = await first.value
            check(firstOutcome == .applied, "the first update still finishes")
            check(center.installCalls.count == 1, "only the first update installs")
            check(service.requestedAddresses.count == downloadsBefore, "the refused update must not start a download")
            service.gateDownloads = false
            service.downloadStarted = false
        }


        // 12) Rime source update: a fetch that fails stops before planning or installing.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            center.sourceSteps = [{ center.error = "无法连接服务器，请检查地址和网络。" }]
            let outcome = await center.updateInstalledRimeSource(packageID: "pkg", target: "owner/repo")
            check(outcome == .unchanged, "a failed fetch must not install")
            check(center.sourceStepCalls == ["acquire"], "a failed fetch must stop the chain")
        }

        // 13) A plan that cannot be checked, because the user must still supply a file, installs nothing.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            center.sourceSteps = [
                { center.sourcePackageID = "pkg"; center.acquiredSources = ["owner/repo"] },
                { center.error = "请先下载或导入必需的语法模型：sentence.gram" },
            ]
            let outcome = await center.updateInstalledRimeSource(packageID: "pkg", target: "owner/repo")
            check(outcome == .unchanged, "an incomplete plan must not install")
            check(center.sourceStepCalls == ["acquire", "plan"], "the chain stops at the failed plan check")
        }

        // 14) A plan built from another baseline is not this update's plan and is never installed.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            center.sourceSteps = [
                { center.sourcePackageID = "pkg"; center.acquiredSources = ["owner/repo"] },
                { center.sourcePlan = UpdateProbeCenter.FakePlan(expectedGeneration: "generation-other") },
            ]
            let outcome = await center.updateInstalledRimeSource(packageID: "pkg", target: "owner/repo")
            check(outcome == .unchanged, "a plan from another baseline must not install")
            check(center.error == "更新时输入方案发生了变化，请重试。", "the stale plan must say why")
            check(center.sourceStepCalls == ["acquire", "plan"], "the stale plan must stop before installing")
        }

        // 15) A step cancelled while this update waited for it ends the update.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            center.sourceSteps = [{ center.sourceTask?.cancel() }]
            let outcome = await center.updateInstalledRimeSource(packageID: "pkg", target: "owner/repo")
            check(outcome == .unchanged, "a cancelled step must not install")
            check(center.sourceStepCalls == ["acquire"], "a cancelled step must stop the chain")
            check(center.replaceCalls.isEmpty, "a cancelled step must not move the keyboard")
            check(center.error == nil, "cancelling a step is not a failure")
        }

        // 18) A busy center refuses the step without replacing the shared state: the updater sees
        //     nil, stops, and the stale completed step from an earlier action is never awaited.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            center.busy = true
            center.sourceSteps = [
                { center.sourcePackageID = "pkg"; center.acquiredSources = ["owner/repo"] },
                { center.sourcePlan = UpdateProbeCenter.FakePlan(expectedGeneration: "generation-1") },
                {
                    center.lastInstalledPackageID = "pkg"
                    center.installedPackages = [InstalledPackage(id: "pkg", name: "我的方案",
                        active: ActiveRecipe(installation: Installed(generation: "generation-2", revision: "revision-2")))]
                },
            ]
            let outcome = await center.updateInstalledRimeSource(packageID: "pkg", target: "owner/repo")
            check(outcome == .busy, "a busy center must refuse the update as busy")
            check(center.sourceStepCalls.isEmpty, "a busy center must not start any step")
            check(center.error == "另一项操作正在进行，请稍后再试。", "the refusal must say why")
            check(center.userNotice == nil, "a refused update must not claim success")
            check(center.replaceCalls.isEmpty, "a refused update must not move the keyboard")
            center.busy = false
        }

        // 19) A page-level cancel stops only its own update attempt, and the attempt stays silent.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            service.outcome = .success
            service.gateDownloads = true
            service.downloadStarted = false
            let update = Task { await center.updateInstalledPackage(packageID: "pkg", address: address) }
            var spins = 0
            while !service.downloadStarted && spins < 10_000 { await Task.yield(); spins += 1 }
            check(service.downloadStarted, "the update must reach its download")
            check(center.error == nil && center.userNotice == nil, "the previous attempt's result must be cleared at entry")
            center.error = "上一次尝试的错误"
            keyboardUsesScheme()
            center.cancelUpdateTarget()
            let outcome = await update.value
            check(outcome == .unchanged, "a cancelled update must not report a new version")
            check(center.error == "上一次尝试的错误", "a cancelled update must not add its own error")
            check(center.userNotice == nil, "a cancelled update must not claim success")
            check(center.replaceCalls.isEmpty, "a cancelled update must not move the keyboard")
            service.gateDownloads = false
            service.downloadStarted = false
            service.outcome = .failure("未设置")
        }

        // 20) Cancelling one page's update does not cancel another page's source acquisition: the
        //     update's cancel never touches the shared source task.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            // An unrelated page started an acquisition on the shared center.
            var acquireRan = false
            center.sourceSteps = [{ acquireRan = true; center.sourcePackageID = "other"; center.acquiredSources = ["other/repo"] }]
            center.acquireSource("other/repo", updatingPackageID: nil)
            await center.sourceTask?.value
            check(acquireRan, "the unrelated page's acquisition must be running")
            service.outcome = .success
            let update = Task { await center.updateInstalledPackage(packageID: "pkg", address: address) }
            var spins = 0
            while center.schemeUpdateTask == nil && spins < 10_000 { await Task.yield(); spins += 1 }
            center.cancelUpdateTarget()
            _ = await update.value
            check(center.sourceTask?.isCancelled != true, "the shared source task must survive another page's update cancel")
            check(acquireRan, "the unrelated page's acquisition step must have run")
            check(center.acquiredSources == ["other/repo"], "the unrelated page's fetched source must survive")
            center.sourcePackageID = nil
            center.acquiredSources = []
        }

        // 21) A publication whose recipe was disabled is never auto-switched: the keyboard fell
        //     back to the built-in scheme and the update must not pull it back.
        do {
            keyboardUsesSchemeDisabled()
            let center = makeCenter()
            service.outcome = .success
            let outcome = await center.updateInstalledPackage(packageID: "pkg", address: address)
            check(outcome == .installedOnly, "a disabled publication must not auto-apply")
            check(center.replaceCalls.isEmpty, "a disabled publication must not be replaced")
            keyboardUsesScheme()
        }

        // 16) A complete chain installs the new version and keeps the keyboard on this scheme.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            center.sourceSteps = [
                { center.sourcePackageID = "pkg"; center.acquiredSources = ["owner/repo"] },
                { center.sourcePlan = UpdateProbeCenter.FakePlan(expectedGeneration: "generation-1") },
                {
                    center.lastInstalledPackageID = "pkg"
                    center.installedPackages = [InstalledPackage(id: "pkg", name: "我的方案",
                        active: ActiveRecipe(installation: Installed(generation: "generation-2",
                            revision: center.revisionAfterSourceInstall)))]
                },
            ]
            let outcome = await center.updateInstalledRimeSource(packageID: "pkg", target: "owner/repo")
            check(outcome == .applied, "a complete source update applies")
            check(center.sourceStepCalls == ["acquire", "plan", "install"], "all three existing steps run once")
            check(center.replaceCalls.count == 1, "the keyboard is moved after a source update")
        }

        // 17) A source update that lands on the same revision is not reported as an update.
        do {
            keyboardUsesScheme()
            let center = makeCenter()
            center.revisionAfterSourceInstall = "revision-1"
            center.sourceSteps = [
                { center.sourcePackageID = "pkg"; center.acquiredSources = ["owner/repo"] },
                { center.sourcePlan = UpdateProbeCenter.FakePlan(expectedGeneration: "generation-1") },
                {
                    center.lastInstalledPackageID = "pkg"
                    center.installedPackages = [InstalledPackage(id: "pkg", name: "我的方案",
                        active: ActiveRecipe(installation: Installed(generation: "generation-2", revision: "revision-1")))]
                },
            ]
            let outcome = await center.updateInstalledRimeSource(packageID: "pkg", target: "owner/repo")
            check(outcome == .unchanged, "the same revision is not an update")
            check(center.userNotice == "已是最新版本，无需更新。", "the same revision must say so")
            check(center.replaceCalls.isEmpty, "the same revision must not move the keyboard")
        }

        if failures.isEmpty {
            print("scheme direct update behavior passed")
        } else {
            for failure in failures { print("FAIL: " + failure) }
            exit(1)
        }
    }
}
'''

if __name__ == "__main__":
    unittest.main()
