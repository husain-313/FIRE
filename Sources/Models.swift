import Foundation

enum Kind: Int, Codable, CaseIterable {
    case live, movie, series
}

struct Cat: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct Item: Codable, Hashable, Identifiable {
    var kind: Kind
    var sid: Int
    var name: String
    var icon: String?
    var ext: String?
    var num: String? = nil
    // Wide picture, story and "2024 • ★ 7.1 • Drama" line, when the list already carries them (series do).
    var backdrop: String? = nil
    var plot: String? = nil
    var meta: String? = nil
    // Second line on wide cards, e.g. "S1 E3 · 23m left"; for episodes, the length.
    var sub: String? = nil
    // How far it was watched, 0...1; nil shows no bar.
    var progress: Double? = nil

    var id: String { "\(kind.rawValue):\(sid)" }
}

// Details shown on a film's page.
struct Info {
    var backdrop: String?
    var poster: String?
    var plot: String?
    var meta: String
    var trailer: String?
}

struct Prog: Hashable {
    let title: String
    let start: Date
    let end: Date

    var progress: Double {
        let d = end.timeIntervalSince(start)
        guard d > 0 else { return 0 }
        return min(max(Date().timeIntervalSince(start) / d, 0), 1)
    }

    var times: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

struct Season: Hashable {
    let name: String
    let episodes: [Item]
}

struct SeriesInfo {
    var plot: String?
    var meta: String
    var cover: String?
    var backdrop: String?
    var seasons: [Season]
}

// MARK: - Lenient values

// Xtream panels send numbers as strings and strings as numbers; read any scalar as text.
func str(_ v: Any?) -> String? {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    default: return nil
    }
}

func int(_ v: Any?) -> Int? {
    guard let s = str(v)?.trimmingCharacters(in: .whitespaces) else { return nil }
    return Int(s) ?? Double(s).map { Int($0) }
}

// backdrop_path comes as a list of links, sometimes as a single one.
func firstStr(_ v: Any?) -> String? {
    if let a = v as? [Any] { return a.lazy.compactMap { str($0) }.first { !$0.isEmpty } }
    return str(v)
}

func http(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), t.hasPrefix("http") else { return nil }
    return t
}

private func nonEmpty(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

// MARK: - Text

// "2024  •  ★ 7.1  •  1h 55m  •  Drama"
func metaLine(year: String?, rating: String?, secs: Int, genre: String?) -> String {
    var parts: [String] = []
    if let y = year?.prefix(4), y.count == 4, y.allSatisfy(\.isNumber) { parts.append(String(y)) }
    if let r = rating.flatMap({ Double($0) }), r > 0 { parts.append(String(format: "★ %.1f", r)) }
    if secs > 0 { parts.append(duration(Double(secs))) }
    if let g = nonEmpty(genre) {
        parts.append(g.split(separator: ",").prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
    }
    return parts.joined(separator: "  •  ")
}

func duration(_ secs: Double) -> String {
    let m = Int(secs / 60)
    return m >= 60 ? String(format: "%dh %02dm", m / 60, m % 60) : "\(max(m, 1))m"
}

func clock(_ secs: Double) -> String {
    let s = max(Int(secs), 0)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

private func isArabicLetter(_ c: Character) -> Bool {
    c.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
}

// What a provider prefix tells: "4K-AR - The Batman" is a 4K copy with Arabic subtitles.
// cleanTitle drops the prefix, so these come back as badges.
func nameTags(_ name: String) -> [String] {
    guard let r = name.range(of: " - ") else { return [] }
    let n = name.distance(from: name.startIndex, to: r.lowerBound)
    guard (1...16).contains(n) else { return [] }
    let tags = name[..<r.lowerBound].uppercased().split { "- |:".contains($0) }.map(String.init)
    return [tags.contains("4K") ? "4K" : nil, tags.contains("AR") ? "AR" : nil].compactMap { $0 }
}

// Provider prefixes like "4K-OSN+ - " or "NF - " are noise on screen; the name after them is the title.
func cleanTitle(_ name: String) -> String {
    guard let r = name.range(of: " - ") else { return name }
    let n = name.distance(from: name.startIndex, to: r.lowerBound)
    guard (1...16).contains(n) else { return name }
    let prefix = name[..<r.lowerBound]
    if prefix.contains(where: { isArabicLetter($0) || $0.isLowercase }) { return name }
    let rest = name[r.upperBound...].trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? name : rest
}

// MARK: - Parsing

private func json(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) }

func parseCats(_ d: Data) -> [Cat]? {
    guard let a = json(d) as? [[String: Any]] else { return nil }
    return a.compactMap { o in
        guard let id = str(o["category_id"]) else { return nil }
        return Cat(id: id, name: (str(o["category_name"]) ?? "").trimmingCharacters(in: .whitespaces))
    }
}

func item(_ kind: Kind, _ o: [String: Any]) -> Item? {
    guard let id = int(o["stream_id"] ?? o["series_id"]) else { return nil }
    var it = Item(kind: kind, sid: id, name: (str(o["name"]) ?? "").trimmingCharacters(in: .whitespaces),
                  icon: http(str(o["stream_icon"] ?? o["cover"])), ext: str(o["container_extension"]))
    it.num = str(o["num"])
    if kind == .series {
        it.backdrop = http(firstStr(o["backdrop_path"]))
        it.plot = nonEmpty(str(o["plot"]))
        it.meta = nonEmpty(metaLine(year: str(o["releaseDate"] ?? o["releasedate"]), rating: str(o["rating"]), secs: 0, genre: str(o["genre"])))
    }
    return it
}

func parseItems(_ kind: Kind, _ d: Data) -> [Item]? {
    guard let a = json(d) as? [[String: Any]] else { return nil }
    return a.compactMap { item(kind, $0) }
}

func parseVodInfo(_ d: Data) -> Info? {
    guard let o = json(d) as? [String: Any], let i = o["info"] as? [String: Any] else { return nil }
    let plot = nonEmpty(str(i["plot"])) ?? nonEmpty(str(i["description"]))
    let poster = http(str(i["cover_big"])) ?? http(str(i["movie_image"]))
    return Info(backdrop: http(firstStr(i["backdrop_path"])) ?? poster, poster: poster, plot: plot,
                meta: metaLine(year: str(i["releasedate"]), rating: str(i["rating"]), secs: int(i["duration_secs"]) ?? 0, genre: str(i["genre"])),
                trailer: nonEmpty(str(i["youtube_trailer"])))
}

// "04/11/2026"
func parseExpiry(_ d: Data) -> String? {
    guard let o = json(d) as? [String: Any], let u = o["user_info"] as? [String: Any] else { return nil }
    guard let t = int(u["exp_date"]) else { return "" }
    let f = DateFormatter()
    f.dateFormat = "dd/MM/yyyy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
}

func parseEpg(_ d: Data) -> [Prog] {
    guard let o = json(d) as? [String: Any], let a = o["epg_listings"] as? [[String: Any]] else { return [] }
    return a.compactMap { e in
        guard let raw = str(e["title"]), let s = int(e["start_timestamp"]), let t = int(e["stop_timestamp"]) else { return nil }
        let title = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        guard let tt = nonEmpty(title) else { return nil }
        return Prog(title: tt, start: Date(timeIntervalSince1970: TimeInterval(s)), end: Date(timeIntervalSince1970: TimeInterval(t)))
    }
}

func parseSeriesInfo(_ d: Data) -> SeriesInfo? {
    guard let o = json(d) as? [String: Any] else { return nil }
    let i = o["info"] as? [String: Any] ?? [:]
    var seasons: [String: [Item]] = [:]
    func add(_ list: [Any], _ fallback: String) {
        for case let e as [String: Any] in list {
            guard let id = int(e["id"]) else { continue }
            let inf = e["info"] as? [String: Any] ?? [:]
            let secs = int(inf["duration_secs"]) ?? 0
            var ep = Item(kind: .series, sid: id, name: (str(e["title"]) ?? "").trimmingCharacters(in: .whitespaces),
                          icon: http(str(inf["movie_image"])), ext: str(e["container_extension"]))
            ep.num = str(e["episode_num"])
            ep.plot = nonEmpty(str(inf["plot"]))
            ep.sub = secs > 0 ? duration(Double(secs)) : nil
            seasons[str(e["season"]) ?? fallback, default: []].append(ep)
        }
    }
    if let m = o["episodes"] as? [String: Any] {
        for (k, v) in m { if let l = v as? [Any] { add(l, k) } }
    } else if let a = o["episodes"] as? [Any] {
        for v in a { if let l = v as? [Any] { add(l, "1") } else { add([v], "1") } }
    }
    let sorted = seasons.sorted { (Int($0.key) ?? Int.max, $0.key) < (Int($1.key) ?? Int.max, $1.key) }
        .map { Season(name: $0.key, episodes: $0.value.sorted { (Int($0.num ?? "") ?? 0) < (Int($1.num ?? "") ?? 0) }) }
    return SeriesInfo(plot: nonEmpty(str(i["plot"])),
                      meta: metaLine(year: str(i["releaseDate"] ?? i["release_date"]), rating: str(i["rating"]), secs: 0, genre: str(i["genre"])),
                      cover: http(str(i["cover"])), backdrop: http(firstStr(i["backdrop_path"])), seasons: sorted)
}

// Calls [each] for every object of a big top-level JSON array without building the whole
// array in memory: it finds each object's bytes and parses just that slice.
func eachObject(in d: Data, _ each: ([String: Any]) -> Void) {
    d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        let n = raw.count
        var depth = 0, inStr = false, esc = false, start = -1
        var i = 0
        while i < n {
            let c = p[i]
            if inStr {
                if esc { esc = false } else if c == 0x5C { esc = true } else if c == 0x22 { inStr = false }
            } else {
                switch c {
                case 0x22: inStr = true
                case 0x7B, 0x5B: // { [
                    depth += 1
                    if c == 0x7B && depth == 2 { start = i }
                case 0x7D, 0x5D: // } ]
                    if c == 0x7D && depth == 2 && start >= 0 {
                        autoreleasepool {
                            let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p + start), count: i - start + 1, deallocator: .none)
                            if let o = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] { each(o) }
                        }
                        start = -1
                    }
                    depth -= 1
                default: break
                }
            }
            i += 1
        }
    }
}
