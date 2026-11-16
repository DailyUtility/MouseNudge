// Shiftbell, a menu bar work-time keeper; its mouse nudge runs on working days (Monday–Friday, minus public holidays from an optional calendar subscription) during work hours (set from the menu, default 09:00–18:00) plus any overtime (one day or repeating), minus rest periods, plus work periods (daily, weekly, monthly or one-off), every N minutes (set from the menu, default 10), last nudge at the first step past the end; skips when the screen is locked (unless allowed) or the person used any input device in the last minute.
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
// Minutes between nudges, chosen by the person from the menu.
var intervalMinutes: Int = { let v = UserDefaults.standard.integer(forKey: "intervalMinutes"); return (1...240).contains(v) ? v : 10 }()
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

// Overtime: on the days its `rule` picks (same rules as periods), between these times, nudge even on weekends, holidays
// and leave. Times are HH:mm, end exclusive. Older entries carry a start…end date range instead of a rule.
let overtimeURL = URL(fileURLWithPath: dir + "/overtime.json")
struct Overtime: Codable, Equatable { var start: String? = nil; var end: String? = nil; var from: String; var to: String; var note: String; var rule: String?
    // A one-off ("once:") overtime may run on to `to` on this later day, all day in between.
    var until: String? = nil; var disabled: Bool? = nil }
var overtimes: [Overtime] = []
// Periods: stretches of the day, on the days `rule` picks. A rest period (lunch, a tea break) pauses nudging, on working
// days and overtime alike; a work period (a meeting, focus time) counts as work time. `rule` says which days: nil = every day, "once:yyyy-MM-dd", "weekly:W", "monthly:N:W" (the Nth W of the month, N = 1–5 or -1 for the last),
// or "monthday:D" (day D of the month, or with D < 0 counted from the end: -1 is the last day; a missing day is skipped),
// W = Calendar weekday (1 = Sunday). The older "lastweekday:W" means "monthly:-1:W".
let periodsURL = URL(fileURLWithPath: dir + "/periods.json")
// `id` is what an app following the period refers to; `work` is true for a work period.
struct Period: Codable, Equatable { var id = UUID().uuidString; var from: String; var to: String; var note: String; var rule: String?; var disabled: Bool? = nil; var work: Bool? = nil }
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
// Rest periods, which apply every day the rule picks.
func breaksOn(_ d: Date) -> [Period] { periods.filter { $0.disabled != true && $0.work != true && ruleApplies($0.rule, on: d) } }
// A period as work time or for an app: a repeating one counts on working days only, a one-off on its own day.
func periodSpans(_ p: Period, _ d: Date) -> [(from: String, to: String)] {
    p.disabled != true && ruleApplies(p.rule, on: d) && (onceDay(p.rule) != nil || isWorkday(d)) ? [(p.from, p.to)] : []
}
func workPeriodSpans(_ d: Date) -> [(from: String, to: String)] { periods.filter { $0.work == true }.flatMap { periodSpans($0, d) } }
func loadJSON<T: Decodable>(_ url: URL, into v: inout T) { if let d = try? Data(contentsOf: url), let x = try? JSONDecoder().decode(T.self, from: d) { v = x } }
func saveJSON<T: Encodable>(_ v: T, to url: URL) { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(v).write(to: url) }
func onceDay(_ rule: String?) -> String? { rule?.hasPrefix("once:") == true ? String(rule!.dropFirst(5)) : nil }
func overtime(on d: Date) -> [Overtime] {
    let k = dayKey.string(from: d)
    return overtimes.filter { o in
        if o.disabled == true { return false }
        if let u = o.until, let s = onceDay(o.rule) { return s <= k && k <= u }
        if let s = o.start, let e = o.end { return s <= k && k <= e }
        return ruleApplies(o.rule, on: d)
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

// Rest periods plus part-day leave: no nudges in these stretches.
func pausesOn(_ d: Date) -> [(from: String, to: String)] {
    breaksOn(d).map { ($0.from, $0.to) } + partLeaves(on: dayKey.string(from: d)).map { ($0.from!, $0.to!) }
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
func overtimeSpans(_ d: Date) -> [(from: String, to: String)] {
    let k = dayKey.string(from: d)
    return overtime(on: d).map { o in o.until == nil ? (o.from, o.to) : (k == onceDay(o.rule) ? o.from : "00:00", k == o.until ? o.to : "24:00") }
}
// "22:00–次日06:00", or for overtime over several days "11/14 09:00–11/16 15:00".
func otSpanText(_ o: Overtime) -> String { o.until.map { "\(md(onceDay(o.rule) ?? "")) \(o.from)–\(md($0)) \(o.to)" } ?? spanText(o.from, o.to) }
func workSpans(_ d: Date) -> [(from: String, to: String)] { isWorkday(d) ? [(workStart, workEnd)] : [] }

func inWindow(_ d: Date) -> Bool {
    if inBreak(d) { return false }
    return covered(d, overtimeSpans) || covered(d, workSpans) || covered(d, workPeriodSpans)
}

// The first moment after `d` when nudging may start again: the start of work hours on a working day, an overtime or work period start, or a break end.
func nextStart(after d: Date) -> Date {
    let c = Calendar.current
    for offset in 0..<400 {
        let day = c.date(byAdding: .day, value: offset, to: c.startOfDay(for: d))!
        // Break ends today include those of last night's breaks that run past midnight.
        var marks = (overtimeSpans(day) + workPeriodSpans(day)).map(\.from) + (pausesOn(day) + pausesOn(dayBefore(day))).map(\.to)
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

// Apps opened for a stretch of time and quit after it. Each follows work hours (with overtime), overtime alone or a
// period: opened `lead` minutes before it starts and quit `lag` minutes after it ends (each 0–240, default 0), or, with
// `keepOpen`, never quit. Breaks and pausing don't close an app that follows work hours.
let appsURL = URL(fileURLWithPath: dir + "/apps.json")
struct WatchedApp: Codable, Equatable { var name: String; var path: String; var bundleID: String?; var disabled: Bool? = nil
    // "work" (or nil) for work hours, "overtime", or a period's id.
    var follows: String? = nil; var lead: Int? = nil; var lag: Int? = nil; var keepOpen: Bool? = nil }
var watchedApps: [WatchedApp] = []
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
func appSpans(_ a: WatchedApp, _ d: Date) -> [(from: String, to: String)] {
    let spans: [(from: String, to: String)]
    switch a.follows ?? "work" {
    case "work": spans = workSpans(d) + overtimeSpans(d)
    case "overtime": spans = overtimeSpans(d)
    case let id: spans = periods.first { $0.id == id }.map { periodSpans($0, d) } ?? []
    }
    return spans.map { widened($0, lead: a.lead ?? 0, lag: a.lag ?? 0) }
}
func appWanted(_ a: WatchedApp, _ d: Date) -> Bool { a.disabled != true && covered(d) { appSpans(a, $0) } }

// Reminders: a pop-up at `at` (HH:mm) on the days `rule` picks (same rules as periods). Repeating ones ring only on
// working days; a one-off rings on its date whatever the day. The work start / end reminders (`work` "start" or "end")
// are listed like the others, are there by default, and follow the work hours.
let remindersURL = URL(fileURLWithPath: dir + "/reminders.json")
struct Reminder: Codable, Equatable { var at: String; var note: String; var rule: String?; var disabled: Bool? = nil; var work: String? = nil }
var reminders: [Reminder] = []
func workReminder(_ kind: String) -> Reminder { Reminder(at: kind == "start" ? workStart : workEnd, note: "", rule: nil, work: kind) }
// Keeps the work start / end reminders on the current work hours.
func syncWorkReminders() {
    for i in reminders.indices { if let k = reminders[i].work { reminders[i].at = k == "start" ? workStart : workEnd } }
}
func reminderText(_ r: Reminder) -> String {
    if let k = r.work { return T(k == "start" ? "reminder.workStart" : "reminder.workEnd") }
    return r.note.isEmpty ? T("reminder.untitled", r.at) : r.note
}
// The texts to show at this minute. An overnight shift's end belongs to the working day it started on.
func remindersDue(_ d: Date) -> [String] {
    let hm = hmFmt.string(from: d)
    var due: [String] = []
    for r in reminders where r.disabled != true {
        switch r.work {
        case "start": if hm == workStart && isWorkday(d) { due.append(reminderText(r)) }
        case "end": if hm == workEnd && isWorkday(overnight(workStart, workEnd) ? dayBefore(d) : d) { due.append(reminderText(r)) }
        default: if r.at == hm && ruleApplies(r.rule, on: d) && (onceDay(r.rule) != nil || isWorkday(d)) { due.append(reminderText(r)) }
        }
    }
    return due
}

// The nearest break start, named work period start or reminder in the minutes after `d` (up to `within` seconds away),
// for the menu bar countdown. A break only counts when it interrupts work.
func upcomingEvent(after d: Date, within: TimeInterval) -> (at: Date, name: String)? {
    var m = Calendar.current.dateInterval(of: .minute, for: d)!.end
    while m.timeIntervalSince(d) <= within {
        let hm = hmFmt.string(from: m)
        let starting = (inWindow(m - 60) ? breaksOn(m).filter { $0.from == hm }.map { $0.note.isEmpty ? T("period.rest") : $0.note } : [])
            + periods.filter { $0.work == true && !$0.note.isEmpty && $0.from == hm && !periodSpans($0, m).isEmpty }.map(\.note)
        let names = starting + remindersDue(m)
        if !names.isEmpty { return (m, names.joined(separator: T("common.listSeparator"))) }
        m += 60
    }
    return nil
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

// An entry row: its label, then an edit button, a pause/resume button that turns the entry off or on in place (the menu
// stays open) and a delete button. A turned-off entry is greyed out.
final class EntryRowView: NSView {
    let label = NSTextField(labelWithString: ""), edit = NSButton(), toggle = NSButton(), trash = NSButton()
    let title: String, onToggle: () -> Bool, onEdit: () -> Void, onDelete: () -> Void
    var disabled: Bool { didSet { refresh() } }

    init(title: String, disabled: Bool, onToggle: @escaping () -> Bool, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.title = title; self.disabled = disabled; self.onToggle = onToggle; self.onEdit = onEdit; self.onDelete = onDelete
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        autoresizingMask = [.width]
        label.font = .menuFont(ofSize: 0); label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (b, sel) in [(edit, #selector(edited)), (toggle, #selector(toggled)), (trash, #selector(deleted))] {
            b.isBordered = false; b.imagePosition = .imageOnly; b.target = self; b.action = sel
            b.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        }
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: T("common.delete")); trash.toolTip = T("common.delete")
        edit.image = NSImage(systemSymbolName: "pencil.circle", accessibilityDescription: T("common.edit")); edit.toolTip = T("common.edit")
        trash.contentTintColor = .secondaryLabelColor; edit.contentTintColor = .secondaryLabelColor
        for v in [label, edit, toggle, trash] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            edit.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            edit.centerYAnchor.constraint(equalTo: centerYAnchor), edit.widthAnchor.constraint(equalToConstant: 20),
            toggle.leadingAnchor.constraint(equalTo: edit.trailingAnchor, constant: 4), toggle.centerYAnchor.constraint(equalTo: centerYAnchor), toggle.widthAnchor.constraint(equalToConstant: 20),
            trash.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 4), trash.centerYAnchor.constraint(equalTo: centerYAnchor),
            trash.widthAnchor.constraint(equalToConstant: 20), trash.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        frame.size.width = max(240, label.intrinsicContentSize.width + 36 + 94)
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
        frame.size.width = max(frame.size.width, label.frame.width + 36 + 94)
    }
    @objc func toggled() { disabled = onToggle() }
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
    let appsRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let reminderRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    weak var openForm: NSAlert?
    // Open reminder pop-ups with the targets of their OK buttons, kept until closed.
    var reminderAlerts: [(NSAlert, ClosureTarget)] = []
    var lastReminderMinute = ""
    let sectionNames = ["leave": "section.leave", "overtime": "section.overtime", "periods": "section.periods", "apps": "section.apps", "reminders": "section.reminders"]
    // Sections expand in place under their heading; which ones are open survives restarts (older versions saved the Chinese names).
    var expanded = Set((UserDefaults.standard.stringArray(forKey: "expanded") ?? []).map { ["休假": "leave", "加班": "overtime", "休息时间": "periods", "break": "periods"][$0] ?? $0 })
    var sectionRows: [String: [NSMenuItem]] = [:]
    var sectionCount: [String: Int] = [:]
    let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "p")
    let intervalItem = NSMenuItem(title: "", action: #selector(setInterval), keyEquivalent: "i")
    let workHoursItem = NSMenuItem(title: "", action: #selector(setWorkHours), keyEquivalent: "")
    let lockItem = NSMenuItem(title: "", action: #selector(toggleLocked(_:)), keyEquivalent: "")
    let nowItem = NSMenuItem(title: "", action: #selector(nudgeNow), keyEquivalent: "n")
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
    var next = Date.distantFuture
    var fetching = false
    // Holidays are only fetched online; coming back online checks again. A failed automatic fetch waits an hour.
    let network = NWPathMonitor()
    var online = false
    var autoFetchFailed: Date?
    var languagesWatch: DispatchSourceFileSystemObject?
    // Watched apps are checked every few seconds; whether each entry (appKey) wanted its app at the last check.
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
        for i in [permLine, pauseItem, intervalItem, workHoursItem, lockItem, nowItem, refetchItem, clearSourceItem, logItem, clearLogItem, autoClearItem, loginItem, sourceItem] { i.target = self }
        let (now, more, quit) = (nowItem, moreItem, quitItem)
        more.submenu = NSMenu(); languageItem.submenu = NSMenu(); languageItem.submenu!.delegate = self
        loginItem.state = loginAgentOn ? .on : .off
        lockItem.state = nudgeWhenLocked ? .on : .off
        autoClearItem.state = autoClearLog ? .on : .off
        [loginItem, lockItem, languageItem, .separator(), sourceItem, refetchItem, clearSourceItem, .separator(), logItem, clearLogItem, autoClearItem].forEach(more.submenu!.addItem)
        for (root, key, sym) in [(leaveRoot, "leave", "airplane"), (overtimeRoot, "overtime", "briefcase"), (periodRoot, "periods", "calendar.day.timeline.left"), (reminderRoot, "reminders", "bell"), (appsRoot, "apps", "app.badge.checkmark")] {
            root.representedObject = key
            let v = SectionHeaderView(symbol: sym); v.onClick = { [weak self, weak root] in if let root { self?.toggleSection(root) } }
            root.view = v
        }
        for (i, sym) in [(pauseItem, "pause.circle"), (now, "cursorarrow.motionlines"), (intervalItem, "timer"), (workHoursItem, "clock"), (more, "ellipsis.circle")] {
            i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        }
        [lastLine, nextLine, holidayLine, todayLine, overtimeLine, breakLine, permLine, .separator(), pauseItem, now, .separator(), leaveRoot, overtimeRoot, periodRoot, reminderRoot, appsRoot, workHoursItem, intervalItem, .separator(), more, quit].forEach(menu.addItem)
        item.menu = menu
        loadHolidays()
        loadLeaves()
        loadJSON(overtimeURL, into: &overtimes)
        loadJSON(appsURL, into: &watchedApps)
        if FileManager.default.fileExists(atPath: periodsURL.path) { loadJSON(periodsURL, into: &periods) }
        else { periods = [Period(from: "12:00", to: "13:00", note: T("break.lunch"), rule: nil)]; saveJSON(periods, to: periodsURL) }
        loadJSON(remindersURL, into: &reminders)
        // Work start and end reminders are added once; after that they can be turned off or deleted like any other.
        if !UserDefaults.standard.bool(forKey: "workRemindersAdded") {
            for k in ["start", "end"] where !reminders.contains(where: { $0.work == k }) { reminders.append(workReminder(k)) }
            saveJSON(reminders, to: remindersURL); UserDefaults.standard.set(true, forKey: "workRemindersAdded")
            for k in ["remindWorkStart", "remindWorkEnd"] { UserDefaults.standard.removeObject(forKey: k) }
        }
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
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // Common modes, so the countdown in the menu keeps going while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }; timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    // Every title, in the current language; the section rows are rebuilt.
    func retitle() {
        permLine.title = T("status.needAccessibility")
        nowItem.title = T("menu.nudgeNow"); refetchItem.title = T("menu.refetchHolidays"); clearSourceItem.title = T("menu.unsubscribeHoliday"); logItem.title = T("menu.openLog")
        moreItem.title = T("menu.more"); loginItem.title = T("menu.openAtLogin"); sourceItem.title = T("menu.subscribeHoliday")
        quitItem.title = T("menu.quit")
        // Always says "Language" too, so someone stuck in a language they can't read still finds it.
        languageItem.title = T("menu.language") == "Language" ? "Language" : T("menu.language") + " / Language"
        intervalItem.title = T("menu.interval", String(intervalMinutes))
        workHoursItem.title = T("menu.workHours", workStart, endText(workStart, workEnd)); lockItem.title = T("menu.nudgeWhenLocked")
        clearLogItem.title = T("menu.clearLog"); autoClearItem.title = T("menu.autoClearLog")
        lastLine.title = lastRun.map { T("status.last", $0.time, T($0.result)) } ?? T("status.lastNever")
        if fetching { holidayLine.title = T("status.holidaysFetching") }
        rebuildLeaveMenu(); rebuildOvertimeMenu(); rebuildPeriodMenu(); rebuildReminderMenu(); rebuildAppsMenu()
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
            a.addButton(withTitle: T("language.openFolder")); a.addButton(withTitle: T("common.ok"))
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
            b.forEach { appendLog(T("log.periodExpired", periodLabel($0))); dropApps(following: $0) }
        }
        // A one-off reminder goes once its minute has passed (tick shows it before pruning).
        let r = reminders.filter { over(onceDay($0.rule), nil, $0.at) }
        if !r.isEmpty { reminders.removeAll { over(onceDay($0.rule), nil, $0.at) }; saveJSON(reminders, to: remindersURL); rebuildReminderMenu(); r.forEach { appendLog(T("log.reminderExpired", reminderLabel($0))) } }
    }

    func tick() {
        let now = Date()
        let minute = dayKey.string(from: now) + " " + hmFmt.string(from: now)
        if minute != lastReminderMinute {
            lastReminderMinute = minute
            let due = remindersDue(now)
            if !due.isEmpty { showReminder(due); appendLog(T("log.reminderShown", due.joined(separator: T("common.listSeparator")))) }
        }
        if hmFmt.string(from: now) != lastPrune { pruneExpired() }
        if now.timeIntervalSince(lastAppCheck) >= 10 { checkApps() }
        permLine.isHidden = AXIsProcessTrusted()
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
            let late = breaksOn(dayBefore(now)).filter { spanCovers($0.from, $0.to, hm, startedToday: false) }
            let br = late.map { ($0, false) } + breaksOn(now).map { ($0, true) }
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
            if !paused && now.timeIntervalSince(next) < 60 { run(manual: false) }
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
        // shortly before a break or reminder.
        setIcon(paused || !counting ? 0 : 1 - Double(left) / interval)
        var title = paused ? T("status.paused") : ""
        if let e = upcomingEvent(after: now, within: 600) {
            let s = Int(e.at.timeIntervalSince(now).rounded(.up)), name = e.name.count > 8 ? e.name.prefix(7) + "…" : e.name
            title = name + String(format: " %d:%02d", s / 60, s % 60)
        }
        if !title.isEmpty { title = " " + title }
        if item.button?.title != title { item.button?.title = title }
        let tip = paused ? nil : T("status.nextNudge", localFmt("MdEEEHHmm").string(from: next))
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
    // the add item and any extra items. `toggle` flips entry i and returns whether it is now off; `edit` opens its form;
    // `remove` asks, then deletes.
    func fill(_ root: NSMenuItem, _ rows: [(String, Bool)], toggle: @escaping (Int) -> Bool, edit: @escaping (Int) -> Void, remove: @escaping (Int) -> Void,
              add: (String, Selector, String), extra: [NSMenuItem] = []) {
        let name = root.representedObject as! String
        sectionRows[name]?.forEach { if $0.menu != nil { menu.removeItem($0) } }
        var items: [NSMenuItem] = rows.enumerated().map { i, r in
            let it = NSMenuItem(title: r.0, action: nil, keyEquivalent: "")
            it.view = EntryRowView(title: r.0, disabled: r.1, onToggle: { toggle(i) }, onEdit: { edit(i) }, onDelete: { remove(i) }); return it
        }
        if rows.isEmpty { let none = NSMenuItem(title: T("menu.none"), action: nil, keyEquivalent: ""); none.isEnabled = false; items.append(none) }
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
    // Shows a form; returns false on cancel. `check` returns an error message to keep the form open, or nil to accept.
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
        a.accessoryView = grid; a.addButton(withTitle: button ?? T("common.add")); a.addButton(withTitle: T("common.cancel"))
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
        a.addButton(withTitle: ok); a.addButton(withTitle: keep)
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
        T(p.work == true ? "period.work" : "period.rest") + "  \(ruleLabel(p.rule)) " + spanText(p.from, p.to) + (p.note.isEmpty ? "" : "  " + p.note)
    }
    func rebuildPeriodMenu() {
        // Repeating ones first, then one-offs by date; finished one-offs are removed by pruneExpired.
        periods.sort { (onceDay($0.rule) ?? "", $0.from) < (onceDay($1.rule) ?? "", $1.from) }
        fill(periodRoot, periods.map { (periodLabel($0), $0.disabled == true) }, toggle: { [unowned self] i in
            defer { saveJSON(periods, to: periodsURL); replan(); checkApps() }; return flip(&periods[i].disabled, periodLabel(periods[i]))
        }, edit: { [unowned self] in editPeriod(periods[$0]) }, remove: removePeriod, add: (T("menu.addPeriod"), #selector(addPeriod), "b"))
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
    // Apps following an edited period keep following it, at its new times.
    func editPeriod(_ old: Period?) {
        let kind = NSPopUpButton(), rep = repeatRows(defaultIndex: 0, editing: old.map { ($0.rule, nil) })
        let t1 = timePicker(old?.from ?? "15:00"), t2 = timePicker(old?.to ?? "16:00"), note = noteField()
        kind.addItems(withTitles: [T("period.rest"), T("period.work")]); kind.selectItem(at: old?.work == true ? 1 : 0)
        defer { withExtendedLifetime(rep.sync) {} }
        note.placeholderString = T("period.notePlaceholder"); note.stringValue = old?.note ?? ""
        guard form(T(old == nil ? "menu.addPeriod" : "edit.period"), sentences(T("period.help"), T("help.overnight")),
                   [(T("form.kind"), kind)] + rep.rows + [(T("form.from"), t1), (T("form.to"), t2), (T("form.note"), note)],
                   button: old == nil ? nil : T("common.save"),
                   check: { hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        var p = Period(from: hmFmt.string(from: t1.dateValue), to: hmFmt.string(from: t2.dateValue), note: note.stringValue.trimmingCharacters(in: .whitespaces),
                       rule: rep.rule(), work: kind.indexOfSelectedItem == 1 ? true : nil)
        if let o = old { p.id = o.id; p.disabled = o.disabled }
        put(p, over: old, in: &periods, label: periodLabel, added: "log.periodAdded")
        saveJSON(periods, to: periodsURL); rebuildPeriodMenu(); rebuildAppsMenu(); replan(); checkApps()
    }
    // Apps following a period go with it.
    func removePeriod(_ i: Int) {
        guard periods.indices.contains(i) else { return }
        let p = periods[i], bound = watchedApps.filter { $0.follows == p.id }.map(\.name)
        guard confirmRemove(T("confirm.deletePeriod"), periodLabel(p) + (bound.isEmpty ? "" : "\n\n" + T("period.deleteApps", bound.joined(separator: T("common.listSeparator"))))) else { return }
        periods.remove(at: i); saveJSON(periods, to: periodsURL); rebuildPeriodMenu()
        appendLog(T("log.periodDeleted", periodLabel(p))); dropApps(following: p)
        next = nextSlot(after: Date()); tick()
    }

    func reminderLabel(_ r: Reminder) -> String { "\(ruleLabel(r.rule)) \(r.at)" + (r.work != nil ? "  " + reminderText(r) : r.note.isEmpty ? "" : "  " + r.note) }
    func rebuildReminderMenu() {
        // Repeating ones first, then one-offs by date; finished one-offs are removed by pruneExpired.
        syncWorkReminders()
        reminders.sort { (onceDay($0.rule) ?? "", $0.at) < (onceDay($1.rule) ?? "", $1.at) }
        fill(reminderRoot, reminders.map { (reminderLabel($0), $0.disabled == true) }, toggle: { [unowned self] i in
            defer { saveJSON(reminders, to: remindersURL) }; return flip(&reminders[i].disabled, reminderLabel(reminders[i]))
        }, edit: { [unowned self] in editReminder(reminders[$0]) }, remove: removeReminder, add: (T("menu.addReminder"), #selector(addReminder), ""))
    }
    @objc func addReminder() {
        let rep = repeatRows(defaultIndex: 1), t = timePicker("10:00"), note = noteField()
        note.placeholderString = T("reminder.notePlaceholder")
        // Several at once from existing times: work start and end (which follow the work hours), and each period's start
        // with its repeat, copied so a later change to the period does not move it. "Custom" adds the one in the fields below.
        let presets: [Reminder] = [workReminder("start"), workReminder("end")]
            + periods.filter { $0.disabled != true }.map { Reminder(at: $0.from, note: $0.note.isEmpty ? T($0.work == true ? "period.work" : "period.rest") : $0.note, rule: $0.rule) }
        let titles = [T("reminder.presetWorkStart", workStart), T("reminder.presetWorkEnd", workEnd)] + periods.filter { $0.disabled != true }.map(periodLabel)
        let boxes = titles.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        let list = NSStackView(views: boxes); list.orientation = .vertical; list.alignment = .leading; list.spacing = 4
        // Pick from existing times, or fill in a custom one; only the fields for the chosen way are shown.
        let mode = NSPopUpButton(); mode.addItems(withTitles: [T("reminder.fromExisting"), T("reminder.presetCustom")])
        let custom: [NSView] = rep.rows.map(\.1) + [t, note]
        let switchMode = ClosureTarget { [unowned self] in
            let isCustom = mode.indexOfSelectedItem == 1
            list.isHidden = isCustom; custom.forEach { $0.isHidden = !isCustom }
            if isCustom { rep.sync.fire() } else { self.refitForm(mode) }
        }
        mode.target = switchMode; mode.action = #selector(ClosureTarget.fire); switchMode.fire()
        defer { withExtendedLifetime((rep.sync, switchMode)) {} }
        guard form(T("menu.addReminder"), T("reminder.help"), [(T("form.preset"), mode), (T("reminder.pick"), list)] + rep.rows + [(T("form.at"), t), (T("form.note"), note)],
                   check: { mode.indexOfSelectedItem == 1 || boxes.contains { $0.state == .on } ? nil : T("error.pickOne") }) else { return }
        let isCustom = mode.indexOfSelectedItem == 1
        var added = isCustom ? [] : zip(presets, boxes).filter { $0.1.state == .on }.map(\.0)
        if isCustom { added.append(Reminder(at: hmFmt.string(from: t.dateValue), note: note.stringValue.trimmingCharacters(in: .whitespaces), rule: rep.rule())) }
        // One already there (same time, repeat and text) is not added twice; if it was turned off, picking it turns it back on.
        added = added.filter { r in
            guard let i = reminders.firstIndex(where: { r.work != nil ? $0.work == r.work : $0.work == nil && $0.at == r.at && $0.rule == r.rule && $0.note == r.note }) else { return true }
            if reminders[i].disabled == true { reminders[i].disabled = nil; appendLog(T("log.reminderAdded", reminderLabel(reminders[i]))) }
            return false
        }
        reminders += added; saveJSON(reminders, to: remindersURL); rebuildReminderMenu()
        added.forEach { appendLog(T("log.reminderAdded", reminderLabel($0))) }
    }
    // Start and end of work reminders follow the work hours, so editing one changes those.
    func editReminder(_ old: Reminder) {
        guard old.work == nil else { return setWorkHours() }
        let rep = repeatRows(defaultIndex: 1, editing: (old.rule, nil)), t = timePicker(old.at), note = noteField()
        defer { withExtendedLifetime(rep.sync) {} }
        note.placeholderString = T("reminder.notePlaceholder"); note.stringValue = old.note
        guard form(T("edit.reminder"), T("reminder.help"), rep.rows + [(T("form.at"), t), (T("form.note"), note)], button: T("common.save"), check: { nil }) else { return }
        let r = Reminder(at: hmFmt.string(from: t.dateValue), note: note.stringValue.trimmingCharacters(in: .whitespaces), rule: rep.rule(), disabled: old.disabled)
        put(r, over: old, in: &reminders, label: reminderLabel, added: "log.reminderAdded")
        saveJSON(reminders, to: remindersURL); rebuildReminderMenu()
    }
    func removeReminder(_ i: Int) {
        guard reminders.indices.contains(i), confirmRemove(T("confirm.deleteReminder"), reminderLabel(reminders[i])) else { return }
        let r = reminders.remove(at: i); saveJSON(reminders, to: remindersURL); rebuildReminderMenu()
        appendLog(T("log.reminderDeleted", reminderLabel(r)))
    }
    // A floating pop-up that does not block the menu bar timer; several can be open at once.
    func showReminder(_ lines: [String]) {
        let a = NSAlert(); a.messageText = T("reminder.title", hmFmt.string(from: Date())); a.informativeText = lines.joined(separator: "\n")
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

    func followName(_ follows: String?) -> String {
        switch follows ?? "work" {
        case "work": return T("apps.followWork")
        case "overtime": return T("section.overtime")
        case let id: return periods.first { $0.id == id }.map { $0.note.isEmpty ? spanText($0.from, $0.to) : $0.note + " " + spanText($0.from, $0.to) } ?? T("apps.periodGone")
        }
    }
    func appLabel(_ a: WatchedApp) -> String {
        let lead = a.lead ?? 0, lag = a.lag ?? 0
        let timing = a.keepOpen == true ? (lead > 0 ? T("apps.earlyNoQuit", String(lead)) : T("apps.noQuit"))
            : lead + lag > 0 ? T("apps.timing", String(lead), String(lag)) : ""
        return a.name + "  " + followName(a.follows) + (timing.isEmpty ? "" : T("common.paren", timing))
    }
    func appKey(_ a: WatchedApp) -> String { a.path + "|" + (a.follows ?? "work") }
    func rebuildAppsMenu() {
        fill(appsRoot, watchedApps.map { (appLabel($0), $0.disabled == true) }, toggle: { [unowned self] i in
            defer { saveJSON(watchedApps, to: appsURL); checkApps() }; return flip(&watchedApps[i].disabled, appLabel(watchedApps[i]))
        }, edit: { [unowned self] in editApp(watchedApps[$0]) }, remove: removeApp, add: (T("menu.addApp"), #selector(addApp), ""))
    }
    // Pick the apps, then what they follow: work hours, overtime or a period, with minutes early and late.
    @objc func addApp() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel(); p.message = T("apps.pickHelp"); p.prompt = T("common.next")
        p.allowedContentTypes = [.application]; p.allowsMultipleSelection = true; p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let names = p.urls.map { $0.deletingPathExtension().lastPathComponent }
        guard let rule = appRule(T("apps.ruleTitle", names.joined(separator: T("common.listSeparator"))), nil) else { return }
        // The same app can follow several times; the same app and time again only updates the minutes.
        for (url, name) in zip(p.urls, names) {
            var a = rule; a.name = name; a.path = url.path; a.bundleID = Bundle(url: url)?.bundleIdentifier
            if let i = watchedApps.firstIndex(where: { appKey($0) == appKey(a) }) { watchedApps[i] = a } else { watchedApps.append(a) }
            appendLog(T("log.appAdded", appLabel(a)))
        }
        saveJSON(watchedApps, to: appsURL); rebuildAppsMenu(); checkApps()
    }
    // Changes what an app follows and its minutes; another entry left with the same app and time is merged into it.
    func editApp(_ old: WatchedApp) {
        guard var a = appRule(T("edit.app", old.name), old) else { return }
        a.name = old.name; a.path = old.path; a.bundleID = old.bundleID; a.disabled = old.disabled
        watchedApps.removeAll { $0 != old && appKey($0) == appKey(a) }
        put(a, over: old, in: &watchedApps, label: appLabel, added: "log.appAdded")
        saveJSON(watchedApps, to: appsURL); rebuildAppsMenu(); checkApps()
    }
    // The form for what apps follow, filled in from `old` when editing; returns the choice as an entry with no app set.
    func appRule(_ title: String, _ old: WatchedApp?) -> WatchedApp? {
        // A turned-off or deleted period stays on the list while it is the one being edited.
        let shown = periods.filter { $0.disabled != true || $0.id == old?.follows }
        var choices: [String] = ["work", "overtime"] + shown.map(\.id), titles = [T("apps.followWork"), T("section.overtime")] + shown.map(periodLabel)
        if let f = old?.follows, !choices.contains(f) { choices.append(f); titles.append(T("apps.periodGone")) }
        let follow = NSPopUpButton(); follow.addItems(withTitles: titles); follow.selectItem(at: choices.firstIndex(of: old?.follows ?? "work") ?? 0)
        let lead = noteField(), lag = noteField(), quit = NSButton(checkboxWithTitle: T("apps.autoQuit"), target: nil, action: nil)
        lead.stringValue = String(old?.lead ?? 0); lag.stringValue = String(old?.lag ?? 0); quit.state = old?.keepOpen == true ? .off : .on
        // Minutes late only matter when the app is quit.
        let sync = ClosureTarget { [unowned self] in lag.isHidden = quit.state == .off; self.refitForm(quit) }
        quit.target = sync; quit.action = #selector(ClosureTarget.fire); sync.fire()
        defer { withExtendedLifetime(sync) {} }
        func minutes(_ f: NSTextField) -> Int? { Int(f.stringValue.trimmingCharacters(in: .whitespaces)).flatMap { (0...240).contains($0) ? $0 : nil } }
        guard form(title, T("apps.ruleHelp"), [(T("form.follow"), follow), (T("form.openEarly"), lead), (T("form.quit"), quit), (T("form.closeLate"), lag)],
                   button: old == nil ? nil : T("common.save"),
                   check: { minutes(lead) != nil && (quit.state == .off || minutes(lag) != nil) ? nil : T("appTimes.invalid") }) else { return nil }
        let keep = quit.state == .off
        return WatchedApp(name: "", path: "", follows: choices[follow.indexOfSelectedItem],
                          lead: minutes(lead), lag: keep ? nil : minutes(lag), keepOpen: keep ? true : nil)
    }
    func removeApp(_ i: Int) {
        guard watchedApps.indices.contains(i), confirmRemove(T("confirm.deleteApp"), appLabel(watchedApps[i])) else { return }
        let a = watchedApps.remove(at: i); saveJSON(watchedApps, to: appsURL); rebuildAppsMenu()
        appendLog(T("log.appDeleted", appLabel(a)))
    }
    func dropApps(following p: Period) {
        let gone = watchedApps.filter { $0.follows == p.id }
        guard !gone.isEmpty else { return }
        watchedApps.removeAll { $0.follows == p.id }; saveJSON(watchedApps, to: appsURL); rebuildAppsMenu()
        gone.forEach { appendLog(T("log.appDeleted", $0.name)) }
    }
    // Opens any watched app that isn't running while it is wanted (a failed launch is retried after a minute), and
    // quits it once when its time ends; an app opened by hand outside its time is left alone. Entries for the same app
    // go together: it is wanted while any of them wants it, and is quit when the last ends, unless each entry that just
    // ended keeps it open.
    func checkApps() {
        let now = Date(); lastAppCheck = now
        let running = NSWorkspace.shared.runningApplications
        for path in Set(watchedApps.map(\.path)) {
            let group = watchedApps.filter { $0.path == path }, a = group[0]
            let ended = group.filter { $0.disabled != true && appWasWanted[appKey($0)] == true }
            let wanted = group.contains { appWanted($0, now) }
            group.forEach { appWasWanted[appKey($0)] = appWanted($0, now) }
            let ending = !wanted && ended.contains { $0.keepOpen != true }
            guard wanted || ending else { continue }
            let mine = running.filter { $0.bundleURL?.path == a.path || (a.bundleID != nil && $0.bundleIdentifier == a.bundleID) }
            if ending {
                if !mine.isEmpty { mine.forEach { $0.terminate() }; appendLog(T("log.appClosed", a.name)) }
                continue
            }
            guard mine.isEmpty, now.timeIntervalSince(appLaunchTried[a.path] ?? .distantPast) >= 60 else { continue }
            appLaunchTried[a.path] = now
            let c = NSWorkspace.OpenConfiguration(); c.activates = false; c.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: a.path), configuration: c) { _, error in
                DispatchQueue.main.async { appendLog(error.map { T("log.appOpenFailed", a.name, $0.localizedDescription) } ?? T("log.appOpened", a.name)) }
            }
        }
    }

    @objc func setInterval() {
        NSApp.activate(ignoringOtherApps: true)
        let field = NSTextField(string: String(intervalMinutes)); field.frame.size.width = 120
        let a = NSAlert(); a.messageText = T("interval.title"); a.informativeText = T("interval.help")
        a.accessoryView = field; a.addButton(withTitle: T("common.save")); a.addButton(withTitle: T("common.cancel"))
        a.window.initialFirstResponder = field
        while a.runModal() == .alertFirstButtonReturn {
            guard let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (1...240).contains(v) else {
                a.informativeText = T("interval.invalid", field.stringValue); continue
            }
            intervalMinutes = v; UserDefaults.standard.set(v, forKey: "intervalMinutes")
            intervalItem.title = T("menu.interval", String(v))
            appendLog(T("log.intervalChanged", String(v)))
            next = nextSlot(after: Date()); tick(); return
        }
    }

    @objc func setWorkHours() {
        let t1 = timePicker(workStart), t2 = timePicker(workEnd)
        guard form(T("workHours.title"), sentences(T("workHours.help"), T("workHours.nightShiftHelp")), [(T("form.from"), t1), (T("form.to"), t2)], button: T("common.save"),
                   check: { hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        let (s, e) = (hmFmt.string(from: t1.dateValue), hmFmt.string(from: t2.dateValue))
        UserDefaults.standard.set(s, forKey: "workStart"); UserDefaults.standard.set(e, forKey: "workEnd")
        workHoursItem.title = T("menu.workHours", s, endText(s, e))
        appendLog(T("log.workHoursChanged", s, endText(s, e))); rebuildReminderMenu()
        next = nextSlot(after: Date()); tick()
    }
    @objc func toggleLocked(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!nudgeWhenLocked, forKey: "nudgeWhenLocked"); sender.state = nudgeWhenLocked ? .on : .off
        appendLog(T(nudgeWhenLocked ? "log.nudgeWhenLockedOn" : "log.nudgeWhenLockedOff"))
    }

    @objc func togglePause() { paused.toggle(); UserDefaults.standard.set(paused, forKey: "paused"); tick() }
    @objc func nudgeNow() { run(manual: true); let now = Date(); next = slot(after: now, now: now); tick() }
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
        a.accessoryView = field; a.addButton(withTitle: T("holiday.saveAndFetch")); a.addButton(withTitle: T("common.cancel"))
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
        a.addButton(withTitle: T("holiday.editLink")); a.addButton(withTitle: T("common.cancel"))
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
