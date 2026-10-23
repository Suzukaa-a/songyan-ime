// macOS has no UIKit; the extracted level enum only touches the fallback impact
// style, mirrored here from UIImpactFeedbackGenerator.FeedbackStyle.
import CoreGraphics

struct UIImpactFeedbackGenerator {
    enum FeedbackStyle: Equatable {
        case soft, light, medium, heavy, rigid
    }
}
