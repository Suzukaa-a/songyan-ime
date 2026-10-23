import Foundation

/// Identity and copy of the built-in input scheme (shared by Engine/UI; no UIKit/SwiftUI dependency).
///
/// The built-in package (`Resources/BuiltinPackages/Basic`) plays two roles:
///  - the host installs it like an imported scheme (`builtinPackageID`), so its input methods can
///    be added to 我的键盘 and published like any other scheme;
///  - the keyboard runs it straight from its own bundle (`builtinResourceID`,
///    `KeyboardResourceSet.builtin`) when nothing is published: 内置全拼 on the remembered layout.
public enum ProductionInputAvailability: Sendable {

    // MARK: - Identifiers and text constants

    /// Resource-set identity of the keyboard's bundled fallback (the single literal source for `KeyboardResourceSet.builtin`).
    public static let builtinResourceID = "builtin"
    /// Package identity of the installed built-in scheme, from `Resources/BuiltinPackages/Basic/manifest.yaml`.
    /// Recipe update rules are keyed by package ID and reject dots, so the ID has none.
    public static let builtinPackageID = "songyan-builtin"
    /// Display name of the built-in scheme.
    public static let builtinDisplayName = "内置输入方案"
    /// The input method the keyboard falls back to when nothing is in use.
    public static var fallbackInputMethodName: String {
        BuiltinTemplateSchemas.names[BuiltinTemplateSchemas.quanpin] ?? builtinDisplayName
    }

    /// Standard title when no scheme is configured.
    public static let unconfiguredTitle = "尚未添加输入方案"
    /// Installed-source count summary when nothing is installed.
    public static let unconfiguredCountSummary = "键盘正在使用内置全拼 · 轻点添加输入方案"

    // MARK: - Pure checks

    /// Whether the resource identity is the keyboard's bundled fallback (`nil` is the `KeyboardPadSession` no-explicit-resource-set route, also the fallback).
    public static func isBuiltin(resourceID: String?) -> Bool {
        guard let resourceID else { return true }
        return resourceID == builtinResourceID
    }

    /// Installed source count summary (explicit "not configured" at 0; never called a "scheme count").
    public static func installationSummary(sources: Int) -> String {
        UserTerminology.installedSourceSummary(count: sources)
    }

    // MARK: - Runtime text (keyboard extension / trial panel)

    /// Status title when nothing is published.
    public static var runtimeUnconfiguredSchemeName: String { builtinDisplayName }

    /// Status description (second line) when nothing is published.
    public static var runtimeUnconfiguredReason: String { "正在使用\(fallbackInputMethodName)" }

    /// Panel notice when nothing is published (tap for details).
    public static var runtimeUnconfiguredNotice: String {
        "正在使用\(fallbackInputMethodName)；可在「松烟」App 中添加更多输入方案。"
    }
}
