import Foundation

/// The headings saved chats are listed under in the sidebar, newest first.
public enum AppConversationDateGroup: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case previousWeek = "Previous 7 Days"
    case older = "Older"

    public static func group(for date: Date, now: Date = Date(),
                             calendar: Calendar = .current) -> Self {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)
        else { return .older }
        if date >= startOfYesterday { return .yesterday }
        if date >= startOfWeek { return .previousWeek }
        return .older
    }

    /// The conversations under each heading, in heading order, leaving out
    /// headings with none. Each group keeps the order it was given.
    public static func grouped(
        _ conversations: [AppConversationRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(group: Self, conversations: [AppConversationRecord])] {
        let byGroup = Dictionary(grouping: conversations) {
            group(for: $0.updatedAt, now: now, calendar: calendar)
        }
        return allCases.compactMap { group in
            byGroup[group].map { (group, $0) }
        }
    }

    /// A short time for a row: the hour today, the weekday this week,
    /// otherwise the date.
    public static func shortTimestamp(for date: Date, now: Date = Date(),
                                      calendar: Calendar = .current) -> String {
        switch group(for: date, now: now, calendar: calendar) {
        case .today:
            return date.formatted(date: .omitted, time: .shortened)
        case .yesterday:
            return "Yesterday"
        case .previousWeek:
            return date.formatted(.dateTime.weekday(.abbreviated))
        case .older:
            return calendar.isDate(date, equalTo: now, toGranularity: .year)
                ? date.formatted(.dateTime.month(.abbreviated).day())
                : date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}
