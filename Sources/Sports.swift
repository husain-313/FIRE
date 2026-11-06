import Foundation

// A match of one of the big teams, from ESPN's public schedules.
struct Game: Codable, Hashable {
    let id: String
    let home: String
    let away: String
    let league: String
    let kickoff: Date
    // How guides may write each team (plain, lowercase); short ones count only as whole words.
    let homeNames: [String]
    let awayNames: [String]
}

struct MatchRow: Hashable, Identifiable {
    let game: Game
    let channels: [Item]
    var id: String { game.id }
}

// The big teams' matches on the Live tab, one row per match with the channels showing it (the same
// as FIRE on the TV). Fixtures come from ESPN (no key): the five big leagues, their cups and the
// Champions League. The channels come from the provider's guides, matched by both team names within
// two hours of kickoff so replays never count. One pass over the guides serves every match in the
// window, and it also finds the channels showing LaLiga / Copa del Rey / Champions League this week.
// The pass reads hundreds of guides, so it runs on Wi-Fi only; mobile data keeps the saved rows.
enum Matches {
    static let length: TimeInterval = 3 * HOUR
    private static let ahead: TimeInterval = 36 * HOUR
    // Raised when the channel picks or the search change, so saved results are made again at once.
    private static let version = 3
    // Each subscription has its own results; the first one (no tag) keeps the old place.
    private static var ud: UserDefaults { UserDefaults(suiteName: "fire.matches" + (Api.account?.tag ?? "")) ?? .standard }

    // Most channels carry no guide, so a guide alone rarely finds more than one. Each competition lists
    // the channels that normally show it, from the Big Leagues package, best first.
    private static let beIN = ["BEIN SPORTS 1", "BEIN SPORTS 2", "BEIN SPORTS 3"]
    private static let ukSky = ["UK · SKY SPORTS MAIN EVENTS?", "UK · SKY SPORTS PL", "UK · SKY SPORTS FOOTBALL"]
    private static let ukTnt = ["UK · TNT SPORTS 1", "UK · TNT SPORTS 2", "UK · TNT SPORTS 3"]
    private static let es = ["ES · MOVISTAR LALIGA", "ES · DAZN LA LIGA", "ES · MOVISTAR LALIGA 2", "ES · DAZN LA LIGA 2"]
    private static let it = ["IT · SKY SPORT CALCIO", "IT · SKY SPORT UNO", "IT · ZONA DAZN SERIE A 1", "IT · DAZN CHANNEL", "IT · SKY CALCIO 1"]
    private static let de = ["DE · SKY SPORT TOP EVENT", "DE · SKY SPORT BUNDESLIGA 1", "DE · SKY SPORT BUNDESLIGA", "DE · SKY SPORT BUNDESLIGA 2", "DE · SKY SPORT 1", "DE · DAZN 1"]
    private static let fr = ["FR · LIGUE1\\+ 1", "FR · CANAL\\+ FOOT", "FR · LIGUE1\\+ 2", "FR · BEIN SPORTS 1", "FR · CANAL\\+ SPORT"]
    private static let usual: [String: [String]] = [
        "Premier League": Array(beIN.prefix(2)) + ukSky,
        "LaLiga": Array(beIN.prefix(2)) + es,
        "Serie A": it,
        "Bundesliga": de,
        "Ligue 1": fr,
        "Champions League": Array(beIN.prefix(2)) + Array(ukTnt.prefix(2)) + ["ES · M\\+ LIGA DE CAMPEONES", "FR · CANAL\\+ FOOT"],
        "FA Cup": ukTnt + beIN,
        "Carabao Cup": Array(beIN.prefix(2)) + ukSky,
        "Community Shield": ukTnt + beIN,
        "Copa del Rey": Array(beIN.prefix(2)) + es,
        "Supercopa": Array(beIN.prefix(2)) + es,
        "Coppa Italia": it,
        "Supercoppa": it,
        "DFB-Pokal": de,
        "Supercup": de,
        "Coupe de France": fr,
        "Trophée des Champions": fr,
    ]

    // A match's row: the channels whose guide names it, then the usual ones up to five.
    static func cards(_ g: Game, found: [Item], big: [Item], want: Int = 5) -> [Item] {
        var out = found
        for p in usual[g.league] ?? beIN {
            if out.count >= want { break }
            let rx = re("^(?:" + p + ")$")
            guard let c = big.first(where: { matches(rx, $0.name) }) else { continue }
            if !out.contains(where: { $0.sid == c.sid || $0.name.caseInsensitiveCompare(c.name) == .orderedSame }) { out.append(c) }
        }
        return out
    }

    // Set when the last look could not read the guides (no Wi-Fi, or no connection at all).
    private(set) static var couldNotSearch = false

    // The Refresh button: ask ESPN and the guides again now instead of waiting for their time.
    static func forget() {
        let d = ud
        for k in ["at", "searched", "searchV"] { d.removeObject(forKey: k) }
    }

    // ESPN team id -> how guides write the team.
    private static let teams: [(String, [String])] = [
        ("83", ["barcelona", "barca"]),
        ("86", ["real madrid"]),
        ("1068", ["atletico", "atleti"]),
        ("110", ["inter", "internazionale"]),
        ("103", ["milan"]),
        ("111", ["juventus", "juve"]),
        ("104", ["roma"]),
        ("114", ["napoli"]),
        ("382", ["manchester city", "man city"]),
        ("360", ["manchester united", "man united", "man utd"]),
        ("363", ["chelsea"]),
        ("160", ["psg", "paris saint germain", "paris sg", "paris st germain"]),
        ("132", ["bayern"]),
        ("124", ["dortmund"]),
    ]
    private static let teamNames = Dictionary(uniqueKeysWithValues: teams)

    // The leagues, their cups and super cups, and the Champions League, with the name shown on the row.
    private static let comps: [String: String] = [
        "eng.1": "Premier League", "esp.1": "LaLiga", "ita.1": "Serie A", "ger.1": "Bundesliga", "fra.1": "Ligue 1",
        "uefa.champions": "Champions League",
        "eng.fa": "FA Cup", "eng.league_cup": "Carabao Cup", "eng.charity": "Community Shield",
        "esp.copa_del_rey": "Copa del Rey", "esp.super_cup": "Supercopa",
        "ita.coppa_italia": "Coppa Italia", "ita.super_cup": "Supercoppa",
        "ger.dfb_pokal": "DFB-Pokal", "ger.super_cup": "Supercup",
        "fra.coupe_de_france": "Coupe de France", "fra.super_cup": "Trophée des Champions",
    ]

    // Words in team names that say nothing about which team it is.
    private static let generic: Set<String> = ["club", "city", "united", "real", "sporting", "athletic", "atletico", "olympique",
        "borussia", "deportivo", "racing", "saint", "union", "calcio", "football", "town", "rovers", "wanderers", "albion"]

    // MARK: Saved results

    static func clear() {
        for k in ud.dictionaryRepresentation().keys { ud.removeObject(forKey: k) }
    }

    private static func readItems(_ key: String) -> [Item] {
        guard let d = ud.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: d)) ?? []
    }

    private static func writeItems(_ l: [Item], _ key: String) {
        ud.set(try? JSONEncoder().encode(l), forKey: key)
    }

    private static func readGames() -> [Game] {
        guard let d = ud.data(forKey: "games") else { return [] }
        return (try? JSONDecoder().decode([Game].self, from: d)) ?? []
    }

    private static func inWindow(_ g: Game, _ now: Date) -> Bool {
        g.kickoff.timeIntervalSince(now) <= ahead && now <= g.kickoff.addingTimeInterval(length)
    }

    // What was found last time, shown at once while a fresh look runs.
    static func saved(_ now: Date = Date()) -> [MatchRow] {
        readGames().filter { inWindow($0, now) }.map { MatchRow(game: $0, channels: readItems("c:" + $0.id)) }
    }

    // Channels whose guide shows LaLiga, the Copa del Rey or the Champions League this week.
    // News channels only talk about the matches.
    static func football() -> [Item] {
        readItems("football").filter { !$0.name.localizedCaseInsensitiveContains("NEWS") }
    }

    static func big() -> [Item] { readItems("big") }

    // MARK: Matches

    static func lookNow() async -> [MatchRow] {
        couldNotSearch = false
        let now = Date()
        let games = await fixtures(now).filter { inWindow($0, now) }
        if games.isEmpty { return [] }
        let saved = games.map { MatchRow(game: $0, channels: readItems("c:" + $0.id)) }
        // Every match already searched: keep it, but look again now and then while one has nothing.
        let searchedAll = ud.integer(forKey: "searchV") == version && games.allSatisfy { ud.object(forKey: "c:" + $0.id) != nil }
        let searchedAt = Date(timeIntervalSince1970: ud.double(forKey: "searched"))
        if searchedAll && (saved.allSatisfy { !$0.channels.isEmpty } || now.timeIntervalSince(searchedAt) < 2 * HOUR) {
            return saved
        }
        guard let found = await search(games) else {
            couldNotSearch = !Task.isCancelled
            return saved
        }
        // The subscription changed during the pass: these results belong to the old one.
        if Task.isCancelled { return saved }
        let (byGame, foot) = found
        ud.set(now.timeIntervalSince1970, forKey: "searched")
        ud.set(version, forKey: "searchV")
        // Matches that have left the window drop their saved channels.
        for k in ud.dictionaryRepresentation().keys where k.hasPrefix("c:") && !games.contains(where: { "c:" + $0.id == k }) {
            ud.removeObject(forKey: k)
        }
        for g in games { writeItems(byGame[g.id] ?? [], "c:" + g.id) }
        if !foot.isEmpty { writeItems(foot, "football") }
        return games.map { MatchRow(game: $0, channels: byGame[$0.id] ?? []) }
    }

    // MARK: Fixtures

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return f
    }()

    // The teams' schedules are asked for every 3 hours; between times the saved list is used.
    private static func fixtures(_ now: Date) async -> [Game] {
        if now.timeIntervalSince1970 - ud.double(forKey: "at") < 3 * HOUR { return readGames() }
        let answers = await withTaskGroup(of: (String, [String: Any]?).self) { group -> [(String, [String: Any]?)] in
            for (team, _) in teams {
                group.addTask {
                    let u = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/all/teams/\(team)/schedule?fixture=true")!
                    var r = URLRequest(url: u)
                    r.timeoutInterval = 15
                    guard let (d, _) = try? await URLSession.shared.data(for: r) else { return (team, nil) }
                    return (team, try? JSONSerialization.jsonObject(with: d) as? [String: Any])
                }
            }
            var out: [(String, [String: Any]?)] = []
            for await a in group { out.append(a) }
            return out
        }
        var games: [String: Game] = [:]
        var answered = 0
        // In the teams' order, so a match two big teams play is read once.
        for (team, _) in teams {
            guard let o = answers.first(where: { $0.0 == team })?.1 else { continue }
            answered += 1
            for case let e as [String: Any] in (o["events"] as? [Any]) ?? [] {
                guard let id = str(e["id"]), !id.isEmpty, games[id] == nil else { continue }
                let league = e["league"] as? [String: Any]
                // Barcelona keeps every match; the other teams only these competitions.
                guard let comp = comps[str(league?["slug"]) ?? ""] ?? (team == "83" ? str(league?["shortName"]) : nil) else { continue }
                guard let c = (e["competitions"] as? [[String: Any]])?.first else { continue }
                let state = ((c["status"] as? [String: Any])?["type"] as? [String: Any])?["state"] as? String
                if state == "post" { continue }
                guard let t = str(e["date"]).flatMap({ iso.date(from: $0) }) else { continue }
                if t.addingTimeInterval(length) < now || t.timeIntervalSince(now) > 8 * DAY { continue }
                var home = "", away = ""
                var homeNames: [String] = [], awayNames: [String] = []
                for ct in (c["competitors"] as? [[String: Any]]) ?? [] {
                    guard let tm = ct["team"] as? [String: Any] else { continue }
                    let full = str(tm["displayName"]) ?? ""
                    let name = str(tm["shortDisplayName"]) ?? full
                    let names = teamNames[str(tm["id"]) ?? ""] ?? namesFor(full, name)
                    if str(ct["homeAway"]) == "home" { home = name; homeNames = names } else { away = name; awayNames = names }
                }
                if homeNames.isEmpty || awayNames.isEmpty { continue }
                games[id] = Game(id: id, home: home, away: away, league: comp, kickoff: t, homeNames: homeNames, awayNames: awayNames)
            }
        }
        // Only keep the new list when ESPN answered; otherwise the old one serves until next time.
        guard answered > 0 else { return readGames() }
        let list = games.values.sorted { $0.kickoff < $1.kickoff }
        ud.set(now.timeIntervalSince1970, forKey: "at")
        ud.set(try? JSONEncoder().encode(list), forKey: "games")
        return list
    }

    // How a guide may write another team: its full and short names, and the telling words in them.
    private static func namesFor(_ full: String, _ short: String) -> [String] {
        var whole: [String] = []
        for n in [plain(full), plain(short)] where n.count >= 3 && !whole.contains(n) { whole.append(n) }
        var out = whole
        for w in whole.flatMap({ $0.split(separator: " ").map(String.init) }) where w.count >= 4 && !generic.contains(w) && !out.contains(w) {
            out.append(w)
        }
        return out
    }

    // MARK: Guides

    // "Alavés" -> "alaves", "Paris Saint-Germain" -> "paris saint germain".
    static func plain(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\x{0600}-\\x{06FF}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // A name counts only as whole words of the title ("inter" not in "international").
    private static func has(_ title: String, _ names: [String]) -> Bool {
        names.contains { " \(title) ".contains(" \($0) ") }
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }
    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // Sports packages; entertainment and film packages are left out.
    private static let sporty = re("SPORT|⚽|SSC|KASS|DAZN|ESPN|MOVISTAR|LALIGA|LIGA|FUTBOL|FOOT|TNT|SKY|CANAL|ELEVEN|ARENA|TOD|THMANYAH|SHAHID|STARZ")
    private static let notSport = re("ENTERTAIN|CINEMA|MOVIE|FILM|KIDS|\\bOD\\b|SERIES")
    // Guide titles read like "Barcelona vs Alaves - Spanish LaLiga 2026/2027 - Week 11".
    private static let footballTitle = re("la\\s?liga|copa del rey|uefa champions league")
    private static let hd = re("\\bF?HD\\b|ᴴᴰ")

    private struct Pack {
        var keys: [String] = []
        var copies: [String: [Item]] = [:]
        var tags: [String: String] = [:]

        mutating func add(_ k: String, _ ch: Item, tag: String? = nil) {
            if copies[k] == nil { keys.append(k) }
            copies[k, default: []].append(ch)
            if let tag { tags[k] = tag }
        }
    }

    private static func channels(_ catId: String) async -> [Item]? {
        await Store.load(Q.streams(.live, Cat(id: catId, name: "")), ttl: 6 * HOUR) { parseItems(.live, $0) }
    }

    // For every match, the channels showing it; and the channels showing LaLiga / Copa / Champions
    // League in the week ahead. nil when the guides could not be read (no Wi-Fi).
    private static func search(_ games: [Game]) async -> ([String: [Item]], [Item])? {
        let cats = await Store.load(Q.cats(.live), ttl: 6 * HOUR, parseCats) ?? []
        // Arabic packages only: foreign guides are mostly empty, and every country's channels would
        // take an hour to read.
        let packs = cats.filter { $0.name.hasPrefix("AR") && matches(sporty, $0.name) && !matches(notSport, $0.name) }
        var groups = Pack()
        // The Big Leagues channels from other countries first (the pass stops at its limit, and the
        // Arabic packages alone can fill it): some of their guides list the matches.
        for p in picks where !p.tag.isEmpty {
            for ch in await channels(p.cat) ?? [] where !ch.name.contains("##") && p.fits(label(ch.name).uppercased()) {
                groups.add(p.tag.lowercased() + key(ch.name), ch, tag: p.tag)
            }
        }
        for c in packs {
            for ch in await channels(c.id) ?? [] {
                let k = key(ch.name)
                if k.count >= 3 && !ch.name.contains("####") { groups.add(k, ch) }
            }
        }

        // No package answered (no connection): the saved channels must stay, not be replaced by nothing.
        if groups.keys.isEmpty { return nil }

        // One guide per channel: many copies carry none, so up to two copies are tried. At most 600
        // guides are read in a pass, six at a time.
        struct Look { let index: Int; let games: [String]; let comp: Bool; let asked: Int; let offline: Bool }
        let now = Date()
        var hits: [String: [(Int, String)]] = [:]
        var comps: [(Int, String)] = []
        var asked = 0
        var start = 0
        while start < groups.keys.count && asked < 600 {
            if Task.isCancelled { return nil }
            let batch = Array(groups.keys.enumerated().dropFirst(start).prefix(6))
            start += batch.count
            let looks = await withTaskGroup(of: Look.self) { group -> [Look] in
                for (i, k) in batch {
                    let copies = Array((groups.copies[k] ?? []).prefix(2))
                    group.addTask {
                        var n = 0
                        for ch in copies {
                            n += 1
                            let listings: [(String, Date)]
                            do {
                                let d = try await Api.data("&action=get_simple_data_table&stream_id=\(ch.sid)", timeout: 20, wifiOnly: true)
                                listings = titles(d)
                            } catch {
                                // Not on Wi-Fi: the whole pass waits for next time.
                                if (error as? URLError)?.networkUnavailableReason != nil { return Look(index: i, games: [], comp: false, asked: n, offline: true) }
                                continue
                            }
                            if listings.isEmpty { continue }
                            let on = games.filter { g in
                                listings.contains { title, start in
                                    guard abs(start.timeIntervalSince(g.kickoff)) < 2 * HOUR else { return false }
                                    let t = plain(title)
                                    return has(t, g.homeNames) && has(t, g.awayNames)
                                }
                            }.map(\.id)
                            // Women's football has its own Champions League; it isn't what this row is for.
                            let comp = listings.contains { title, start in
                                start > now.addingTimeInterval(-DAY) && start < now.addingTimeInterval(7 * DAY) &&
                                    matches(footballTitle, title) && !title.localizedCaseInsensitiveContains("women")
                            }
                            return Look(index: i, games: on, comp: comp, asked: n, offline: false)
                        }
                        return Look(index: i, games: [], comp: false, asked: n, offline: false)
                    }
                }
                var out: [Look] = []
                for await l in group { out.append(l) }
                return out
            }
            if looks.contains(where: \.offline) { return nil }
            for l in looks {
                asked += l.asked
                let k = groups.keys[l.index]
                for g in l.games { hits[g, default: []].append((l.index, k)) }
                if l.comp { comps.append((l.index, k)) }
            }
        }
        // One card per channel, its HD copy when there is one; in package order.
        func cards(_ keys: [(Int, String)]) -> [Item] {
            keys.sorted { $0.0 < $1.0 }.prefix(20).compactMap { _, k in
                guard let copies = groups.copies[k], let first = copies.first else { return nil }
                let best = copies.first { matches(hd, $0.name) } ?? first
                return Item(kind: .live, sid: best.sid, name: (groups.tags[k].map { "\($0) · " } ?? "") + label(best.name), icon: best.icon, ext: best.ext)
            }
        }
        return (hits.mapValues { cards($0) }, cards(comps))
    }

    // "8K: beIN SP⚽RTS 2 ᴴᴰ" -> "beIN SPORTS 2": no provider prefix, no quality marks.
    static func label(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "⚽️", with: "O").replacingOccurrences(of: "⚽", with: "O")
        // Prefixes like "8K:", "SS:", "◉:", "AR|".
        for _ in 0..<2 { n = n.replacingOccurrences(of: "^\\s*[^:|]{1,6}[:|]\\s*", with: "", options: .regularExpression) }
        n = n.replacingOccurrences(of: "[ᴀ-ᶿ⁰-₟ʰ-˿ⱼⱽ◉▼▶●◆★]", with: " ", options: .regularExpression)
        n = n.replacingOccurrences(of: "(?i)\\b(SD|HD|FHD|UHD|4K|8K|LQ|RAW|HEVC|H265|3840P|1080P|720P|50FPS|BACKUP)\\b", with: " ", options: .regularExpression)
        n = n.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " -|:"))
        return n.isEmpty ? name.trimmingCharacters(in: .whitespaces) : n
    }

    private static func key(_ name: String) -> String { plain(label(name)).replacingOccurrences(of: " ", with: "") }

    private static func titles(_ d: Data) -> [(String, Date)] {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["epg_listings"] as? [[String: Any]] else { return [] }
        return a.compactMap { e in
            guard let raw = str(e["title"]), let s = int(e["start_timestamp"]) else { return nil }
            let title = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
            return (title, Date(timeIntervalSince1970: TimeInterval(s)))
        }
    }

    // MARK: Big Leagues package

    // The channels that carry these leagues, cups and the Champions League, whether or not their guide
    // says so: package id, which channels (by plain label), and the country tag shown on the card.
    private struct Pick {
        let cat: String
        let names: NSRegularExpression
        let tag: String

        init(_ cat: String, _ names: String, _ tag: String) {
            self.cat = cat
            self.names = try! NSRegularExpression(pattern: "^(?:" + names + ")$")
            self.tag = tag
        }

        func fits(_ s: String) -> Bool { names.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    }

    private static let picks = [
        Pick("108", "BEIN SPORTS [1-9]", ""),
        Pick("303", "SKY SPORTS (MAIN EVENTS?|PL|FOOTBALL)|TNT SPORTS [1-4]", "UK"),
        Pick("870", "MOVISTAR LALIGA( [23])?", "ES"),
        Pick("552", "DAZN LA LIGA( 2)?", "ES"),
        Pick("553", "M\\+ LIGA DE CAMPEONES( [2-4])?", "ES"),
        Pick("265", "SKY SPORT (CALCIO|UNO)|SKY CALCIO [1-3]", "IT"),
        Pick("476", "DAZN CHANNEL", "IT"),
        Pick("681", "ZONA DAZN SERIE A [1-3]", "IT"),
        Pick("667", "SKY SPORT (TOP EVENT|BUNDESLIGA( [1-4])?|[12])|DAZN [12]", "DE"),
        Pick("557", "CANAL\\+ (FOOT|SPORT)|BEIN SPORTS [1-3]", "FR"),
        Pick("1952", "LIGUE1\\+ [1-3]", "FR"),
    ]

    // Built from the packages twice a day (channel ids can change); the saved list serves between times.
    static func refreshBig() async -> [Item] {
        let now = Date().timeIntervalSince1970
        if now - ud.double(forKey: "bigAt") < 12 * HOUR && ud.integer(forKey: "bigV") == version && !big().isEmpty { return big() }
        var out: [Item] = []
        var answered = 0
        for p in picks {
            guard let list = await channels(p.cat) else { continue }
            answered += 1
            var order: [String] = []
            var best: [String: (Item, Bool)] = [:]
            for ch in list where !ch.name.contains("##") {
                let l = label(ch.name).uppercased()
                guard p.fits(l) else { continue }
                let isHD = matches(hd, ch.name) && !ch.name.localizedCaseInsensitiveContains("MOBIL")
                // The first copy holds the place; an HD copy found later takes it over.
                if let had = best[l], had.1 || !isHD { continue }
                if best[l] == nil { order.append(l) }
                let name = (p.tag.isEmpty ? "" : "\(p.tag) · ") + label(ch.name)
                best[l] = (Item(kind: .live, sid: ch.sid, name: name, icon: ch.icon, ext: ch.ext), isHD)
            }
            // In the package's own order (beIN 1, 2, 3…).
            out += order.compactMap { best[$0]?.0 }
        }
        guard answered > 0, !out.isEmpty, !Task.isCancelled else { return big() }
        ud.set(now, forKey: "bigAt")
        ud.set(version, forKey: "bigV")
        writeItems(out, "big")
        return out
    }
}

// What the Live tab shows of it. Used from the main thread only.
final class Sports: ObservableObject {
    static let shared = Sports()
    @Published private(set) var matches: [MatchRow] = []
    @Published private(set) var big: [Item] = []
    @Published private(set) var football: [Item] = []
    // The hand-picked packages (Curated), by key.
    @Published private(set) var curated: [String: [Item]] = [:]
    @Published private(set) var busy = false
    // Shown once after the Refresh button when the channels could not be searched.
    @Published var notice: String?
    private var pass: Task<Void, Never>?
    private var pressed = false

    private init() { load() }

    private func load() {
        matches = Matches.saved()
        big = Matches.big()
        football = Matches.football()
        curated = Curated.saved()
    }

    // Rows from a day and a half before kickoff until full time, in kickoff order, each with the
    // channels its guide names and then the usual ones for the competition up to five.
    var shown: [MatchRow] {
        let now = Date()
        return matches.filter { now <= $0.game.kickoff.addingTimeInterval(Matches.length) }
            .sorted { $0.game.kickoff < $1.game.kickoff }
            .map { MatchRow(game: $0.game, channels: Matches.cards($0.game, found: $0.channels, big: big)) }
            .filter { !$0.channels.isEmpty }
    }

    // The package shows at once; the pass over the guides after it can take a few minutes.
    // [force] is the Refresh button: finished matches go now and everything is asked for again.
    func refresh(force: Bool = false) {
        if force {
            objectWillChange.send()
            pressed = true
        }
        guard !busy, Api.account != nil else { return }
        if force { Matches.forget() }
        busy = true
        pass = Task { @MainActor in
            let b = await Matches.refreshBig()
            if Task.isCancelled { return }
            if b != big { big = b }
            let c = await Curated.refresh()
            if Task.isCancelled { return }
            if c != curated { curated = c }
            let m = await Matches.lookNow()
            if Task.isCancelled { return }
            if m != matches { matches = m }
            let f = Matches.football()
            if f != football { football = f }
            busy = false
            if pressed && Matches.couldNotSearch {
                notice = "Channels were not searched because Wi-Fi isn't available, or Low Data Mode is on. The saved channels stay. Connect to Wi-Fi and press Refresh again."
            }
            pressed = false
        }
    }

    func clear() {
        Matches.clear()
        Curated.clear()
        load()
    }

    // Another subscription came into use: what is running belongs to the old one.
    func reload() {
        pass?.cancel()
        pass = nil
        busy = false
        pressed = false
        notice = nil
        load()
    }

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        return f
    }()

    // "⚽  Barcelona vs Alavés  ·  LaLiga  ·  Sat 21:00", "● LIVE now" once it has started.
    static func title(_ g: Game) -> String {
        let at = Date() >= g.kickoff ? "● LIVE now" : when.string(from: g.kickoff)
        return ["⚽  \(g.home) vs \(g.away)", g.league, at].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}
