// Schedule tests, compiled together with the scheduling half of main.swift by tests/run.sh.
// Dates are November 2026: the 13th is a Friday, the 14th–15th a weekend.

var failures = 0, checks = 0
func at(_ s: String) -> Date {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}
func show(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}
func check<V: Equatable>(_ name: String, _ got: V, _ want: V) {
    checks += 1
    if got != want { failures += 1; print("FAIL \(name): got \(got), want \(want)") }
}
func window(_ s: String) -> Bool { inWindow(at(s)) }
func reset(start: String = "09:00", end: String = "18:00") {
    workStart = start; workEnd = end; intervalMinutes = 10
    holidays = HolidayCache(fetched: "", years: [], days: [:]); leaves = []; overtimes = []; breaks = []
}

// Day shift
reset()
check("day: in hours", window("2026-11-13 10:00"), true)
check("day: before start", window("2026-11-13 08:59"), false)
check("day: end is exclusive", window("2026-11-13 18:00"), false)
check("day: Saturday off", window("2026-11-14 10:00"), false)
check("day: last nudge runs past the end", show(step(after: at("2026-11-13 17:55"))), "2026-11-13 18:05")
check("day: Friday evening waits for Monday", show(step(after: at("2026-11-13 18:05"))), "2026-11-16 09:00")
check("day: slot skips what is past", show(slot(after: at("2026-11-13 09:00"), now: at("2026-11-13 09:35"))), "2026-11-13 09:40")
check("day: fresh schedule on the interval mark", show(nextSlot(after: at("2026-11-13 10:03"))), "2026-11-13 10:10")

// Night shift: the stretch belongs to the day it starts on
reset(start: "22:00", end: "06:00")
check("night: Friday night", window("2026-11-13 23:00"), true)
check("night: Saturday morning from Friday", window("2026-11-14 03:00"), true)
check("night: Saturday night off", window("2026-11-14 23:00"), false)
check("night: Monday morning (from Sunday) off", window("2026-11-16 02:00"), false)
check("night: Monday night", window("2026-11-16 23:00"), true)
check("night: overnight detected", overnight("22:00", "06:00"), true)

// Holiday: the night before works as usual, the holiday night is off
holidays.days["2026-11-17"] = "Test Day"
check("holiday: night before", window("2026-11-16 23:00"), true)
check("holiday: morning after the night before", window("2026-11-17 03:00"), true)
check("holiday: holiday night off", window("2026-11-17 23:00"), false)
check("holiday: morning after the holiday night", window("2026-11-18 03:00"), false)

// Breaks across midnight
reset(start: "22:00", end: "06:00")
breaks = [Break(from: "23:30", to: "00:30", note: "", rule: nil)]
check("break: before midnight", window("2026-11-13 23:45"), false)
check("break: after midnight", window("2026-11-14 00:15"), false)
check("break: over", window("2026-11-14 00:45"), true)
check("break: next start is the break end", show(nextStart(after: at("2026-11-13 23:40"))), "2026-11-14 00:30")

// Overtime, one day and several days
reset()
overtimes = [Overtime(from: "10:00", to: "12:00", note: "", rule: "once:2026-11-14")]
check("overtime: Saturday", window("2026-11-14 11:00"), true)
check("overtime: after it", window("2026-11-14 13:00"), false)
overtimes = [Overtime(from: "09:00", to: "15:00", note: "", rule: "once:2026-11-14", until: "2026-11-15")]
check("multi-day: before start", window("2026-11-14 08:00"), false)
check("multi-day: first day", window("2026-11-14 09:30"), true)
check("multi-day: late first day", window("2026-11-14 23:59"), true)
check("multi-day: night between", window("2026-11-15 03:00"), true)
check("multi-day: last day before end", window("2026-11-15 14:59"), true)
check("multi-day: after end", window("2026-11-15 15:30"), false)
check("multi-day: next start", show(nextStart(after: at("2026-11-14 08:00"))), "2026-11-14 09:00")

// Leave
reset()
leaves = [Leave(start: "2026-11-16", end: "2026-11-16", note: "")]
check("leave: whole day off", window("2026-11-16 10:00"), false)
overtimes = [Overtime(from: "10:00", to: "11:00", note: "", rule: "once:2026-11-16")]
check("leave: overtime still nudges", window("2026-11-16 10:30"), true)
leaves = [Leave(start: "2026-11-13", end: "2026-11-13", note: "", from: "13:00", to: "15:00")]
check("part leave: paused", window("2026-11-13 14:00"), false)
check("part leave: back after", window("2026-11-13 15:00"), true)

// Repeat rules (weekday 6 = Friday)
check("rule: last Friday", ruleApplies("monthly:-1:6", on: at("2026-11-27 12:00")), true)
check("rule: not the last Friday", ruleApplies("monthly:-1:6", on: at("2026-11-20 12:00")), false)
check("rule: fourth Friday", ruleApplies("monthly:4:6", on: at("2026-11-27 12:00")), true)
check("rule: weekly Friday", ruleApplies("weekly:6", on: at("2026-11-13 12:00")), true)
check("rule: old lastweekday", ruleApplies("lastweekday:6", on: at("2026-11-27 12:00")), true)

// Log quarters
check("quarter: Nov", quarterKey(at("2026-11-13 12:00")), "2026-Q4")
check("quarter: Jan", quarterKey(at("2026-01-01 00:00")), "2026-Q1")
check("quarter: end of Mar", quarterKey(at("2026-03-31 23:59")), "2026-Q1")
check("quarter: Apr", quarterKey(at("2026-04-01 00:00")), "2026-Q2")

print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
