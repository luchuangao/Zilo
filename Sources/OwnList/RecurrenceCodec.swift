import Foundation
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
enum RecurrenceCodec {
    static func components(_ value: String) -> [String:String] { let stripped = value.replacingOccurrences(of: "RRULE:",with: ""); return Dictionary(stripped.uppercased().split(separator: ";").compactMap { part -> (String,String)? in let p = part.split(separator: "=",maxSplits: 1); return p.count == 2 ? (String(p[0]),String(p[1])) : nil },uniquingKeysWith: { _,v in v }) }
    static func rule(_ value: String,anchor: Date?) throws -> RepeatRule {
        let c = components(value); var r = RepeatRule(); r.anchor = anchor; r.interval = max(1,Int(c["INTERVAL"] ?? "1") ?? 1)
        switch c["FREQ"] { case "DAILY": r.frequency = "daily"; case "WEEKLY": r.frequency = "weekly"; case "MONTHLY": r.frequency = "monthly"; case "YEARLY": r.frequency = "yearly"; default: throw ServiceError.message("不支持的重复频率") }
        let days = ["SU":1,"MO":2,"TU":3,"WE":4,"TH":5,"FR":6,"SA":7]
        if let byday = c["BYDAY"] { if r.frequency == "weekly" { r.weekdays = byday.split(separator: ",").compactMap { days[String($0)] }; if r.weekdays.isEmpty { throw ServiceError.message("无效星期") } } else if r.frequency == "monthly" { let suffix = String(byday.suffix(2)); guard let day = days[suffix], let ordinal = Int(byday.dropLast(2)), ordinal != 0, abs(ordinal) <= 5 else { throw ServiceError.message("仅支持每月第 N 个星期的单一规则") }; r.frequency = "monthlyWeekday"; r.weekday = day; r.ordinal = ordinal } else { throw ServiceError.message("此频率的 BYDAY 暂不支持") } }
        if let raw = c["BYMONTHDAY"] { guard r.frequency == "monthly", let d = Int(raw), d != 0, abs(d) <= 31 else { throw ServiceError.message("仅支持每月单一日期") }; r.frequency = "monthlyDay"; r.monthDay = d }
        for key in c.keys where !["FREQ","INTERVAL","BYDAY","BYMONTHDAY","UNTIL","COUNT","WKST"].contains(key) { throw ServiceError.message("不支持 \(key)") }
        if let raw = c["COUNT"], let count = Int(raw) { r.remainingCount = count }; if let raw = c["UNTIL"] { r.until = date(raw) }
        return r
    }
    static func date(_ value: String,timeZone: TimeZone? = nil) -> Date? { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = value.count == 8 ? "yyyyMMdd" : value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"; f.timeZone = value.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : timeZone ?? .current; return f.date(from: value) }
    static func duration(_ input: String) -> Double? { let value = input.uppercased().replacingOccurrences(of: "TRIGGER:",with: ""); if let number = Double(value) { return number }; guard let regex = try? NSRegularExpression(pattern: "([+-])?P(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?)?"), let m = regex.firstMatch(in: value,range: NSRange(value.startIndex...,in: value)) else { return nil }; func n(_ i: Int) -> Double { Range(m.range(at: i),in: value).flatMap { Double(value[$0]) } ?? 0 }; let seconds = n(2)*86400 + n(3)*3600 + n(4)*60 + n(5); return value.contains("-") ? -seconds : seconds }
    static func expand(start: Date,end: Date,rule raw: String,exclusions: Set<Date> = [],calendar: Calendar = .current) throws -> [(Date,Date)] {
        let components = components(raw); let r = try rule(raw,anchor: start); let count = min(10000,Int(components["COUNT"] ?? "10000") ?? 10000); let horizon = calendar.date(byAdding: .year,value: 3,to: Date())!; let duration = end.timeIntervalSince(start); var date = start; var results: [(Date,Date)] = []
        for _ in 0..<count { if date > horizon { break }; if !exclusions.contains(date) { results.append((date,date.addingTimeInterval(duration))) }; guard let next = r.next(after: date,calendar: calendar), next > date else { break }; date = next }
        return results
    }
}
