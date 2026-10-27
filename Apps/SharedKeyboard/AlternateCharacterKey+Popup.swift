import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

extension AlternateCharacterKey.CharacterButton {
    /// An ordinary character key (not the keyboard switcher, not a
    /// preference-writing quick-symbol slot): its popup opens with a visible
    /// default alternate already selected.
    private var opensOnDefaultAlternate: Bool { !layoutPicker && !requiresExplicitAlternateSelection }

    /// The hold delay elapsed. An ordinary key counts as held only once its
    /// popup has actually opened (`showAlternates` sets `didHold`): if the
    /// popup cannot open, the press stays a tap, so releasing on the key still
    /// types it instead of being silently dropped. The keyboard switcher and
    /// the quick-symbol slots keep swallowing that release — typing their
    /// primary action after a long press is never what was meant, and nothing
    /// here can reach their preference writes.
    func holdDelayElapsed() {
        holdTimer = nil
        if !opensOnDefaultAlternate { didHold = true }
        showAlternates()
    }

    /// The popup release uses the one pure policy
    /// (`AlternateDragPicker.releaseResolution`): only a highlighted, fully
    /// visible option commits; a deliberate horizontal slide-out, a
    /// deliberate drop away below the opening point (the cancel an edge key
    /// can reach), or a highlight scrolled out of view, commits nothing. An ordinary key's
    /// popup opens on its default alternate, so a stationary hold commits
    /// that alternate. The keyboard switcher keeps its own preselected
    /// default, and the quick-symbol slots commit (write a setting) only
    /// after an explicit selection; neither ever types its primary action.
    func popupReleaseSelection(at point: CGPoint, in popup: UIScrollView) -> KeyCap? {
        guard let window, let geometry = liveDragGeometry(in: popup) else { return nil }
        let resolution = AlternateDragPicker.releaseResolution(
            highlighted: highlightedAlternate,
            point: popup.convert(point, from: window),
            geometry: geometry,
            drop: dragDrop(at: point))
        guard case .alternate(let index) = resolution else { return nil }
        guard cellAlternates.indices.contains(index) else { return nil }
        return alternates[cellAlternates[index]]
    }

    /// The blind-drag grid clipped to what the popup shows right now. A
    /// scroll view's bounds are its viewport in content coordinates and move
    /// with the edge auto-scroll, so a row scrolled out of view (or a cell
    /// clipped by the popup frame) is neither highlighted nor committed.
    private func liveDragGeometry(in popup: UIScrollView) -> AlternateDragPicker.Geometry? {
        dragGeometry?.withViewport(popup.bounds)
    }

    /// Screen-space downward travel of a window point since the popup
    /// opened: what `AlternateDragPicker` measures the drop-away cancel on.
    func dragDrop(at point: CGPoint) -> Double {
        Double(point.y - dragOriginInWindow.y)
    }

    /// The keyboard is hiding or this key became another key under the finger:
    /// the rest of the touch (a slide-off, a lift on the key) types nothing.
    @objc func abandonPress() {
        cancelPress()
        consumed = isTracking
    }

    @objc func cancelPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        scrollTimer?.invalidate()
        scrollTimer = nil
        popup?.removeFromSuperview()
        popup = nil
        // A released key keeps its callout for a moment, like the system keyboard;
        // the next press takes the callout over at once.
        keyPreview?.hide(for: self, immediately: false)
        keyPreview = nil
        popupLabels = []
        layoutCheckmarks = [:]
        cellAlternates = []
        popupHost = nil
        highlightedAlternate = nil
        explicitSelection = ExplicitAlternateSelection()
        dragGeometry = nil
        motionGuard = nil
        dragAnchor = nil
        didHold = false
        didSwipeUp = false
        slidOff = false
        exitedUpward = false
        resetLetterSwipe()
        KeyRollover.release(self)
        isHighlighted = false
    }

    private func showAlternates() {
        guard isHighlighted, window != nil, let host = popupSurface, host.window == window,
            !alternates.isEmpty
        else { return }
        holdTimer = nil
        keyPreview?.hide(for: self, immediately: true)
        keyPreview = nil
        let keyFrame = convert(bounds, to: host)
        let safe = host.bounds.insetBy(dx: 6, dy: 6)
        guard safe.width >= 48, safe.height >= 48 else { return }
        // Keep the fifth choice (four keyboards plus tools) visible above the
        // language key on a standard-height keyboard. Larger lists still scroll;
        // each option retains its 44-point touch target.
        let rowHeight: CGFloat = layoutPicker ? 44 : 46
        let font = appearance.uiFont(
            layoutPicker
                ? appearance.controlTextSize
                : min(20, appearance.skin.typography.keySize))
        // Content width: measured from the longest entry's text + checkmark/insets, clamped within the available screen bounds;
        // not a fixed full width, and layout names are not force-truncated.
        let textWidth = alternates.reduce(CGFloat(0)) { longest, alternate in
            max(longest, (alternate.title as NSString).size(withAttributes: [.font: font]).width)
        }
        let cellWidth: CGFloat
        let columns: Int
        if layoutPicker {
            columns = 1
            cellWidth = min(max(textWidth + 56, 150), safe.width)
        } else {
            let cell = max(44, min(72, textWidth + 20))
            columns = max(1, min(alternates.count, Int((safe.width + 4) / (cell + 4))))
            cellWidth = cell
        }
        let width = CGFloat(columns) * cellWidth + CGFloat(max(0, columns - 1)) * 4
        let rows = (alternates.count + columns - 1) / columns
        let contentHeight = CGFloat(rows) * rowHeight
        // About 5 rows visible, the rest scrolls; prefers expanding upward so the height does not take over the whole keyboard.
        let maxVisible = layoutPicker ? 5 : max(rows, 1)
        // A popup never shows a half row; a list taller than its room shrinks to whole rows that
        // scroll. An ordinary popup prefers the room above the key (at least two rows); the menu
        // may cover a few points of the held key (the drag maps by position, not by hit).
        let above = keyFrame.minY - safe.minY - 6
        let room = layoutPicker ? safe.height : min(max(above, rowHeight * 2), safe.height)
        let fitting = max(1, (room / rowHeight).rounded(.down))
        let height = min(contentHeight, CGFloat(maxVisible) * rowHeight, fitting * rowHeight)
        // An ordinary popup grows from the key toward the screen centre, so its
        // first option sits right above the finger: left-half keys open to the
        // right, right-half keys mirror and open to the left.
        let mirrored = !layoutPicker && keyFrame.midX > host.bounds.midX
        let preferredX =
            layoutPicker
            ? keyFrame.midX - width / 2
            : (mirrored ? keyFrame.maxX - width : keyFrame.minX)
        let x = min(max(preferredX, safe.minX), max(safe.minX, safe.maxX - width))
        cellAlternates = (0..<alternates.count).map { cell in
            let row = cell / columns, column = cell % columns
            let inRow = min(columns, alternates.count - row * columns)
            return row * columns + (mirrored ? inRow - 1 - column : column)
        }
        let y = max(safe.minY, min(keyFrame.minY - height - 6, safe.maxY - height))
        let scroll = UIScrollView(frame: CGRect(x: x, y: y, width: width, height: height))
        // Blind-drag grid in the popup's content space. Rows are packed edge
        // to edge (label y = row * rowHeight), columns 4pt apart — exactly the
        // label frames built below.
        let grid = AlternateDragPicker.Geometry(
            optionCount: alternates.count, columns: columns,
            cellWidth: Double(cellWidth),
            cellHeight: Double(rowHeight),
            spacing: 4, rowSpacing: 0)
        // An ordinary key opens on a deterministic default that is actually on
        // screen (the first fully visible alternate — the key-face hint). A
        // popup that could show none is not an opened popup: the press stays a
        // tap rather than a hold that can commit nothing.
        // The default is the first alternate (in alternate order) whose cell is
        // fully visible — the rightmost cell for a mirrored popup.
        let visibleGrid = grid.withViewport(scroll.bounds)
        let openingDefault =
            opensOnDefaultAlternate
            ? (0..<alternates.count).lazy
                .compactMap { alternate in self.cellAlternates.firstIndex(of: alternate) }
                .first { visibleGrid.isVisible(index: $0) }
            : nil
        if opensOnDefaultAlternate, openingDefault == nil { return }
        scroll.contentSize = CGSize(width: width, height: contentHeight)
        scroll.backgroundColor = appearance.uiColor("key")
        scroll.layer.cornerRadius =
            layoutPicker
            ? max(12, appearance.skin.keycap.cornerRadius)
            : appearance.skin.keycap.cornerRadius
        scroll.layer.borderWidth = appearance.skin.keycap.borderWidth
        scroll.layer.borderColor = appearance.uiColor("border").cgColor
        scroll.isUserInteractionEnabled = false
        scroll.accessibilityElementsHidden = true  // VoiceOver uses ordered custom actions.
        // iOS 26 blurs scroll edges by default. The popup is clamped inside the
        // shorter 26-key panel, so the list scrolls and the top option was blurred.
        if #available(iOS 26.0, *) {
            scroll.topEdgeEffect.isHidden = true
            scroll.bottomEdgeEffect.isHidden = true
        }
        for (index, alternateIndex) in cellAlternates.enumerated() {
            let alternate = alternates[alternateIndex]
            let label = UILabel()
            if layoutPicker {
                // Leading/trailing insets come from the paragraph style; the
                // highlight fills the full inset row (iOS menu geometry).
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = 12
                style.headIndent = 12
                style.tailIndent = alternate.subtitle != nil ? -34 : -12
                style.lineBreakMode = .byTruncatingTail
                label.attributedText = NSAttributedString(
                    string: alternate.title,
                    attributes: [.paragraphStyle: style])
            } else {
                label.text = alternate.title
            }
            if layoutPicker, alternate.subtitle != nil {
                // A real checkmark glyph on the trailing edge, not " ✓" glued to the name.
                let check = UIImageView(
                    image: UIImage(
                        systemName: "checkmark",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
                check.tintColor = appearance.uiAccentForeground
                check.contentMode = .center
                check.frame = CGRect(x: cellWidth - 8 - 30, y: 0, width: 26, height: rowHeight)
                label.addSubview(check)
                layoutCheckmarks[index] = check
            }
            label.textAlignment = layoutPicker ? .left : .center
            label.font = font
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.layer.cornerRadius = 7
            label.clipsToBounds = true
            let column = index % columns
            let row = index / columns
            label.frame =
                layoutPicker
                ? CGRect(x: 4, y: CGFloat(row) * rowHeight, width: cellWidth - 8, height: rowHeight)
                : CGRect(
                    x: CGFloat(column) * (cellWidth + 4), y: CGFloat(row) * rowHeight,
                    width: cellWidth, height: rowHeight)
            scroll.addSubview(label)
            popupLabels.append(label)
        }
        host.addSubview(scroll)
        popupHost = host
        popupHostSize = host.bounds.size
        popup = scroll
        // Blind drag baseline: the origin and the grid in the popup's content
        // space. The origin is the long-press point (the finger is on the key,
        // usually *below* the popup), so horizontal distance from it — not a
        // cell hit — addresses the columns.
        dragOrigin = scroll.convert(lastLocation, from: window)
        dragOriginInWindow = lastLocation
        dragGeometry = grid
        // The popup is really open: from here the release belongs to it.
        didHold = true
        if let openingDefault {
            // Selected and painted before the finger moves (the
            // `updateSelection` below keeps it through the dead zone), so a
            // stationary release commits exactly what is highlighted.
            highlightedAlternate = openingDefault
            dragAnchor = openingDefault
            motionGuard = AlternateDragPicker.MotionGuard(origin: dragOrigin)
        }
        explicitSelection.begin(
            x: Double(lastLocation.x), y: Double(lastLocation.y),
            overlappingItem: popupItem(at: lastLocation))
        scroll.flashScrollIndicators()
        // Leaving the window cancels the press, which invalidates this timer;
        // a timer that outlives its key stops itself.
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] timer in
            let alive = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                self.advancePopupScroll()
                return true
            }
            if !alive { timer.invalidate() }
        }
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateSelection(at: lastLocation)
    }

    /// Letter callout for 26-key caps, drawn as one shape with the keycap like the
    /// system keyboard. It lives in the same panel-local clipped overlay as
    /// alternate popups, so the top row is clamped inside the keyboard instead of
    /// changing panel height.
    var showsCallout: Bool { showsKeyPreview && cap?.title.count == 1 }

    func showKeyPreviewIfNeeded() {
        guard showsCallout, let cap, let host = popupSurface, host.window == window else { return }
        let safe = host.bounds.insetBy(dx: 4, dy: 4)
        guard safe.width >= 44, safe.height >= 44 else { return }
        let keyRect = convert(appearance.visualRect(in: bounds), to: host)
        let width = min(max(48, keyRect.width * 1.2), safe.width)
        // The top row has little room above it inside the keyboard: a shorter bubble that
        // still sits on the key keeps the joined shape; only when even that does not fit
        // does the bubble overlap the key.
        let wanted = min(max(52, keyRect.height * 1.12), safe.height)
        let room = keyRect.minY - safe.minY
        let height = room >= 36 ? min(wanted, room) : wanted
        let x = min(max(keyRect.midX - width / 2, safe.minX), safe.maxX - width)
        let y = max(safe.minY, keyRect.minY - height)
        let callout = KeyCalloutView.shared(in: host)
        callout.show(
            cap.title, bubble: CGRect(x: x, y: y, width: width, height: height), key: keyRect,
            keyRadius: appearance.skin.keycap.cornerRadius,
            fill: appearance.uiColor("key"), textColor: appearance.text(on: "key"),
            border: appearance.uiColor("border"), borderWidth: appearance.skin.keycap.borderWidth,
            font: appearance.uiFont(max(appearance.keyTextSize + 8, 28)), for: self)
        keyPreview = callout
    }

    private func advancePopupScroll() {
        guard let popup, let window, let host = popupHost else {
            cancelPress()
            return
        }
        guard host.bounds.size == popupHostSize else {
            cancelPress()
            return
        }
        // A popup covering an unmoved finger must not scroll underneath it
        // and manufacture a setting selection.
        guard !requiresExplicitAlternateSelection || explicitSelection.hasDepartedInitialRegion else { return }
        let point = popup.convert(lastLocation, from: window)
        // Nor may it scroll an ordinary key's opening default out of view
        // (a scrolled-out option can never commit) under an unmoved finger.
        if opensOnDefaultAlternate,
            AlternateDragPicker.isWithinDeadZone(origin: dragOrigin, point: point)
        {
            return
        }
        guard popup.bounds.contains(point) else {
            updateSelection(at: lastLocation)
            return
        }
        let edgeY = point.y - popup.bounds.minY
        let direction: CGFloat = edgeY < 20 ? -1 : (edgeY > popup.bounds.height - 20 ? 1 : 0)
        let limit = max(0, popup.contentSize.height - popup.bounds.height)
        popup.contentOffset.y = min(limit, max(0, popup.contentOffset.y + direction * 8))
        updateSelection(at: lastLocation)
    }

    private func popupItem(at point: CGPoint) -> Int? {
        guard let popup, let window else { return nil }
        let local = popup.convert(point, from: window)
        return popup.bounds.contains(local) ? popupLabels.firstIndex(where: { $0.frame.contains(local) }) : nil
    }

    /// The language key's hold menu opens on the *current* keyboard, like the
    /// system globe menu: a long press released in place changes nothing.
    /// (Preselecting the next keyboard made an accidental hold switch layouts.)
    /// Switching or opening Keyboard Settings always takes a deliberate slide.
    private var defaultLayoutAlternate: Int? {
        guard layoutPicker, !alternates.isEmpty else { return nil }
        return alternates.firstIndex {
            $0.id.hasPrefix("user-keyboard:")
                && $0.subtitle == UserTerminology.userKeyboardCurrent
        }
    }

    /// Blind-drag selection. The finger does not have to land on a cell: the
    /// column follows the horizontal distance from the long-press origin
    /// (`AlternateDragPicker`, dead-zoned + hysteretic), the row follows the
    /// clamped vertical position (so drifting above/below the popup keeps the
    /// option), and a deliberate horizontal overshoot still cancels. The
    /// explicit-selection gate for preference-writing pickers is unchanged and
    /// still applied last, so nothing commits below its threshold. An
    /// ordinary key's popup opens on its default alternate (`showAlternates`):
    /// a stationary finger keeps it, and `motionGuard` stops it from jumping
    /// against the finger's motion.
    ///
    /// `emitHighlight` is false on release: the commit path already emits its
    /// own feedback, so the last mapping must not add a second tick.
    func updateSelection(at point: CGPoint, emitHighlight: Bool = true) {
        let mapped: Int?
        if let popup, let window, let geometry = liveDragGeometry(in: popup) {
            let local = popup.convert(point, from: window)
            let proposed = AlternateDragPicker.selection(
                origin: dragOrigin, point: local,
                geometry: geometry, current: highlightedAlternate,
                drop: dragDrop(at: point), anchor: dragAnchor)
            if var motion = motionGuard {
                mapped = motion.resolve(
                    proposed: proposed, current: highlightedAlternate,
                    point: local, geometry: geometry)
                motionGuard = motion
            } else {
                mapped = proposed
            }
        } else {
            mapped = popupItem(at: point)
        }
        let chosen =
            requiresExplicitAlternateSelection
            ? explicitSelection.selection(x: Double(point.x), y: Double(point.y), hitItem: mapped)
            : mapped
        // The popup sits above the held key. Its appearance must immediately
        // highlight a real default even if UIKit relayouts the key by a few
        // points while the finger is stationary. A small natural tremor still
        // counts as holding; a deliberate slide selects another row or cancels.
        let travel = hypot(point.x - layoutHoldOrigin.x, point.y - layoutHoldOrigin.y)
        let index =
            layoutPicker && travel <= 14
            ? defaultLayoutAlternate : chosen
        if emitHighlight, index != highlightedAlternate, index != nil, !layoutPicker {
            // Crossing into a different option while picking an alternate:
            // the same selection haptic the rest of the keyboard uses, without
            // the key click of a commit. The layout menu keeps its existing
            // "highlight only, feedback on commit" behaviour.
            KeyboardFeedbackService.shared.alternateHighlightMoved()
        }
        highlightedAlternate = index
        if let popup, !layoutPicker {
            // Pulling down toward the cancel fades and settles the popup in
            // step with the finger; moving back up restores it.
            let progress = CGFloat(AlternateDragPicker.dropProgress(dragDrop(at: point)))
            popup.alpha = 1 - 0.6 * progress
            let scale = 1 - 0.08 * progress
            popup.transform = CGAffineTransform(translationX: 0, y: 6 * progress)
                .scaledBy(x: scale, y: scale)
        }
        for (offset, view) in popupLabels.enumerated() {
            if layoutPicker {
                // Menu-style highlight: a solid accent fill with white text,
                // no outline (the outline read as a focus ring, not a choice).
                let isHighlighted = offset == index
                view.backgroundColor = isHighlighted ? appearance.uiAccentForeground : .clear
                view.textColor = isHighlighted ? .white : appearance.text(on: "key")
                layoutCheckmarks[offset]?.tintColor = isHighlighted ? .white : appearance.uiAccentForeground
                view.layer.borderWidth = 0
                continue
            }
            let role = offset == index ? "selected" : "key"
            view.backgroundColor = appearance.uiColor(role)
            view.textColor = appearance.text(on: role)
            view.layer.borderWidth = offset == index ? 2 : 0
            view.layer.borderColor = appearance.text(on: role).cgColor
        }
    }
}
