// Interface language: the built-in tables in Strings.swift (keyed by short names such as menu.more) plus language files
// the person adds as JSON or Excel in the languages folder. Missing text falls back to English.
import Cocoa

let builtinLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"), ("ko", "한국어"),
    ("ms", "Bahasa Melayu"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
]
var languagesDir: URL { URL(fileURLWithPath: dir + "/languages") }

struct CustomLanguage { var code: String; var name: String; var strings: [String: String] }
var customLanguages: [CustomLanguage] = []
// One line per file that could not be used (fully or partly), shown in the Language menu, and beside each an id
// (file name and modification date) so the same version of a file is only reported once.
var languageProblems: [String] = []
var languageProblemIDs: [String] = []

// nil = follow the system.
var languageChoice: String? {
    get { UserDefaults.standard.string(forKey: "language") }
    set { UserDefaults.standard.set(newValue, forKey: "language") }
}
var lang = "en"
var activeStrings: [String: String] = [:]

func languageCodes() -> [String] { builtinLanguages.map(\.code) + customLanguages.map(\.code).filter { c in !builtinLanguages.contains { $0.code == c } } }
func languageName(_ code: String) -> String { builtinLanguages.first { $0.code == code }?.name ?? customLanguages.first { $0.code == code }?.name ?? code }

// Only the first preferred language counts: when it is not available the interface is English.
func systemLanguage() -> String {
    guard let pref = Locale.preferredLanguages.first?.lowercased() else { return "en" }
    let base = String(pref.split(separator: "-").first ?? "")
    if base == "zh" { return ["hant", "-tw", "-hk", "-mo"].contains { pref.contains($0) } ? "zh-Hant" : "zh-Hans" }
    let codes = languageCodes()
    return codes.first { $0.lowercased() == pref } ?? codes.first { $0.lowercased() == base } ?? "en"
}

// Picks the language and its table; true when anything the menu shows changed.
@discardableResult func applyLanguageChoice() -> Bool {
    var code = languageChoice ?? systemLanguage()
    if !languageCodes().contains(code) { code = systemLanguage() }
    var s = translations[code] ?? [:]
    if let c = customLanguages.first(where: { $0.code == code }) { s.merge(c.strings) { $1 } }
    let changed = code != lang || s != activeStrings
    lang = code; activeStrings = s; fmtCache = [:]
    return changed
}

func T(_ key: String, _ args: CVarArg...) -> String {
    let s = activeStrings[key] ?? translations["en"]?[key] ?? key
    return args.isEmpty ? s : String(format: s, arguments: args)
}

var appLocale: Locale { Locale(identifier: lang == "zh-Hans" ? "zh_CN" : lang == "zh-Hant" ? "zh_TW" : lang) }
var fmtCache: [String: DateFormatter] = [:]
// Date formats from a template, so day/month order and weekday names follow the interface language.
func localFmt(_ template: String) -> DateFormatter {
    if let f = fmtCache[template] { return f }
    let f = DateFormatter(); f.locale = appLocale; f.setLocalizedDateFormatFromTemplate(template)
    fmtCache[template] = f; return f
}
var weekdayNames: [String] { localFmt("EEE").shortWeekdaySymbols }
func md(_ k: String) -> String { dayKey.date(from: k).map { localFmt("Md").string(from: $0) } ?? k }

// A translation may only use the arguments its English original has (%@ or %n$@, n up to that count), or String(format:) would crash.
func placeholdersOK(_ key: String, _ value: String) -> Bool {
    let argc = (translations["en"]?[key] ?? key).components(separatedBy: "%").count - 1
    if argc == 0 { return true }
    var seq = 0, i = value.startIndex
    while let p = value[i...].firstIndex(of: "%") {
        var j = value.index(after: p), digits = ""
        while j < value.endIndex, value[j].isNumber { digits.append(value[j]); j = value.index(after: j) }
        if !digits.isEmpty { guard j < value.endIndex, value[j] == "$" else { return false }; j = value.index(after: j) }
        guard j < value.endIndex else { return false }
        switch value[j] {
        case "%" where digits.isEmpty: break
        case "@":
            if let n = Int(digits) { guard (1...argc).contains(n) else { return false } } else { seq += 1; guard seq <= argc else { return false } }
        default: return false
        }
        i = value.index(after: j)
    }
    return true
}

struct LanguageFileError: Error { let message: String }

// Language files are keyed by the short key; the English or Chinese text still works for files made by older templates.
let sourceKey: [String: String] = Dictionary(["en", "zh-Hans"].flatMap { l in translationKeys.map { ((translations[l]?[$0] ?? $0), $0) } }) { a, _ in a }

// Reads every .json and .xlsx in the languages folder. The code comes from the file (code / @code) or its name.
// A file whose code matches a built-in language corrects that language's text.
func loadCustomLanguages() {
    customLanguages = []; languageProblems = []; languageProblemIDs = []
    let fm = FileManager.default
    try? fm.createDirectory(at: languagesDir, withIntermediateDirectories: true)
    let files = ((try? fm.contentsOfDirectory(at: languagesDir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    for f in files {
        let ext = f.pathExtension.lowercased()
        guard ext == "json" || ext == "xlsx", !f.lastPathComponent.hasPrefix("~$") else { continue }
        let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        func problem(_ message: String) {
            languageProblems.append(T("common.labelValue", f.lastPathComponent, message)); languageProblemIDs.append("\(f.lastPathComponent)|\(modified)")
        }
        do {
            var l = try ext == "json" ? readLanguageJSON(f) : readLanguageXLSX(f)
            if l.code.isEmpty { l.code = f.deletingPathExtension().lastPathComponent }
            if l.name.isEmpty { l.name = languageName(l.code) }
            var bad = 0
            l.strings = Dictionary(l.strings.map { (translations["en"]?[$0.key] != nil ? $0.key : sourceKey[$0.key] ?? $0.key, $0.value) }) { a, _ in a }.filter { k, v in
                guard !v.isEmpty else { return false }
                if placeholdersOK(k, v) { return true }
                bad += 1; return false
            }
            if bad > 0 { problem(T("language.badPlaceholders", String(bad))) }
            guard !l.strings.isEmpty else { throw LanguageFileError(message: T("language.noStrings")) }
            customLanguages.removeAll { $0.code == l.code }; customLanguages.append(l)
        } catch {
            problem((error as? LanguageFileError)?.message ?? error.localizedDescription)
        }
    }
}

// {"code": "it", "name": "Italiano", "strings": {"menu.more": "<translation>"}}; a flat object of strings also works.
func readLanguageJSON(_ f: URL) throws -> CustomLanguage {
    let parsed: Any
    // JSON's own message says where it broke, e.g. "Unexpected end of file around line 12, column 3."
    do { parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) } catch {
        let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
        throw LanguageFileError(message: T("language.invalidFormat") + (detail.map { T("common.paren", $0) } ?? ""))
    }
    guard let o = parsed as? [String: Any] else { throw LanguageFileError(message: T("language.invalidFormat")) }
    let raw = (o["strings"] as? [String: Any]) ?? o.filter { !["code", "name", "_help"].contains($0.key) }
    return CustomLanguage(code: (o["code"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                          name: (o["name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                          strings: raw.compactMapValues { $0 as? String })
}

func unzipEntry(_ f: URL, _ entry: String) -> Data? {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", f.path, entry]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return p.terminationStatus == 0 && !d.isEmpty ? d : nil
}
func xmlNodes(_ n: XMLNode, _ xpath: String) -> [XMLNode] { (try? n.nodes(forXPath: xpath)) ?? [] }
// Text of a shared or inline string: its own runs only, not Excel's phonetic (rPh) hints.
func cellText(_ n: XMLNode) -> String {
    xmlNodes(n, "./*[local-name()='t'] | ./*[local-name()='r']/*[local-name()='t']").map { $0.stringValue ?? "" }.joined()
}

// First sheet: column A the key, column B the translation; rows @code and @name carry the language.
func readLanguageXLSX(_ f: URL) throws -> CustomLanguage {
    guard let sheetData = unzipEntry(f, "xl/worksheets/sheet1.xml"), let sheet = try? XMLDocument(data: sheetData) else {
        throw LanguageFileError(message: T("language.invalidFormat"))
    }
    let shared = unzipEntry(f, "xl/sharedStrings.xml").flatMap { try? XMLDocument(data: $0) }
        .map { xmlNodes($0, "//*[local-name()='si']").map(cellText) } ?? []
    var rows: [Int: [String: String]] = [:]
    for case let c as XMLElement in xmlNodes(sheet, "//*[local-name()='c']") {
        guard let ref = c.attribute(forName: "r")?.stringValue else { continue }
        let col = String(ref.prefix { $0.isLetter }), row = Int(ref.drop { $0.isLetter }) ?? 0
        let v = xmlNodes(c, "./*[local-name()='v']").first?.stringValue
        let text: String?
        switch c.attribute(forName: "t")?.stringValue {
        case "s": text = v.flatMap(Int.init).flatMap { shared.indices.contains($0) ? shared[$0] : nil }
        case "inlineStr": text = xmlNodes(c, "./*[local-name()='is']").first.map(cellText)
        default: text = v
        }
        if let text { rows[row, default: [:]][col] = text }
    }
    var l = CustomLanguage(code: "", name: "", strings: [:])
    for (_, r) in rows {
        guard let key = r["A"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty, let value = r["B"] else { continue }
        switch key {
        case "@code": l.code = value.trimmingCharacters(in: .whitespaces)
        case "@name": l.name = value.trimmingCharacters(in: .whitespaces)
        case "key": break
        default: if !key.hasPrefix("@") { l.strings[key] = value }
        }
    }
    return l
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}

// A one-sheet workbook with inline strings, zipped by the system zip tool.
func writeXLSX(_ rows: [[String]], widths: [Int], to url: URL) throws {
    let fm = FileManager.default, tmp = fm.temporaryDirectory.appendingPathComponent("mn-xlsx-" + UUID().uuidString)
    defer { try? fm.removeItem(at: tmp) }
    let col = { (i: Int) in String(UnicodeScalar(65 + i)!) }
    let ns = "http://schemas.openxmlformats.org/", head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    let cols = widths.enumerated().map { "<col min=\"\($0 + 1)\" max=\"\($0 + 1)\" width=\"\($1)\" customWidth=\"1\"/>" }.joined()
    let data = rows.enumerated().map { r, cells in
        "<row r=\"\(r + 1)\">" + cells.enumerated().filter { !$1.isEmpty }.map { c, v in
            "<c r=\"\(col(c))\(r + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(v))</t></is></c>"
        }.joined() + "</row>"
    }.joined()
    let files = [
        "[Content_Types].xml": "<Types xmlns=\"\(ns)package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>",
        "_rels/.rels": "<Relationships xmlns=\"\(ns)package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(ns)officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
        "xl/workbook.xml": "<workbook xmlns=\"\(ns)spreadsheetml/2006/main\" xmlns:r=\"\(ns)officeDocument/2006/relationships\"><sheets><sheet name=\"Strings\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
        "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"\(ns)package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(ns)officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
        "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(ns)spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\"><pane xSplit=\"2\" ySplit=\"1\" topLeftCell=\"C2\" activePane=\"bottomRight\" state=\"frozen\"/></sheetView></sheetViews><cols>\(cols)</cols><sheetData>\(data)</sheetData></worksheet>",
    ]
    for (path, xml) in files {
        let u = tmp.appendingPathComponent(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (head + xml).write(to: u, atomically: true, encoding: .utf8)
    }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    p.arguments = ["-X", "-q", "-r", url.path] + files.keys.sorted(); p.currentDirectoryURL = tmp
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw LanguageFileError(message: "zip \(p.terminationStatus)") }
}

let templateHelp = "Fill in the translation (keep placeholders such as %@ and %1$@, and any leading space), set code (e.g. it, pt-BR) and name, then put the file in More → Language → Open languages folder. Anything left empty shows in English. / 填写译文（保留 %@、%1$@ 这类占位符和开头的空格），填好 code（比如 it、pt-BR）和 name，再放进“更多 → 语言 → 打开语言文件夹”。留空的条目显示英文。"

// Saves a template to Downloads without overwriting an earlier one. Excel lists every built-in language beside the
// translation column for reference; JSON starts from the English text.
func saveTemplate(xlsx: Bool) throws -> URL {
    let fm = FileManager.default, downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!, ext = xlsx ? "xlsx" : "json"
    var url = downloads.appendingPathComponent("MouseNudge-language-template.\(ext)"), n = 2
    while fm.fileExists(atPath: url.path) { url = downloads.appendingPathComponent("MouseNudge-language-template \(n).\(ext)"); n += 1 }
    func text(_ code: String, _ k: String) -> String { translations[code]?[k] ?? "" }
    if xlsx {
        let refs = builtinLanguages.map(\.code)
        let rows = [["key", "translation"] + refs, ["@code", ""], ["@name", ""], ["@help", templateHelp]]
            + translationKeys.map { k in [k, ""] + refs.map { text($0, k) } }
        try writeXLSX(rows, widths: [28, 36] + refs.map { _ in 28 }, to: url)
    } else {
        let e = JSONEncoder(); e.outputFormatting = .withoutEscapingSlashes
        let q = { (s: String) in String(data: try! e.encode(s), encoding: .utf8)! }
        let body = translationKeys.map { "    \(q($0)): \(q(text("en", $0)))" }.joined(separator: ",\n")
        try "{\n  \"_help\": \(q(templateHelp)),\n  \"code\": \"\",\n  \"name\": \"\",\n  \"strings\": {\n\(body)\n  }\n}\n".write(to: url, atomically: true, encoding: .utf8)
    }
    return url
}
