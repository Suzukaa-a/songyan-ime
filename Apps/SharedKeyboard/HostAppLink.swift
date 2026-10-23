import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Opens the host app from the keyboard extension.
///
/// A keyboard extension cannot present anything except its own input view, so going to the app is
/// a URL hop. `extensionContext.open` is reserved for Today widgets and never opens anything from a
/// keyboard, and `UIApplication.shared` is unavailable to extensions, so the application object is
/// found on the responder chain of the keyboard's own view controller instead.
public enum HostAppLink {
    /// The scheme the host app registers; it must match that app's `CFBundleURLSchemes`.
    public static let scheme = "songyan"

    public static var settingsURL: URL? { URL(string: scheme + "://open") }

    #if canImport(UIKit)
        /// Reports whether the system accepted the hop, so the panel never leaves a tap that did nothing.
        @MainActor
        public static func open(
            _ url: URL, from responder: UIResponder?,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            var next = responder
            while let current = next {
                if let application = current as? UIApplication {
                    application.open(url, options: [:]) { accepted in
                        Task { @MainActor in completion(accepted) }
                    }
                    return
                }
                next = current.next
            }
            completion(false)
        }
    #else
        @MainActor
        public static func open(
            _ url: URL, from responder: AnyObject?,
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            completion(false)
        }
    #endif
}
