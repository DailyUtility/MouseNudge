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
check("rule: fifth Monday", ruleApplies("monthly:5:2", on: at("2026-11-30 12:00")), true)
check("rule: no fifth Friday in November", ruleApplies("monthly:5:6", on: at("2026-11-27 12:00")), false)
check("rule: 15th", ruleApplies("monthday:15", on: at("2026-11-15 12:00")), true)
check("rule: not the 15th", ruleApplies("monthday:15", on: at("2026-11-16 12:00")), false)
check("rule: last day of November", ruleApplies("monthday:-1", on: at("2026-11-30 12:00")), true)
check("rule: last day of February", ruleApplies("monthday:-1", on: at("2026-02-28 12:00")), true)
check("rule: second to last day", ruleApplies("monthday:-2", on: at("2026-11-29 12:00")), true)
check("rule: no 31st in November", ruleApplies("monthday:31", on: at("2026-11-30 12:00")), false)

// Reminders (2026-11-13 is a Friday, 11-14 a Saturday)
reset(start: "09:00", end: "18:00")
reminders = [Reminder(at: "10:00", note: "standup", rule: nil), Reminder(at: "14:00", note: "", rule: "once:2026-11-14"),
             Reminder(at: "11:00", note: "off", rule: nil, disabled: true)]
check("remind: daily on a workday", remindersDue(at("2026-11-13 10:00")), ["standup"])
check("remind: not a minute later", remindersDue(at("2026-11-13 10:01")), [String]())
check("remind: daily skips Saturday", remindersDue(at("2026-11-14 10:00")), [String]())
check("remind: one-off rings on Saturday", remindersDue(at("2026-11-14 14:00")).count, 1)
check("remind: turned off", remindersDue(at("2026-11-13 11:00")), [String]())
reminders = [workReminder("start"), workReminder("end")]
check("remind: start of work", remindersDue(at("2026-11-13 09:00")).count, 1)
check("remind: end of work", remindersDue(at("2026-11-13 18:00")).count, 1)
check("remind: no start on Saturday", remindersDue(at("2026-11-14 09:00")).count, 0)
reset(start: "22:00", end: "06:00")
check("remind: night shift ends next morning", remindersDue(at("2026-11-14 06:00")).count, 1)
check("remind: no end after Saturday night", remindersDue(at("2026-11-15 06:00")).count, 0)
workEnd = "19:00"; syncWorkReminders()
check("remind: end follows the work hours", remindersDue(at("2026-11-13 19:00")).count, 1)
reminders[1].disabled = true
check("remind: end turned off", remindersDue(at("2026-11-13 19:00")).count, 0)
reminders = []
reset(start: "09:00", end: "18:00")

// Menu bar: the countdown before a break or reminder
breaks = [Break(from: "12:00", to: "13:00", note: "lunch", rule: nil)]
reminders = [Reminder(at: "14:00", note: "meeting", rule: nil)]
check("event: lunch in 5 minutes", upcomingEvent(after: at("2026-11-13 11:55"), within: 600)?.name, "lunch")
check("event: at the break start", upcomingEvent(after: at("2026-11-13 11:55"), within: 600).map { show($0.at) }, "2026-11-13 12:00")
check("event: exactly 10 minutes", upcomingEvent(after: at("2026-11-13 11:50"), within: 600)?.name, "lunch")
check("event: too far off", upcomingEvent(after: at("2026-11-13 11:49"), within: 600)?.name, nil)
check("event: meeting", upcomingEvent(after: at("2026-11-13 13:55"), within: 600)?.name, "meeting")
check("event: nothing on Saturday", upcomingEvent(after: at("2026-11-14 11:55"), within: 600)?.name, nil)
reminders = []
reset()

// Log quarters
// Apps kept open: work hours widened by the lead and lag, plus overtime
reset()
appLeadMinutes = 0; appLagMinutes = 0
check("apps: before work", appsWanted(at("2026-11-13 08:59")), false)
check("apps: work hours", appsWanted(at("2026-11-13 09:00")), true)
check("apps: closed at the end", appsWanted(at("2026-11-13 18:00")), false)
appLeadMinutes = 30; appLagMinutes = 15
check("apps: open early", appsWanted(at("2026-11-13 08:30")), true)
check("apps: not too early", appsWanted(at("2026-11-13 08:29")), false)
check("apps: quit late", appsWanted(at("2026-11-13 18:14")), true)
check("apps: quit after the lag", appsWanted(at("2026-11-13 18:15")), false)
check("apps: Saturday off", appsWanted(at("2026-11-14 10:00")), false)
overtimes = [Overtime(from: "10:00", to: "12:00", note: "", rule: "once:2026-11-14")]
check("apps: Saturday overtime", appsWanted(at("2026-11-14 11:00")), true)
reset(start: "01:00", end: "06:00")
appLeadMinutes = 120; appLagMinutes = 0
check("apps: early opening stops at midnight", appsWanted(at("2026-11-13 00:30")), true)
check("apps: no wrap into the night before", appsWanted(at("2026-11-12 23:30")), false)
reset(start: "22:00", end: "06:00")
appLeadMinutes = 0; appLagMinutes = 60
check("apps: night shift lag", appsWanted(at("2026-11-14 06:30")), true)
check("apps: night shift over", appsWanted(at("2026-11-14 07:00")), false)
appLeadMinutes = 0; appLagMinutes = 0

// Turned-off entries stay listed but are left out of the schedule
reset(start: "09:00", end: "18:00")
leaves = [Leave(start: "2026-11-13", end: "2026-11-13", note: "", disabled: true), Leave(start: "2026-11-13", end: "2026-11-13", note: "", from: "10:00", to: "11:00", disabled: true)]
check("off: whole-day leave ignored", leave(on: "2026-11-13") == nil, true)
check("off: part leave ignored", partLeaves(on: "2026-11-13").count, 0)
leaves = []
breaks = [Break(from: "15:00", to: "16:00", note: "", rule: nil, disabled: true)]
check("off: break ignored", breaksOn(at("2026-11-13 12:00")).count, 0)
breaks = []
overtimes = [Overtime(from: "10:00", to: "12:00", note: "", rule: "once:2026-11-14", disabled: true)]
check("off: overtime ignored", overtime(on: at("2026-11-14 11:00")).count, 0)
check("off: no Saturday apps", appsWanted(at("2026-11-14 11:00")), false)
overtimes = []

// Log quarters
check("quarter: Nov", quarterKey(at("2026-11-13 12:00")), "2026-Q4")
check("quarter: Jan", quarterKey(at("2026-01-01 00:00")), "2026-Q1")
check("quarter: end of Mar", quarterKey(at("2026-03-31 23:59")), "2026-Q1")
check("quarter: Apr", quarterKey(at("2026-04-01 00:00")), "2026-Q2")

print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
