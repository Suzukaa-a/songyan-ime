import Foundation

/// One rendering host's cancellation channel. Hosts may share an input session,
/// but their gesture notifications and delayed view teardown must remain separate.
public final class KeyboardPanelHostLifetime: NSObject {
    private let isActive: () -> Bool

    public init(isActive: @escaping () -> Bool) {
        self.isActive = isActive
        super.init()
    }

    /// Always stop this host's own gestures, including after another host took over.
    public func notifyDisappearance(name: Notification.Name, center: NotificationCenter = .default) {
        center.post(name: name, object: self)
    }

    /// Evaluate ownership at teardown time, not when the view was constructed.
    public func cancelSharedSelection(_ cancel: () -> Void) {
        guard isActive() else { return }
        cancel()
    }
}
