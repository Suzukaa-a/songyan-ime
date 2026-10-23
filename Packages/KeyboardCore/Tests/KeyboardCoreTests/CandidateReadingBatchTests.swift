import XCTest

@testable import KeyboardCore

final class CandidateReadingBatchTests: XCTestCase {
    @MainActor
    func testPrefetchPublishesOneOrderedBatchFromEightSmallHops() async throws {
        var offsets: [Int] = []
        var sizes: [Int] = []
        let batch = try await CandidateReadingBatch.read(
            fromIndex: 0, count: 64, quantum: 8,
            isCurrent: { true },
            fetch: { offset, count in
                offsets.append(offset)
                sizes.append(count)
                return (offset..<(offset + count)).map {
                    ReadingCandidate(index: $0, text: "word", syllables: ["reading\($0)"])
                }
            })
        XCTAssertEqual(offsets, Array(stride(from: 0, to: 64, by: 8)))
        XCTAssertEqual(sizes, Array(repeating: 8, count: 8))
        XCTAssertEqual(batch?.map(\.index), Array(0..<64))
        var filter = CandidateReadingFilter()
        filter.reset(revision: 1)
        filter.append(try XCTUnwrap(batch), requested: 64, revision: 1)
        XCTAssertEqual(filter.options.count, 64)
        XCTAssertTrue(filter.hasMore)
    }

    @MainActor
    func testSmallSchemaPageAndShortFinalHopPreserveEOF() async throws {
        var calls = 0
        let batch = try await CandidateReadingBatch.read(
            fromIndex: 10, count: 64, quantum: 3,
            isCurrent: { true },
            fetch: { offset, count in
                calls += 1
                return (offset..<min(offset + count, 15)).map { ReadingCandidate(index: $0, text: "word") }
            })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(batch?.map(\.index), Array(10..<15))
    }

    @MainActor
    func testInputChangeCancelsBeforeNextHop() async throws {
        var current = true
        var calls = 0
        do {
            _ = try await CandidateReadingBatch.read(
                fromIndex: 0, count: 64, quantum: 8,
                isCurrent: { current },
                fetch: { offset, count in
                    calls += 1
                    current = false
                    return (offset..<(offset + count)).map { ReadingCandidate(index: $0, text: "word") }
                })
            XCTFail("Old composition must not publish")
        } catch is CancellationError {}
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testInputChangeDuringFinalHopIsAlsoDiscarded() async throws {
        var current = true
        do {
            _ = try await CandidateReadingBatch.read(
                fromIndex: 0, count: 8, quantum: 8,
                isCurrent: { current },
                fetch: { offset, count in
                    current = false
                    return (offset..<(offset + count)).map { ReadingCandidate(index: $0, text: "word") }
                })
            XCTFail("Final-hop staleness must be checked")
        } catch is CancellationError {}
    }

    @MainActor
    func testUnsupportedBackendDoesNotReturnPartialReadings() async throws {
        let batch = try await CandidateReadingBatch.read(
            fromIndex: 0, count: 64, quantum: 8,
            isCurrent: { true },
            fetch: { offset, count in
                if offset > 0 { return nil }
                return (offset..<(offset + count)).map { ReadingCandidate(index: $0, text: "word") }
            })
        XCTAssertNil(batch)
    }

    @MainActor
    func testFailureDoesNotReturnPartialReadings() async throws {
        enum ProbeError: Error { case failed }
        do {
            _ = try await CandidateReadingBatch.read(
                fromIndex: 0, count: 64, quantum: 8,
                isCurrent: { true },
                fetch: { offset, count in
                    if offset > 0 { throw ProbeError.failed }
                    return (offset..<(offset + count)).map { ReadingCandidate(index: $0, text: "word") }
                })
            XCTFail("Failure must not publish a partial column")
        } catch ProbeError.failed {}
    }

    @MainActor
    func testInvalidBoundsAndMalformedPagesFailClosed() async throws {
        for (count, quantum) in [(0, 8), (65, 8), (64, 0), (64, 9)] {
            do {
                _ = try await CandidateReadingBatch.read(
                    fromIndex: 0, count: count, quantum: quantum,
                    isCurrent: { true },
                    fetch: { _, _ in
                        XCTFail("Invalid request reached engine")
                        return []
                    })
                XCTFail("Invalid bounds accepted")
            } catch CandidateReadingBatch.ReadError.invalidRequest {}
        }
        do {
            _ = try await CandidateReadingBatch.read(
                fromIndex: 0, count: 8, quantum: 8,
                isCurrent: { true }, fetch: { _, _ in [ReadingCandidate(index: 1, text: "wrong offset")] })
            XCTFail("Wrong absolute index accepted")
        } catch CandidateReadingBatch.ReadError.invalidPage {}
    }

    @MainActor
    func testFilteredBatchStopsAtAFullRowAndPublishesOnce() async throws {
        var filter = CandidateReadingFilter()
        filter.reset(revision: 1)
        filter.append([ReadingCandidate(index: 0, text: "你", syllables: ["ni"])], requested: 1, revision: 1)
        filter.select("ni")
        var calls = 0
        let batch = try await CandidateReadingBatch.read(
            fromIndex: 1, count: 64, quantum: 8,
            isCurrent: { true }, enough: { filter.matchCount(in: $0) >= 12 },
            fetch: { offset, count in
                calls += 1
                // Every other candidate matches the selected reading.
                return (offset..<(offset + count)).map {
                    ReadingCandidate(index: $0, text: "词", syllables: [$0.isMultiple(of: 2) ? "ni" : "mi"])
                }
            })
        XCTAssertEqual(calls, 3, "12 matches need three 8-candidate hops, not the whole 64")
        XCTAssertEqual(batch?.count, 24)
        XCTAssertEqual(filter.matchCount(in: try XCTUnwrap(batch)), 12)
    }
}
