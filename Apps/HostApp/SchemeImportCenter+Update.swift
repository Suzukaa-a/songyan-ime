import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

extension SchemeImportCenter {
    // MARK: - Direct update of an installed input scheme (check, download, install, keep the keyboard current)

    /// What one direct update accomplished.
    enum SchemeUpdateOutcome: Equatable {
        /// Nothing was installed: the downloaded content is what the installation already has, the
        /// user cancelled, or the attempt failed (`error` carries the reason).
        case unchanged
        /// A new version is installed; the keyboard still uses the previous one.
        case installedOnly
        /// A new version is installed and the keyboard now uses it.
        case applied
        /// The update did not start: the center was already working on something else.
        case busy
    }

    /// Update an installed scheme from its recorded download address in one action: download under the
    /// existing URL rules, prove the package identity from the downloaded files, install through the
    /// existing transaction with the generation captured before the download as the store's
    /// compare-and-set baseline, and keep the keyboard on the new version when this scheme is the one
    /// it uses. Nothing is installed unless every step succeeded.
    @discardableResult
    func updateInstalledPackage(
        packageID: String, address: String,
        applyingAfterInstall: Bool = true
    ) async -> SchemeUpdateOutcome {
        guard !busy, !schemeUpdateActive else {
            error = "另一项操作正在进行，请稍后再试。"
            return .busy
        }
        guard let item = installedPackages.first(where: { $0.id == packageID }) else {
            error = "未找到要更新的输入方案。"
            return .unchanged
        }
        // Reserve the update before the first await: two updates for one package must never overlap.
        schemeUpdateActive = true
        defer { schemeUpdateActive = false }
        let attempt = Task {
            await runUpdateInstalledPackage(
                packageID: packageID, address: address,
                applyingAfterInstall: applyingAfterInstall, item: item)
        }
        schemeUpdateTask = attempt
        return await attempt.value
    }

    private func runUpdateInstalledPackage(
        packageID: String, address: String,
        applyingAfterInstall: Bool, item: InstalledPackage
    ) async -> SchemeUpdateOutcome {
        defer { schemeUpdateTask = nil }
        error = nil
        userNotice = nil
        let previousRevision = item.active.installation.revision
        // Baseline and publication are captured first so concurrent changes are refused, not overwritten.
        let baseline: String?
        do { baseline = try await manager(packageID).activeInstallation()?.installation.generation } catch {
            fail(.nothingCommitted, error)
            return .unchanged
        }
        let publication = await captureKeyboardPublication(packageID: packageID)
        let download: SchemeURLDownloadService.Result
        do {
            download = try await SchemeURLDownloadService.shared.download(address: address)
        } catch is CancellationError { return .unchanged } catch {
            fail(.nothingCommitted, error)
            return .unchanged
        }
        // Keep the download's temporary-file lease alive for the whole install.
        defer { withExtendedLifetime(download) {} }
        // Recognition shares the import page's state; restore it when nothing was installed.
        let importPage = (prepared, preparedSourceURL, diagnostics)
        var installed = false
        defer {
            if !installed { (prepared, preparedSourceURL, diagnostics) = importPage }
        }
        // Recognition rejects a package that declares another scheme.
        guard
            await prepareRecognizedImport(
                [download.localFileURL],
                capture: ImportCapture(target: item, sourceURL: download.requestedURL)), let recognized = prepared
        else {
            return .unchanged
        }
        // Unchanged content is not reinstalled as an empty new version.
        guard recognized.manifest.revision != previousRevision else {
            userNotice = "已是最新版本，无需更新。"
            return .unchanged
        }
        guard !Task.isCancelled else { return .unchanged }
        guard let revision = await performInstall(recognized, expectedGeneration: baseline) else { return .unchanged }
        installed = true
        guard revision != previousRevision else {
            userNotice = "已是最新版本，无需更新。"
            return .unchanged
        }
        guard applyingAfterInstall, publication.isCurrent, !Task.isCancelled else { return .installedOnly }
        do {
            try await applyInstalledRevision(packageID: packageID, publication: publication)
            return .applied
        } catch {
            // The install is committed; the keyboard did not move.
            HostLog.append("scheme update keyboard switch failed: \(error.localizedDescription)")
            userNotice = "方案已更新。要让键盘改用新版本，请轻点「使用新版本」。"
            return .installedOnly
        }
    }

    /// The publication the keyboard used when an update started. `isCurrent` requires an enabled
    /// record: a disabled one fell back to the built-in scheme and must not be switched back.
    private struct KeyboardPublicationCapture {
        let activation: KeyboardRecipeStore.Activation?
        let roster: [PublishedKeyboard]
        let isCurrent: Bool
    }

    private func captureKeyboardPublication(packageID: String) async -> KeyboardPublicationCapture {
        let activation = try? await AppliedSelectionLoader.loadActivation()
        // A read failure yields an empty roster, which the apply step refuses.
        let roster = (try? await publishedKeyboards(packageID: packageID)) ?? []
        return KeyboardPublicationCapture(
            activation: activation, roster: roster,
            isCurrent: activation?.kind == .userScheme && activation?.packageID == packageID
                && activation?.recipeEnabled == true)
    }

    /// Republish the captured roster against the new version. The publication transaction compares
    /// it with the captured publication and refuses if the keyboard changed meanwhile.
    private func applyInstalledRevision(
        packageID: String,
        publication: KeyboardPublicationCapture
    ) async throws {
        guard !publication.roster.isEmpty else {
            throw KeyboardRecipeStore.StoreError(message: "键盘列表为空，请重新选择键盘后再试。")
        }
        _ = try await performReplaceKeyboards(
            packageID: packageID,
            requested: publication.roster,
            viewedActivation: publication.activation,
            viewedRoster: publication.roster,
            viewedSourceKey: Self.rosterKey(packageID: packageID))
    }

    /// Update an installed scheme that came from a Rime source expression, in one action: drive the
    /// existing acquire, plan and install steps in order, then keep the keyboard on the new version.
    @discardableResult
    func updateInstalledRimeSource(
        packageID: String, target: String,
        applyingAfterInstall: Bool = true
    ) async -> SchemeUpdateOutcome {
        guard !busy, !schemeUpdateActive else {
            error = "另一项操作正在进行，请稍后再试。"
            return .busy
        }
        guard let item = installedPackages.first(where: { $0.id == packageID }) else {
            error = "未找到要更新的输入方案。"
            return .unchanged
        }
        // Reserve the update before the first await: two updates for one package must never overlap.
        schemeUpdateActive = true
        defer { schemeUpdateActive = false }
        let attempt = Task {
            await runUpdateInstalledRimeSource(
                packageID: packageID, target: target,
                applyingAfterInstall: applyingAfterInstall, item: item)
        }
        schemeUpdateTask = attempt
        return await attempt.value
    }

    private func runUpdateInstalledRimeSource(
        packageID: String, target: String,
        applyingAfterInstall: Bool, item: InstalledPackage
    ) async -> SchemeUpdateOutcome {
        defer { schemeUpdateTask = nil }
        error = nil
        userNotice = nil
        let previousRevision = item.active.installation.revision
        // Baseline and publication are captured first so concurrent changes are refused, not overwritten.
        let baseline: String?
        do { baseline = try await manager(packageID).activeInstallation()?.installation.generation } catch {
            fail(.nothingCommitted, error)
            return .unchanged
        }
        let publication = await captureKeyboardPublication(packageID: packageID)
        guard let acquireStep = acquireSource(target, updatingPackageID: packageID),
            await waitForSourceStep(acquireStep), error == nil,
            sourcePackageID == packageID, !acquiredSources.isEmpty
        else { return .unchanged }
        // A plan built from another baseline is not this update's plan.
        guard let checkStep = checkSourcePlan(entrySchemaID: ""),
            await waitForSourceStep(checkStep), error == nil, let plan = sourcePlan
        else { return .unchanged }
        guard plan.expectedGeneration == baseline, sourcePackageID == packageID else {
            error = "更新时输入方案发生了变化，请重试。"
            return .unchanged
        }
        guard !Task.isCancelled else { return .unchanged }
        guard let installStep = installSourcePlan(),
            await waitForSourceStep(installStep), error == nil, lastInstalledPackageID == packageID
        else { return .unchanged }
        let revision = installedPackages.first { $0.id == packageID }?.active.installation.revision
        guard let revision, revision != previousRevision else {
            userNotice = "已是最新版本，无需更新。"
            return .unchanged
        }
        guard applyingAfterInstall, publication.isCurrent, !Task.isCancelled else { return .installedOnly }
        do {
            try await applyInstalledRevision(packageID: packageID, publication: publication)
            return .applied
        } catch {
            HostLog.append("source update keyboard switch failed: \(error.localizedDescription)")
            userNotice = "方案已更新。要让键盘改用新版本，请轻点「使用新版本」。"
            return .installedOnly
        }
    }

    /// Waits for a step this update started, forwarding cancellation to it. False when the center
    /// was busy (nil step) or the update was cancelled.
    func waitForSourceStep(_ step: Task<Void, Never>?) async -> Bool {
        guard let step else {
            error = "另一项操作正在进行，请稍后再试。"
            return false
        }
        await withTaskCancellationHandler(operation: { await step.value }, onCancel: { step.cancel() })
        return !Task.isCancelled
    }
}
