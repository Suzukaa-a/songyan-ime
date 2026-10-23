import SwiftUI
import UIKit

/// Fixed, app-owned clipboard only; does not prove an extension can paste media.
@main @MainActor final class PasteButtonProbe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var delivered: [String] = []
    var error: String?
    var rows: [[String: Any]] = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UIPasteboard.general.items = []
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(
            rootView: QuickPasteView(
                inputContext: { "fixed-fixture-document" },
                insertLiteral: { [weak self] text in
                    self?.delivered.append(text)
                    return true
                },
                onError: { [weak self] in self?.error = $0 }))
        self.window = window
        window.makeKeyAndVisible()
        Task { @MainActor in await self.run() }
        return true
    }

    func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
    func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }
    func record(_ name: String, _ passed: Bool) {
        rows.append(["name": name, "passed": passed])
    }
    func run() async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        window?.layoutIfNeeded()
        guard let root = window,
            let button = descendants(root).first(where: { $0.accessibilityIdentifier == "quickPaste.iconButton" })
                as? UIButton
        else {
            record("attachedProductionButton", false)
            finish()
            return
        }
        rows.append([
            "name": "initialMetadataEvidence", "passed": true,
            "hasStrings": UIPasteboard.general.hasStrings,
            "items": UIPasteboard.general.numberOfItems,
            "enabled": button.isEnabled,
        ])
        record("emptyDisabledWithoutError", !button.isEnabled && error == nil)
        button.sendActions(for: .touchUpInside)
        await settle()
        record("disabledActionDoesNothing", delivered.isEmpty && error == nil)
        let icons = descendants(button).compactMap { $0 as? UIImageView }.filter { $0.image != nil }
        rows.append([
            "name": "geometryEvidence", "passed": true,
            "buttonWidth": button.bounds.width, "buttonHeight": button.bounds.height,
            "icons": icons.map { ["width": $0.bounds.width, "height": $0.bounds.height] },
        ])
        record(
            "icon16ptHitArea44pt",
            icons.contains { abs($0.bounds.width - 16) < 0.1 && abs($0.bounds.height - 16) < 0.1 }
                && abs(button.bounds.width - 44) < 0.1 && abs(button.bounds.height - 44) < 0.1)

        let text = "固定原生粘贴𠮷👩🏽‍💻\n第二行"
        UIPasteboard.general.string = text
        await settle()
        record("textEnablesAfterClipboardChange", button.isEnabled)
        button.isHighlighted = true
        await settle()
        record(
            "pressedOnlyDimsIcon",
            abs(button.alpha - 0.55) < 0.01
                && (button.configuration?.background.backgroundColor?.cgColor.alpha ?? 0) == 0)
        button.isHighlighted = false
        button.sendActions(for: .touchUpInside)
        for _ in 0..<30 {
            if !delivered.isEmpty || error != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        record("wholeNativeProviderTextPaste", delivered == [text] && error == nil)

        UIPasteboard.general.items = []
        await settle()
        record("clearDisablesWithoutError", !button.isEnabled && error == nil && abs(button.alpha - 0.3) < 0.01)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        UIPasteboard.general.image = image
        await settle()
        record("imageDisablesWithoutReadingOrError", !button.isEnabled && error == nil && delivered == [text])
        UIPasteboard.general.items = [
            [UTType.utf8PlainText.identifier: Data(text.utf8)],
            [UTType.png.identifier: image.pngData()!],
        ]
        await settle()
        record("mixedMediaDisablesWithoutDroppingImage", !button.isEnabled && error == nil && delivered == [text])
        UIPasteboard.general.items = [
            [
                UTType.html.identifier: Data("<b>fixed</b>".utf8),
                UTType.utf8PlainText.identifier: Data("fixed".utf8),
            ]
        ]
        await settle()
        record("richTextDisablesWithoutStrippingFormatting", !button.isEnabled && error == nil)
        UIPasteboard.general.items = []
        finish()
    }
    func finish() {
        let report: [String: Any] = [
            "passed": rows.allSatisfy { $0["passed"] as? Bool == true },
            "steps": rows,
            "scope": "production UIKit/SwiftUI paste button; app-owned clipboard; no extension media target",
        ]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("paste-button-report.json"), options: .atomic)
        }
    }
}
