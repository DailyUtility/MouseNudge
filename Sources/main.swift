// Shiftbell, a menu bar work-time keeper that runs scheduled tasks (pop-ups, apps, shortcuts, links, commands) around work time; its mouse nudge, a task that can be turned off, runs on working days (Monday–Friday, minus public holidays from an optional calendar subscription) during work hours (set from the menu, default 09:00–18:00) plus any overtime (one day or repeating), minus rest periods, plus work periods (daily, weekly, monthly or one-off), every N minutes (set on the nudge task, default 10), last nudge at the first step past the end; skips when the screen is locked (unless allowed) or the person used any input device in the last minute.
import Cocoa
import IOKit
import ApplicationServices
import ServiceManagement
import Network
import UniformTypeIdentifiers

// Shiftbell was called MouseNudge: its settings and data folder move over once, before anything reads them.
// Tests run without a bundle and skip this.
let oldBundleID = "io.github.mar-er.mousenudge"
let movedFromMouseNudge: Void = {
    guard Bundle.main.bundleIdentifier == "io.github.mar-er.shiftbell" else { return }
    let d = UserDefaults.standard
    if !d.bool(forKey: "movedFromMouseNudge") {
        for (k, v) in d.persistentDomain(forName: oldBundleID) ?? [:] where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        d.set(true, forKey: "movedFromMouseNudge")
    }
    let base = NSHomeDirectory() + "/Library/Application Support/", fm = FileManager.default
    if fm.fileExists(atPath: base + "mouse-nudge") && !fm.fileExists(atPath: base + "shiftbell") { try? fm.moveItem(atPath: base + "mouse-nudge", toPath: base + "shiftbell") }
}()

let skipIfIdleUnder: Double = 60
// Minutes between nudges, from the nudge task (applyNudge).
var intervalMinutes = 10
var interval: TimeInterval { TimeInterval(intervalMinutes * 60) }
// Work hours on working days, set from the menu.
var workStart: String { UserDefaults.standard.string(forKey: "workStart") ?? "09:00" }
var workEnd: String { UserDefaults.standard.string(forKey: "workEnd") ?? "18:00" }
// Off by default: a locked Mac means the person is away, and a nudge could keep waking the screen.
var nudgeWhenLocked: Bool { UserDefaults.standard.bool(forKey: "nudgeWhenLocked") }
func screenLocked() -> Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }
func onScreen(_ pt: CGPoint) -> Bool { var n: UInt32 = 0; CGGetDisplaysWithPoint(pt, 0, nil, &n); return n > 0 }
let dir = NSHomeDirectory() + "/Library/Application Support/shiftbell"
// A fresh install on someone else's Mac has no data folder yet.
let _ = try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let logURL = URL(fileURLWithPath: dir + "/nudge.log")
let holidayURL = URL(fileURLWithPath: dir + "/holidays.json")
// Any iCalendar subscription (Apple's holiday calendars, officeholidays.com …), set from the menu;
// webcal:// links are fetched over https. None by default: until one is set only weekends are days off.
var holidaySource: String { UserDefaults.standard.string(forKey: "holidaySource") ?? "" }

let dayKey: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()

struct HolidayCache: Codable { var fetched: String; var years: [Int]; var days: [String: String] }
var holidays = HolidayCache(fetched: "", years: [], days: [:])

// Personal leave, kept apart from holidays.json so a holiday refetch never wipes it. Dates are inclusive yyyy-MM-dd.
let leaveURL = URL(fileURLWithPath: dir + "/leave.json")
// Without from/to the leave covers whole days; with them, only that stretch of each day (a few hours or half a day),
// which pauses nudging like a break and leaves the rest of the working day as usual.
// `disabled` (on leave, overtime, periods and watched apps) keeps an entry in its list but leaves it out of the schedule.
struct Leave: Codable, Equatable { var start: String; var end: String; var note: String; var from: String? = nil; var to: String? = nil; var disabled: Bool? = nil }
var leaves: [Leave] = []
func loadLeaves() { if let d = try? Data(contentsOf: leaveURL), let l = try? JSONDecoder().decode([Leave].self, from: d) { leaves = l } }
func saveLeaves() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(leaves).write(to: leaveURL) }
func leave(on key: String) -> Leave? { leaves.first { $0.disabled != true && $0.start <= key && key <= $0.end && $0.from == nil } }
func partLeaves(on key: String) -> [Leave] { leaves.filter { $0.disabled != true && $0.start <= key && key <= $0.end && $0.from != nil } }

// Overtime: on the days its `rule` picks (same rules as periods), between these times, nudge even on weekends. A repeating
// one skips holidays; leave (whole-day or part-day) wins over any overtime. Times are HH:mm, end exclusive. Older
// entries carry a start…end date range instead of a rule.
let overtimeURL = URL(fileURLWithPath: dir + "/overtime.json")
struct Overtime: Codable, Equatable { var start: String? = nil; var end: String? = nil; var from: String; var to: String; var note: String; var rule: String?
    // A one-off ("once:") overtime may run on to `to` on this later day, all day in between.
    var until: String? = nil; var disabled: Bool? = nil }
var overtimes: [Overtime] = []
// Periods: named stretches of the day (lunch, a meeting, focus time), on the days `rule` picks, on working days and days
// with overtime. Tasks can follow them, and a task every few minutes (the nudge too) can be quiet in them. `rule` says which days: nil = every day, "once:yyyy-MM-dd", "weekly:W", "monthly:N:W" (the Nth W of the month, N = 1–5 or -1 for the last),
// or "monthday:D" (day D of the month, or with D < 0 counted from the end: -1 is the last day; a missing day is skipped),
// W = Calendar weekday (1 = Sunday). The older "lastweekday:W" means "monthly:-1:W".
let periodsURL = URL(fileURLWithPath: dir + "/periods.json")
// `id` is what a task following the period, or quiet in it, refers to.
struct Period: Codable, Equatable { var id = UUID().uuidString; var from: String; var to: String; var note: String; var rule: String?; var disabled: Bool? = nil }
var periods: [Period] = []
// Translation keys; weekday names come from the interface language (Language.swift).
let weekOrdinals = ["week.first", "week.second", "week.third", "week.fourth", "week.fifth"]
func ordinalName(_ n: Int) -> String { T(n == -1 ? "week.last" : weekOrdinals[max(0, min(4, n - 1))]) }
func monthDayName(_ n: Int) -> String { n > 0 ? T("monthday.nth", String(n)) : n == -1 ? T("monthday.last") : T("monthday.fromEnd", String(-n)) }
// Joins sentences: a space after Latin text, none after a full-width stop as in Chinese and Japanese.
func sentences(_ parts: String...) -> String {
    parts.reduce("") { a, b in a.isEmpty ? b : a + ("。！？".contains(a.last!) ? "" : " ") + b }
}
func ruleApplies(_ rule: String?, on d: Date) -> Bool {
    guard let rule = rule, let colon = rule.firstIndex(of: ":") else { return true }
    let kind = rule[..<colon], arg = String(rule[rule.index(after: colon)...]), c = Calendar.current
    switch kind {
    case "once": return dayKey.string(from: d) == arg
    case "weekly": return c.component(.weekday, from: d) == Int(arg)
    case "lastweekday": return ruleApplies("monthly:-1:" + arg, on: d)
    case "monthly":
        let p = arg.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, c.component(.weekday, from: d) == p[1] else { return false }
        if p[0] == -1 { return c.component(.month, from: d + 7 * 86400) != c.component(.month, from: d) }
        return (c.component(.day, from: d) - 1) / 7 + 1 == p[0]
    case "monthday":
        guard let n = Int(arg) else { return false }
        return c.component(.day, from: d) == (n > 0 ? n : c.range(of: .day, in: .month, for: d)!.count + n + 1)
    default: return true
    }
}
// Whether a period counts on `d`: a one-off on its own day, a repeating one on working days and days with overtime;
// never on a day of leave. Tasks follow it, and are quiet in it, on exactly these days.
func periodOn(_ p: Period, _ d: Date) -> Bool {
    p.disabled != true && ruleApplies(p.rule, on: d) && leave(on: dayKey.string(from: d)) == nil
        && (onceDay(p.rule) != nil || isWorkday(d) || !overtime(on: d).isEmpty)
}
func periodSpans(_ p: Period, _ d: Date) -> [(from: String, to: String)] { periodOn(p, d) ? [(p.from, p.to)] : [] }
// The periods on `d` that task `j` (every few minutes) is quiet in.
func skipsOn(_ j: Job?, _ d: Date) -> [Period] { periods.filter { j?.skip?.contains($0.id) == true && periodOn($0, d) } }
func loadJSON<T: Decodable>(_ url: URL, into v: inout T) { if let d = try? Data(contentsOf: url), let x = try? JSONDecoder().decode(T.self, from: d) { v = x } }
func saveJSON<T: Encodable>(_ v: T, to url: URL) { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(v).write(to: url) }
func onceDay(_ rule: String?) -> String? { rule?.hasPrefix("once:") == true ? String(rule!.dropFirst(5)) : nil }
func overtime(on d: Date) -> [Overtime] {
    let k = dayKey.string(from: d)
    if leave(on: k) != nil { return [] }
    return overtimes.filter { o in
        if o.disabled == true { return false }
        if let u = o.until, let s = onceDay(o.rule) { return s <= k && k <= u }
        if let s = o.start, let e = o.end { return s <= k && k <= e }
        return ruleApplies(o.rule, on: d) && (onceDay(o.rule) != nil || holidays.days[k] == nil)
    }
}

// The quarter a date falls in, e.g. 2026-Q4.
func quarterKey(_ d: Date) -> String { let c = Calendar.current.dateComponents([.year, .month], from: d); return "\(c.year!)-Q\((c.month! - 1) / 3 + 1)" }
var autoClearLog: Bool { UserDefaults.standard.object(forKey: "autoClearLog") as? Bool ?? true }
func clearLogFiles() { [logURL.path, logURL.path + ".1"].forEach { try? FileManager.default.removeItem(atPath: $0) } }

func appendLog(_ s: String) {
    // On the first entry of a new quarter the old log is removed (unless turned off under More).
    let q = quarterKey(Date()), lastQ = UserDefaults.standard.string(forKey: "logQuarter")
    if lastQ != q {
        UserDefaults.standard.set(q, forKey: "logQuarter")
        if lastQ != nil && autoClearLog { clearLogFiles(); appendLog(T("log.quarterCleared")) }
    }
    guard let data = (ISO8601DateFormatter().string(from: Date()) + " " + s + "\n").data(using: .utf8) else { return }
    // Past 1 MB the log starts over; the previous one is kept as nudge.log.1.
    if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
        let old = URL(fileURLWithPath: logURL.path + ".1")
        try? FileManager.default.removeItem(at: old); try? FileManager.default.moveItem(at: logURL, to: old)
    }
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: logURL) }
}

func loadHolidays() {
    if let d = try? Data(contentsOf: holidayURL), let c = try? JSONDecoder().decode(HolidayCache.self, from: d) { holidays = c }
}

// Stale when empty or fetched in an earlier (local) year: a new year gets a fresh copy of the calendar.
func holidaysStale() -> Bool {
    let c = Calendar.current
    guard !holidays.days.isEmpty, let f = ISO8601DateFormatter().date(from: holidays.fetched) else { return true }
    return c.component(.year, from: f) != c.component(.year, from: Date())
}

let ymd: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd"; return f }()
func icsDay(_ v: String) -> Date? { v.count >= 8 ? ymd.date(from: String(v.prefix(8))) : nil }
func icsUnescape(_ v: String) -> String {
    v.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\N", with: " ")
     .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
     .trimmingCharacters(in: .whitespaces)
}

// iCalendar feed: every VEVENT is a day off from DTSTART up to DTEND (exclusive; one day when missing). Yearly RRULEs
// (Apple lists fixed-date holidays that way) are expanded through next year, honouring COUNT and UNTIL. Events the feed
// itself calls "not a national/public holiday" (Apple's state-only days and observances) and the start of Ramadan are skipped.
func parseICS(_ text: String) -> HolidayCache? {
    let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
    let c = Calendar.current, lastYear = c.component(.year, from: Date()) + 1
    var days: [String: String] = [:]
    let calName = unfolded.components(separatedBy: "\n").first { $0.hasPrefix("X-WR-CALNAME") }.map { String($0.drop { $0 != ":" }.dropFirst()) } ?? ""
    for block in unfolded.components(separatedBy: "BEGIN:VEVENT").dropFirst() {
        var f: [String: String] = [:]
        for line in block.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon].split(separator: ";").first ?? "")
            if f[name] == nil { f[name] = String(line[line.index(after: colon)...]) }
        }
        let desc = (f["DESCRIPTION"] ?? "").lowercased()
        guard f["STATUS"] != "CANCELLED", !desc.contains("not a national holiday"), !desc.contains("not a public holiday"),
              let start = f["DTSTART"].flatMap(icsDay) else { continue }
        let end = f["DTEND"].flatMap(icsDay) ?? start
        let length = max(1, c.dateComponents([.day], from: start, to: end).day ?? 1)
        var name = icsUnescape(f["SUMMARY"] ?? T("holiday.unnamed"))
        // officeholidays.com puts the place in front: "Kuala Lumpur: Labour Day".
        if let sep = name.range(of: ": "), case let place = name[..<sep.lowerBound], calName.contains(place) || (f["LOCATION"] ?? "").contains(place) {
            name = String(name[sep.upperBound...])
        }
        // Apple lists the first day of Ramadan as an observance with no marker in its description; it is a workday.
        if name.lowercased().hasPrefix("ramadan") { continue }
        var starts = [start]
        if let rule = f["RRULE"], rule.contains("FREQ=YEARLY") {
            let parts = Dictionary(rule.split(separator: ";").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
            let count = Int(parts["COUNT"] ?? "") ?? Int.max, until = parts["UNTIL"].flatMap(icsDay)
            var i = 1
            while i < count, let n = c.date(byAdding: .year, value: i, to: start), c.component(.year, from: n) <= lastYear, until.map({ n <= $0 }) ?? true {
                starts.append(n); i += 1
            }
        }
        for s in starts {
            for k in 0..<length {
                let key = dayKey.string(from: c.date(byAdding: .day, value: k, to: s)!)
                days[key] = days[key].map { $0.contains(name) ? $0 : $0 + "、" + name } ?? name
            }
        }
    }
    let years = Set(days.keys.compactMap { Int($0.prefix(4)) }).sorted()
    return days.isEmpty ? nil : HolidayCache(fetched: ISO8601DateFormatter().string(from: Date()), years: years, days: days)
}

// Why a holiday calendar could not be used, with the title and advice shown to the person.
enum HolidayFetchError: Error {
    case badAddress, offline, unreachable(String), notCalendar, noHolidays
    var title: String {
        switch self {
        case .badAddress: return T("holiday.badAddressTitle")
        case .offline: return T("holiday.offlineTitle")
        case .unreachable: return T("holiday.unreachableTitle")
        case .notCalendar: return T("holiday.notCalendarTitle")
        case .noHolidays: return T("holiday.noHolidaysTitle")
        }
    }
    var advice: String {
        switch self {
        case .badAddress: return T("holiday.formatHint")
        case .offline: return T("holiday.offlineText")
        case .unreachable(let detail): return T("holiday.unreachableText", detail)
        case .notCalendar: return sentences(T("holiday.notCalendarText"), T("holiday.formatHint"))
        case .noHolidays: return T("holiday.noHolidaysText")
        }
    }
}

// The address to download, or nil unless it is a web (http/https) or webcal link with a real host name.
func holidayFeedURL(_ source: String) -> URL? {
    let link = source.lowercased().hasPrefix("webcal://") ? "https://" + source.dropFirst("webcal://".count) : source
    guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, host.contains(".") || host == "localhost" else { return nil }
    return url
}

func refreshHolidays(from source: String = holidaySource, done: @escaping (HolidayFetchError?) -> Void) {
    guard let url = holidayFeedURL(source) else {
        appendLog(T("log.holidayBadUrl", source)); DispatchQueue.main.async { done(.badAddress) }; return
    }
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, resp, err in
        // Parsed here, but the cache, log and strings are only touched on the main thread, where tick() reads them.
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let page = data.flatMap { String(data: $0, encoding: .utf8) }, isCalendar = page?.contains("BEGIN:VCALENDAR") == true
        let parsed = isCalendar ? parseICS(page!) : nil
        DispatchQueue.main.async {
            let failure: HolidayFetchError?
            if let c = parsed {
                holidays = c
                try? JSONEncoder().encode(c).write(to: holidayURL)
                appendLog(T("log.holidayUpdated", c.years.map(String.init).joined(separator: "/"), String(c.days.count)))
                failure = nil
            } else {
                if let e = err as? URLError, [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(e.code) { failure = .offline }
                else if let err { failure = .unreachable(err.localizedDescription) }
                else if !(200..<300).contains(status) { failure = .unreachable("HTTP \(status)") }
                else { failure = isCalendar ? .noHolidays : .notCalendar }
                if case .unreachable(let detail) = failure! { appendLog(T("log.holidayFailed", detail)) } else { appendLog(T("log.holidayFailed", failure!.title)) }
            }
            done(failure)
        }
    }.resume()
}

func hidIdleSeconds() -> Double {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iter) == KERN_SUCCESS else { return .infinity }
    defer { IOObjectRelease(iter) }
    let entry = IOIteratorNext(iter)
    defer { IOObjectRelease(entry) }
    guard let v = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return .infinity }
    return v.doubleValue / 1_000_000_000
}

func isWorkday(_ d: Date) -> Bool {
    guard let w = Calendar.current.dateComponents([.weekday], from: d).weekday, (2...6).contains(w) else { return false }
    let key = dayKey.string(from: d)
    return holidays.days[key] == nil && leave(on: key) == nil
}

let hmFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f }()

// The periods the nudge is quiet in, plus part-day leave: no nudges in these stretches.
func pausesOn(_ d: Date) -> [(from: String, to: String)] {
    skipsOn(nudgeJob, d).map { ($0.from, $0.to) } + partLeaves(on: dayKey.string(from: d)).map { ($0.from!, $0.to!) }
}
// A from–to stretch belongs to the day it starts on; when `to` is not after `from` it runs on to `to` the next morning
// (a night shift). Whether that day is a workday, holiday or leave decides the whole stretch.
func overnight(_ from: String, _ to: String) -> Bool { to <= from }
func dayBefore(_ d: Date) -> Date { Calendar.current.date(byAdding: .day, value: -1, to: d)! }
func spanCovers(_ from: String, _ to: String, _ hm: String, startedToday: Bool) -> Bool {
    startedToday ? from <= hm && (overnight(from, to) || hm < to) : overnight(from, to) && hm < to
}
// Whether `d` falls in one of the stretches `spans` gives for its own day or, past midnight, the day before.
func covered(_ d: Date, _ spans: (Date) -> [(from: String, to: String)]) -> Bool {
    let hm = hmFmt.string(from: d)
    return spans(d).contains { spanCovers($0.from, $0.to, hm, startedToday: true) }
        || spans(dayBefore(d)).contains { spanCovers($0.from, $0.to, hm, startedToday: false) }
}
// "06:00" or, for a stretch that ends the next morning, "次日06:00".
func endText(_ from: String, _ to: String) -> String { overnight(from, to) ? T("time.nextDay", to) : to }
func spanText(_ from: String, _ to: String) -> String { from + "–" + endText(from, to) }

func inBreak(_ d: Date) -> Bool { covered(d, pausesOn) }
// Inside part-day leave; `orEnd` also counts the minute it ends, so the end of work as leave ends is not told either.
func onPartLeave(_ d: Date, orEnd: Bool = false) -> Bool {
    covered(d) { partLeaves(on: dayKey.string(from: $0)).map { ($0.from!, $0.to!) } } || orEnd && onPartLeave(d - 60)
}
func overtimeSpans(_ d: Date) -> [(from: String, to: String)] {
    let k = dayKey.string(from: d)
    return overtime(on: d).map { o in o.until == nil ? (o.from, o.to) : (k == onceDay(o.rule) ? o.from : "00:00", k == o.until ? o.to : "24:00") }
}
// "22:00–次日06:00", or for overtime over several days "11/14 09:00–11/16 15:00".
func otSpanText(_ o: Overtime) -> String { o.until.map { "\(md(onceDay(o.rule) ?? "")) \(o.from)–\(md($0)) \(o.to)" } ?? spanText(o.from, o.to) }
func workSpans(_ d: Date) -> [(from: String, to: String)] { isWorkday(d) ? [(workStart, workEnd)] : [] }

func inWindow(_ d: Date) -> Bool {
    if inBreak(d) { return false }
    return covered(d, overtimeSpans) || covered(d, workSpans)
}

// The first moment after `d` when nudging may start again: the start of work hours on a working day, an overtime start, or a pause end.
func nextStart(after d: Date) -> Date {
    let c = Calendar.current
    for offset in 0..<400 {
        let day = c.date(byAdding: .day, value: offset, to: c.startOfDay(for: d))!
        // Break ends today include those of last night's breaks that run past midnight.
        var marks = overtimeSpans(day).map(\.from) + (pausesOn(day) + pausesOn(dayBefore(day))).map(\.to)
        if isWorkday(day) { marks.append(workStart) }
        for m in Set(marks).sorted() {
            let p = m.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2, let t = c.date(bySettingHour: p[0], minute: p[1], second: 0, of: day), t > d, inWindow(t) else { continue }
            return t
        }
    }
    return d + 86400 * 400
}

// One interval on from `d`. The step that first runs past the end of working hours or overtime still runs
// (e.g. 17:52 → 18:02, or past midnight) as that stretch's last nudge, unless it lands in a break; otherwise wait for the next start.
func step(after d: Date) -> Date {
    let t = d + interval
    if inWindow(t) || (inWindow(d) && !inBreak(t)) { return t }
    return nextStart(after: d)
}

// Fresh schedule (launch, wake, settings change): the next interval mark counted from local midnight, after `d`.
func nextSlot(after d: Date) -> Date {
    let midnight = Calendar.current.startOfDay(for: d)
    return step(after: midnight + floor(d.timeIntervalSince(midnight) / interval) * interval)
}

// One interval on from the last nudge (manual or scheduled), skipping anything already past.
func slot(after d: Date, now: Date) -> Date {
    var t = step(after: d)
    for _ in 0..<60000 where t <= now { t = step(after: t) }
    return t
}

// Scheduled tasks: each is an action and when it runs. Actions: "notify" (a pop-up), "nudge" (the mouse nudge above,
// at most one, every `every` minutes during work time), "app" (opened and quit), "shortcut", "url" or "script".
// When: "at" a time on the days `rule` picks (same rules as periods; repeating ones on working days only and not in part-day leave, a one-off
// on its date), at the "start", "end" or "both" edges of what it follows (`offset` minutes early), "every" `every` minutes
// while inside it (not in a break unless it follows that break), or "during" it (apps: opened `lead` minutes before it
// starts and quit `lag` minutes after it ends, each 0–240, or with `keepOpen` never quit). Part-day leave holds them all.
let jobsURL = URL(fileURLWithPath: dir + "/tasks.json")
struct Job: Codable, Equatable {
    var id = UUID().uuidString; var disabled: Bool? = nil
    var action: String
    // The pop-up text (empty: a default one), shortcut name, link or shell command.
    var text: String = ""
    var name: String? = nil; var path: String? = nil; var bundleID: String? = nil; var keepOpen: Bool? = nil
    var when: String; var at: String? = nil; var rule: String? = nil
    // A repeating "at" task that also runs on days off (weekends, holidays, leave).
    var anyDay: Bool? = nil
    // Each "work" for work hours, "overtime", or a period's id; nil means work hours and overtime.
    var follow: [String]? = nil; var offset: Int? = nil; var every: Int? = nil; var lead: Int? = nil; var lag: Int? = nil
    // The ids of the periods a task every few minutes (the nudge too) is quiet in.
    var skip: [String]? = nil
}
var jobs: [Job] = []
// A fresh install starts with pop-ups at the start and end of work and no nudge; it is added as a task when wanted.
func defaultJobs(nudging: Bool, interval: Int) -> [Job] {
    (nudging ? [Job(action: "nudge", when: "every", every: interval)] : []) +
    [Job(action: "notify", when: "start", follow: ["work", "overtime"]), Job(action: "notify", when: "end", follow: ["work", "overtime"])]
}
var nudgeJob: Job? { jobs.first { $0.action == "nudge" } }
var nudging: Bool { nudgeJob.map { $0.disabled != true } ?? false }
// The nudge engine reads the interval from the nudge task.
func applyNudge() { intervalMinutes = nudgeJob?.every ?? 10 }

func minutesOf(_ hm: String) -> Int { let p = hm.split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0] * 60 + p[1] : 0 }
func hmOf(_ m: Int) -> String { String(format: "%02d:%02d", m / 60 % 24, m % 60) }
// Opening early stops at midnight, so the stretch still belongs to its own day; it never grows to a whole day.
// A stretch that runs to midnight (a day inside overtime over several days) is not stretched past it.
func widened(_ s: (from: String, to: String), lead: Int, lag: Int) -> (from: String, to: String) {
    let from = max(0, minutesOf(s.from) - lead)
    if s.to == "24:00" { return (hmOf(from), s.to) }
    let end = minutesOf(s.to) + (overnight(s.from, s.to) ? 1440 : 0) + lag
    return (hmOf(from), hmOf(min(from + 1439, end) % 1440))
}
func follows(_ j: Job) -> [String] { j.follow ?? ["work", "overtime"] }
func followSpans(_ f: String, _ d: Date) -> [(from: String, to: String)] {
    switch f {
    case "work": return workSpans(d)
    case "overtime": return overtimeSpans(d)
    case let id: return periods.first { $0.id == id }.map { periodSpans($0, d) } ?? []
    }
}
func jobSpans(_ j: Job, _ d: Date) -> [(from: String, to: String)] { follows(j).flatMap { followSpans($0, d) } }
func appSpans(_ j: Job, _ d: Date) -> [(from: String, to: String)] { jobSpans(j, d).map { widened($0, lead: j.lead ?? 0, lag: j.lag ?? 0) } }
// A task that follows only paused entries (overtime with every entry paused, or paused periods) is held with them.
func followPaused(_ f: String) -> Bool {
    switch f {
    case "work": return false
    case "overtime": return !overtimes.isEmpty && overtimes.allSatisfy { $0.disabled == true }
    case let id: return periods.first { $0.id == id }?.disabled == true
    }
}
func jobHeld(_ j: Job) -> Bool { j.when != "at" && j.action != "nudge" && follows(j).allSatisfy(followPaused) }
func appWanted(_ j: Job, _ d: Date) -> Bool { j.action == "app" && j.disabled != true && !onPartLeave(d) && covered(d) { appSpans(j, $0) } }

// HH:mm on a day as a moment; "24:00" is the next midnight.
func clock(_ hm: String, on day: Date) -> Date {
    let c = Calendar.current
    if hm == "24:00" { return c.date(byAdding: .day, value: 1, to: day)! }
    let m = minutesOf(hm)
    return c.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day)!
}
// What `fs` name as whole stretches of time around `d` (the day before to the day after), touching or overlapping
// pieces joined: work hours running into overtime, or the days of overtime over several days, are one stretch.
func stretches(_ fs: [String], around d: Date) -> [(start: Date, end: Date)] {
    let c = Calendar.current, today = c.startOfDay(for: d)
    var all: [(start: Date, end: Date)] = []
    for k in -1...1 {
        let day = c.date(byAdding: .day, value: k, to: today)!
        for s in fs.flatMap({ followSpans($0, day) }) {
            all.append((clock(s.from, on: day), clock(s.to, on: overnight(s.from, s.to) && s.to != "24:00" ? c.date(byAdding: .day, value: 1, to: day)! : day)))
        }
    }
    var merged: [(start: Date, end: Date)] = []
    for s in all.sorted(by: { $0.start < $1.start }) {
        if let last = merged.last, s.start <= last.end { merged[merged.count - 1].end = max(last.end, s.end) } else { merged.append(s) }
    }
    return merged
}
func periodName(_ p: Period) -> String { p.note.isEmpty ? T("period.unnamed") : p.note }
func followTitle(_ f: String) -> String {
    switch f {
    case "work": return T("apps.followWork")
    case "overtime": return T("section.overtime")
    case let id: return periods.first { $0.id == id }.map(periodName) ?? T("apps.periodGone")
    }
}
// The pop-up text at an edge of `f`, unless the task has its own.
func edgeText(_ j: Job, _ f: String, end: Bool) -> String {
    if !j.text.isEmpty { return j.text }
    if let o = j.offset, o > 0 { return T(end ? "job.endsIn" : "job.startsIn", followTitle(f), String(o)) }
    if f == "work" { return T(end ? "reminder.workEnd" : "reminder.workStart") }
    return T(end ? "reminder.periodEnd" : "reminder.periodStart", followTitle(f))
}
// The tasks due in the minute `d` falls in, each with its pop-up text (or its own text for other actions). The nudge
// keeps its own timing, and apps are checked on their own.
func jobsDue(_ d: Date) -> [(job: Job, text: String)] {
    let m = Calendar.current.dateInterval(of: .minute, for: d)!.start, hm = hmFmt.string(from: m)
    var due: [(job: Job, text: String)] = []
    for j in jobs where j.disabled != true && !["nudge", "app"].contains(j.action) {
        func add(_ s: String) { if !due.contains(where: { $0.job.id == j.id && $0.text == s }) { due.append((j, j.action == "notify" ? s : j.text)) } }
        switch j.when {
        case "at":
            if j.at == hm && ruleApplies(j.rule, on: m) && (onceDay(j.rule) != nil || j.anyDay == true || isWorkday(m) && !onPartLeave(m)) { add(j.text.isEmpty ? T("reminder.untitled", hm) : j.text) }
        case "every":
            let n = j.every ?? 0
            guard n > 0, minutesOf(hm) % n == 0, !onPartLeave(m), covered(m, { jobSpans(j, $0) }) else { continue }
            if covered(m, { d in skipsOn(j, d).map { ($0.from, $0.to) } }) { continue }
            add(j.text.isEmpty ? T("reminder.untitled", hm) : j.text)
        default:
            let early = TimeInterval((j.offset ?? 0) * 60)
            // Work and overtime followed together: where one runs on into the other only the start of the next is
            // told, and the end of the whole stretch is the end of work if it had any. Work comes first: its start is told
            // even inside overtime, and overtime that began during work is told to start as work ends.
            let fs = follows(j), both = fs.contains("work") && fs.contains("overtime")
            for f in fs {
                let other = both && ["work", "overtime"].contains(f) ? stretches([f == "work" ? "overtime" : "work"], around: m) : []
                for s in stretches([f], around: m) {
                    if j.when != "end" && s.start - early == m && !onPartLeave(s.start, orEnd: true) && !cutByLeave(s.start, end: false)
                        && (f == "work" || !other.contains(where: { $0.start < s.start && s.start < $0.end })) {
                        add(edgeText(j, f, end: false))
                    }
                    guard s.end - early == m && !onPartLeave(s.end, orEnd: true) && !cutByLeave(s.end, end: true) else { continue }
                    if !other.contains(where: { $0.start <= s.end && s.end < $0.end }) {
                        guard j.when != "start" else { continue }
                        let whole = stretches(["work", "overtime"], around: m).first { $0.end == s.end }
                        let hadWork = f == "work" || whole.map { w in other.contains { w.start <= $0.start && $0.end <= w.end } } ?? false
                        add(edgeText(j, hadWork ? "work" : f, end: true))
                    } else if f == "work" && j.when != "end" && other.contains(where: { $0.start < s.end && s.end < $0.end }) {
                        add(edgeText(j, "overtime", end: false))
                    }
                }
            }
        }
    }
    return due
}

// A midnight edge that is only there because the next day (for an end) or the day before (for a start) is whole-day
// leave, as when overtime over several days has a day of leave in the middle: no pop-up in the night for it.
func cutByLeave(_ t: Date, end: Bool) -> Bool {
    let c = Calendar.current
    guard c.startOfDay(for: t) == t else { return false }
    return leave(on: dayKey.string(from: end ? t : dayBefore(t))) != nil
}
// Every task due after `from` up to `to` (whole minutes, from the start of that day at the earliest), with the minute it
// was due: what a pause, sleep or a quit Mac missed.
func dueBetween(after from: Date, upTo to: Date) -> [(at: Date, job: Job, text: String)] {
    let c = Calendar.current, first = max(c.dateInterval(of: .minute, for: from)!.start + 60, c.startOfDay(for: to))
    // Only the minutes when a task can be due are checked: its time, its marks, or an edge of what it follows.
    var minutes = Set<Date>(), day = c.startOfDay(for: first)
    while day <= to {
        for j in jobs where j.disabled != true && !["nudge", "app"].contains(j.action) {
            switch j.when {
            case "at": if let a = j.at { minutes.insert(clock(a, on: day)) }
            case "every": if let n = j.every, n > 0 { for k in stride(from: 0, to: 1440, by: n) { minutes.insert(clock(hmOf(k), on: day)) } }
            default:
                let early = TimeInterval((j.offset ?? 0) * 60)
                for f in follows(j) { for s in stretches([f], around: day) { minutes.formUnion([s.start - early, s.end - early]) } }
            }
        }
        day = c.date(byAdding: .day, value: 1, to: day)!
    }
    return minutes.filter { first <= $0 && $0 <= to }.sorted().flatMap { m in jobsDue(m).map { (m, $0.job, $0.text) } }
}

// The nearest period start or timed pop-up in the minutes after `d` (up to `within` seconds away), for the menu bar
// countdown. A period counts when it starts in work or overtime and is named or pauses the nudge; pop-ups every few
// minutes don't count.
func upcomingEvent(after d: Date, within: TimeInterval) -> (at: Date, name: String)? {
    var m = Calendar.current.dateInterval(of: .minute, for: d)!.end
    while m.timeIntervalSince(d) <= within {
        let hm = hmFmt.string(from: m)
        let working = covered(m, workSpans) || covered(m, overtimeSpans)
        let starting = !working ? [] : periods.filter { $0.from == hm && periodOn($0, m) && (!$0.note.isEmpty || nudgeJob?.skip?.contains($0.id) == true) }.map(periodName)
        let names = starting + jobsDue(m).filter { $0.job.action == "notify" && $0.job.when != "every" }.map(\.text)
        if !names.isEmpty { return (m, names.joined(separator: T("common.listSeparator"))) }
        m += 60
    }
    return nil
}
// How far through the current stretch of work and overtime `d` is, 0 outside work.
func workProgress(_ d: Date) -> Double {
    guard let s = stretches(["work", "overtime"], around: d).first(where: { $0.start <= d && d < $0.end }) else { return 0 }
    return d.timeIntervalSince(s.start) / s.end.timeIntervalSince(s.start)
}

final class ClosureTarget: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}

// A menu row drawn by us so clicking it toggles its section without closing the menu (a normal item always closes it).
final class SectionHeaderView: NSView {
    let icon = NSImageView(), label = NSTextField(labelWithString: ""), chevron = NSImageView()
    var onClick: () -> Void = {}
    var hovered = false { didSet { refresh() } }

    init(symbol: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        autoresizingMask = [.width]
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.font = .menuFont(ofSize: 0)
        for v in [icon, label, chevron] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String, open: Bool) {
        label.stringValue = title
        chevron.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: open ? T("section.collapse") : T("section.expand"))?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        setAccessibilityLabel(T(open ? "section.expandedLabel" : "section.collapsedLabel", title))
    }

    var lit: Bool { hovered || enclosingMenuItem?.isHighlighted == true }
    func refresh() {
        let fg: NSColor = lit ? .selectedMenuItemTextColor : .labelColor
        label.textColor = fg; icon.contentTintColor = fg; chevron.contentTintColor = lit ? fg : .secondaryLabelColor
        needsDisplay = true
    }
    override func draw(_ r: NSRect) {
        guard lit else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func viewDidMoveToWindow() { hovered = false }
    override func mouseEntered(with e: NSEvent) { hovered = true }
    override func mouseExited(with e: NSEvent) { hovered = false }
    override func mouseUp(with e: NSEvent) { onClick() }
    // A button to VoiceOver and other assistive tools, which can open and close the section too.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

// An entry row: its label, then a test button (tasks only) that runs it once now, an edit button, a pause/resume button
// that turns the entry off or on in place (the menu stays open) and a delete button. A turned-off entry is greyed out.
final class EntryRowView: NSView {
    let label = NSTextField(labelWithString: ""), test = NSButton(), edit = NSButton(), toggle = NSButton(), trash = NSButton()
    let title: String, onToggle: () -> Bool, onEdit: () -> Void, onDelete: () -> Void, onTest: (() -> Void)?
    var disabled: Bool { didSet { refresh() } }
    // Room right of the label for the buttons.
    var buttonsWidth: CGFloat { onTest == nil ? 94 : 118 }

    init(title: String, disabled: Bool, onToggle: @escaping () -> Bool, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void, onTest: (() -> Void)? = nil) {
        self.title = title; self.disabled = disabled; self.onToggle = onToggle; self.onEdit = onEdit; self.onDelete = onDelete; self.onTest = onTest
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        autoresizingMask = [.width]
        label.font = .menuFont(ofSize: 0); label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (b, sel) in [(test, #selector(tested)), (edit, #selector(edited)), (toggle, #selector(toggled)), (trash, #selector(deleted))] {
            b.isBordered = false; b.imagePosition = .imageOnly; b.target = self; b.action = sel
            b.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        }
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: T("common.delete")); trash.toolTip = T("common.delete")
        edit.image = NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: T("common.edit")); edit.toolTip = T("common.edit")
        test.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: T("common.test")); test.toolTip = T("common.test")
        trash.contentTintColor = .secondaryLabelColor; edit.contentTintColor = .secondaryLabelColor; test.contentTintColor = .secondaryLabelColor
        let first: NSButton = onTest == nil ? edit : test
        for v in [label, edit, toggle, trash] + (onTest == nil ? [] : [test]) as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        if onTest != nil {
            NSLayoutConstraint.activate([edit.leadingAnchor.constraint(equalTo: test.trailingAnchor, constant: 4), test.centerYAnchor.constraint(equalTo: centerYAnchor), test.widthAnchor.constraint(equalToConstant: 20)])
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            first.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            edit.centerYAnchor.constraint(equalTo: centerYAnchor), edit.widthAnchor.constraint(equalToConstant: 20),
            toggle.leadingAnchor.constraint(equalTo: edit.trailingAnchor, constant: 4), toggle.centerYAnchor.constraint(equalTo: centerYAnchor), toggle.widthAnchor.constraint(equalToConstant: 20),
            trash.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 4), trash.centerYAnchor.constraint(equalTo: centerYAnchor),
            trash.widthAnchor.constraint(equalToConstant: 20), trash.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        frame.size.width = max(240, label.intrinsicContentSize.width + 36 + buttonsWidth)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        label.stringValue = title; label.textColor = disabled ? .tertiaryLabelColor : .labelColor
        let tip = T(disabled ? "common.enable" : "common.disable")
        toggle.image = NSImage(systemSymbolName: disabled ? "play.circle" : "pause.circle", accessibilityDescription: tip); toggle.toolTip = tip
        toggle.contentTintColor = disabled ? .controlAccentColor : .secondaryLabelColor
        setAccessibilityLabel(disabled ? T("item.disabledLabel", title) : title)
        label.sizeToFit()
        frame.size.width = max(frame.size.width, label.frame.width + 36 + buttonsWidth)
    }
    @objc func toggled() { disabled = onToggle() }
    @objc func tested() { enclosingMenuItem?.menu?.cancelTracking(); if let onTest { DispatchQueue.main.async(execute: onTest) } }
    @objc func edited() { enclosingMenuItem?.menu?.cancelTracking(); DispatchQueue.main.async(execute: onEdit) }
    @objc func deleted() { enclosingMenuItem?.menu?.cancelTracking(); DispatchQueue.main.async(execute: onDelete) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    // Titles are set in retitle(), again whenever the language changes.
    let lastLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let nextLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let holidayLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    // Today's status, one fact per line; a line is hidden when it has nothing to say.
    let todayLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let overtimeLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let breakLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let permLine = NSMenuItem(title: "", action: #selector(openPrivacy), keyEquivalent: "")
    let leaveRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let overtimeRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let periodRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let tasksRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    weak var openForm: NSAlert?
    // Open reminder pop-ups with the targets of their OK buttons, kept until closed.
    var reminderAlerts: [(NSAlert, ClosureTarget)] = []
    var lastReminderMinute = ""
    let sectionNames = ["leave": "section.leave", "overtime": "section.overtime", "periods": "section.periods", "tasks": "section.tasks"]
    // Sections expand in place under their heading; which ones are open survives restarts (older versions saved the Chinese names).
    var expanded = Set((UserDefaults.standard.stringArray(forKey: "expanded") ?? []).map { ["休假": "leave", "加班": "overtime", "休息时间": "periods", "break": "periods"][$0] ?? $0 })
    var sectionRows: [String: [NSMenuItem]] = [:]
    var sectionCount: [String: Int] = [:]
    let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "p")
    let workHoursItem = NSMenuItem(title: "", action: #selector(setWorkHours), keyEquivalent: "")
    let refetchItem = NSMenuItem(title: "", action: #selector(refetchHolidays), keyEquivalent: "")
    let clearSourceItem = NSMenuItem(title: "", action: #selector(clearHolidaySource), keyEquivalent: "")
    let logItem = NSMenuItem(title: "", action: #selector(openLog), keyEquivalent: "")
    let clearLogItem = NSMenuItem(title: "", action: #selector(clearLog), keyEquivalent: "")
    let autoClearItem = NSMenuItem(title: "", action: #selector(toggleAutoClear(_:)), keyEquivalent: "")
    let moreItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "", action: #selector(toggleLogin(_:)), keyEquivalent: "")
    let sourceItem = NSMenuItem(title: "", action: #selector(setHolidaySource), keyEquivalent: "")
    let languageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let quitItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    // The last run's time and result key, kept so the line can be retitled in another language.
    var lastRun: (time: String, result: String)?
    var paused = UserDefaults.standard.bool(forKey: "paused")
    // Timed pop-ups due while paused, asleep or with the app quit, kept across restarts until they are listed together.
    var missed: [(at: Date, text: String)] = (UserDefaults.standard.stringArray(forKey: "missed") ?? []).compactMap { s in
        let p = s.split(separator: "\t", maxSplits: 1)
        return p.count == 2 ? Double(p[0]).map { (Date(timeIntervalSince1970: $0), String(p[1])) } : nil
    }
    // The last minute looked at, so the minutes slept through are known.
    var lastSeen = UserDefaults.standard.object(forKey: "lastSeen") as? Date
    var next = Date.distantFuture
    var fetching = false
    // Holidays are only fetched online; coming back online checks again. A failed automatic fetch waits an hour.
    let network = NWPathMonitor()
    var online = false
    var autoFetchFailed: Date?
    var languagesWatch: DispatchSourceFileSystemObject?
    // Watched apps are checked every few seconds; whether each app (by path) was wanted at the last check.
    // Missing until the first check, so launching after hours closes nothing.
    var appWasWanted: [String: Bool] = [:]
    var lastAppCheck = Date.distantPast
    var appLaunchTried: [String: Date] = [:]
    let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for i in [lastLine, nextLine, todayLine, overtimeLine, breakLine] { i.isEnabled = false }
        holidayLine.submenu = NSMenu(); holidayLine.submenu!.delegate = self
        loadCustomLanguages(); applyLanguageChoice(); reportLanguageProblems(); watchLanguagesFolder()
        for i in [permLine, pauseItem, workHoursItem, refetchItem, clearSourceItem, logItem, clearLogItem, autoClearItem, loginItem, sourceItem] { i.target = self }
        let (more, quit) = (moreItem, quitItem)
        more.submenu = NSMenu(); languageItem.submenu = NSMenu(); languageItem.submenu!.delegate = self
        loginItem.state = loginAgentOn ? .on : .off
        autoClearItem.state = autoClearLog ? .on : .off
        [loginItem, languageItem, .separator(), sourceItem, refetchItem, clearSourceItem, .separator(), logItem, clearLogItem, autoClearItem].forEach(more.submenu!.addItem)
        for (root, key, sym) in [(leaveRoot, "leave", "airplane"), (overtimeRoot, "overtime", "briefcase"), (periodRoot, "periods", "calendar.day.timeline.left"), (tasksRoot, "tasks", "bell")] {
            root.representedObject = key
            let v = SectionHeaderView(symbol: sym); v.onClick = { [weak self, weak root] in if let root { self?.toggleSection(root) } }
            root.view = v
        }
        for (i, sym) in [(pauseItem, "pause.circle"), (workHoursItem, "clock"), (more, "ellipsis.circle")] {
            i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        }
        [lastLine, nextLine, holidayLine, todayLine, overtimeLine, breakLine, permLine, .separator(), pauseItem, .separator(), leaveRoot, overtimeRoot, periodRoot, tasksRoot, .separator(), more, quit].forEach(menu.addItem)
        item.menu = menu
        loadHolidays()
        loadLeaves()
        loadJSON(overtimeURL, into: &overtimes)
        if FileManager.default.fileExists(atPath: periodsURL.path) { loadJSON(periodsURL, into: &periods) }
        else { periods = [Period(from: "12:00", to: "13:00", note: T("break.lunch"), rule: nil)]; saveJSON(periods, to: periodsURL) }
        // A Mac that nudged before tasks existed keeps nudging at its interval; a fresh install has no nudge.
        if FileManager.default.fileExists(atPath: jobsURL.path) { loadJSON(jobsURL, into: &jobs) }
        else {
            let v = UserDefaults.standard.integer(forKey: "intervalMinutes")
            jobs = defaultJobs(nudging: UserDefaults.standard.bool(forKey: "workRemindersAdded"), interval: (1...240).contains(v) ? v : 10); saveJSON(jobs, to: jobsURL)
        }
        applyNudge()
        catchUp(Date())
        pruneExpired()
        holidayLine.title = T("status.holidaysLoading")
        retitle()
        // The first update arrives right away and fetches the holidays if they are due.
        network.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasOnline = self.online; self.online = path.status == .satisfied
                if self.online && !wasOnline { self.autoFetchFailed = nil; self.checkHolidays() }
            }
        }
        network.start(queue: .global(qos: .utility))
        next = nextSlot(after: Date())
        if nudging { askAccessibility() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // Common modes, so the countdown in the menu keeps going while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }; timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    // Every title, in the current language; the section rows are rebuilt.
    func retitle() {
        permLine.title = T("status.needAccessibility")
        refetchItem.title = T("menu.refetchHolidays"); clearSourceItem.title = T("menu.unsubscribeHoliday"); logItem.title = T("menu.openLog")
        moreItem.title = T("menu.more"); loginItem.title = T("menu.openAtLogin"); sourceItem.title = T("menu.subscribeHoliday")
        quitItem.title = T("menu.quit")
        // Always says "Language" too, so someone stuck in a language they can't read still finds it.
        languageItem.title = T("menu.language") == "Language" ? "Language" : T("menu.language") + " / Language"
        workHoursItem.title = T("menu.workHours", workStart, endText(workStart, workEnd))
        clearLogItem.title = T("menu.clearLog"); autoClearItem.title = T("menu.autoClearLog")
        lastLine.title = lastRun.map { T("status.last", $0.time, T($0.result)) } ?? T("status.lastNever")
        if fetching { holidayLine.title = T("status.holidaysFetching") }
        rebuildLeaveMenu(); rebuildOvertimeMenu(); rebuildPeriodMenu(); rebuildTasksMenu()
        tick()
    }

    // Built each time it opens, so language files dropped into the folder show up (and edits to the current one apply).
    func buildLanguageMenu(_ m: NSMenu) {
        loadCustomLanguages()
        if applyLanguageChoice() { retitle() }
        reportLanguageProblems()
        m.removeAllItems()
        let sys = NSMenuItem(title: T("language.system", languageName(systemLanguage())), action: #selector(chooseLanguage(_:)), keyEquivalent: "")
        sys.target = self; sys.state = languageChoice == nil ? .on : .off; m.addItem(sys); m.addItem(.separator())
        for code in languageCodes() {
            let it = NSMenuItem(title: languageName(code), action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = code; it.state = languageChoice == code ? .on : .off
            if code == builtinLanguages.last?.code, customLanguages.contains(where: { c in !builtinLanguages.contains { $0.code == c.code } }) {
                m.addItem(it); m.addItem(.separator()); continue
            }
            m.addItem(it)
        }
        m.addItem(.separator())
        for p in languageProblems { let it = NSMenuItem(title: "⚠️ " + p, action: nil, keyEquivalent: ""); it.isEnabled = false; m.addItem(it) }
        let templates = NSMenuItem(title: T("language.downloadTemplate"), action: nil, keyEquivalent: ""); templates.submenu = NSMenu()
        for (title, xlsx) in [(T("language.excelTemplate"), true), (T("language.jsonTemplate"), false)] {
            let it = NSMenuItem(title: title, action: #selector(downloadTemplate(_:)), keyEquivalent: ""); it.target = self; it.tag = xlsx ? 1 : 0
            templates.submenu!.addItem(it)
        }
        m.addItem(templates)
        let folder = NSMenuItem(title: T("language.openFolder"), action: #selector(openLanguagesFolder), keyEquivalent: ""); folder.target = self
        m.addItem(folder)
    }
    var loggedProblems: [String] = []
    // Logs new problems and shows each file version that cannot be used once, after any open menu has closed.
    func reportLanguageProblems() {
        if languageProblems != loggedProblems { languageProblems.forEach { appendLog(T("language.problem", $0)) }; loggedProblems = languageProblems }
        let shown = Set(UserDefaults.standard.stringArray(forKey: "shownLanguageProblems") ?? [])
        let fresh = zip(languageProblemIDs, languageProblems).filter { !shown.contains($0.0) }.map(\.1)
        UserDefaults.standard.set(languageProblemIDs, forKey: "shownLanguageProblems")
        guard !fresh.isEmpty else { return }
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert(); a.alertStyle = .warning; a.messageText = T("language.problemTitle")
            a.informativeText = fresh.joined(separator: "\n") + "\n\n" + T("language.problemHelp")
            a.addButton(withTitle: T("language.openFolder")); a.addButton(withTitle: T("common.ok")).keyEquivalent = "\u{1b}"
            if a.runModal() == .alertFirstButtonReturn { self?.openLanguagesFolder() }
        }
    }
    // Files dropped into, changed in or removed from the languages folder are read again without opening the menu.
    func watchLanguagesFolder() {
        try? FileManager.default.createDirectory(at: languagesDir, withIntermediateDirectories: true)
        let fd = open(languagesDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            // A copy or an Excel save arrives in several steps; read once they settle.
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.reloadLanguages), object: nil)
            self.perform(#selector(self.reloadLanguages), with: nil, afterDelay: 1)
        }
        s.setCancelHandler { close(fd) }
        s.resume(); languagesWatch = s
    }
    @objc func reloadLanguages() {
        loadCustomLanguages()
        if applyLanguageChoice() { retitle() }
        reportLanguageProblems()
    }
    @objc func chooseLanguage(_ sender: NSMenuItem) {
        languageChoice = sender.representedObject as? String
        if applyLanguageChoice() { retitle() }
    }
    @objc func downloadTemplate(_ sender: NSMenuItem) {
        do {
            let url = try saveTemplate(xlsx: sender.tag == 1)
            appendLog(T("log.templateSaved", url.path))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { appendLog(T("log.templateFailed", error.localizedDescription)) }
    }
    @objc func openLanguagesFolder() {
        try? FileManager.default.createDirectory(at: languagesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(languagesDir)
    }

    // Checked at launch and on every run; a failed fetch is retried on the next run.
    // `report` (Refresh holidays) says why a fetch did not work; automatic fetches only log it.
    func checkHolidays(force: Bool = false, report: Bool = false) {
        guard !fetching, !holidaySource.isEmpty, force || holidaysStale() else { return }
        guard online else { if report { holidayProblem(.offline, link: nil) }; return }
        if !force, let f = autoFetchFailed, Date().timeIntervalSince(f) < 3600 { return }
        fetching = true
        holidayLine.title = T("status.holidaysFetching")
        refreshHolidays { [weak self] failure in
            guard let self else { return }
            self.fetching = false
            self.autoFetchFailed = failure == nil ? nil : Date()
            if let failure, report { self.holidayProblem(failure, link: nil) }
            self.next = nextSlot(after: Date())
            self.tick()
        }
    }

    // One-off leave, overtime and periods are removed once their last day (and end time, if any) has passed.
    // Repeating ones stay. Checked at launch and whenever the minute changes.
    var lastPrune = ""
    func pruneExpired() {
        let now = Date(), k = dayKey.string(from: now), hm = hmFmt.string(from: now)
        lastPrune = hm
        // A stretch that runs past midnight finishes the day after its last day.
        func over(_ day: String?, _ from: String?, _ to: String?) -> Bool {
            guard var day else { return false }
            if let from, let to, overnight(from, to), let d = dayKey.date(from: day) { day = dayKey.string(from: Calendar.current.date(byAdding: .day, value: 1, to: d)!) }
            return day < k || (day == k && to.map { $0 <= hm } ?? false)
        }
        let l = leaves.filter { over($0.end, $0.from, $0.to) }, o = overtimes.filter(otOver)
        func otOver(_ o: Overtime) -> Bool { o.until != nil ? over(o.until, nil, o.to) : over(onceDay(o.rule) ?? (o.rule == nil ? o.end : nil), o.from, o.to) }
        let b = periods.filter { over(onceDay($0.rule), $0.from, $0.to) }
        if !l.isEmpty { leaves.removeAll { over($0.end, $0.from, $0.to) }; saveLeaves(); rebuildLeaveMenu(); l.forEach { appendLog(T("log.leaveExpired", label($0))) } }
        if !o.isEmpty { overtimes.removeAll(where: otOver); saveJSON(overtimes, to: overtimeURL); rebuildOvertimeMenu(); o.forEach { appendLog(T("log.overtimeExpired", otLabel($0))) } }
        if !b.isEmpty {
            periods.removeAll { over(onceDay($0.rule), $0.from, $0.to) }; saveJSON(periods, to: periodsURL); rebuildPeriodMenu()
            b.forEach { appendLog(T("log.periodExpired", periodLabel($0))); dropFollowers(of: $0) }
        }
        // A one-off timed task goes once its minute has passed (tick runs it before pruning).
        func done(_ j: Job) -> Bool { j.when == "at" && over(onceDay(j.rule), nil, j.at) }
        let r = jobs.filter(done)
        if !r.isEmpty { jobs.removeAll(where: done); saveJSON(jobs, to: jobsURL); rebuildTasksMenu(); r.forEach { appendLog(T("log.taskExpired", jobLabel($0))) } }
    }

    func saveMissed() { UserDefaults.standard.set(missed.map { "\($0.at.timeIntervalSince1970)\t\($0.text)" }, forKey: "missed") }
    // Of what was missed, only timed pop-ups wait to be listed: a start, an end or a pop-up every few minutes means nothing
    // once its moment has gone. Shortcuts, links and commands are not run later, only logged.
    func noteMissed(_ due: [(at: Date, job: Job, text: String)]) {
        for x in due {
            if x.job.action == "notify" { if x.job.when == "at" { missed.append((x.at, x.text)) } }
            else { appendLog(T("log.taskMissed", jobLabel(x.job))) }
        }
        saveMissed()
    }
    // Notes what came due in the minutes between the last one looked at and `now` (asleep, or the app quit), before
    // pruning drops one-off tasks whose time has passed.
    func catchUp(_ now: Date) {
        let m = Calendar.current.dateInterval(of: .minute, for: now)!.start
        if let l = lastSeen, m.timeIntervalSince(l) > 60 {
            let due = dueBetween(after: l, upTo: m - 60)
            if !due.isEmpty { noteMissed(due) }
        }
        lastSeen = m; UserDefaults.standard.set(m, forKey: "lastSeen")
    }

    func tick() {
        let now = Date()
        let minute = dayKey.string(from: now) + " " + hmFmt.string(from: now)
        if minute != lastReminderMinute {
            lastReminderMinute = minute
            catchUp(now)
            // Paused, every task waits and is only listed on resume; all pop-ups due this minute share one window.
            let due = jobsDue(now)
            if paused { noteMissed(due.map { (now, $0.job, $0.text) }) }
            else {
                let pops = due.filter { $0.job.action == "notify" }.map(\.text)
                if !pops.isEmpty { showReminder(pops); appendLog(T("log.reminderShown", pops.joined(separator: T("common.listSeparator")))) }
                due.filter { $0.job.action != "notify" }.forEach { perform($0.job) }
            }
        }
        // Only today's are listed; nothing is shown after days away.
        if !paused && !missed.isEmpty {
            let lines = missed.filter { Calendar.current.isDateInToday($0.at) }.map { hmFmt.string(from: $0.at) + "  " + $0.text }
            if !lines.isEmpty { showReminder(lines, title: T("reminder.missed")); appendLog(T("log.missedShown", lines.joined(separator: T("common.listSeparator")))) }
            missed = []; saveMissed()
        }
        if hmFmt.string(from: now) != lastPrune { pruneExpired() }
        if !paused && now.timeIntervalSince(lastAppCheck) >= 10 { checkApps() }
        // The nudge lines show only while the nudge is on; pausing holds the nudge and every task, apps included.
        for i in [lastLine, nextLine] { i.isHidden = !nudging }
        permLine.isHidden = !nudging || AXIsProcessTrusted()
        pauseItem.isHidden = !jobs.contains { $0.disabled != true }
        // With no source there is nothing to refetch or clear.
        refetchItem.isHidden = holidaySource.isEmpty; clearSourceItem.isHidden = holidaySource.isEmpty
        pauseItem.title = paused ? T("menu.resume") : T("menu.pause")
        if !fetching {
            let k = dayKey.string(from: now)
            let parts: [String] = partLeaves(on: k).map { l in T("status.partLeave", spanText(l.from!, l.to!)) + (l.note.isEmpty ? "" : T("common.paren", l.note)) }
            let whole: String? = leave(on: k).map { l in T("section.leave") + (l.note.isEmpty ? "" : T("common.paren", l.note)) }
            let today: String? = holidays.days[k] ?? whole ?? (parts.isEmpty ? nil : parts.joined(separator: T("common.listSeparator")))
            todayLine.title = T("status.today", today ?? ""); todayLine.isHidden = today == nil
            let hm = hmFmt.string(from: now)
            // Today's, plus last night's that are still running.
            let ots = overtime(on: dayBefore(now)).filter { $0.until == nil && spanCovers($0.from, $0.to, hm, startedToday: false) } + overtime(on: now)
            let ot = ots.map { otSpanText($0) + ($0.note.isEmpty ? "" : " " + $0.note) }
            overtimeLine.title = T("status.overtimeToday", ot.joined(separator: T("common.listSeparator"))); overtimeLine.isHidden = ot.isEmpty
            // The periods the nudge is quiet in, while it is on.
            let quiet = { (d: Date) in nudging ? skipsOn(nudgeJob, d) : [] }
            let late = quiet(dayBefore(now)).filter { spanCovers($0.from, $0.to, hm, startedToday: false) }
            let br = late.map { ($0, false) } + quiet(now).map { ($0, true) }
            let brText = br.map { b, today in spanText(b.from, b.to) + (b.note.isEmpty ? "" : " " + b.note) + (spanCovers(b.from, b.to, hm, startedToday: today) ? T("status.onBreak") : "") }
            breakLine.title = T("status.breaks", brText.joined(separator: T("common.listSeparator"))); breakLine.isHidden = brText.isEmpty
            // Only this year is shown, even in December; later years stay in the data for scheduling.
            let year = String(k.prefix(4))
            // Days to the next holiday after today, looking into next year's data too.
            let untilNext = holidays.days.keys.filter { $0 > k }.min().flatMap(dayKey.date(from:)).flatMap { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: $0).day }
            let span = holidays.years.contains(Int(year)!) ? { let ks = holidays.days.keys.filter { $0.hasPrefix(year) }; return T("status.holidaysLeft", String(ks.filter { $0 >= k }.count), String(ks.count)) + (untilNext.map { T("status.holidaysNext", String($0)) } ?? "") }() : holidaySource.isEmpty ? T("status.holidaysNotSubscribed") : T("status.holidaysNoData", year)
            holidayLine.title = T("status.holidays", span)
        }
        if now >= next {
            // After sleep the slot may be long past; only run a slot that is due right now.
            if !paused && nudging && now.timeIntervalSince(next) < 60 { run(manual: false) }
            next = slot(after: next, now: now)
        }
        let left = Int(next.timeIntervalSince(now))
        // Count down only during work hours or overtime (including the last step that runs past the end), not before work starts.
        let counting = inWindow(now) || inWindow(next - interval)
        let nextText: String
        if paused { nextText = T("status.paused") }
        else if left < 3600 && counting { nextText = T("status.nextCountdown", String(format: "%02d:%02d", left / 60, left % 60)) }
        else if Calendar.current.isDateInToday(next) { nextText = fmt.string(from: next) }
        else { nextText = localFmt("MdEEEHHmm").string(from: next) }
        if nextLine.title != T("status.next", nextText) { nextLine.title = T("status.next", nextText) }
        // The menu bar shows no clock: the icon fills from the top as the next nudge comes closer, and a countdown appears only
        // shortly before a break or reminder. With the nudge off it fills as the current stretch of work goes by.
        setIcon(!nudging ? workProgress(now) : paused || !counting ? 0 : 1 - Double(left) / interval)
        var title = paused ? T("status.paused") : ""
        if !paused, let e = upcomingEvent(after: now, within: 600) {
            let s = Int(e.at.timeIntervalSince(now).rounded(.up)), name = e.name.count > 8 ? e.name.prefix(7) + "…" : e.name
            title = name + String(format: " %d:%02d", s / 60, s % 60)
        }
        if !title.isEmpty { title = " " + title }
        if item.button?.title != title { item.button?.title = title }
        let tip = paused || !nudging ? nil : T("status.nextNudge", localFmt("MdEEEHHmm").string(from: next))
        if item.button?.toolTip != tip { item.button?.toolTip = tip }
    }

    // The 🖱 emoji, drawn once at twice the menu bar size, with the rows its drawing actually covers (the glyph box has
    // empty space above and below). It fills from the top down as the next nudge comes closer: the filled part is the
    // emoji as it is, the rest faded. Off hours and while paused it is faded all over.
    lazy var mouseEmoji: (rep: NSBitmapImageRep, top: CGFloat, bottom: CGFloat) = {
        let s = NSAttributedString(string: "🖱", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let size = s.size()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep); s.draw(at: .zero); NSGraphicsContext.restoreGraphicsState()
        let rows = (0..<rep.pixelsHigh).filter { y in (0..<rep.pixelsWide).contains { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 } }
        let (first, last) = (rows.first ?? 0, rows.last ?? rep.pixelsHigh - 1)
        return (rep, size.height - CGFloat(first) / 2, size.height - CGFloat(last + 1) / 2)
    }()
    var iconFill = -1.0
    func setIcon(_ progress: Double) {
        let fill = (min(max(progress, 0), 1) * 50).rounded() / 50
        guard fill != iconFill else { return }
        iconFill = fill
        let e = mouseEmoji
        let image = NSImage(size: e.rep.size, flipped: false) { r in
            e.rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.3, respectFlipped: true, hints: nil)
            let y = e.top - (e.top - e.bottom) * fill
            NSRect(x: 0, y: y, width: r.width, height: r.height - y).clip()
            e.rep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        image.accessibilityDescription = "Shiftbell"
        item.button?.image = image; item.button?.imagePosition = .imageLeading
    }

    // Only the nudge needs it; asked at launch and when the nudge is turned on.
    func askAccessibility() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }

    func run(manual: Bool) {
        checkHolidays()
        let idle = hidIdleSeconds()
        let result: String
        if !manual && idle < skipIfIdleUnder {
            result = "result.skippedInUse"
        } else if !manual && !nudgeWhenLocked && screenLocked() {
            result = "result.skippedLocked"
        } else if !AXIsProcessTrusted() {
            result = "result.noPermission"
        } else {
            let p = CGEvent(source: nil)?.location ?? .zero
            // Toward whichever side still has screen, so a cursor at the right edge still moves.
            let dx: CGFloat = [1, -1].first { onScreen(CGPoint(x: p.x + $0, y: p.y)) } ?? 1
            for pt in [CGPoint(x: p.x + dx, y: p.y), p] {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(50_000)
            }
            result = "result.moved"
        }
        lastRun = (fmt.string(from: Date()), result)
        lastLine.title = T("status.last", lastRun!.time, T(result))
        appendLog("\(T(result)) idle=\(Int(idle))s\(manual ? " manual" : "")")
    }

    func label(_ l: Leave) -> String {
        return (l.start == l.end ? md(l.start) : md(l.start) + "–" + md(l.end)) + (l.from.map { " " + spanText($0, l.to!) } ?? "") + (l.note.isEmpty ? "" : "  " + l.note)
    }

    func setHeading(_ root: NSMenuItem) {
        let key = root.representedObject as! String, n = sectionCount[key] ?? 0, name = T(sectionNames[key]!)
        (root.view as? SectionHeaderView)?.set(title: n == 0 ? name : T("common.withCount", name, String(n)), open: expanded.contains(key))
    }

    // Rebuilds a section's rows right under its heading: one row per entry (with edit, turn off/on and delete buttons), then
    // the add item and any extra items. `head` items go first, as they are. `toggle` flips entry i and returns whether it is now off; `edit` opens its form;
    // `remove` asks, then deletes.
    func fill(_ root: NSMenuItem, _ rows: [(String, Bool)], toggle: @escaping (Int) -> Bool, edit: @escaping (Int) -> Void, remove: @escaping (Int) -> Void,
              add: (String, Selector, String), head: [NSMenuItem] = [], extra: [NSMenuItem] = [], test: ((Int) -> Void)? = nil) {
        let name = root.representedObject as! String
        sectionRows[name]?.forEach { if $0.menu != nil { menu.removeItem($0) } }
        var items: [NSMenuItem] = head + rows.enumerated().map { i, r in
            let it = NSMenuItem(title: r.0, action: nil, keyEquivalent: "")
            it.view = EntryRowView(title: r.0, disabled: r.1, onToggle: { toggle(i) }, onEdit: { edit(i) }, onDelete: { remove(i) }, onTest: test.map { t in { t(i) } }); return it
        }
        if rows.isEmpty && head.isEmpty { let none = NSMenuItem(title: T("menu.none"), action: nil, keyEquivalent: ""); none.isEnabled = false; items.append(none) }
        let a = NSMenuItem(title: add.0, action: add.1, keyEquivalent: add.2); a.target = self
        a.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil); items.append(a); items += extra
        let at = menu.index(of: root) + 1
        for (i, it) in items.enumerated() { it.indentationLevel = 1; it.isHidden = !expanded.contains(name); menu.insertItem(it, at: at + i) }
        sectionRows[name] = items; sectionCount[name] = rows.count
        setHeading(root)
    }

    // Turns an entry off or on, logs it and re-plans the next nudge; returns the new state.
    func flip(_ disabled: inout Bool?, _ label: String) -> Bool {
        let off = disabled != true; disabled = off ? true : nil
        appendLog(T(off ? "log.itemDisabled" : "log.itemEnabled", label))
        return off
    }
    func replan() { next = nextSlot(after: Date()); tick() }
    // Saves a form's result: puts it where the entry it edits is now (the list may have been re-sorted or pruned while the
    // form was open), or adds it. Logs the change with `label`.
    func put<E: Equatable>(_ new: E, over old: E?, in list: inout [E], label: (E) -> String, added: String) {
        if let o = old, let i = list.firstIndex(of: o) { list[i] = new } else { list.append(new) }
        appendLog(old.map { T("log.itemEdited", label($0), label(new)) } ?? T(added, label(new)))
    }

    func toggleSection(_ sender: NSMenuItem) {
        let name = sender.representedObject as! String
        if expanded.remove(name) == nil { expanded.insert(name) }
        UserDefaults.standard.set(Array(expanded), forKey: "expanded")
        sectionRows[name]?.forEach { $0.isHidden = !expanded.contains(name) }
        setHeading(sender)
    }

    // Lists current and upcoming leave by start date; finished leave is removed by pruneExpired.
    func rebuildLeaveMenu() {
        leaves.sort { $0.start < $1.start }
        fill(leaveRoot, leaves.map { (label($0), $0.disabled == true) }, toggle: { [unowned self] i in
            defer { saveLeaves(); replan() }; return flip(&leaves[i].disabled, label(leaves[i]))
        }, edit: { [unowned self] in editLeave(leaves[$0]) }, remove: removeLeave, add: (T("menu.addLeave"), #selector(addLeave), "l"))
    }

    @objc func addLeave() { editLeave(nil) }
    // The add form, or with `old` the same form filled in from it.
    func editLeave(_ old: Leave?) {
        // Morning / Afternoon split the shift at 13:00, or at its middle when 13:00 is not inside it (night shifts).
        let mid: String = {
            if !overnight(workStart, workEnd) && workStart < "13:00" && "13:00" < workEnd { return "13:00" }
            let s = hmFmt.date(from: workStart)!, e = hmFmt.date(from: workEnd)!
            return hmFmt.string(from: s + (e.timeIntervalSince(s) + (overnight(workStart, workEnd) ? 86400 : 0)) / 2)
        }()
        let from = datePicker(), to = datePicker(), part = NSPopUpButton(), t1 = timePicker(workStart), t2 = timePicker(mid), note = noteField()
        part.addItems(withTitles: ["leave.allDay", "leave.morning", "leave.afternoon", "leave.custom"].map { T($0) })
        note.placeholderString = T("leave.notePlaceholder")
        if let o = old {
            from.dateValue = dayKey.date(from: o.start) ?? Date(); to.dateValue = dayKey.date(from: o.end) ?? Date(); note.stringValue = o.note
            if let f = o.from, let t = o.to {
                part.selectItem(at: f == workStart && t == mid ? 1 : f == mid && t == workEnd ? 2 : 3)
                t1.dateValue = hmFmt.date(from: f)!; t2.dateValue = hmFmt.date(from: t)!
            }
        }
        // Morning / Afternoon fill in the usual half day; the times show, and can be changed, for anything other than All day.
        let sync = ClosureTarget { [unowned self] in
            let i = part.indexOfSelectedItem
            if i == 1 { t1.dateValue = hmFmt.date(from: workStart)!; t2.dateValue = hmFmt.date(from: mid)! }
            if i == 2 { t1.dateValue = hmFmt.date(from: mid)!; t2.dateValue = hmFmt.date(from: workEnd)! }
            t1.isHidden = i == 0; t2.isHidden = i == 0
            self.refitForm(part)
        }
        part.target = sync; part.action = #selector(ClosureTarget.fire); sync.fire()
        defer { withExtendedLifetime(sync) {} }
        guard form(T(old == nil ? "menu.addLeave" : "edit.leave"), sentences(T("leave.help"), T("help.overnight")),
                   [(T("form.start"), from), (T("form.end"), to), (T("form.time"), part), (T("form.from"), t1), (T("form.to"), t2), (T("form.note"), note)],
                   button: old == nil ? nil : T("common.save"),
                   check: { part.indexOfSelectedItem == 0 || hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        var s = dayKey.string(from: from.dateValue), e = dayKey.string(from: to.dateValue)
        if e < s { swap(&s, &e) }
        let whole = part.indexOfSelectedItem == 0
        let l = Leave(start: s, end: e, note: note.stringValue.trimmingCharacters(in: .whitespaces),
                      from: whole ? nil : hmFmt.string(from: t1.dateValue), to: whole ? nil : hmFmt.string(from: t2.dateValue), disabled: old?.disabled)
        put(l, over: old, in: &leaves, label: label, added: "log.leaveAdded")
        saveLeaves(); rebuildLeaveMenu(); replan()
    }

    func removeLeave(_ i: Int) {
        guard leaves.indices.contains(i) else { return }
        let l = leaves[i]
        guard confirmRemove(T("confirm.deleteLeave"), label(l)) else { return }
        leaves.remove(at: i); saveLeaves(); rebuildLeaveMenu()
        appendLog(T("log.leaveDeleted", label(l)))
        next = nextSlot(after: Date()); tick()
    }

    // Woken from sleep: drop the old rhythm and start again from the next interval mark (or the start of work hours if before work).
    @objc func didWake() {
        next = nextSlot(after: Date())
        appendLog(T("log.woke", localFmt("MdEEEHHmm").string(from: next)))
        tick()
    }

    func timePicker(_ hm: String) -> NSDatePicker {
        let p = NSDatePicker(); p.datePickerStyle = .textFieldAndStepper; p.datePickerElements = .hourMinute
        p.locale = Locale(identifier: "en_GB"); p.dateValue = hmFmt.date(from: hm)!; p.sizeToFit(); return p
    }
    func datePicker() -> NSDatePicker {
        let p = NSDatePicker(); p.datePickerStyle = .textFieldAndStepper; p.datePickerElements = .yearMonthDay
        p.presentsCalendarOverlay = true; p.locale = appLocale; p.dateValue = Date(); p.sizeToFit(); return p
    }
    // Shows a form; returns false on cancel. Cancel buttons here and in the other dialogs take Esc themselves: NSAlert only
    // does that for a button titled "Cancel" in English. `check` returns an error message to keep the form open, or nil to accept.
    func form(_ title: String, _ info: String, _ rows: [(String, NSView)], button: String? = nil, check: () -> String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        // Pickers and pop-ups all take the date picker's width; text fields keep their own.
        let w = datePicker().fittingSize.width
        for (_, v) in rows where v is NSDatePicker || v is NSPopUpButton { v.widthAnchor.constraint(equalToConstant: w).isActive = true }
        // The grid shows every view it is given, so carry over which fields start hidden.
        let hidden = rows.map { $0.1.isHidden }
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        for (i, h) in hidden.enumerated() { rows[i].1.isHidden = h }
        grid.rowSpacing = 8; grid.yPlacement = .center; fitRows(grid)
        // A list's label lines up with its first item rather than its middle.
        for (i, r) in rows.enumerated() where r.1 is NSStackView { grid.row(at: i).yPlacement = .top; grid.row(at: i).rowAlignment = .firstBaseline }
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        openForm = a
        a.accessoryView = grid; a.addButton(withTitle: button ?? T("common.add")); a.addButton(withTitle: T("common.cancel")).keyEquivalent = "\u{1b}"
        a.window.initialFirstResponder = rows.first?.1
        while a.runModal() == .alertFirstButtonReturn {
            guard let err = check() else { return true }
            a.informativeText = err
        }
        return false
    }
    // A form row shows only while its control does, so a choice can show or hide the fields that go with it.
    func fitRows(_ grid: NSGridView) {
        for r in 0..<grid.numberOfRows { let row = grid.row(at: r); row.isHidden = row.cell(at: 1).contentView?.isHidden ?? false }
        // The label column fits the labels of the rows shown; hidden rows would otherwise still widen it, leaving a wide gap
        // before the fields until the next show or hide.
        grid.column(at: 0).width = (0..<grid.numberOfRows).filter { !grid.row(at: $0).isHidden }
            .compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0).contentView?.fittingSize.width }.max() ?? 0
        // A minimum width keeps the help text above from wrapping into a tall narrow column.
        let fit = grid.fittingSize; grid.frame.size = NSSize(width: max(fit.width, 360), height: fit.height)
    }
    // Call after showing or hiding controls in the open form.
    func refitForm(_ control: NSView) {
        guard let grid = control.superview as? NSGridView ?? control.superview?.superview as? NSGridView else { return }
        fitRows(grid); openForm?.layout()
    }
    func confirmRemove(_ question: String, _ text: String, ok: String = T("common.delete"), keep: String = T("common.cancel")) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = question; a.informativeText = text
        a.addButton(withTitle: ok); a.addButton(withTitle: keep).keyEquivalent = "\u{1b}"
        return a.runModal() == .alertFirstButtonReturn
    }
    func pair(_ a: NSView, _ b: NSView) -> NSStackView { let s = NSStackView(views: [a, b]); s.spacing = 6; return s }
    func noteField() -> NSTextField { let f = NSTextField(string: ""); f.widthAnchor.constraint(equalToConstant: 180).isActive = true; return f }

    func otLabel(_ o: Overtime) -> String {
        if o.until != nil { return otSpanText(o) + (o.note.isEmpty ? "" : "  " + o.note) }
        var when = ruleLabel(o.rule)
        if let s = o.start, let e = o.end { when = s == e ? md(s) : md(s) + "–" + md(e) }
        return "\(when) " + spanText(o.from, o.to) + (o.note.isEmpty ? "" : "  " + o.note)
    }
    func rebuildOvertimeMenu() {
        // Repeating ones first, then one-offs by date; finished one-offs are removed by pruneExpired.
        overtimes.sort { ($0.start ?? onceDay($0.rule) ?? "", $0.from) < ($1.start ?? onceDay($1.rule) ?? "", $1.from) }
        fill(overtimeRoot, overtimes.map { (otLabel($0), $0.disabled == true) }, toggle: { [unowned self] i in
            defer { saveJSON(overtimes, to: overtimeURL); replan() }; return flip(&overtimes[i].disabled, otLabel(overtimes[i]))
        }, edit: { [unowned self] in editOvertime(overtimes[$0]) }, remove: removeOvertime, add: (T("menu.addOvertime"), #selector(addOvertime), "o"))
    }
    @objc func addOvertime() { editOvertime(nil) }
    func editOvertime(_ old: Overtime?) {
        let rep = repeatRows(defaultIndex: 1, editing: old.map { ($0.rule, $0.until) })
        let t1 = timePicker(old?.from ?? "19:00"), t2 = timePicker(old?.to ?? "21:00"), note = noteField()
        defer { withExtendedLifetime(rep.sync) {} }
        note.placeholderString = T("overtime.notePlaceholder"); note.stringValue = old?.note ?? ""
        guard form(T(old == nil ? "menu.addOvertime" : "edit.overtime"), sentences(T("overtime.help"), T("help.overnight"), T("overtime.multiDayHelp")),
                   // Start and End each put the date beside the time: 11/14 09:00 → 11/15 15:00.
                   rep.rows.filter { $0.1 !== rep.day } + [(T("form.start"), pair(rep.day, t1)), (T("form.end"), pair(rep.endDay, t2)), (T("form.note"), note)],
                   button: old == nil ? nil : T("common.save"),
                   check: { rep.until() != nil || hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        let o = Overtime(from: hmFmt.string(from: t1.dateValue), to: hmFmt.string(from: t2.dateValue), note: note.stringValue.trimmingCharacters(in: .whitespaces),
                         rule: rep.rule(), until: rep.until(), disabled: old?.disabled)
        put(o, over: old, in: &overtimes, label: otLabel, added: "log.overtimeAdded")
        saveJSON(overtimes, to: overtimeURL); rebuildOvertimeMenu(); replan(); checkApps()
    }
    func removeOvertime(_ i: Int) {
        guard overtimes.indices.contains(i), confirmRemove(T("confirm.deleteOvertime"), otLabel(overtimes[i])) else { return }
        let o = overtimes.remove(at: i); saveJSON(overtimes, to: overtimeURL); rebuildOvertimeMenu()
        appendLog(T("log.overtimeDeleted", otLabel(o)))
        next = nextSlot(after: Date()); tick()
    }

    func ruleLabel(_ rule: String?) -> String {
        var when = T("repeat.daily")
        if let rule = rule, let colon = rule.firstIndex(of: ":") {
            let arg = String(rule[rule.index(after: colon)...]), p = arg.split(separator: ":").compactMap { Int($0) }
            func wd(_ w: Int?) -> String { weekdayNames[((w ?? 1) - 1 + 7) % 7] }
            switch rule[..<colon] {
            case "once": when = md(arg)
            case "weekly": when = T("repeat.everyWeekday", wd(Int(arg)))
            case "lastweekday": when = T("repeat.monthlyNth", ordinalName(-1), wd(Int(arg)))
            case "monthly" where p.count == 2: when = T("repeat.monthlyNth", ordinalName(p[0]), wd(p[1]))
            case "monthday" where p.count == 1: when = T("repeat.monthlyDay", monthDayName(p[0]))
            default: break
            }
        }
        return when
    }
    func periodLabel(_ p: Period) -> String {
        "\(ruleLabel(p.rule)) " + spanText(p.from, p.to) + (p.note.isEmpty ? "" : "  " + p.note)
    }
    func rebuildPeriodMenu() {
        // Repeating ones first, then one-offs by date; finished one-offs are removed by pruneExpired.
        periods.sort { (onceDay($0.rule) ?? "", $0.from) < (onceDay($1.rule) ?? "", $1.from) }
        // Work hours come first; they can't be turned off or deleted, only edited.
        // While the nudge is on, each row says whether it pauses there, which is set on the nudge task.
        let quiet = Set(nudgeJob?.skip ?? [])
        let tag = { (p: Period) in nudging ? T("common.paren", T(quiet.contains(p.id) ? "period.nudgePaused" : "period.nudgeKept")) : "" }
        fill(periodRoot, periods.map { (periodLabel($0) + tag($0), $0.disabled == true) }, toggle: { [unowned self] i in
            defer { saveJSON(periods, to: periodsURL); replan(); checkApps() }; return flip(&periods[i].disabled, periodLabel(periods[i]))
        }, edit: { [unowned self] in editPeriod(periods[$0]) }, remove: removePeriod, add: (T("menu.addPeriod"), #selector(addPeriod), "b"), head: [workHoursItem])
    }
    // The Repeat/Date/Week/Weekday rows shared by overtime, periods and reminders. Keep `sync` alive while the form is open; `rule` reads the choice.
    // `endDay` is the end date field for a one-off that runs over several days; `until` reads it (nil unless after Date).
    // `editing` fills the rows in from an existing rule and end day.
    func repeatRows(defaultIndex: Int, editing: (rule: String?, until: String?)? = nil) -> (rows: [(String, NSView)], sync: ClosureTarget, rule: () -> String?, day: NSDatePicker, endDay: NSDatePicker, until: () -> String?) {
        let repeatPop = NSPopUpButton(), ordPop = NSPopUpButton(), weekPop = NSPopUpButton(), day = datePicker(), endDay = datePicker()
        let byPop = NSPopUpButton(), dayPop = NSPopUpButton()
        repeatPop.addItems(withTitles: ["repeat.daily", "repeat.once", "repeat.weekly", "repeat.monthly"].map { T($0) }); repeatPop.selectItem(at: defaultIndex)
        ordPop.addItems(withTitles: (weekOrdinals + ["week.last"]).map { T($0) }); ordPop.selectItem(at: 3)
        // Monthly goes by weekday (the Nth Friday) or by date (the 15th, the last day), since a month can have four or five weeks.
        byPop.addItems(withTitles: [T("repeat.byWeekday"), T("repeat.byDate")])
        let monthDays = Array(1...31) + (1...7).map { -$0 }
        dayPop.addItems(withTitles: monthDays.map(monthDayName)); dayPop.selectItem(at: 0)
        let names = weekdayNames
        weekPop.addItems(withTitles: Array(names[1...]) + [names[0]]); weekPop.selectItem(at: 4)
        // Only the fields the chosen repeat needs are shown.
        let sync = ClosureTarget { [unowned self] in
            let i = repeatPop.indexOfSelectedItem
            let byDate = i == 3 && byPop.indexOfSelectedItem == 1
            day.isHidden = i != 1; endDay.isHidden = i != 1; byPop.isHidden = i != 3
            weekPop.isHidden = i < 2 || byDate; ordPop.isHidden = i != 3 || byDate; dayPop.isHidden = !byDate
            self.refitForm(repeatPop)
            // The end day never comes before the start day.
            if endDay.dateValue < day.dateValue && !Calendar.current.isDate(endDay.dateValue, inSameDayAs: day.dateValue) { endDay.dateValue = day.dateValue }
        }
        if let (rule, until) = editing {
            let parts = (rule ?? "").split(separator: ":").map(String.init), arg = parts.dropFirst().compactMap { Int($0) }
            func week(_ w: Int?) { if let w = w { weekPop.selectItem(at: (w + 5) % 7) } }
            switch parts.first {
            case "once":
                repeatPop.selectItem(at: 1)
                if parts.count > 1, let d = dayKey.date(from: parts[1]) { day.dateValue = d; endDay.dateValue = until.flatMap { dayKey.date(from: $0) } ?? d }
            case "weekly": repeatPop.selectItem(at: 2); week(arg.first)
            case "monthly" where arg.count == 2: repeatPop.selectItem(at: 3); ordPop.selectItem(at: arg[0] < 0 ? 5 : arg[0] - 1); week(arg[1])
            case "lastweekday": repeatPop.selectItem(at: 3); ordPop.selectItem(at: 5); week(arg.first)
            case "monthday": repeatPop.selectItem(at: 3); byPop.selectItem(at: 1); dayPop.selectItem(at: arg.first.flatMap { monthDays.firstIndex(of: $0) } ?? 0)
            default: repeatPop.selectItem(at: 0)
            }
        }
        for c in [repeatPop, byPop, day, endDay] as [NSControl] { c.target = sync; c.action = #selector(ClosureTarget.fire) }
        sync.fire()
        return ([(T("form.repeat"), repeatPop), (T("form.monthlyBy"), byPop), (T("form.date"), day), (T("form.week"), ordPop), (T("form.weekday"), weekPop),
                 (T("form.monthDay"), dayPop)], sync, {
            let w = (weekPop.indexOfSelectedItem + 1) % 7 + 1, n = ordPop.indexOfSelectedItem == 5 ? -1 : ordPop.indexOfSelectedItem + 1
            let monthly = byPop.indexOfSelectedItem == 1 ? "monthday:\(monthDays[dayPop.indexOfSelectedItem])" : "monthly:\(n):\(w)"
            return [nil, "once:" + dayKey.string(from: day.dateValue), "weekly:\(w)", monthly][repeatPop.indexOfSelectedItem]
        }, day, endDay, {
            let s = dayKey.string(from: day.dateValue), e = dayKey.string(from: endDay.dateValue)
            return repeatPop.indexOfSelectedItem == 1 && e > s ? e : nil
        })
    }
    @objc func addPeriod() { editPeriod(nil) }
    // Tasks following an edited period, or quiet in it, keep doing so at its new times; they are set under Tasks, and
    // the form says how many there are.
    func editPeriod(_ old: Period?) {
        let rep = repeatRows(defaultIndex: 0, editing: old.map { ($0.rule, nil) })
        let t1 = timePicker(old?.from ?? "15:00"), t2 = timePicker(old?.to ?? "16:00"), note = noteField()
        defer { withExtendedLifetime(rep.sync) {} }
        note.placeholderString = T("period.notePlaceholder"); note.stringValue = old?.note ?? ""
        let linked = old.map { o in jobs.filter { $0.follow?.contains(o.id) == true || $0.skip?.contains(o.id) == true }.count } ?? 0
        guard form(T(old == nil ? "menu.addPeriod" : "edit.period"), sentences(T("period.help"), T("help.overnight"), linked > 0 ? T("period.otherTasks", String(linked)) : ""),
                   rep.rows + [(T("form.from"), t1), (T("form.to"), t2), (T("form.note"), note)],
                   button: old == nil ? nil : T("common.save"),
                   check: { hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        var p = Period(from: hmFmt.string(from: t1.dateValue), to: hmFmt.string(from: t2.dateValue), note: note.stringValue.trimmingCharacters(in: .whitespaces),
                       rule: rep.rule())
        if let o = old { p.id = o.id; p.disabled = o.disabled }
        put(p, over: old, in: &periods, label: periodLabel, added: "log.periodAdded")
        saveJSON(periods, to: periodsURL); rebuildTasksMenu()
        replan(); checkApps()
    }
    // Tasks that follow nothing else go with it.
    func removePeriod(_ i: Int) {
        guard periods.indices.contains(i) else { return }
        let p = periods[i], bound = jobs.filter { $0.follow == [p.id] }.map(jobLabel)
        guard confirmRemove(T("confirm.deletePeriod"), periodLabel(p) + (bound.isEmpty ? "" : "\n\n" + T("period.deleteTasks", bound.joined(separator: T("common.listSeparator"))))) else { return }
        periods.remove(at: i); saveJSON(periods, to: periodsURL); rebuildPeriodMenu()
        appendLog(T("log.periodDeleted", periodLabel(p))); dropFollowers(of: p)
        next = nextSlot(after: Date()); tick()
    }

    // A floating pop-up that does not block the menu bar timer; several can be open at once.
    func showReminder(_ lines: [String], title: String? = nil) {
        let a = NSAlert(); a.messageText = title ?? T("reminder.title", hmFmt.string(from: Date())); a.informativeText = lines.joined(separator: "\n")
        a.icon = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)
        let ok = a.addButton(withTitle: T("common.ok"))
        let close = ClosureTarget { [weak self, weak a] in
            a?.window.orderOut(nil); self?.reminderAlerts.removeAll { $0.0 === a }
        }
        ok.target = close; ok.action = #selector(ClosureTarget.fire)
        reminderAlerts.append((a, close))
        a.layout(); a.window.level = .floating; a.window.center()
        a.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSSound(named: "Glass")?.play()
        NSApp.activate(ignoringOtherApps: true); a.window.makeKeyAndOrderFront(nil)
    }

    func followName(_ f: String) -> String {
        switch f {
        case "work": return T("apps.followWork")
        case "overtime": return T("section.overtime")
        case let id: return periods.first { $0.id == id }.map { $0.note.isEmpty ? spanText($0.from, $0.to) : $0.note + " " + spanText($0.from, $0.to) } ?? T("apps.periodGone")
        }
    }
    // When a task runs, then what it does.
    func jobLabel(_ j: Job) -> String {
        let names = follows(j).map(followName).joined(separator: T("common.listSeparator")), o = j.offset ?? 0
        switch j.action {
        case "nudge":
            let when = ["work", "overtime"].map(followName)
            return T("job.every", when.joined(separator: T("common.listSeparator")), String(j.every ?? 10)) + skipText(j) + "  " + T("job.nudge")
        case "app":
            let lead = j.lead ?? 0, lag = j.lag ?? 0
            let timing = j.keepOpen == true ? (lead > 0 ? T("apps.earlyNoQuit", String(lead)) : T("apps.noQuit"))
                : lead + lag > 0 ? T("apps.timing", String(lead), String(lag)) : ""
            return T("job.during", names) + (timing.isEmpty ? "" : T("common.paren", timing)) + "  " + T("job.openLink", j.name ?? "")
        default: break
        }
        let edge = ["end": "End", "both": "Both"][j.when] ?? "Start"
        let when = j.when == "at" ? "\(ruleLabel(j.rule)) \(j.at ?? "")" + (j.anyDay == true ? T("common.paren", T("job.anyDayTag")) : "")
            : j.when == "every" ? T("job.every", names, String(j.every ?? 0)) + skipText(j)
            : o > 0 ? T("job.before" + edge, names, String(o)) : T("job.at" + edge, names)
        let what: String
        switch j.action {
        case "notify": what = j.text.isEmpty ? T("job.notify") : T("job.notifyText", j.text)
        case "shortcut": what = T("job.runShortcut", j.text)
        case "url": what = T("job.openLink", j.text)
        default: what = T("job.runCommand", j.text)
        }
        return when + "  " + what
    }
    // "(quiet in lunch, review)" for a task every few minutes with periods to be quiet in.
    func skipText(_ j: Job) -> String {
        guard let s = j.skip, !s.isEmpty else { return "" }
        return T("common.paren", T("job.quietIn", s.map(followTitle).joined(separator: T("common.listSeparator"))))
    }
    func rebuildTasksMenu() {
        fill(tasksRoot, jobs.map { (jobLabel($0) + (jobHeld($0) ? T("common.paren", T("job.heldTag")) : ""), $0.disabled == true) }, toggle: { [unowned self] i in
            defer { saveJSON(jobs, to: jobsURL); jobsChanged() }; return flip(&jobs[i].disabled, jobLabel(jobs[i]))
        }, edit: { [unowned self] in editJob(jobs[$0]) }, remove: removeJob, add: (T("menu.addTask"), #selector(addJob), ""),
           test: { [unowned self] in testJob(jobs[$0]) })
        rebuildPeriodMenu()
    }
    // Runs a task once now, whatever its time, turned off or paused, so its setup can be checked: the pop-up shows the text
    // it would show (at its start, for one told at both edges), the nudge moves the cursor, an app is opened.
    func testJob(_ j: Job) {
        appendLog(T("log.taskTested", jobLabel(j)))
        switch j.action {
        case "nudge": run(manual: true); let now = Date(); next = slot(after: now, now: now); tick()
        case "app":
            guard let path = j.path else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async { appendLog(error.map { T("log.appOpenFailed", j.name ?? "", $0.localizedDescription) } ?? T("log.appOpened", j.name ?? "")) }
            }
        case "notify":
            let f = follows(j).first ?? "work"
            showReminder([["at", "every"].contains(j.when) ? (j.text.isEmpty ? T("reminder.untitled", hmFmt.string(from: Date())) : j.text) : edgeText(j, f, end: j.when == "end")])
        default: perform(j)
        }
    }
    // After any change to the tasks: the nudge interval and its permission, the next nudge, the apps.
    func jobsChanged() {
        applyNudge(); rebuildPeriodMenu()
        if nudging && !AXIsProcessTrusted() { askAccessibility() }
        replan(); checkApps()
    }
    @objc func addJob() { editJob(nil) }
    // One form for every task: first what it does, then when; only the fields those choices need are shown.
    func editJob(_ old: Job?) {
        // There is one nudge; it keeps its action, and others can't become a second one.
        let hasNudge = jobs.contains { $0.action == "nudge" && $0.id != old?.id }
        let actions = old?.action == "nudge" ? ["nudge"] : ["notify", "app", "shortcut", "url", "script"] + (hasNudge ? [] : ["nudge"])
        let whens = ["at", "start", "end", "both", "every"]
        let actionPop = NSPopUpButton(), whenPop = NSPopUpButton()
        actionPop.addItems(withTitles: actions.map { T("job." + $0) }); actionPop.selectItem(at: actions.firstIndex(of: old?.action ?? "notify") ?? 0)
        whenPop.addItems(withTitles: whens.map { T("when." + $0) }); whenPop.selectItem(at: whens.firstIndex(of: old?.when ?? "at") ?? 0)
        let message = noteField(), shortcut = noteField(), link = noteField(), command = noteField()
        message.placeholderString = T("job.messagePlaceholder"); shortcut.placeholderString = T("job.shortcutPlaceholder")
        link.placeholderString = "https://"; command.placeholderString = T("job.commandPlaceholder")
        let textFields = ["notify": message, "shortcut": shortcut, "url": link, "script": command]
        if let o = old { textFields[o.action]?.stringValue = o.text }
        // Apps are picked with the button; adding can pick several, one task each.
        var picked: [URL] = old?.path.map { [URL(fileURLWithPath: $0)] } ?? []
        let appButton = NSButton(title: "", target: nil, action: nil); appButton.bezelStyle = .rounded
        let showPicked = { appButton.title = picked.isEmpty ? T("job.pickApp") : picked.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: T("common.listSeparator")) }
        let pickApp = ClosureTarget { [unowned self] in
            let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.allowsMultipleSelection = old == nil
            p.directoryURL = URL(fileURLWithPath: "/Applications"); p.prompt = T("common.ok")
            if p.runModal() == .OK, !p.urls.isEmpty { picked = p.urls; showPicked(); self.refitForm(appButton) }
        }
        appButton.target = pickApp; appButton.action = #selector(ClosureTarget.fire); showPicked()
        let quit = NSButton(checkboxWithTitle: T("apps.autoQuit"), target: nil, action: nil), locked = NSButton(checkboxWithTitle: T("menu.nudgeWhenLocked"), target: nil, action: nil)
        quit.state = old?.keepOpen == true ? .off : .on; locked.state = nudgeWhenLocked ? .on : .off
        let rep = repeatRows(defaultIndex: 0, editing: old.map { ($0.rule, nil) }), t = timePicker(old?.at ?? "10:00")
        let anyDay = NSButton(checkboxWithTitle: T("job.anyDay"), target: nil, action: nil); anyDay.state = old?.anyDay == true ? .on : .off
        // Any number of times can be followed. A turned-off or deleted period stays on the list while the task follows it.
        let pickedFollow = old.map(follows) ?? ["work", "overtime"]
        let shown = periods.filter { $0.disabled != true || pickedFollow.contains($0.id) }
        var choices: [String] = ["work", "overtime"] + shown.map(\.id), titles = [T("apps.followWork"), T("section.overtime")] + shown.map(periodLabel)
        for f in pickedFollow where !choices.contains(f) { choices.append(f); titles.append(T("apps.periodGone")) }
        let boxes = titles.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        zip(choices, boxes).forEach { $1.state = pickedFollow.contains($0) ? .on : .off }
        let follow = NSStackView(views: boxes); follow.orientation = .vertical; follow.alignment = .leading; follow.spacing = 4
        // The periods to be quiet in, for a task every few minutes; kept the same way as those followed.
        let pickedSkip = old?.skip ?? []
        var skipChoices = periods.filter { $0.disabled != true || pickedSkip.contains($0.id) }.map(\.id)
        var skipTitles = skipChoices.map { id in periods.first { $0.id == id }.map(periodLabel) ?? "" }
        for s in pickedSkip where !skipChoices.contains(s) { skipChoices.append(s); skipTitles.append(T("apps.periodGone")) }
        let skipBoxes = skipTitles.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        zip(skipChoices, skipBoxes).forEach { $1.state = pickedSkip.contains($0) ? .on : .off }
        let skip = NSStackView(views: skipBoxes); skip.orientation = .vertical; skip.alignment = .leading; skip.spacing = 4
        let early = noteField(), every = noteField(), lead = noteField(), lag = noteField()
        early.stringValue = String(old?.offset ?? 0); every.stringValue = String(old?.every ?? 10)
        lead.stringValue = String(old?.lead ?? 0); lag.stringValue = String(old?.lag ?? 0)
        let sync = ClosureTarget { [unowned self] in
            let a = actions[actionPop.indexOfSelectedItem], w = whens[whenPop.indexOfSelectedItem], timed = !["nudge", "app"].contains(a)
            for (k, f) in textFields { f.isHidden = k != a }
            for v in [appButton, quit, lead] as [NSView] { v.isHidden = a != "app" }
            // Minutes late only matter when the app is quit.
            lag.isHidden = a != "app" || quit.state == .off
            locked.isHidden = a != "nudge"; whenPop.isHidden = !timed
            every.isHidden = !(a == "nudge" || timed && w == "every")
            skip.isHidden = every.isHidden || skipBoxes.isEmpty
            follow.isHidden = !(a == "app" || timed && w != "at")
            early.isHidden = !(timed && ["start", "end", "both"].contains(w))
            let at = timed && w == "at"
            t.isHidden = !at; rep.rows.forEach { $0.1.isHidden = !at }
            // A one-off runs on its date whatever day it is.
            anyDay.isHidden = !at || onceDay(rep.rule()) != nil
            if at { rep.sync.fire() } else { self.refitForm(actionPop) }
        }
        // The repeat choice also decides whether days off can be picked.
        for c in [actionPop, whenPop, quit, rep.rows[0].1 as! NSControl] { c.target = sync; c.action = #selector(ClosureTarget.fire) }
        sync.fire()
        defer { withExtendedLifetime((rep.sync, sync, pickApp)) {} }
        func trimmed(_ f: NSTextField) -> String { f.stringValue.trimmingCharacters(in: .whitespaces) }
        func minutes(_ f: NSTextField, _ r: ClosedRange<Int> = 0...240) -> Int? { Int(trimmed(f)).flatMap { r.contains($0) ? $0 : nil } }
        // Only the fields shown are checked and saved.
        guard form(T(old == nil ? "menu.addTask" : "edit.task"), T("task.help"),
                   [(T("form.action"), actionPop), (T("form.message"), message), (T("form.shortcut"), shortcut), (T("form.link"), link),
                    (T("form.command"), command), (T("form.app"), appButton), (T("form.when"), whenPop)] + rep.rows
                   + [(T("form.at"), t), ("", anyDay), (T("form.follow"), follow), (T("form.early"), early), (T("form.every"), every), (T("form.skip"), skip), (T("form.openEarly"), lead),
                      (T("form.quit"), quit), (T("form.closeLate"), lag), ("", locked)],
                   button: old == nil ? nil : T("common.save"),
                   check: {
                       let a = actions[actionPop.indexOfSelectedItem]
                       if a == "shortcut" || a == "script", trimmed(textFields[a]!).isEmpty { return T("job.needText") }
                       if a == "url", URL(string: trimmed(link))?.scheme == nil { return T("job.badLink") }
                       if a == "app" && picked.isEmpty { return T("job.needApp") }
                       if !follow.isHidden && !boxes.contains(where: { $0.state == .on }) { return T("error.pickOne") }
                       if !every.isHidden && minutes(every, 1...240) == nil { return T("interval.invalid", every.stringValue) }
                       return [early, lead, lag].contains { !$0.isHidden && minutes($0) == nil } ? T("appTimes.invalid") : nil
                   }) else { return }
        let a = actions[actionPop.indexOfSelectedItem], timed = !["nudge", "app"].contains(a)
        var j = Job(action: a, text: textFields[a].map(trimmed) ?? "", when: timed ? whens[whenPop.indexOfSelectedItem] : a == "app" ? "during" : "every")
        if let o = old { j.id = o.id; j.disabled = o.disabled }
        if !t.isHidden { j.at = hmFmt.string(from: t.dateValue); j.rule = rep.rule() }
        if !anyDay.isHidden && anyDay.state == .on { j.anyDay = true }
        if !follow.isHidden { j.follow = zip(choices, boxes).filter { $1.state == .on }.map(\.0) }
        if !early.isHidden { j.offset = minutes(early).flatMap { $0 > 0 ? $0 : nil } }
        if !every.isHidden { j.every = minutes(every, 1...240) }
        if !skip.isHidden { j.skip = zip(skipChoices, skipBoxes).filter { $1.state == .on }.map(\.0); if j.skip!.isEmpty { j.skip = nil } }
        if a == "app" { j.lead = minutes(lead); j.keepOpen = quit.state == .off ? true : nil; j.lag = j.keepOpen == true ? nil : minutes(lag) }
        if a == "nudge" && (locked.state == .on) != nudgeWhenLocked {
            UserDefaults.standard.set(locked.state == .on, forKey: "nudgeWhenLocked"); appendLog(T(nudgeWhenLocked ? "log.nudgeWhenLockedOn" : "log.nudgeWhenLockedOff"))
        }
        if a == "app" {
            // An app has one task; picking it again replaces the one it had.
            for (n, url) in picked.enumerated() {
                var x = j; if n > 0 { x.id = UUID().uuidString }
                x.name = url.deletingPathExtension().lastPathComponent; x.path = url.path; x.bundleID = Bundle(url: url)?.bundleIdentifier
                jobs.removeAll { $0.action == "app" && $0.path == x.path && $0.id != old?.id }
                put(x, over: n == 0 ? old : nil, in: &jobs, label: jobLabel, added: "log.taskAdded")
            }
        } else {
            put(j, over: old, in: &jobs, label: jobLabel, added: "log.taskAdded")
        }
        saveJSON(jobs, to: jobsURL); rebuildTasksMenu(); jobsChanged()
    }
    func removeJob(_ i: Int) {
        guard jobs.indices.contains(i), confirmRemove(T("confirm.deleteTask"), jobLabel(jobs[i])) else { return }
        let j = jobs.remove(at: i); saveJSON(jobs, to: jobsURL); rebuildTasksMenu()
        appendLog(T("log.taskDeleted", jobLabel(j))); jobsChanged()
    }
    // Tasks stop following a deleted period; one left following nothing is deleted.
    func dropFollowers(of p: Period) {
        guard jobs.contains(where: { $0.follow?.contains(p.id) == true || $0.skip?.contains(p.id) == true }) else { return }
        jobs.filter { $0.follow == [p.id] }.forEach { appendLog(T("log.taskDeleted", jobLabel($0))) }
        jobs = jobs.filter { $0.follow != [p.id] }.map { var j = $0; j.follow = j.follow?.filter { $0 != p.id }
            j.skip = j.skip?.filter { $0 != p.id }; if j.skip?.isEmpty == true { j.skip = nil }; return j }
        saveJSON(jobs, to: jobsURL); rebuildTasksMenu()
    }
    // Runs a task's shortcut, link or shell command (a login shell, as this user), and logs how it went.
    func perform(_ j: Job) {
        let label = jobLabel(j)
        if j.action == "url" {
            let ok = URL(string: j.text).map { NSWorkspace.shared.open($0) } ?? false
            appendLog(ok ? T("log.taskRan", label) : T("log.taskFailed", label, T("job.badLink"))); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: j.action == "shortcut" ? "/usr/bin/shortcuts" : "/bin/zsh")
        p.arguments = j.action == "shortcut" ? ["run", j.text] : ["-lc", j.text]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { p in
            let status = p.terminationStatus
            DispatchQueue.main.async { appendLog(status == 0 ? T("log.taskRan", label) : T("log.taskFailed", label, "exit \(status)")) }
        }
        do { try p.run() } catch { appendLog(T("log.taskFailed", label, error.localizedDescription)) }
    }
    // Opens any app task's app that isn't running while it is wanted (a failed launch is retried after a minute), and
    // quits it once when its time ends, unless it keeps it open; an app opened by hand outside its time is left alone.
    func checkApps() {
        let now = Date(); lastAppCheck = now
        let running = NSWorkspace.shared.runningApplications
        for a in jobs where a.action == "app" {
            let path = a.path ?? "", name = a.name ?? ""
            let wanted = appWanted(a, now)
            let ending = !wanted && a.disabled != true && a.keepOpen != true && appWasWanted[path] == true
            appWasWanted[path] = wanted
            guard wanted || ending else { continue }
            let mine = running.filter { $0.bundleURL?.path == path || (a.bundleID != nil && $0.bundleIdentifier == a.bundleID) }
            if ending {
                if !mine.isEmpty { mine.forEach { $0.terminate() }; appendLog(T("log.appClosed", name)) }
                continue
            }
            guard mine.isEmpty, now.timeIntervalSince(appLaunchTried[path] ?? .distantPast) >= 60 else { continue }
            appLaunchTried[path] = now
            let c = NSWorkspace.OpenConfiguration(); c.activates = false; c.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: c) { _, error in
                DispatchQueue.main.async { appendLog(error.map { T("log.appOpenFailed", name, $0.localizedDescription) } ?? T("log.appOpened", name)) }
            }
        }
    }

    @objc func setWorkHours() {
        let t1 = timePicker(workStart), t2 = timePicker(workEnd)
        guard form(T("workHours.title"), sentences(T("workHours.help"), T("workHours.nightShiftHelp")), [(T("form.from"), t1), (T("form.to"), t2)], button: T("common.save"),
                   check: { hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        let (s, e) = (hmFmt.string(from: t1.dateValue), hmFmt.string(from: t2.dateValue))
        UserDefaults.standard.set(s, forKey: "workStart"); UserDefaults.standard.set(e, forKey: "workEnd")
        workHoursItem.title = T("menu.workHours", s, endText(s, e))
        appendLog(T("log.workHoursChanged", s, endText(s, e))); rebuildTasksMenu()
        next = nextSlot(after: Date()); tick()
    }
    @objc func togglePause() { paused.toggle(); UserDefaults.standard.set(paused, forKey: "paused"); tick() }
    // Paste a holiday link; it is fetched right away and only kept if it yields holidays.
    // This year's holidays, filled in each time the submenu opens; past days are greyed out.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === languageItem.submenu { buildLanguageMenu(menu); return }
        guard menu === holidayLine.submenu else { return }
        menu.removeAllItems()
        let k = dayKey.string(from: Date()), year = String(k.prefix(4))
        let keys = holidays.days.keys.filter { $0.hasPrefix(year) }.sorted()
        let label = localFmt("MdEEE")
        let nextKey = keys.first { $0 >= k }
        for key in keys {
            let it = NSMenuItem(title: "\(label.string(from: dayKey.date(from: key)!))  \(holidays.days[key]!)" + (key == nextKey ? "  " + T("holiday.nextMarker") : ""), action: nil, keyEquivalent: "")
            // An action keeps upcoming days in normal text; clicking them does nothing.
            if key >= k { it.action = #selector(noop); it.target = self }
            menu.addItem(it)
        }
        if keys.isEmpty { let none = NSMenuItem(title: T("holiday.noYearData", year), action: nil, keyEquivalent: ""); menu.addItem(none) }
    }
    @objc func noop() {}

    @objc func setHolidaySource() { askHolidaySource(holidaySource) }
    func askHolidaySource(_ initial: String) {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSTextField(string: initial); field.frame.size.width = 380; field.placeholderString = "https://example.com/holidays.ics"
        let a = NSAlert(); a.messageText = T("menu.subscribeHoliday")
        a.informativeText = T("holiday.subscribeHelp")
        a.accessoryView = field; a.addButton(withTitle: T("holiday.saveAndFetch")); a.addButton(withTitle: T("common.cancel")).keyEquivalent = "\u{1b}"
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn, !fetching else { return }
        let source = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty { removeHolidaySource(); return }
        // Checked before going online, so a typo or a bare word gets an answer straight away.
        if holidayFeedURL(source) == nil { holidayProblem(.badAddress, link: source); return }
        guard online else { holidayProblem(.offline, link: source); return }
        fetching = true; holidayLine.title = T("status.holidaysFetching")
        refreshHolidays(from: source) { [weak self] failure in
            guard let self else { return }
            self.fetching = false
            if let failure {
                self.holidayProblem(failure, link: source)
            } else {
                UserDefaults.standard.set(source, forKey: "holidaySource"); self.autoFetchFailed = nil
                appendLog(T("log.holidayChanged", source))
            }
            self.next = nextSlot(after: Date()); self.tick()
        }
    }
    // Says why a calendar could not be used. For a link just typed in, the person can go back and correct it.
    func holidayProblem(_ f: HolidayFetchError, link: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = f.title
        a.informativeText = f.advice + (link != nil && !holidaySource.isEmpty && link != holidaySource ? " " + T("holiday.keptPrevious") : "")
        guard let link else { a.runModal(); return }
        a.addButton(withTitle: T("holiday.editLink")); a.addButton(withTitle: T("common.cancel")).keyEquivalent = "\u{1b}"
        if a.runModal() == .alertFirstButtonReturn { askHolidaySource(link) }
    }
    @objc func refetchHolidays() { checkHolidays(force: true, report: true) }
    @objc func clearHolidaySource() {
        guard !fetching, confirmRemove(T("confirm.unsubscribe"), T("confirm.unsubscribeText"), ok: T("confirm.unsubscribeOk"), keep: T("common.keep")) else { return }
        removeHolidaySource()
    }
    func removeHolidaySource() {
        UserDefaults.standard.removeObject(forKey: "holidaySource")
        holidays = HolidayCache(fetched: "", years: [], days: [:]); try? FileManager.default.removeItem(at: holidayURL)
        appendLog(T("log.holidayUnsubscribed")); next = nextSlot(after: Date()); tick()
    }
    // Turning it off stops the agent's copy, so when that is this one a fresh copy is opened first to take over.
    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if loginAgentOn {
                if underLoginAgent {
                    let c = NSWorkspace.OpenConfiguration(); c.createsNewApplicationInstance = true; c.arguments = [takeoverArgument]
                    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { _, _ in
                        DispatchQueue.main.async { try? disableLoginAgent() }
                    }
                    return
                }
                try disableLoginAgent()
            } else {
                try enableLoginAgent()
            }
        } catch { appendLog(T("log.openAtLoginFailed", error.localizedDescription)) }
        sender.state = loginAgentOn ? .on : .off
    }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func clearLog() {
        guard confirmRemove(T("confirm.clearLog"), T("confirm.clearLogText")) else { return }
        clearLogFiles(); appendLog(T("log.clearedManually"))
    }
    @objc func toggleAutoClear(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!autoClearLog, forKey: "autoClearLog"); sender.state = autoClearLog ? .on : .off
        appendLog(T(autoClearLog ? "log.autoClearOn" : "log.autoClearOff"))
    }
    @objc func openPrivacy() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
}

// Open at login is a user launch agent that runs this copy's executable by path, so it starts at login and again after a
// crash, but not after Quit (a clean exit). A plain agent file keeps working when the app is rebuilt or updated in place,
// unlike one registered through SMAppService, which is tied to the signature it was registered with.
let loginAgentLabel = "io.github.mar-er.shiftbell.keepalive"
let loginAgentURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(loginAgentLabel).plist")
let underLoginAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == loginAgentLabel
let takeoverArgument = "--takeover"
var loginAgentOn: Bool { FileManager.default.fileExists(atPath: loginAgentURL.path) }
@discardableResult func launchctl(_ args: String...) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit(); return p.terminationStatus
}
// Loading the agent starts its copy at once, which closes this one.
func enableLoginAgent() throws {
    let plist: [String: Any] = ["Label": loginAgentLabel, "ProgramArguments": [Bundle.main.executablePath!], "RunAtLoad": true,
                                "KeepAlive": ["SuccessfulExit": false], "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"]
    try FileManager.default.createDirectory(at: loginAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: loginAgentURL)
    launchctl("bootstrap", "gui/\(getuid())", loginAgentURL.path)
}
// Unloading stops the agent's copy, if that is the one running.
func disableLoginAgent() throws {
    try FileManager.default.removeItem(at: loginAgentURL)
    launchctl("bootout", "gui/\(getuid())/\(loginAgentLabel)")
}
// Only one copy runs, and while open at login is on it is the launch agent's. Copies opened from Finder hand over to the
// agent; the agent's copy closes any other. Earlier versions used a login item or an SMAppService agent; both move over.
func claimSingleInstance() {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0.processIdentifier != getpid() }
    if CommandLine.arguments.contains(takeoverArgument) { return }
    if underLoginAgent { others.forEach { $0.terminate() }; return }
    // MouseNudge, the old name: close it, and move its open-at-login agent over to this copy.
    NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID).forEach { $0.terminate() }
    let oldAgent = URL(fileURLWithPath: NSHomeDirectory() + "/Library/LaunchAgents/\(oldBundleID).keepalive.plist")
    if FileManager.default.fileExists(atPath: oldAgent.path) {
        try? FileManager.default.removeItem(at: oldAgent); launchctl("bootout", "gui/\(getuid())/\(oldBundleID).keepalive")
        if !loginAgentOn { try? enableLoginAgent() }
    }
    let legacy = SMAppService.agent(plistName: "io.github.mar-er.mousenudge.agent.plist")
    for old in [SMAppService.mainApp, legacy] where old.status == .enabled { try? old.unregister(); if !loginAgentOn { try? enableLoginAgent() } }
    if loginAgentOn {
        // Not loaded yet (turned on in an older session): load it, otherwise just make sure its copy is running.
        if launchctl("kickstart", "gui/\(getuid())/\(loginAgentLabel)") != 0 { launchctl("bootstrap", "gui/\(getuid())", loginAgentURL.path) }
        exit(0)
    }
    if !others.isEmpty { exit(0) }
}
claimSingleInstance()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// A menu bar app has no visible main menu, but text fields only get ⌘X/⌘C/⌘V/⌘A/⌘Z through one; this hidden Edit menu supplies them.
let editMenu = NSMenu(title: "Edit")
for (title, action, key, shift) in [("Undo", "undo:", "z", false), ("Redo", "redo:", "z", true), ("Cut", "cut:", "x", false),
                                    ("Copy", "copy:", "c", false), ("Paste", "paste:", "v", false), ("Select All", "selectAll:", "a", false)] {
    let it = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
    if shift { it.keyEquivalentModifierMask = [.command, .shift] }
    editMenu.addItem(it)
}
let editRoot = NSMenuItem(); editRoot.submenu = editMenu
app.mainMenu = NSMenu(); app.mainMenu!.addItem(NSMenuItem()); app.mainMenu!.addItem(editRoot)
app.run()
