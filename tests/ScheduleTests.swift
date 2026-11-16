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
    holidays = HolidayCache(fetched: "", years: [], days: [:]); leaves = []; overtimes = []; periods = []
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

// Rest periods across midnight
reset(start: "22:00", end: "06:00")
periods = [Period(from: "23:30", to: "00:30", note: "", rule: nil)]
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

// Tasks (2026-11-13 is a Friday, 11-14 a Saturday)
reset(start: "09:00", end: "18:00")
func due(_ s: String) -> [String] { jobsDue(at(s)).map(\.text) }
jobs = [Job(action: "notify", text: "standup", when: "at", at: "10:00"), Job(action: "notify", when: "at", at: "14:00", rule: "once:2026-11-14"),
        Job(disabled: true, action: "notify", text: "off", when: "at", at: "11:00"), Job(action: "url", text: "https://example.com", when: "at", at: "15:00")]
check("task: daily on a workday", due("2026-11-13 10:00"), ["standup"])
check("task: not a minute later", due("2026-11-13 10:01"), [String]())
check("task: daily skips Saturday", due("2026-11-14 10:00"), [String]())
check("task: one-off rings on Saturday", due("2026-11-14 14:00"), [T("reminder.untitled", "14:00")])
check("task: turned off", due("2026-11-13 11:00"), [String]())
check("task: a link is due with its link", jobsDue(at("2026-11-13 15:00")).map(\.job.action), ["url"])
check("task: link text", due("2026-11-13 15:00"), ["https://example.com"])
jobs = [Job(action: "notify", text: "pills", when: "at", at: "21:00", anyDay: true), Job(action: "notify", text: "sat", when: "at", at: "09:00", rule: "weekly:7", anyDay: true)]
check("days off: daily on Saturday", due("2026-11-14 21:00"), ["pills"])
check("days off: daily on a workday", due("2026-11-13 21:00"), ["pills"])
check("days off: weekly Saturday", due("2026-11-14 09:00"), ["sat"])
holidays.days["2026-11-17"] = "Test Day"; leaves = [Leave(start: "2026-11-18", end: "2026-11-18", note: "")]
check("days off: holiday", due("2026-11-17 21:00"), ["pills"])
check("days off: leave", due("2026-11-18 21:00"), ["pills"])
jobs[0].anyDay = nil
check("days off: off by default", due("2026-11-17 21:00").count, 0)
reset()
jobs = defaultJobs(nudging: true, interval: 15)
check("task: default nudge interval", nudgeJob?.every, 15)
check("task: nudge on", nudging, true)
check("task: start of work", due("2026-11-13 09:00"), [T("reminder.workStart")])
check("task: end of work", due("2026-11-13 18:00"), [T("reminder.workEnd")])
check("task: the nudge is never due", due("2026-11-13 09:30").count, 0)
check("task: no start on Saturday", due("2026-11-14 09:00").count, 0)
check("task: fresh install nudge off", defaultJobs(nudging: false, interval: 10).first?.disabled, true)
overtimes = [Overtime(from: "18:00", to: "20:00", note: "", rule: "once:2026-11-13")]
check("task: overtime joins work, no end at 18:00", due("2026-11-13 18:00").count, 0)
check("task: end after the overtime", due("2026-11-13 20:00"), [T("reminder.workEnd")])
overtimes = []
reset(start: "22:00", end: "06:00")
check("task: night shift ends next morning", due("2026-11-14 06:00").count, 1)
check("task: no end after Saturday night", due("2026-11-15 06:00").count, 0)
reset()
workEnd = "19:00"
check("task: end follows the work hours", due("2026-11-13 19:00").count, 1)
jobs[2].disabled = true
check("task: end turned off", due("2026-11-13 19:00").count, 0)
reset()
jobs = [Job(action: "notify", when: "both", follow: ["work"], offset: 10)]
check("task: minutes early", due("2026-11-13 08:50"), [T("job.startsIn", T("apps.followWork"), "10")])
check("task: early before the end", due("2026-11-13 17:50"), [T("job.endsIn", T("apps.followWork"), "10")])
check("task: not at the edge itself", due("2026-11-13 09:00").count, 0)
jobs = []

// Period tasks follow the period as it is now
periods = [Period(id: "lunch", from: "12:00", to: "13:00", note: "lunch", rule: nil)]
jobs = [Job(action: "notify", when: "both", follow: ["lunch"])]
check("period task: start", due("2026-11-13 12:00"), [T("reminder.periodStart", "lunch")])
check("period task: end", due("2026-11-13 13:00"), [T("reminder.periodEnd", "lunch")])
check("period task: not on Saturday", due("2026-11-14 12:00").count, 0)
periods[0].from = "11:30"; periods[0].to = "12:30"; periods[0].note = "food"
check("period task: start moves", due("2026-11-13 11:30"), [T("reminder.periodStart", "food")])
check("period task: old start silent", due("2026-11-13 12:00").count, 0)
check("period task: end moves", due("2026-11-13 12:30").count, 1)
periods[0].disabled = true
check("period task: period off", due("2026-11-13 11:30").count, 0)
check("period task: held with its period", jobHeld(jobs[0]), true)
periods[0].disabled = nil
check("period task: resumed with its period", jobHeld(jobs[0]), false)
periods[0].disabled = true
periods = [Period(id: "late", from: "23:00", to: "01:00", note: "", rule: "once:2026-11-14")]
jobs = [Job(action: "notify", when: "end", follow: ["late"])]
check("period task: overnight one-off ends next day", due("2026-11-15 01:00").count, 1)
periods = []
check("period task: period gone", due("2026-11-15 01:00").count, 0)
jobs = []

// Every few minutes while inside what the task follows
reset()
periods = [Period(id: "lunch", from: "12:00", to: "13:00", note: "", rule: nil)]
jobs = [Job(action: "notify", text: "water", when: "every", every: 30)]
check("every: on the mark", due("2026-11-13 10:30"), ["water"])
check("every: off the mark", due("2026-11-13 10:15").count, 0)
check("every: not before work", due("2026-11-13 08:30").count, 0)
check("every: not on Saturday", due("2026-11-14 10:30").count, 0)
check("every: quiet in a break", due("2026-11-13 12:30").count, 0)
jobs = [Job(action: "notify", text: "stretch", when: "every", follow: ["lunch"], every: 30)]
check("every: inside the break it follows", due("2026-11-13 12:30"), ["stretch"])
jobs = []; periods = []

// How far through work, for the menu bar icon
reset()
check("progress: half way", workProgress(at("2026-11-13 13:30")), 0.5)
check("progress: outside work", workProgress(at("2026-11-13 19:00")), 0)
overtimes = [Overtime(from: "18:00", to: "21:00", note: "", rule: "once:2026-11-13")]
check("progress: overtime stretches the day", workProgress(at("2026-11-13 15:00")), 0.5)
overtimes = []

// Menu bar: the countdown before a break or pop-up
periods = [Period(from: "12:00", to: "13:00", note: "lunch", rule: nil)]
jobs = [Job(action: "notify", text: "meeting", when: "at", at: "14:00"), Job(action: "notify", text: "water", when: "every", every: 5)]
check("event: lunch in 5 minutes", upcomingEvent(after: at("2026-11-13 11:55"), within: 600)?.name, "lunch")
check("event: at the break start", upcomingEvent(after: at("2026-11-13 11:55"), within: 600).map { show($0.at) }, "2026-11-13 12:00")
check("event: exactly 10 minutes", upcomingEvent(after: at("2026-11-13 11:50"), within: 600)?.name, "lunch")
check("event: too far off", upcomingEvent(after: at("2026-11-13 11:49"), within: 600)?.name, nil)
check("event: meeting", upcomingEvent(after: at("2026-11-13 13:55"), within: 600)?.name, "meeting")
check("event: nothing on Saturday", upcomingEvent(after: at("2026-11-14 11:55"), within: 600)?.name, nil)
periods = [Period(from: "15:00", to: "16:00", note: "review", rule: nil, work: true), Period(from: "12:00", to: "13:00", note: "", rule: nil)]
check("event: work period with a note", upcomingEvent(after: at("2026-11-13 14:55"), within: 600)?.name, "review")
check("event: unnamed break", upcomingEvent(after: at("2026-11-13 11:55"), within: 600)?.name, T("period.rest"))
jobs = []; periods = []
reset()

// Work periods count as work time, on working days only
reset()
periods = [Period(from: "19:00", to: "20:00", note: "", rule: nil, work: true)]
check("work period: after hours", window("2026-11-13 19:30"), true)
check("work period: not on Saturday", window("2026-11-14 19:30"), false)
check("work period: next start", show(nextStart(after: at("2026-11-13 18:30"))), "2026-11-13 19:00")
check("work period: not a break", breaksOn(at("2026-11-13 12:00")).count, 0)
periods = [Period(from: "10:00", to: "11:00", note: "", rule: "once:2026-11-14", work: true)]
check("work period: one-off on Saturday", window("2026-11-14 10:30"), true)
periods = []

// Apps follow work hours (with overtime), overtime only, or a period, widened by lead and lag
func appJob(_ name: String, follow: [String]? = nil, lead: Int? = nil, lag: Int? = nil) -> Job {
    Job(action: "app", name: name, path: "/\(name).app", when: "during", follow: follow, lead: lead, lag: lag)
}
reset()
var app = appJob("A")
check("apps: before work", appWanted(app, at("2026-11-13 08:59")), false)
check("apps: work hours", appWanted(app, at("2026-11-13 09:00")), true)
check("apps: closed at the end", appWanted(app, at("2026-11-13 18:00")), false)
app.lead = 30; app.lag = 15
check("apps: open early", appWanted(app, at("2026-11-13 08:30")), true)
check("apps: not too early", appWanted(app, at("2026-11-13 08:29")), false)
check("apps: quit late", appWanted(app, at("2026-11-13 18:14")), true)
check("apps: quit after the lag", appWanted(app, at("2026-11-13 18:15")), false)
check("apps: Saturday off", appWanted(app, at("2026-11-14 10:00")), false)
overtimes = [Overtime(from: "10:00", to: "12:00", note: "", rule: "once:2026-11-14")]
check("apps: Saturday overtime", appWanted(app, at("2026-11-14 11:00")), true)
var ot = appJob("B", follow: ["overtime"])
check("apps: overtime only", appWanted(ot, at("2026-11-14 11:00")), true)
check("apps: overtime only skips work hours", appWanted(ot, at("2026-11-13 10:00")), false)
overtimes[0].disabled = true
check("apps: overtime paused, app stays shut", appWanted(ot, at("2026-11-14 11:00")), false)
check("held: overtime paused", jobHeld(ot), true)
check("held: work is never held", jobHeld(appJob("W")), false)
check("held: a timed task is not held", jobHeld(Job(action: "notify", when: "at", at: "10:00")), false)
jobs = [Job(action: "notify", text: "ot", when: "start", follow: ["overtime"])]
check("held: no pop-up at a paused overtime", due("2026-11-14 10:00").count, 0)
overtimes[0].disabled = nil
check("held: pop-up once resumed", due("2026-11-14 10:00"), ["ot"])
check("held: overtime resumed", jobHeld(ot), false)
jobs = []
ot.disabled = true
check("apps: turned off", appWanted(ot, at("2026-11-14 11:00")), false)
check("apps: only app tasks", appWanted(Job(action: "notify", when: "start"), at("2026-11-13 10:00")), false)
overtimes = []
periods = [Period(id: "m", from: "14:00", to: "15:00", note: "", rule: nil, work: true)]
let meet = appJob("C", follow: ["m"], lead: 5, lag: 0)
check("apps: period lead", appWanted(meet, at("2026-11-13 13:55")), true)
check("apps: period over", appWanted(meet, at("2026-11-13 15:00")), false)
check("apps: deleted period", appWanted(appJob("D", follow: ["gone"]), at("2026-11-13 14:30")), false)
overtimes = [Overtime(from: "10:00", to: "12:00", note: "", rule: "once:2026-11-14")]
let both = appJob("E", follow: ["m", "overtime"])
check("apps: several follows, period", appWanted(both, at("2026-11-13 14:30")), true)
check("apps: several follows, overtime", appWanted(both, at("2026-11-14 11:00")), true)
check("apps: several follows, neither", appWanted(both, at("2026-11-13 10:00")), false)
overtimes = []
periods = []
reset(start: "01:00", end: "06:00")
app = appJob("A", lead: 120, lag: 0)
check("apps: early opening stops at midnight", appWanted(app, at("2026-11-13 00:30")), true)
check("apps: no wrap into the night before", appWanted(app, at("2026-11-12 23:30")), false)
reset(start: "22:00", end: "06:00")
app = appJob("A", lead: 0, lag: 60)
check("apps: night shift lag", appWanted(app, at("2026-11-14 06:30")), true)
check("apps: night shift over", appWanted(app, at("2026-11-14 07:00")), false)

// Turned-off entries stay listed but are left out of the schedule
reset(start: "09:00", end: "18:00")
leaves = [Leave(start: "2026-11-13", end: "2026-11-13", note: "", disabled: true), Leave(start: "2026-11-13", end: "2026-11-13", note: "", from: "10:00", to: "11:00", disabled: true)]
check("off: whole-day leave ignored", leave(on: "2026-11-13") == nil, true)
check("off: part leave ignored", partLeaves(on: "2026-11-13").count, 0)
leaves = []
periods = [Period(from: "15:00", to: "16:00", note: "", rule: nil, disabled: true), Period(from: "19:00", to: "20:00", note: "", rule: nil, disabled: true, work: true)]
check("off: break ignored", breaksOn(at("2026-11-13 12:00")).count, 0)
check("off: work period ignored", window("2026-11-13 19:30"), false)
periods = []
overtimes = [Overtime(from: "10:00", to: "12:00", note: "", rule: "once:2026-11-14", disabled: true)]
check("off: overtime ignored", overtime(on: at("2026-11-14 11:00")).count, 0)
check("off: no Saturday apps", appWanted(appJob("A"), at("2026-11-14 11:00")), false)
overtimes = []

// Log quarters
check("quarter: Nov", quarterKey(at("2026-11-13 12:00")), "2026-Q4")
check("quarter: Jan", quarterKey(at("2026-01-01 00:00")), "2026-Q1")
check("quarter: end of Mar", quarterKey(at("2026-03-31 23:59")), "2026-Q1")
check("quarter: Apr", quarterKey(at("2026-04-01 00:00")), "2026-Q2")

print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
