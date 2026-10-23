#if canImport(AppKit)
    import AppKit
    import SwiftUI
    import XCTest
    import KeyboardCore
    @testable import CandidateKit

    @available(macOS 14.0, *)
    final class ExpandedLoadingViewTests: XCTestCase {
        @MainActor
        func testShortExpandedViewportRequestsReadWithoutScrolling() async {
            let state = CandidatePresentationState(
                schemaID: "test", rawInput: "chun",
                candidates: (0..<15).map { Candidate(index: $0, text: "春") },
                pageSize: 15, canPageForward: true, isComposing: true)
            var browser = CandidateBrowser()
            browser.reset(state)
            var reads = 0
            let context = CandidateAreaContext(
                state: state, bar: .systemDefault,
                actions: CandidateAreaActionSink { action in
                    XCTAssertEqual(action, .loadMore)
                    reads += 1
                }, typography: .init(candidateSize: 20, secondarySize: 10), browser: browser, isExpanded: true)
            let host = NSHostingView(rootView: DefaultCandidateAreaRenderer().expandedView(context: context))
            host.frame = NSRect(x: 0, y: 0, width: 402, height: 162)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // A real SwiftUI lifecycle, no scroll gesture and no call to a model-only helper.
            for _ in 0..<10 {
                if reads >= 3 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // The viewport's initial task, the prefetch row (the first row of a list
            // shorter than the prefetch distance) and the visible footer all mount.
            // The sink deliberately leaves state unchanged so each identity fires once;
            // the controller drops repeats of a read already in flight.
            XCTAssertEqual(reads, 3)
            print("EXPANDED_SHORT_VIEWPORT_INITIAL_AND_FOOTER_READS=\(reads)")
            window.contentView = nil
        }
    }
#endif
