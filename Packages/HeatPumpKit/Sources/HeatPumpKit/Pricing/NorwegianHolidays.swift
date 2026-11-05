import Foundation

/// Norwegian public holidays (helligdager), used for the grid tariff's night/weekend rate.
public enum NorwegianHolidays {
    /// True when `date` (in `timeZone`) falls on a public holiday.
    public static func isHoliday(_ date: Date, timeZone: TimeZone) -> Bool {
        let calendar = WireDate.calendar(timeZone)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return false }
        let fixed: Set<[Int]> = [[1, 1], [5, 1], [5, 17], [12, 25], [12, 26]]
        if fixed.contains([month, day]) { return true }
        guard let easter = easterSunday(year: year, calendar: calendar) else { return false }
        let start = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: easter, to: start).day ?? 999
        // Skjærtorsdag, langfredag, 1. og 2. påskedag, Kristi himmelfartsdag, 1. og 2. pinsedag.
        return [-3, -2, 0, 1, 39, 49, 50].contains(offset)
    }

    /// Easter Sunday (anonymous Gregorian algorithm).
    static func easterSunday(year: Int, calendar: Calendar) -> Date? {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
