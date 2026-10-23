#import <UIKit/UIKit.h>

// UIKit declares documentIdentifier nonnull, but an inactive remote proxy can
// return nil during focus/lifecycle transitions. Read the public Objective-C
// property before Swift's unconditional NSUUID -> UUID bridge can trap.
NS_INLINE NSUUID * _Nullable RimeDocumentIdentifier(id<UITextDocumentProxy> _Nonnull proxy) {
    return [proxy documentIdentifier];
}
