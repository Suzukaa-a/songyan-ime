import XCTest

@testable import KeyboardCore

/// Quick-insert logic tests: only cover meaningful target-capture order, on-demand date computation and reset.
final class QuickInsertTests: XCTestCase {

    // MARK: - Fixed instant and time zone (Asia/Shanghai, local 14:30 = 06:30 UTC)

    private static var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func localDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int = 0,
        calendar: Calendar? = nil
    ) -> Date {
        let cal = calendar ?? shanghai
        return cal.date(
            from: DateComponents(
                year: year, month: month, day: day,
                hour: hour, minute: minute, second: second))!
    }

    private func newDefaults() -> (suite: String, defaults: UserDefaults) {
        let suite = "quickinsert.tests.\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    private func makeCore(
        store: QuickInsertFormatStore? = nil,
        now: @escaping () -> Date = { QuickInsertTests.localDate(2026, 9, 9, 14, 30) },
        insert: @escaping (String) -> Void = { _ in }
    ) -> QuickInsertCore {
        QuickInsertCore(
            formatStore: store ?? QuickInsertFormatStore(defaults: .standard),
            now: now,
            calendar: Self.shanghai,
            insert: insert)
    }

    // MARK: - Date/time formats: fixed output

    func testFixedDateTimeFormatting() {
        let now = Self.localDate(2026, 9, 9, 14, 30)
        XCTAssertEqual(QuickInsertFormatting.text(.date, at: now, calendar: Self.shanghai), "2026-09-09")
        XCTAssertEqual(QuickInsertFormatting.text(.dateChinese, at: now, calendar: Self.shanghai), "2026年9月9日")
        XCTAssertEqual(QuickInsertFormatting.text(.time, at: now, calendar: Self.shanghai), "14:30")
        XCTAssertEqual(QuickInsertFormatting.text(.dateTime, at: now, calendar: Self.shanghai), "2026-09-09 14:30")
        XCTAssertEqual(
            QuickInsertFormatting.text(.dateTimeChinese, at: now, calendar: Self.shanghai), "2026年9月9日 14:30")
    }

    func testDateTimeZeroPaddingAndUnpaddedChineseMonthDay() {
        let now = Self.localDate(2026, 1, 2, 9, 5)
        XCTAssertEqual(QuickInsertFormatting.text(.date, at: now, calendar: Self.shanghai), "2026-01-02")
        XCTAssertEqual(QuickInsertFormatting.text(.time, at: now, calendar: Self.shanghai), "09:05")
        XCTAssertEqual(QuickInsertFormatting.text(.dateChinese, at: now, calendar: Self.shanghai), "2026年1月2日")
    }

    func testFormattingFollowsInjectedTimeZone() {
        let localShanghai = Self.localDate(2026, 9, 9, 14, 30)  // that instant
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(QuickInsertFormatting.text(.time, at: localShanghai, calendar: utc), "06:30")
        XCTAssertEqual(QuickInsertFormatting.text(.time, at: localShanghai, calendar: Self.shanghai), "14:30")
    }

    // MARK: - On-demand dates: not cached across midnight

    func testFormattingAcrossMidnightIsNotCached() {
        let before = Self.localDate(2026, 9, 9, 23, 59)
        let after = Self.localDate(2026, 9, 10, 0, 1)
        XCTAssertNotEqual(
            QuickInsertFormatting.text(.date, at: before, calendar: Self.shanghai),
            QuickInsertFormatting.text(.date, at: after, calendar: Self.shanghai))
        XCTAssertEqual(QuickInsertFormatting.text(.date, at: before, calendar: Self.shanghai), "2026-09-09")
        XCTAssertEqual(QuickInsertFormatting.text(.date, at: after, calendar: Self.shanghai), "2026-09-10")
    }

    func testCoreDateInsertRecomputesAtEveryTap() {
        var clock = Self.localDate(2026, 9, 9, 23, 59)
        var inserted: [String] = []
        let core = QuickInsertCore(
            formatStore: QuickInsertFormatStore(defaults: .standard),
            now: { clock },
            calendar: Self.shanghai,
            insert: { inserted.append($0) })
        XCTAssertTrue(core.insertDateFormat(.date))
        clock = Self.localDate(2026, 9, 10, 0, 1)  // simulate tapping again after midnight
        XCTAssertTrue(core.insertDateFormat(.date))
        XCTAssertEqual(inserted, ["2026-09-09", "2026-09-10"])
    }

    // MARK: - Repeat: target capture order and recording

    func testRepeatReinsertsRecordedCommitAndContinues() {
        var inserted: [String] = []
        let core = makeCore(insert: { inserted.append($0) })
        core.recordCommitted("北京欢迎你")
        XCTAssertTrue(core.hasRepeatableText)
        XCTAssertEqual(core.repeatPreview, "北京欢迎你")
        XCTAssertTrue(core.performRepeat())
        XCTAssertEqual(inserted, ["北京欢迎你"])
        XCTAssertEqual(core.lastCommittedText, "北京欢迎你")
        XCTAssertTrue(core.performRepeat())
        XCTAssertEqual(inserted, ["北京欢迎你", "北京欢迎你"])
    }

    func testRepeatCapturesTargetBeforeConfirmSoConfirmCommitCannotBecomeTarget() {
        var inserted: [String] = []
        let core = makeCore(insert: { inserted.append($0) })
        core.recordCommitted("甲")
        // Simulate: a current composition exists, and the confirm action records the just-confirmed composition word through the commit exit.
        core.confirmComposition = {
            core.recordCommitted("乙")
            return true
        }
        XCTAssertTrue(core.performRepeat())
        XCTAssertEqual(
            inserted, ["甲"],
            "what is repeated must be the original target from before confirm, not the composition word produced by confirm"
        )
        XCTAssertEqual(core.lastCommittedText, "甲", "the confirm callback must not pollute the original repeat target")
        XCTAssertTrue(core.performRepeat())
        XCTAssertEqual(inserted, ["甲", "甲"])
    }

    func testEnglishAndMultilineCommitsAreRecordedAndRepeatedExactly() {
        var inserted: [String] = []
        let core = makeCore(insert: { inserted.append($0) })
        core.recordCommitted("hello")
        XCTAssertEqual(core.lastCommittedText, "hello")
        core.recordCommitted("第一行\n第二行")
        XCTAssertEqual(core.lastCommittedText, "第一行\n第二行")
        XCTAssertEqual(
            core.repeatPreview, "第一行 第二行",
            "the preview collapses to one line while the insert still uses the full original text")
        XCTAssertTrue(core.performRepeat())
        XCTAssertEqual(inserted, ["第一行\n第二行"])
    }

    func testLongPreviewIsTruncatedForDisplayOnly() {
        let text = String(repeating: "长", count: 40)
        XCTAssertEqual(
            QuickInsertRecentText.preview(for: text),
            String(repeating: "长", count: 23) + "…")
    }

    // MARK: - Repeat: no record / failure / reset

    func testNoRecordHidesRepeatAndDoesNothing() {
        var confirmed = false
        var inserted: [String] = []
        let core = makeCore(insert: { inserted.append($0) })
        core.confirmComposition = {
            confirmed = true
            return true
        }
        XCTAssertFalse(core.hasRepeatableText)
        XCTAssertFalse(core.performRepeat())
        XCTAssertFalse(confirmed, "with no record not even composition confirm should fire")
        XCTAssertTrue(inserted.isEmpty)
    }

    func testWhitespaceOnlyCommitsAreIgnored() {
        let core = makeCore()
        core.recordCommitted(" ")
        XCTAssertNil(core.lastCommittedText)
        core.recordCommitted("\n")
        XCTAssertNil(core.lastCommittedText)
        core.recordCommitted(" \t ")
        XCTAssertNil(core.lastCommittedText)
        core.recordCommitted(" 好 ")
        XCTAssertEqual(core.lastCommittedText, " 好 ", "a commit with visible content is kept as is")
    }

    func testConfirmFailureStopsRepeatAndKeepsTarget() {
        var inserted: [String] = []
        let core = makeCore(insert: { inserted.append($0) })
        core.recordCommitted("甲")
        core.confirmComposition = { false }
        XCTAssertFalse(core.performRepeat())
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(core.lastCommittedText, "甲")
    }

    func testDispatchRefusalDoesNotFallBackOrRestoreOldDocumentTarget() {
        var legacyCalls = 0
        let core = makeCore(insert: { _ in legacyCalls += 1 })
        core.recordCommitted("旧文档")
        core.dispatchInsert = { _ in
            core.resetContext()
            return false
        }
        XCTAssertFalse(core.performRepeat())
        XCTAssertNil(core.lastCommittedText)
        XCTAssertEqual(legacyCalls, 0)
    }

    func testReadOnlyStoreKeepsTheChosenFormatForTheSessionOnly() {
        let (suite, defaults) = newDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = QuickInsertCore(formatStore: QuickInsertFormatStore(defaults: defaults, persists: { false }))
        core.dispatchInsert = { _ in true }
        XCTAssertTrue(core.insertDateFormat(.time))
        XCTAssertEqual(core.selectedFormat, .time)
        XCTAssertNil(defaults.string(forKey: QuickInsertFormatStore.selectedFormatKey))
    }

    func testRejectedDateDoesNotRememberFormatOrReplaceRecent() {
        let (suite, defaults) = newDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = QuickInsertCore(formatStore: QuickInsertFormatStore(defaults: defaults))
        core.recordCommitted("之前")
        core.dispatchInsert = { _ in false }
        XCTAssertFalse(core.insertDateFormat(.time))
        XCTAssertEqual(core.selectedFormat, .date)
        XCTAssertNil(defaults.string(forKey: QuickInsertFormatStore.selectedFormatKey))
        XCTAssertEqual(core.lastCommittedText, "之前")
        core.dispatchInsert = { _ in true }
        XCTAssertTrue(core.insertDateFormat(.time))
        XCTAssertEqual(core.selectedFormat, .time)
    }

    func testResetContextClearsRepeatTarget() {
        var confirmed = false
        var inserted: [String] = []
        let core = makeCore(insert: { inserted.append($0) })
        core.confirmComposition = {
            confirmed = true
            return true
        }
        core.recordCommitted("甲")
        XCTAssertTrue(core.hasRepeatableText)
        core.resetContext()
        XCTAssertFalse(core.hasRepeatableText)
        XCTAssertNil(core.lastCommittedText)
        XCTAssertFalse(core.performRepeat())
        XCTAssertFalse(confirmed)
        XCTAssertTrue(inserted.isEmpty)
    }

    func testResetKeepsSelectedDateFormat() {
        let core = makeCore()
        XCTAssertTrue(core.insertDateFormat(.time))
        core.resetContext()
        XCTAssertEqual(core.selectedFormat, .time)
    }

    // MARK: - Date insertion: confirm first, remember format, keep format on reopen

    func testDateInsertConfirmsCompositionFirstAndRemembersFormat() {
        var inserted: [String] = []
        var confirmed = 0
        let core = makeCore(insert: { inserted.append($0) })
        core.confirmComposition = {
            confirmed += 1
            return true
        }
        XCTAssertTrue(core.insertDateFormat(.dateChinese))
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(inserted, ["2026年9月9日"])
        XCTAssertEqual(core.selectedFormat, .dateChinese)
    }

    func testDateFormatChoicePersistsAcrossReopenAndInvalidValueFallsBack() {
        let (suite, defaults) = newDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickInsertFormatStore(defaults: defaults)

        let first = QuickInsertCore(
            formatStore: store, now: { Self.localDate(2026, 9, 9, 14, 30) }, calendar: Self.shanghai)
        XCTAssertEqual(first.selectedFormat, .date, "defaults to the date format when nothing is saved")
        XCTAssertTrue(first.insertDateFormat(.time))
        XCTAssertEqual(first.selectedFormat, .time)

        let reopened = QuickInsertCore(
            formatStore: QuickInsertFormatStore(defaults: defaults),
            now: { Self.localDate(2026, 9, 9, 14, 30) },
            calendar: Self.shanghai)
        XCTAssertEqual(reopened.selectedFormat, .time, "the format is kept across reopen")

        defaults.set("not-a-real-format", forKey: QuickInsertFormatStore.selectedFormatKey)
        let afterCorrupt = QuickInsertCore(
            formatStore: QuickInsertFormatStore(defaults: defaults),
            now: { Self.localDate(2026, 9, 9, 14, 30) },
            calendar: Self.shanghai)
        XCTAssertEqual(
            afterCorrupt.selectedFormat, .date,
            "an unknown saved value falls back to the default, no format is fabricated")
    }

    func testStorePersistsOnlyFormatChoiceNeverUserContent() {
        let (suite, defaults) = newDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = QuickInsertCore(
            formatStore: QuickInsertFormatStore(defaults: defaults),
            now: { Self.localDate(2026, 9, 9, 14, 30) },
            calendar: Self.shanghai)
        core.recordCommitted("不应被持久化的用户文本")
        _ = core.insertDateFormat(.time)
        let storedKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("quickInsert") }
        XCTAssertEqual(
            Array(storedKeys), [QuickInsertFormatStore.selectedFormatKey],
            "only the format is saved, never the committed content")
        XCTAssertEqual(defaults.string(forKey: QuickInsertFormatStore.selectedFormatKey), "time")
    }
}
