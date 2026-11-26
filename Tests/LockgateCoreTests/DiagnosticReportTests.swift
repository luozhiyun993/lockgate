import XCTest
@testable import LockgateCore

final class DiagnosticReportTests: XCTestCase {
    func testMaskedIPKeepsOnlyNetworkPrefix() {
        XCTAssertEqual(DiagnosticReport.maskedIP("204.141.243.28"), "204.141.x.x")
        XCTAssertEqual(DiagnosticReport.maskedIP(" 45.39.65.65 "), "45.39.x.x")
        XCTAssertEqual(DiagnosticReport.maskedIP("2001:db8:1234::1"), "2001:db8:…")
        XCTAssertEqual(DiagnosticReport.maskedIP(""), "已隐藏")
        XCTAssertEqual(DiagnosticReport.maskedIP("not-an-ip"), "已隐藏")
    }

    func testRenderSortsEventsChronologicallyAndRedactsHome() throws {
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            DiagnosticReport.Event(time: base.addingTimeInterval(60), text: "已锁定：出口地区为 US，目标地区为 JP。"),
            DiagnosticReport.Event(time: base, text: "急停软件 /Users/alice/Applications/Foo.app 已添加"),
        ]
        let text = DiagnosticReport.render(summary: [("目标地区", "US"), ("锁定原因", "无")], events: events,
                                           generatedAt: base.addingTimeInterval(120), timeZone: zone, home: "/Users/alice")
        XCTAssertTrue(text.contains("UTC+08:00"))
        XCTAssertTrue(text.contains("目标地区：US\n锁定原因：无"))
        XCTAssertTrue(text.contains("事件记录（2 条"))
        XCTAssertFalse(text.contains("/Users/alice"))
        XCTAssertTrue(text.contains("~/Applications/Foo.app"))
        let first = try XCTUnwrap(text.range(of: "急停软件"))
        let second = try XCTUnwrap(text.range(of: "已锁定"))
        XCTAssertTrue(first.lowerBound < second.lowerBound, "events must be oldest first")
        XCTAssertTrue(text.contains("2027-01-15 16:00:00  急停软件"))
    }
}
