import Foundation

/// One user-facing result combines publication identity with a validated runtime receipt.
public enum GrammarModelStatus: Equatable, Sendable {
    case inactive, olderVersion, unverifiedVersion, noInputMethod, disabled
    case awaitingLoad(model: String), loaded(model: String)

    /// The caller must validate a receipt against the current source, runtime schema and model path.
    public static func resolve(
        publication: ModelPublicationState, enabled: Bool,
        hasSelection: Bool, modelName: String?, loadConfirmed: Bool
    ) -> Self {
        guard enabled else { return .inactive }
        switch publication {
        case .notPublished, .otherSource: return .inactive
        case .olderInstallation: return .olderVersion
        case .revisionOnly: return .unverifiedVersion
        case .currentInstallation: break
        }
        guard hasSelection else { return .noInputMethod }
        guard let modelName else { return .disabled }
        return loadConfirmed ? .loaded(model: modelName) : .awaitingLoad(model: modelName)
    }

    public var message: String {
        switch self {
        case .inactive: return "键盘还没有使用这个输入方案。"
        case .olderVersion: return "键盘仍在使用旧版本，请在方案详情中轻点「使用新版本」。"
        case .unverifiedVersion: return "暂时无法确认键盘使用的版本，请在「我的键盘」中重新选择。"
        case .noInputMethod: return "还没有选择输入方式，请在「我的键盘」中选择。"
        case .disabled: return "当前输入方式未开启语法模型。"
        case .awaitingLoad(let model): return "已为当前输入方式设置 \(model)，下次打开键盘时生效。"
        case .loaded(let model): return "上次使用键盘时已载入 \(model)。"
        }
    }
}

/// Publication identity is independent of installation and of runtime model loading.
public enum ModelPublicationState: Equatable, Sendable {
    case notPublished, otherSource, olderInstallation, revisionOnly, currentInstallation

    public static func resolve(
        sourceMatches: Bool, installedRevision: String,
        installedGeneration: String, publishedRevision: String?,
        publishedGeneration: String?, hostGeneration: String?
    ) -> Self {
        guard let publishedRevision, let publishedGeneration, !publishedGeneration.isEmpty else { return .notPublished }
        guard sourceMatches else { return .otherSource }
        guard installedRevision == publishedRevision else { return .olderInstallation }
        guard let hostGeneration else { return .revisionOnly }
        return hostGeneration == installedGeneration ? .currentInstallation : .olderInstallation
    }

    public var message: String {
        switch self {
        case .notPublished: return "此输入方案尚未在键盘中启用"
        case .otherSource: return "当前键盘使用的是其他输入方案；在「我的键盘」中轻点「使用」即可换用此方案"
        case .olderInstallation: return "当前键盘使用的是旧版本；轻点「使用新版本」即可更新"
        case .revisionOnly: return "已启用相同版本的输入方案，但无法核实是否为此安装版本"
        case .currentInstallation: return "当前键盘正在使用此版本"
        }
    }
}
