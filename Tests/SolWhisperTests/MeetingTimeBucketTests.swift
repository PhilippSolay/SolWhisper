import XCTest
@testable import SolWhisper

final class MeetingTimeBucketTests: XCTestCase {

    private var calendar: Calendar!
    private var reference: Date!

    override func setUp() {
        super.setUp()
        // Pin the calendar to UTC + a fixed reference time so the buckets are deterministic.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        calendar = cal

        // Reference: Wednesday 2026-05-13 12:00 UTC. Mid-week so This Week is non-trivial.
        var components = DateComponents()
        components.year = 2026; components.month = 5; components.day = 13
        components.hour = 12; components.minute = 0
        reference = calendar.date(from: components)!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour
        return calendar.date(from: c)!
    }

    // MARK: - Bucket lookup

    func testTodayBucket() {
        XCTAssertEqual(MeetingTimeBucket.bucket(for: reference,
                                                 reference: reference,
                                                 calendar: calendar), .today)
    }

    func testYesterdayBucket() {
        let y = calendar.date(byAdding: .day, value: -1, to: reference)!
        XCTAssertEqual(MeetingTimeBucket.bucket(for: y, reference: reference, calendar: calendar),
                       .yesterday)
    }

    func testThisWeekBucketForSameWeekDifferentDay() {
        // Monday of the same week (2026-05-11)
        let m = date(2026, 5, 11)
        XCTAssertEqual(MeetingTimeBucket.bucket(for: m, reference: reference, calendar: calendar),
                       .thisWeek)
    }

    func testEarlierBucketForLastWeek() {
        let lastWeek = calendar.date(byAdding: .day, value: -8, to: reference)!
        XCTAssertEqual(MeetingTimeBucket.bucket(for: lastWeek, reference: reference, calendar: calendar),
                       .earlier)
    }

    // MARK: - Grouping order + sorting

    func testGroupingOrdersBucketsTodayFirst() {
        let meetings = [
            makeMeeting(at: calendar.date(byAdding: .day, value: -10, to: reference)!), // earlier
            makeMeeting(at: reference),                                                  // today
            makeMeeting(at: calendar.date(byAdding: .day, value: -1, to: reference)!),   // yesterday
            makeMeeting(at: date(2026, 5, 11))                                            // thisWeek
        ]
        let groups = MeetingTimeBucket.grouped(meetings, reference: reference, calendar: calendar)
        XCTAssertEqual(groups.map(\.bucket), [.today, .yesterday, .thisWeek, .earlier])
    }

    func testGroupingSortsNewestFirstWithinBucket() {
        let m1 = makeMeeting(at: date(2026, 5, 13, hour: 9))
        let m2 = makeMeeting(at: date(2026, 5, 13, hour: 11))
        let m3 = makeMeeting(at: date(2026, 5, 13, hour: 14))
        let groups = MeetingTimeBucket.grouped([m1, m2, m3], reference: reference, calendar: calendar)
        XCTAssertEqual(groups.first?.bucket, .today)
        XCTAssertEqual(groups.first?.meetings.map(\.id), [m3.id, m2.id, m1.id])
    }

    func testGroupingOmitsEmptyBuckets() {
        let only = [makeMeeting(at: reference)]
        let groups = MeetingTimeBucket.grouped(only, reference: reference, calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.bucket, .today)
    }

    // MARK: - Helpers

    private func makeMeeting(at date: Date) -> Meeting {
        Meeting(
            createdAt: date,
            updatedAt: date,
            source: .recording,
            transcriptionBackend: "test",
            folderName: "test-\(date.timeIntervalSince1970)"
        )
    }
}
