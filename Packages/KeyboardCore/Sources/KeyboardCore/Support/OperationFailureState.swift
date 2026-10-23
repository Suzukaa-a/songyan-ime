import Foundation

/// Structured description of whether state changed when an operation failed (pure value).
///
/// The failure page must describe the state truthfully rather than always claim "unchanged".
/// The installer is an atomic transaction (an error before commit keeps the previous active
/// generation), so "not committed" is provable; but some failures happen after the commit
/// (e.g. the install succeeded and only the source record write failed), where the content is
/// saved but not applied. The two cases must be distinguished and given actionable steps.
public enum OperationFailureState: Equatable, Sendable {
    /// Transaction not committed: neither installed content nor the current keyboard changed (provable with the atomic installer).
    case nothingCommitted
    /// Installed content is saved but the current keyboard is unchanged (not yet applied, or only a secondary record write failed).
    case installedNotApplied
    /// State cannot be proven: claim nothing and ask the user to reload.
    case unknown

    /// Status line (plain wording, no internal terms).
    public var stateLine: String {
        switch self {
        case .nothingCommitted:
            return "安装内容与当前键盘都没有改变。"
        case .installedNotApplied:
            return "安装内容已经保存；当前键盘没有改变。"
        case .unknown:
            return "暂时无法确认当前状态。"
        }
    }

    /// Next-step hint; `nil` means no extra hint is needed.
    public var nextStep: String? {
        switch self {
        case .nothingCommitted:
            return "可重试，或改选其他文件。"
        case .installedNotApplied:
            return "可重试，或打开已安装输入方案并轻点「\(UserTerminology.startUsing)」。"
        case .unknown:
            return "请重新载入当前状态后再试。"
        }
    }
}
