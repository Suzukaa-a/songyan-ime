import Foundation

/// Layering of ordinary-flow notices (pure value; shared by Host and views).
///
/// Invariants:
///  * Success and actionable notices ordinary users need (install, update, start using,
///    adaptation done...) go through the plain-language channel and do not disappear when
///    developer options are off.
///  * Raw `diagnostics` (paths, UUIDs, English reasons, schema source names...) go only to
///    developer diagnostics, never into the ordinary flow.
///  * The same fact is not repeated in several places (e.g. the "installed" section and a
///    success notice).
public enum UserNoticeLayering {

    /// Ordinary notice lines: only the plain-language notice; developer diagnostics are a separate channel.
    public static func userLines(notice: String?) -> [String] {
        guard let notice, !notice.isEmpty else { return [] }
        return [notice]
    }

    /// Next-step guidance after a successful install/update (not the status fact itself).
    ///
    /// The status fact ("installed / update done, not applied" plus "view scheme") is owned by
    /// the "installed" section; this only adds what the user should do next.
    public static func installationNextStep(installedPackageID: String?) -> String? {
        guard installedPackageID != nil else { return nil }
        return "接下来选择要使用的键盘。"
    }
}
