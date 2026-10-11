import Foundation
import Testing
@testable import TUFFAppCore

struct AppConversationDateGroupTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func groupsByCalendarDay() {
        let now = date(11, 9)
        #expect(AppConversationDateGroup.group(for: date(11, 1), now: now, calendar: calendar) == .today)
        #expect(AppConversationDateGroup.group(for: date(10, 23), now: now, calendar: calendar) == .yesterday)
        #expect(AppConversationDateGroup.group(for: date(5), now: now, calendar: calendar) == .previousWeek)
        #expect(AppConversationDateGroup.group(for: date(1), now: now, calendar: calendar) == .older)
    }

    @Test func groupedKeepsOrderAndSkipsEmptyHeadings() {
        let now = date(11, 9)
        let records = [
            AppConversationRecord(title: "a", modelID: "m", updatedAt: date(11, 8)),
            AppConversationRecord(title: "b", modelID: "m", updatedAt: date(1)),
            AppConversationRecord(title: "c", modelID: "m", updatedAt: date(11, 2)),
        ]
        let grouped = AppConversationDateGroup.grouped(records, now: now, calendar: calendar)
        #expect(grouped.map(\.group) == [.today, .older])
        #expect(grouped[0].conversations.map(\.title) == ["a", "c"])
    }
}
