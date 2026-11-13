// Menu bar mouse nudger: working days (Monday–Friday, minus public holidays from an optional calendar subscription) during work hours (set from the menu, default 09:00–18:00) plus any overtime (one day or repeating), minus breaks (daily, weekly, last weekday of the month or one-off), every N minutes (set from the menu, default 10), last nudge at the first step past the end; skips when the screen is locked (unless allowed) or the person used any input device in the last minute.
import Cocoa
import IOKit
import ApplicationServices
import ServiceManagement
import Network

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
let dir = NSHomeDirectory() + "/Library/Application Support/mouse-nudge"
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
struct Leave: Codable { var start: String; var end: String; var note: String; var from: String? = nil; var to: String? = nil }
var leaves: [Leave] = []
func loadLeaves() { if let d = try? Data(contentsOf: leaveURL), let l = try? JSONDecoder().decode([Leave].self, from: d) { leaves = l } }
func saveLeaves() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(leaves).write(to: leaveURL) }
func leave(on key: String) -> Leave? { leaves.first { $0.start <= key && key <= $0.end && $0.from == nil } }
func partLeaves(on key: String) -> [Leave] { leaves.filter { $0.start <= key && key <= $0.end && $0.from != nil } }

// Overtime: on the days its `rule` picks (same rules as breaks), between these times, nudge even on weekends, holidays
// and leave. Times are HH:mm, end exclusive. Older entries carry a start…end date range instead of a rule.
let overtimeURL = URL(fileURLWithPath: dir + "/overtime.json")
struct Overtime: Codable { var start: String? = nil; var end: String? = nil; var from: String; var to: String; var note: String; var rule: String?
    // A one-off ("once:") overtime may run on to `to` on this later day, all day in between.
    var until: String? = nil }
var overtimes: [Overtime] = []
// Breaks: no nudges between from and to, on working days and overtime alike. `rule` says which days:
// nil = every day, "once:yyyy-MM-dd", "weekly:W", or "monthly:N:W" (the Nth W of the month, N = 1–4 or -1 for the last),
// W = Calendar weekday (1 = Sunday). The older "lastweekday:W" means "monthly:-1:W".
let breaksURL = URL(fileURLWithPath: dir + "/breaks.json")
struct Break: Codable { var from: String; var to: String; var note: String; var rule: String? }
var breaks: [Break] = []
// Translation keys; weekday names come from the interface language (Language.swift).
let weekOrdinals = ["week.first", "week.second", "week.third", "week.fourth"]
func ordinalName(_ n: Int) -> String { T(n == -1 ? "week.last" : weekOrdinals[max(0, min(3, n - 1))]) }
func breakApplies(_ b: Break, on d: Date) -> Bool { ruleApplies(b.rule, on: d) }
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
    default: return true
    }
}
func breaksOn(_ d: Date) -> [Break] { breaks.filter { breakApplies($0, on: d) } }
func loadJSON<T: Decodable>(_ url: URL, into v: inout T) { if let d = try? Data(contentsOf: url), let x = try? JSONDecoder().decode(T.self, from: d) { v = x } }
func saveJSON<T: Encodable>(_ v: T, to url: URL) { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(v).write(to: url) }
func onceDay(_ rule: String?) -> String? { rule?.hasPrefix("once:") == true ? String(rule!.dropFirst(5)) : nil }
func overtime(on d: Date) -> [Overtime] {
    let k = dayKey.string(from: d)
    return overtimes.filter { o in
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
        case .notCalendar: return T("holiday.notCalendarText") + " " + T("holiday.formatHint")
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

// Breaks plus part-day leave: no nudges in these stretches.
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
    return covered(d, overtimeSpans) || covered(d, workSpans)
}

// The first moment after `d` when nudging may start again: the start of work hours on a working day, an overtime start, or a break end.
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
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    // Titles are set in retitle(), again whenever the language changes.
    let lastLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let holidayLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    // Today's status, one fact per line; a line is hidden when it has nothing to say.
    let todayLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let overtimeLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let breakLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let permLine = NSMenuItem(title: "", action: #selector(openPrivacy), keyEquivalent: "")
    let leaveRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let overtimeRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let breakRoot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let sectionNames = ["leave": "section.leave", "overtime": "section.overtime", "break": "section.breaks"]
    // Sections expand in place under their heading; which ones are open survives restarts (older versions saved the Chinese names).
    var expanded = Set((UserDefaults.standard.stringArray(forKey: "expanded") ?? []).map { ["休假": "leave", "加班": "overtime", "休息时间": "break"][$0] ?? $0 })
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
    let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for i in [lastLine, todayLine, overtimeLine, breakLine] { i.isEnabled = false }
        holidayLine.submenu = NSMenu(); holidayLine.submenu!.delegate = self
        loadCustomLanguages(); applyLanguageChoice(); reportLanguageProblems(); watchLanguagesFolder()
        for i in [permLine, pauseItem, intervalItem, workHoursItem, lockItem, nowItem, refetchItem, clearSourceItem, logItem, clearLogItem, autoClearItem, loginItem, sourceItem] { i.target = self }
        let (now, more, quit) = (nowItem, moreItem, quitItem)
        more.submenu = NSMenu(); languageItem.submenu = NSMenu(); languageItem.submenu!.delegate = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        lockItem.state = nudgeWhenLocked ? .on : .off
        autoClearItem.state = autoClearLog ? .on : .off
        [loginItem, lockItem, languageItem, .separator(), sourceItem, refetchItem, clearSourceItem, .separator(), logItem, clearLogItem, autoClearItem].forEach(more.submenu!.addItem)
        for (root, key, sym) in [(leaveRoot, "leave", "airplane"), (overtimeRoot, "overtime", "briefcase"), (breakRoot, "break", "cup.and.saucer")] {
            root.representedObject = key
            let v = SectionHeaderView(symbol: sym); v.onClick = { [weak self, weak root] in if let root { self?.toggleSection(root) } }
            root.view = v
        }
        for (i, sym) in [(pauseItem, "pause.circle"), (now, "cursorarrow.motionlines"), (intervalItem, "timer"), (workHoursItem, "clock"), (more, "ellipsis.circle")] {
            i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        }
        [lastLine, holidayLine, todayLine, overtimeLine, breakLine, permLine, .separator(), pauseItem, now, .separator(), leaveRoot, overtimeRoot, breakRoot, workHoursItem, intervalItem, .separator(), more, quit].forEach(menu.addItem)
        item.menu = menu
        loadHolidays()
        loadLeaves()
        loadJSON(overtimeURL, into: &overtimes)
        if FileManager.default.fileExists(atPath: breaksURL.path) { loadJSON(breaksURL, into: &breaks) }
        else { breaks = [Break(from: "12:00", to: "13:00", note: T("break.lunch"), rule: nil)]; saveJSON(breaks, to: breaksURL) }
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
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }.tolerance = 0.2
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
        rebuildLeaveMenu(); rebuildOvertimeMenu(); rebuildBreakMenu()
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

    // One-off leave, overtime and breaks are removed once their last day (and end time, if any) has passed.
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
        let b = breaks.filter { over(onceDay($0.rule), $0.from, $0.to) }
        if !l.isEmpty { leaves.removeAll { over($0.end, $0.from, $0.to) }; saveLeaves(); rebuildLeaveMenu(); l.forEach { appendLog(T("log.leaveExpired", label($0))) } }
        if !o.isEmpty { overtimes.removeAll(where: otOver); saveJSON(overtimes, to: overtimeURL); rebuildOvertimeMenu(); o.forEach { appendLog(T("log.overtimeExpired", otLabel($0))) } }
        if !b.isEmpty { breaks.removeAll { over(onceDay($0.rule), $0.from, $0.to) }; saveJSON(breaks, to: breaksURL); rebuildBreakMenu(); b.forEach { appendLog(T("log.breakExpired", breakLabel($0))) } }
    }

    func tick() {
        let now = Date()
        if hmFmt.string(from: now) != lastPrune { pruneExpired() }
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
            let span = holidays.years.contains(Int(year)!) ? { let ks = holidays.days.keys.filter { $0.hasPrefix(year) }; return T("status.holidaysLeft", year, String(ks.filter { $0 >= k }.count), String(ks.count)) }() : holidaySource.isEmpty ? T("status.holidaysNotSubscribed") : T("status.holidaysNoData", year)
            holidayLine.title = T("status.holidays", span)
        }
        if now >= next {
            // After sleep the slot may be long past; only run a slot that is due right now.
            if !paused && now.timeIntervalSince(next) < 60 { run(manual: false) }
            next = slot(after: next, now: now)
        }
        let left = Int(next.timeIntervalSince(now))
        let title: String
        if paused { title = "🖱 " + T("status.paused") }
        else if left < 3600 { title = String(format: "🖱 %d:%02d", left / 60, left % 60) }
        // Off hours just the icon, to keep the menu bar narrow; the next time is in the tooltip.
        else if !inWindow(now) { title = "🖱" }
        else if Calendar.current.isDateInToday(next) { title = "🖱 " + fmt.string(from: next) }
        else { title = "🖱 " + localFmt("MdEEEHHmm").string(from: next) }
        if item.button?.title != title { item.button?.title = title }
        let tip = paused ? nil : T("status.nextNudge", localFmt("MdEEEHHmm").string(from: next))
        if item.button?.toolTip != tip { item.button?.toolTip = tip }
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

    // Rebuilds a section's rows right under its heading: one row per entry (click to delete), then the add item.
    func fill(_ root: NSMenuItem, _ rows: [String], remove: Selector, add: (String, Selector, String)) {
        let name = root.representedObject as! String
        sectionRows[name]?.forEach { if $0.menu != nil { menu.removeItem($0) } }
        var items: [NSMenuItem] = rows.enumerated().map { i, t in
            let it = NSMenuItem(title: t, action: remove, keyEquivalent: ""); it.target = self; it.tag = i; it.toolTip = T("menu.clickToDelete")
            it.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: T("common.delete")); return it
        }
        if rows.isEmpty { let none = NSMenuItem(title: T("menu.none"), action: nil, keyEquivalent: ""); none.isEnabled = false; items.append(none) }
        let a = NSMenuItem(title: add.0, action: add.1, keyEquivalent: add.2); a.target = self
        a.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil); items.append(a)
        let at = menu.index(of: root) + 1
        for (i, it) in items.enumerated() { it.indentationLevel = 1; it.isHidden = !expanded.contains(name); menu.insertItem(it, at: at + i) }
        sectionRows[name] = items; sectionCount[name] = rows.count
        setHeading(root)
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
        fill(leaveRoot, leaves.map(label), remove: #selector(removeLeave(_:)), add: (T("menu.addLeave"), #selector(addLeave), "l"))
    }

    @objc func addLeave() {
        // Morning / Afternoon split the shift at 13:00, or at its middle when 13:00 is not inside it (night shifts).
        let mid: String = {
            if !overnight(workStart, workEnd) && workStart < "13:00" && "13:00" < workEnd { return "13:00" }
            let s = hmFmt.date(from: workStart)!, e = hmFmt.date(from: workEnd)!
            return hmFmt.string(from: s + (e.timeIntervalSince(s) + (overnight(workStart, workEnd) ? 86400 : 0)) / 2)
        }()
        let from = datePicker(), to = datePicker(), part = NSPopUpButton(), t1 = timePicker(workStart), t2 = timePicker(mid), note = noteField()
        part.addItems(withTitles: ["leave.allDay", "leave.morning", "leave.afternoon", "leave.custom"].map { T($0) })
        note.placeholderString = T("leave.notePlaceholder")
        // Morning / Afternoon fill in the usual half day; the times stay editable for anything other than All day.
        let sync = ClosureTarget {
            let i = part.indexOfSelectedItem
            if i == 1 { t1.dateValue = hmFmt.date(from: workStart)!; t2.dateValue = hmFmt.date(from: mid)! }
            if i == 2 { t1.dateValue = hmFmt.date(from: mid)!; t2.dateValue = hmFmt.date(from: workEnd)! }
            t1.isEnabled = i != 0; t2.isEnabled = i != 0
        }
        part.target = sync; part.action = #selector(ClosureTarget.fire); sync.fire()
        defer { withExtendedLifetime(sync) {} }
        guard form(T("menu.addLeave"), T("leave.help") + " " + T("help.overnight"),
                   [(T("form.start"), from), (T("form.end"), to), (T("form.time"), part), (T("form.from"), t1), (T("form.to"), t2), (T("form.note"), note)],
                   check: { part.indexOfSelectedItem == 0 || hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        var s = dayKey.string(from: from.dateValue), e = dayKey.string(from: to.dateValue)
        if e < s { swap(&s, &e) }
        let whole = part.indexOfSelectedItem == 0
        let l = Leave(start: s, end: e, note: note.stringValue.trimmingCharacters(in: .whitespaces),
                      from: whole ? nil : hmFmt.string(from: t1.dateValue), to: whole ? nil : hmFmt.string(from: t2.dateValue))
        leaves.append(l); saveLeaves(); rebuildLeaveMenu()
        appendLog(T("log.leaveAdded", label(l)))
        next = nextSlot(after: Date()); tick()
    }

    @objc func removeLeave(_ sender: NSMenuItem) {
        guard leaves.indices.contains(sender.tag) else { return }
        let l = leaves[sender.tag]
        guard confirmRemove(T("confirm.deleteLeave"), label(l)) else { return }
        leaves.remove(at: sender.tag); saveLeaves(); rebuildLeaveMenu()
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
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 8; grid.yPlacement = .center; grid.frame.size = grid.fittingSize
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        a.accessoryView = grid; a.addButton(withTitle: button ?? T("common.add")); a.addButton(withTitle: T("common.cancel"))
        a.window.initialFirstResponder = rows.first?.1
        while a.runModal() == .alertFirstButtonReturn {
            guard let err = check() else { return true }
            a.informativeText = err
        }
        return false
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
        fill(overtimeRoot, overtimes.map(otLabel), remove: #selector(removeOvertime(_:)), add: (T("menu.addOvertime"), #selector(addOvertime), "o"))
    }
    @objc func addOvertime() {
        let rep = repeatRows(defaultIndex: 1), t1 = timePicker("19:00"), t2 = timePicker("21:00"), note = noteField()
        defer { withExtendedLifetime(rep.sync) {} }
        note.placeholderString = T("overtime.notePlaceholder")
        guard form(T("menu.addOvertime"), T("overtime.help") + " " + T("help.overnight") + " " + T("overtime.multiDayHelp"),
                   // Start and End each put the date beside the time: 11/14 09:00 → 11/15 15:00.
                   rep.rows.filter { $0.1 !== rep.day } + [(T("form.start"), pair(rep.day, t1)), (T("form.end"), pair(rep.endDay, t2)), (T("form.note"), note)],
                   check: { rep.until() != nil || hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        let o = Overtime(from: hmFmt.string(from: t1.dateValue), to: hmFmt.string(from: t2.dateValue), note: note.stringValue.trimmingCharacters(in: .whitespaces), rule: rep.rule(), until: rep.until())
        overtimes.append(o); saveJSON(overtimes, to: overtimeURL); rebuildOvertimeMenu()
        appendLog(T("log.overtimeAdded", otLabel(o)))
        next = nextSlot(after: Date()); tick()
    }
    @objc func removeOvertime(_ sender: NSMenuItem) {
        guard overtimes.indices.contains(sender.tag), confirmRemove(T("confirm.deleteOvertime"), otLabel(overtimes[sender.tag])) else { return }
        let o = overtimes.remove(at: sender.tag); saveJSON(overtimes, to: overtimeURL); rebuildOvertimeMenu()
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
            default: break
            }
        }
        return when
    }
    func breakLabel(_ b: Break) -> String { "\(ruleLabel(b.rule)) " + spanText(b.from, b.to) + (b.note.isEmpty ? "" : "  " + b.note) }
    func rebuildBreakMenu() {
        // Repeating ones first, then one-offs by date; finished one-offs are removed by pruneExpired.
        breaks.sort { ($0.rule?.hasPrefix("once:") ?? false ? $0.rule! : "", $0.from) < ($1.rule?.hasPrefix("once:") ?? false ? $1.rule! : "", $1.from) }
        fill(breakRoot, breaks.map(breakLabel), remove: #selector(removeBreak(_:)), add: (T("menu.addBreak"), #selector(addBreak), "b"))
    }
    // The Repeat/Date/Week/Weekday rows shared by overtime and breaks. Keep `sync` alive while the form is open; `rule` reads the choice.
    // `endDay` is the end date field for a one-off that runs over several days; `until` reads it (nil unless after Date).
    func repeatRows(defaultIndex: Int) -> (rows: [(String, NSView)], sync: ClosureTarget, rule: () -> String?, day: NSDatePicker, endDay: NSDatePicker, until: () -> String?) {
        let repeatPop = NSPopUpButton(), ordPop = NSPopUpButton(), weekPop = NSPopUpButton(), day = datePicker(), endDay = datePicker()
        repeatPop.addItems(withTitles: ["repeat.daily", "repeat.once", "repeat.weekly", "repeat.monthly"].map { T($0) }); repeatPop.selectItem(at: defaultIndex)
        ordPop.addItems(withTitles: weekOrdinals.map { T($0) }); ordPop.selectItem(at: 3)
        let names = weekdayNames
        weekPop.addItems(withTitles: Array(names[1...]) + [names[0]]); weekPop.selectItem(at: 4)
        // Only the field the chosen repeat needs is editable.
        let sync = ClosureTarget {
            let i = repeatPop.indexOfSelectedItem
            day.isEnabled = i == 1; endDay.isEnabled = i == 1; weekPop.isEnabled = i >= 2; ordPop.isEnabled = i == 3
            // The end day never comes before the start day.
            if endDay.dateValue < day.dateValue && !Calendar.current.isDate(endDay.dateValue, inSameDayAs: day.dateValue) { endDay.dateValue = day.dateValue }
        }
        for c in [repeatPop, day, endDay] as [NSControl] { c.target = sync; c.action = #selector(ClosureTarget.fire) }
        sync.fire()
        return ([(T("form.repeat"), repeatPop), (T("form.date"), day), (T("form.week"), ordPop), (T("form.weekday"), weekPop)], sync, {
            let w = (weekPop.indexOfSelectedItem + 1) % 7 + 1, n = ordPop.indexOfSelectedItem + 1
            return [nil, "once:" + dayKey.string(from: day.dateValue), "weekly:\(w)", "monthly:\(n):\(w)"][repeatPop.indexOfSelectedItem]
        }, day, endDay, {
            let s = dayKey.string(from: day.dateValue), e = dayKey.string(from: endDay.dateValue)
            return repeatPop.indexOfSelectedItem == 1 && e > s ? e : nil
        })
    }
    @objc func addBreak() {
        let rep = repeatRows(defaultIndex: 0), t1 = timePicker("15:00"), t2 = timePicker("16:00"), note = noteField()
        defer { withExtendedLifetime(rep.sync) {} }
        note.placeholderString = T("break.notePlaceholder")
        guard form(T("menu.addBreak"), T("break.help") + " " + T("help.overnight"),
                   rep.rows + [(T("form.from"), t1), (T("form.to"), t2), (T("form.note"), note)],
                   check: { hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        let b = Break(from: hmFmt.string(from: t1.dateValue), to: hmFmt.string(from: t2.dateValue), note: note.stringValue.trimmingCharacters(in: .whitespaces), rule: rep.rule())
        breaks.append(b); saveJSON(breaks, to: breaksURL); rebuildBreakMenu()
        appendLog(T("log.breakAdded", breakLabel(b)))
        next = nextSlot(after: Date()); tick()
    }
    @objc func removeBreak(_ sender: NSMenuItem) {
        guard breaks.indices.contains(sender.tag), confirmRemove(T("confirm.deleteBreak"), breakLabel(breaks[sender.tag])) else { return }
        let b = breaks.remove(at: sender.tag); saveJSON(breaks, to: breaksURL); rebuildBreakMenu()
        appendLog(T("log.breakDeleted", breakLabel(b)))
        next = nextSlot(after: Date()); tick()
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
        guard form(T("workHours.title"), T("workHours.help") + " " + T("workHours.nightShiftHelp"), [(T("form.from"), t1), (T("form.to"), t2)], button: T("common.save"),
                   check: { hmFmt.string(from: t2.dateValue) != hmFmt.string(from: t1.dateValue) ? nil : T("error.sameStartEnd") }) else { return }
        let (s, e) = (hmFmt.string(from: t1.dateValue), hmFmt.string(from: t2.dateValue))
        UserDefaults.standard.set(s, forKey: "workStart"); UserDefaults.standard.set(e, forKey: "workEnd")
        workHoursItem.title = T("menu.workHours", s, endText(s, e))
        appendLog(T("log.workHoursChanged", s, endText(s, e)))
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
    // Registers the app itself as a login item, for copies installed from the disk image.
    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { appendLog(T("log.openAtLoginFailed", error.localizedDescription)) }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
