import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

// MARK: - Control row

struct ControlRow<ModeKey: View>: View {
    let policy: KeyboardControlPolicy
    let returnTitle: String
    var returnEnabled = true
    let layoutName: String?
    let layoutHintName: String?
    let layoutHintToken: UUID?
    let modeKey: ModeKey
    let systemKeyboardSwitch: ((UIView, UIEvent) -> Void)?
    let moveCursor: ((Int) -> Void)?
    let onPage: (KeyboardPage) -> Void
    let onKey: (KeyAction) -> Void
    var phoneColumns: KeyboardControlPolicy.PhoneColumns? = nil
    /// Whether the symbol page stays open after a symbol is typed.
    var symbolPageLocked = false
    var onToggleSymbolLock: () -> Void = {}

    var body: some View {
        StableKeyboardControlRow(policy: policy.aligned(to: phoneColumns)) { slot in
            keyView(policy.key(at: slot)).buttonStyle(KeyboardPressStyle())
        }
    }

    @ViewBuilder
    private func keyView(_ slot: KeyboardControlPolicy.Slot) -> some View {
        switch slot {
        case .globe:
            if let systemKeyboardSwitch {
                NativeInputModeKey(
                    handleEvent: systemKeyboardSwitch,
                    accessibilitySwitch: { onKey(.switchKeyboard) })
            }
        case .page:
            // Use the same UIKit touch owner as the letter and language keys.
            // A SwiftUI Button here used a separate pressed transform/gesture
            // during page changes, making the visible 123 cap feel different from
            // the hit rectangle of its neighbours.
            AlternateCharacterKey(
                cap: KeyCap(id: "control-page", title: policy.pageTitle, action: .cycleLayout),
                alternates: []
            ) { _ in onPage(policy.pageTarget) }
            .accessibilityLabel(
                policy.pageTarget == .symbols
                    ? (policy.isBundledPhonePad ? "打开符号页" : "打开更多符号页") : "打开数字符号页")
        case .symbolPage:
            // Long press types 0: the 9-key letter page has no other key for it.
            AlternateCharacterKey(
                cap: KeyCap(
                    id: "control-symbol-page", title: KeyboardControlPolicy.symbolPageTitle,
                    action: .cycleLayout),
                alternates: [KeyCap(id: "control-symbol-page-0", title: "0", action: .literal("0"))]
            ) { cap in
                if case .literal = cap.action { onKey(cap.action) } else { onPage(.symbols) }
            }
            .accessibilityLabel("打开符号页")
            .accessibilityHint("长按输入 0")
        case .symbolLock:
            AlternateCharacterKey(
                cap: KeyCap(id: "control-symbol-lock", title: "锁定", action: .cycleLayout),
                alternates: [], visualRole: symbolPageLocked ? "selected" : "control"
            ) { _ in onToggleSymbolLock() }
            .accessibilityLabel("锁定符号页")
            .accessibilityValue(symbolPageLocked ? "已开启" : "已关闭")
            .accessibilityHint(symbolPageLocked ? "输入符号后留在符号页" : "输入一个符号后回到字母页")
        case .language:
            modeKey
        case .space:
            CursorSpaceKey(
                title: policy.isEnglishMode ? "space" : "空格",
                layoutName: layoutName,
                layoutHintName: layoutHintName,
                layoutHintToken: layoutHintToken,
                onTap: { onKey(.space) }, moveCursor: moveCursor)
        case .utility:
            switch policy.utility {
            case .punctuation(let text):
                AlternateCharacterKey(
                    cap: KeyCap(id: "control-period", title: text, action: .literal(text)),
                    alternates: policy.utilityAlternates.enumerated().map {
                        KeyCap(
                            id: "control-punctuation-\($0.offset)", title: $0.element, action: .literal($0.element))
                    }
                ) { onKey($0.action) }
                .accessibilityLabel("\(text)，长按选择标点")
            case .digit(let digit):
                AlternateCharacterKey(
                    cap: KeyCap(id: "control-digit-\(digit)", title: digit, action: .literal(digit)),
                    alternates: []
                ) { onKey($0.action) }
            }
        case .enter:
            ReturnKey(title: returnTitle, isEnabled: returnEnabled) { onKey($0.action) }
        }
    }

}

/// All return placements share the same composition/host title and enter action.
struct ReturnKey: View {
    let title: String
    var isEnabled = true
    var alternates: [KeyCap] = []
    var longPressDelay: TimeInterval = 0.35
    let onSelect: (KeyCap) -> Void

    var body: some View {
        AlternateCharacterKey(
            cap: KeyCap(id: "return", title: title, action: .enter),
            alternates: alternates, longPressDelay: longPressDelay, onSelect: onSelect
        )
        .accessibilityLabel(title == "确认" ? "确认输入" : title)
        // Dimmed, never disabled: the enablement is a cached host trait, so the
        // tap still reaches the controller, which re-reads the field before
        // deciding (`KeyboardController.onRequestHostTraitsRefresh`).
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct ControlKeyFace: View {
    @Environment(\.keyboardAppearance) private var appearance
    var text: String? = nil
    var symbol: String? = nil
    /// Space and other main input keys use a white fill, like character keys; other control keys use gray.
    var prominent = false

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(appearance.font(appearance.controlIconSize))
            } else if let text {
                Text(text)
                    .font(appearance.font(appearance.controlTextSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(uiColor: appearance.text(on: prominent ? "key" : "control")))
        .background(SkinKeyBackground(role: prominent ? "key" : "control"))
        .contentShape(Rectangle())
    }
}

struct KeyboardPressStyle: ButtonStyle {
    @Environment(\.keyboardAppearance) private var appearance
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                    .fill(Color.primary.opacity(configuration.isPressed ? KeyboardPressPhysics.overlayOpacity : 0))
                    .padding(.horizontal, appearance.skin.spacing.visualInsetX)
                    .padding(.vertical, appearance.skin.spacing.visualInsetY)
                    .allowsHitTesting(false)
            }
            // One shared press vocabulary with the UIKit keys: immediate
            // sink/scale on touch-down, critically damped spring on release, shadow tightened
            // through the environment. No whole-key opacity change, no
            // compositing group, layout frame and hit region untouched.
            .environment(\.keyboardKeyPressed, configuration.isPressed)
            .keyboardPressMovement(isPressed: configuration.isPressed)
    }
}

struct ShiftKey: UIViewRepresentable {
    @Environment(\.keyboardAppearance) private var appearance
    let state: ShiftState
    var isEnglishMode = true
    let tap: () -> Void
    let doubleTap: () -> Void

    func makeUIView(context: Context) -> ShiftButton {
        let button = ShiftButton(type: .custom)
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: ShiftButton, context: Context) {
        button.appearance = appearance
        button.skinRole = state == .off ? "control" : "selected"
        button.tap = tap
        button.double = doubleTap
        button.shiftState = state
        let symbol = state == .locked ? "capslock.fill" : (state == .once ? "shift.fill" : "shift")
        if button.symbolName != symbol {
            button.symbolName = symbol
            button.setImage(UIImage(systemName: symbol), for: .normal)
        }
        // Shift has no effect in Chinese mode: it should also look disabled, rather than being an unresponsive key.
        button.alpha = isEnglishMode ? 1 : 0.4
        button.accessibilityLabel = "上档键"
        button.accessibilityTraits = state == .locked ? [.keyboardKey, .selected] : .keyboardKey
        button.accessibilityValue =
            !isEnglishMode ? "中文" : (state == .off ? "小写" : (state == .once ? "下一字母大写" : "大写锁定"))
        button.accessibilityHint = isEnglishMode ? "轻点切换一次大写，连续点按两次锁定大写" : "当前为中文输入；使用 ABC/中文 键切换到英文后可用"
        button.accessibilityCustomActions =
            isEnglishMode
            ? [
                UIAccessibilityCustomAction(name: "切换大写锁定") { _ in
                    doubleTap()
                    return true
                }
            ] : []
    }

    final class ShiftButton: SkinnedButton {
        var symbolName: String?
        var tap: (() -> Void)?
        var double: (() -> Void)?
        var shiftState: ShiftState = .off
        private var sequenceStartedLocked = false
        /// This press already turned Shift on at touch-down; its release adds nothing.
        private var activatedOnDown = false

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            AlternateCharacterKey.CharacterButton.commitPendingTap()
            let began = super.beginTracking(touch, with: event)
            activatedOnDown = false
            // Like the system keyboard, Shift turns on at touch-down: a letter tapped while
            // Shift is still held (a chord) is capitalised, which a release-time toggle missed.
            if touch.tapCount < 2, shiftState == .off {
                activatedOnDown = true
                sequenceStartedLocked = false
                tap?()
            }
            return began
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            super.endTracking(touch, with: event)
            // Same slop as the other keys: an edge strip routes here from outside the cap.
            guard let touch, bounds.insetBy(dx: -10, dy: -10).contains(touch.location(in: self)) else { return }
            if touch.tapCount == 2 {
                // The first release already unlocked Caps Lock; avoid relocking on the second.
                if !sequenceStartedLocked { double?() }
            } else if !activatedOnDown {
                sequenceStartedLocked = shiftState == .locked
                tap?()  // Immediate: a fast next letter must already see Shift.
            }
        }
        override func accessibilityActivate() -> Bool {
            tap?()
            return true
        }
    }
}

/// A hold transfers ownership to cursor motion; it never also emits a space on release.
struct CursorSpaceKey: UIViewRepresentable {
    @Environment(\.keyboardPanelHostLifetime) private var hostLifetime
    @Environment(\.keyboardAppearance) private var appearance
    let title: String
    var layoutName: String? = nil
    /// Brief hint driven by a real switch event (passed in by PanelView after token dedup).
    var layoutHintName: String? = nil
    var layoutHintToken: UUID? = nil
    let onTap: () -> Void
    let moveCursor: ((Int) -> Void)?

    func makeUIView(context: Context) -> SpaceButton {
        let button = SpaceButton(type: .custom)
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: SpaceButton, context: Context) {
        button.hostLifetime = hostLifetime
        button.appearance = appearance
        button.skinRole = "key"
        if button.moveCursor != nil && moveCursor == nil { button.cancelPress() }
        button.normalTitle = title
        button.layoutName = layoutName
        button.onTap = onTap
        button.moveCursor = moveCursor
        button.applyTransientHint(layoutHintName, token: layoutHintToken)
        button.refreshAppearance()
        button.accessibilityLabel = title == "确认" ? "确认候选" : title
        button.accessibilityValue = layoutName
        button.accessibilityHint = moveCursor == nil ? nil : "长按后左右滑动移动光标"
        button.accessibilityTraits = moveCursor == nil ? [.keyboardKey] : [.keyboardKey, .adjustable]
    }

    static func dismantleUIView(_ button: SpaceButton, coordinator: ()) { button.cancelPress() }

    final class SpaceButton: SkinnedButton, KeyboardRolloverPress {
        var hostLifetime: KeyboardPanelHostLifetime? {
            didSet {
                guard oldValue !== hostLifetime else { return }
                cancelPress()
                rebindPanelHostObserver(self, selector: #selector(cancelPress), from: oldValue, to: hostLifetime)
            }
        }
        private let layoutLabel = UILabel()
        var normalTitle = "空格"
        /// The stable layout name is for accessibility only; the visible hint is driven by applyTransientHint events.
        var layoutName: String? {
            didSet {
                guard oldValue != layoutName else { return }
                layoutLabel.accessibilityLabel = layoutName
            }
        }
        var onTap: (() -> Void)?
        var moveCursor: ((Int) -> Void)?
        private var hintTimer: Timer?
        private var shownHintToken: UUID?
        private var transientHintTimer: Timer?
        private var transientHintName: String?
        private var showsLayoutHint = false
        private var isDragging = false
        private var latestX: CGFloat = 0
        private var steppedX: CGFloat = 0
        private var originX: CGFloat = 0
        /// Cursor mode moved the cursor at least once during this press.
        private var didMoveCursor = false
        private var pressStartedAt: TimeInterval = 0
        private var previousSize = CGSize.zero
        /// Cursor mode starts on a still hold this long (0.35s turned slow taps into
        /// swallowed spaces) or on a deliberate sideways drag of `cursorDragStart`.
        private static let cursorHoldDelay: TimeInterval = 0.5
        private static let cursorDragStart: CGFloat = 14
        /// A cursor-mode press that never moved the cursor and lifted within this
        /// time was a slow tap: it still types the space.
        private static let slowTapLimit: TimeInterval = 0.8
        /// A thumb drifting a little past the wide bar still means space.
        private var trackingBounds: CGRect { bounds.insetBy(dx: -10, dy: -10) }

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerRadius = 6
            setTitleColor(.label, for: .normal)
            titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            titleLabel?.adjustsFontSizeToFitWidth = true
            titleLabel?.minimumScaleFactor = 0.6
            layoutLabel.font = .systemFont(ofSize: 10)
            layoutLabel.textColor = .secondaryLabel
            layoutLabel.textAlignment = .center
            layoutLabel.lineBreakMode = .byTruncatingTail
            layoutLabel.isUserInteractionEnabled = false
            addSubview(layoutLabel)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Only a new token resets the hint duration; a view rebuild with the same token does not retrigger it.
        func applyTransientHint(_ name: String?, token: UUID?) {
            guard let name, !name.isEmpty else {
                transientHintTimer?.invalidate()
                transientHintTimer = nil
                transientHintName = nil
                showsLayoutHint = false
                return
            }
            guard token != shownHintToken else { return }
            shownHintToken = token
            transientHintName = name
            transientHintTimer?.invalidate()
            transientHintTimer = nil
            showsLayoutHint = true
            let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.showsLayoutHint = false
                    self.transientHintTimer = nil
                    self.refreshAppearance()
                }
            }
            transientHintTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        /// What the last `refreshAppearance` painted; SwiftUI calls it on every
        /// panel update, and an unchanged key must not relayout its cap.
        private var paintedState: (title: String, hint: String?, appearance: KeyboardAppearance)?

        func refreshAppearance() {
            let title = isDragging ? "移动光标" : normalTitle
            let hint = showsLayoutHint && !isDragging && normalTitle != "确认" ? transientHintName : nil
            skinRole = isDragging ? "pressed" : "key"
            if let paintedState, paintedState.title == title, paintedState.hint == hint,
                paintedState.appearance == appearance
            {
                return
            }
            paintedState = (title, hint, appearance)
            setTitle(title, for: .normal)
            setTitleColor(appearance.text(on: "key"), for: .normal)
            layoutLabel.textColor = appearance.text(on: "key", secondary: true)
            layoutLabel.font = appearance.uiFont(appearance.skin.typography.secondarySize)
            layoutLabel.text = hint
            setNeedsLayout()
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            AlternateCharacterKey.CharacterButton.commitPendingTap()
            cancelPress()
            isHighlighted = true
            latestX = touch.location(in: window).x
            steppedX = latestX
            originX = latestX
            pressStartedAt = ProcessInfo.processInfo.systemUptime
            refreshAppearance()
            AlternateCharacterKey.CharacterButton.pendingTap = self
            if moveCursor != nil {
                let timer = Timer(timeInterval: Self.cursorHoldDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.isHighlighted, self.window != nil else { return }
                        self.hintTimer = nil
                        self.startCursorMode()
                    }
                }
                hintTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return true
        }

        /// The next key landed while the space bar is still a plain tap: type the space
        /// now so it stays ahead of that key. The release then types nothing.
        func commitRolloverPress() {
            guard isHighlighted, !isDragging else { return }
            cancelPress()
            onTap?()
        }

        private func startCursorMode() {
            if AlternateCharacterKey.CharacterButton.pendingTap === self {
                AlternateCharacterKey.CharacterButton.pendingTap = nil
            }
            hintTimer?.invalidate()
            hintTimer = nil
            isDragging = true
            steppedX = latestX
            refreshAppearance()
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            latestX = touch.location(in: window).x
            if !isDragging, moveCursor != nil, isHighlighted, abs(latestX - originX) >= Self.cursorDragStart {
                startCursorMode()
            }
            if isDragging {
                let offset = Int((latestX - steppedX) / 12)
                if offset != 0 {
                    steppedX += CGFloat(offset) * 12
                    didMoveCursor = true
                    moveCursor?(offset)
                }
            } else if !trackingBounds.contains(touch.location(in: self)) {
                cancelPress()
                return false
            }
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            let inside = touch.map { trackingBounds.contains($0.location(in: self)) } == true
            let slowTap =
                isDragging && !didMoveCursor
                && ProcessInfo.processInfo.systemUptime - pressStartedAt < Self.slowTapLimit
            let shouldTap = isHighlighted && inside && (!isDragging || slowTap)
            cancelPress()
            if shouldTap { onTap?() }
        }

        override func cancelTracking(with event: UIEvent?) { cancelPress() }

        @objc func cancelPress() {
            if AlternateCharacterKey.CharacterButton.pendingTap === self {
                AlternateCharacterKey.CharacterButton.pendingTap = nil
            }
            hintTimer?.invalidate()
            hintTimer = nil
            isDragging = false
            didMoveCursor = false
            isHighlighted = false
            refreshAppearance()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != bounds.size {
                cancelPress()
                previousSize = bounds.size
            }
            if layoutLabel.text != nil, var titleFrame = titleLabel?.frame {
                titleFrame.origin.y -= 6
                titleLabel?.frame = titleFrame
            }
            layoutLabel.frame = CGRect(x: 4, y: bounds.height - 16, width: max(0, bounds.width - 8), height: 12)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                transientHintTimer?.invalidate()
                transientHintTimer = nil
                hintTimer?.invalidate()
                hintTimer = nil
                showsLayoutHint = false
                cancelPress()
            }
        }

        override func accessibilityActivate() -> Bool {
            onTap?()
            return true
        }
        override func accessibilityIncrement() { moveCursor?(1) }
        override func accessibilityDecrement() { moveCursor?(-1) }
    }
}

/// Forward every touch phase to UIKit: tap, hold and upward swipe remain system-owned.
struct NativeInputModeKey: UIViewRepresentable {
    @Environment(\.keyboardAppearance) private var appearance
    let handleEvent: (UIView, UIEvent) -> Void
    let accessibilitySwitch: () -> Void

    func makeUIView(context: Context) -> InputModeButton {
        let button = InputModeButton(type: .custom)
        button.appearance = appearance
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "切换系统输入法"
        button.accessibilityHint = "长按或向上滑动显示系统键盘列表"
        button.addTarget(button, action: #selector(InputModeButton.forwardEvent(_:event:)), for: .allTouchEvents)
        button.handleEvent = handleEvent
        button.accessibilitySwitch = accessibilitySwitch
        return button
    }

    func updateUIView(_ button: InputModeButton, context: Context) {
        button.appearance = appearance
        button.handleEvent = handleEvent
        button.accessibilitySwitch = accessibilitySwitch
    }

    final class InputModeButton: SkinnedButton {
        override var emitsTouchDownFeedback: Bool { false }
        var handleEvent: ((UIView, UIEvent) -> Void)?
        var accessibilitySwitch: (() -> Void)?

        @objc func forwardEvent(_ sender: UIButton, event: UIEvent) {
            handleEvent?(sender, event)
        }

        override func accessibilityActivate() -> Bool {
            accessibilitySwitch?()
            return true
        }
    }
}

/// The UIKit touch lifecycle ensures repeat-delete stops immediately on move-out, lift, and view disappearance.
struct RepeatingDeleteKey: UIViewRepresentable {
    @Environment(\.keyboardPanelHostLifetime) private var hostLifetime
    @Environment(\.keyboardAppearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled
    let action: (Bool) -> Void

    init(action: @escaping (Bool) -> Void) { self.action = action }
    init(action: @escaping () -> Void) { self.action = { _ in action() } }

    func makeUIView(context: Context) -> DeleteButton {
        let button = DeleteButton(type: .custom)
        button.hostLifetime = hostLifetime
        button.appearance = appearance
        button.setImage(UIImage(systemName: "delete.left"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "退格"
        button.accessibilityHint = "轻点删除一个字符，按住连续删除"
        // As with letter/space keys: under VoiceOver touch typing, lifting the finger triggers it, rather than needing a double tap.
        button.accessibilityTraits = .keyboardKey
        button.action = action
        return button
    }

    func updateUIView(_ button: DeleteButton, context: Context) {
        button.hostLifetime = hostLifetime
        button.action = action
        button.appearance = appearance
        if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
    }

    static func dismantleUIView(_ button: DeleteButton, coordinator: ()) { button.stopRepeating() }

    final class DeleteButton: SkinnedButton {
        var hostLifetime: KeyboardPanelHostLifetime? {
            didSet {
                guard oldValue !== hostLifetime else { return }
                stopRepeating()
                rebindPanelHostObserver(self, selector: #selector(stopRepeating), from: oldValue, to: hostLifetime)
            }
        }
        var action: ((Bool) -> Void)?
        private var timer: Timer?
        private var repeatCount = 0

        override var isEnabled: Bool {
            didSet { if !isEnabled { stopRepeating() } }
        }

        override var isHighlighted: Bool {
            didSet {
                // The shared cap layer already paints the pressed role, so the
                // delete key uses the same immediate press + spring release as
                // every other key instead of a separate backgroundColor tint.
                setNeedsLayout()
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerRadius = 6
            addTarget(self, action: #selector(beginRepeating), for: .touchDown)
            addTarget(
                self, action: #selector(stopRepeating),
                for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func beginRepeating() {
            AlternateCharacterKey.CharacterButton.commitPendingTap()
            stopRepeating()
            guard isEnabled, window != nil else { return }
            action?(false)
            scheduleRepeat(after: 0.45)
        }

        private func scheduleRepeat(after interval: TimeInterval) {
            guard isEnabled, isTracking, isHighlighted, window != nil else { return }
            let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled, self.isTracking,
                        self.isHighlighted, self.window != nil
                    else { return }
                    self.action?(true)
                    self.repeatCount += 1
                    // One key event remains one grapheme/engine backspace. Never infer
                    // host word boundaries from incomplete proxy context. Past 75ms a
                    // character the release lands too late and overshoots.
                    let nextInterval: TimeInterval = self.repeatCount < 8 ? 0.09 : 0.075
                    self.scheduleRepeat(after: nextInterval)
                }
            }
            timer = next
            RunLoop.main.add(next, forMode: .common)
        }

        @objc func stopRepeating() {
            timer?.invalidate()
            timer = nil
            repeatCount = 0
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stopRepeating() }
        }

        override func accessibilityActivate() -> Bool {
            action?(false)
            return true
        }
    }
}
