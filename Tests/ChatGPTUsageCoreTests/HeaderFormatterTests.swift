import XCTest
@testable import ChatGPTUsageCore

/// The header is pure formatting, so it gets exact-string tests: the bytes in
/// the menu bar are the product here.
final class HeaderFormatterTests: XCTestCase {

    func test_sessionOnly_rendersThePercentBare() {
        XCTAssertEqual(HeaderFormatter.title(style: .sessionOnly, sessionPercent: 2, weeklyPercent: 47), "2%")
    }

    func test_sessionWeekly_rendersSAndWPrefixes() {
        // The spec's literal example: "S%2 W%47" with S = session, W = weekly.
        XCTAssertEqual(
            HeaderFormatter.title(style: .sessionWeekly, sessionPercent: 2, weeklyPercent: 47),
            "S2% W47%"
        )
    }

    func test_missingWindows_renderAsDashesNeverAsZero() {
        XCTAssertEqual(HeaderFormatter.title(style: .sessionOnly, sessionPercent: nil, weeklyPercent: nil), "--%")
        XCTAssertEqual(
            HeaderFormatter.title(style: .sessionWeekly, sessionPercent: nil, weeklyPercent: 47),
            "S--% W47%"
        )
        XCTAssertEqual(
            HeaderFormatter.title(style: .sessionWeekly, sessionPercent: 100, weeklyPercent: nil),
            "S100% W--%"
        )
    }

    func test_lookup_findsSessionAndWeeklyByDerivedName() {
        let limits = [
            UsageLimit(name: "Weekly", usedFraction: 0.47, resetsAt: nil),
            UsageLimit(name: "Session (5h)", usedFraction: 0.02, resetsAt: nil),
        ]
        XCTAssertEqual(UsageWindowLookup.sessionPercent(in: limits), 2)
        XCTAssertEqual(UsageWindowLookup.weeklyPercent(in: limits), 47)
    }

    func test_lookup_returnsNilForAbsentWindows() {
        XCTAssertEqual(UsageWindowLookup.sessionPercent(in: []), nil)
        XCTAssertEqual(UsageWindowLookup.weeklyPercent(in: [UsageLimit(name: "30-day", usedFraction: 0.5, resetsAt: nil)]), nil)
    }

    func test_lookup_remainingPercent_reportsOneHundredMinusUsed() {
        let limits = [
            UsageLimit(name: "Weekly", usedFraction: 0.47, resetsAt: nil),
            UsageLimit(name: "Session (5h)", usedFraction: 0.02, resetsAt: nil),
        ]
        XCTAssertEqual(UsageWindowLookup.sessionRemainingPercent(in: limits), 98)
        XCTAssertEqual(UsageWindowLookup.weeklyRemainingPercent(in: limits), 53)
    }

    func test_remainingPercentRounded_clampsToZeroAndOneHundred() {
        XCTAssertEqual(UsageLimit(name: "X", usedFraction: 1.0, resetsAt: nil).remainingPercentRounded, 0)
        XCTAssertEqual(UsageLimit(name: "X", usedFraction: 0.0, resetsAt: nil).remainingPercentRounded, 100)
    }

    func test_geminiLookup_findsPrefixedSessionAndWeekly() {
        let limits = [
            UsageLimit(name: "Weekly", usedFraction: 0.47, resetsAt: nil),
            UsageLimit(name: "Gemini Weekly", usedFraction: 0.35, resetsAt: nil),
            UsageLimit(name: "Gemini Session", usedFraction: 0.06, resetsAt: nil),
        ]
        XCTAssertEqual(UsageWindowLookup.geminiSessionPercent(in: limits), 6)
        XCTAssertEqual(UsageWindowLookup.geminiWeeklyPercent(in: limits), 35)
        XCTAssertEqual(UsageWindowLookup.geminiSessionRemainingPercent(in: limits), 94)
        XCTAssertEqual(UsageWindowLookup.geminiWeeklyRemainingPercent(in: limits), 65)
        // The unprefixed matcher must not steal the Gemini rows.
        XCTAssertEqual(UsageWindowLookup.weeklyPercent(in: limits), 47)
    }

    func test_geminiLookup_returnsNilForAbsentWindows() {
        XCTAssertEqual(UsageWindowLookup.geminiSessionPercent(in: []), nil)
        XCTAssertEqual(UsageWindowLookup.geminiWeeklyPercent(in: []), nil)
    }
}
