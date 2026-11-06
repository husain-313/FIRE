import Foundation

// Hand-picked Live packages built from the provider's own packages (the same as FIRE on the TV,
// its 5.1): one card per channel, its HD copy when there is one, in the order listed here.
// Rebuilt twice a day (channel ids can change); the saved lists serve between times.
enum Curated {
    // [cats]: provider packages to look in; [name]: the channel's plain label (Matches.label,
    // upper case) as a whole-string pattern; [shown]: a nicer name for the card.
    struct Want { let cats: [String]; let name: String; let shown: String }
    struct Pack { let key: String; let title: String; let wants: [Want] }

    private static func us(_ n: String, _ s: String) -> Want { Want(cats: ["493", "58"], name: n, shown: s) }
    private static func ar(_ n: String, _ s: String) -> Want { Want(cats: ["104"], name: n, shown: s) }
    private static func usNews(_ n: String, _ s: String) -> Want { Want(cats: ["491"], name: n, shown: s) }
    private static func shia(_ n: String, _ s: String) -> Want { Want(cats: ["713"], name: n, shown: s) }

    static let packs: [Pack] = [
        Pack(key: "pk:movies", title: "🎬  US Movies & Series", wants: [
            us("HBO", "HBO"), us("HBO 2", "HBO 2"), us("HBO SIGNATURE", "HBO Signature"),
            us("HBO COMEDY", "HBO Comedy"), us("HBO FAMILY", "HBO Family"),
            us("SHOWTIME", "Showtime"), us("SHOWTIME 2", "Showtime 2"),
            us("SHOWTIME EXTREME", "Showtime Extreme"), us("SHOWTIME SHOWCASE", "Showtime Showcase"),
            us("CINEMAX", "Cinemax"), us("MOVIEMAX", "MovieMax"), us("CINEMAX THRILLERMAX", "ThrillerMax"),
            us("STARZ", "Starz"), us("STARZ CINEMA", "Starz Cinema"), us("STARZ EDGE", "Starz Edge"),
            us("STARZ COMEDY", "Starz Comedy"), us("STARZ ENCORE", "Starz Encore"),
            us("STARZ ENCORE ACTION", "Starz Encore Action"), us("EPIX", "MGM+"),
            us("THE MOVIE CHANNEL", "The Movie Channel"), us("SONY MOVIE CHANNEL", "Sony Movie Channel"),
            us("FX MOVIES", "FX Movies"), us("TCM", "TCM"), us("AMC", "AMC"), us("FX", "FX"), us("FXX", "FXX"),
            us("TNT", "TNT"), us("TBS", "TBS"), us("USA NETWORK", "USA Network"), us("SYFY", "SYFY"),
            us("PARAMOUNT", "Paramount Network"), us("A&E", "A&E"), us("IFC", "IFC"),
        ]),
        // Arabic first, then English.
        Pack(key: "pk:news", title: "📰  News", wants: [
            ar("AL JAZEERA", "Al Jazeera"), ar("AL JAZEERA MUBASHER", "Al Jazeera Mubasher"),
            ar("AL ARABIYA", "Al Arabiya"), ar("AL ARABIYA HADATH", "Al Hadath"),
            ar("SKY NEWS", "Sky News Arabia"), ar("SAUDIA ASHARQ NEWS", "Asharq News"),
            ar("BBC ARABIC", "BBC Arabic"), ar("FRANCE 24 ARABIC", "France 24 Arabic"),
            ar("AL ARABY", "Al Araby"), ar("AL MAYADEEN", "Al Mayadeen"), ar("AL ALAM NEWS TV", "Al Alam"),
            ar("AL QAHERA NEWS", "Al Qahera News"), ar("RUSIA TODAY ARABIC", "RT Arabic"),
            ar("TRT AL ARABIA", "TRT Arabic"), ar("DW ARABIC", "DW Arabic"), ar("CNBC ARABIC", "CNBC Arabia"),
            ar("AL ARABIYA BUSINESS", "Al Arabiya Business"), ar("AL GHAD AL ARABY", "Al Ghad"),
            ar("AL JAZEERA ENGLISH", "Al Jazeera English"), usNews("BBC WORLD NEWS", "BBC World News"),
            usNews("CNN", "CNN"), Want(cats: ["956"], name: "SKY NEWS", shown: "Sky News"),
            ar("FRANCE 24 ENGLISH", "France 24 English"), usNews("TRT WORLD", "TRT World"),
            ar("DW ENGLISH", "DW English"), usNews("BLOOMBERG", "Bloomberg"), usNews("CNBC", "CNBC"),
            usNews("FOX NEWS", "Fox News"), usNews("MSNBC", "MSNBC"), usNews("EURONEWS", "Euronews"),
            ar("RUSIA TODAY ENGLISH", "RT"),
        ]),
        // The religious Shia channels (the political ones in the same provider package are left out).
        Pack(key: "pk:shia", title: "🕌  Shia Channels", wants: [
            shia("KARBALA TV", "Karbala"), shia("IMAM HUSSEIN 2", "Imam Hussein 2"), shia("AL KAWTHER", "Al Kawthar"),
            shia("IMAM ALI", "Imam Ali"), shia("ALNAJAF ALASHRAF", "Al Najaf Al Ashraf"),
            shia("KARBALA AL QURAN TV", "Karbala Al Quran"), shia("AL ANWAR", "Al Anwar"),
            shia("AL MAAREF", "Al Maaref"), shia("AL ESHRAQ TV", "Al Eshraq"), shia("AL GHADEER TV", "Al Ghadeer"),
            shia("AL NAEEM", "Al Naeem"), shia("AL WILAYAH TV", "Al Wilayah"), shia("MAHDI", "Al Mahdi"),
            shia("AL QAMAR", "Al Qamar"), shia("ALSHIRAZI TV", "Al Shirazi"), shia("AL BAEENAH", "Al Baeenah"),
            shia("AL AWHAD", "Al Awhad"), shia("AL SHAAER TV", "Al Shaaer"), shia("SAOUT ALAQILA", "Sawt Al Aqila"),
            shia("AL AQILA TV", "Al Aqila"), shia("SAWT ALITRA TV", "Sawt Al Itra"), shia("ASIL TV", "Asil"),
            shia("AL JAWADAIN", "Al Jawadain"), shia("DUA CHANNEL", "Dua"), shia("AL TALEAA TV", "Al Taleaa"),
            shia("SAFEER TV", "Safeer"), Want(cats: ["7"], name: "AHLULBAYT TV EU", shown: "Ahlulbayt TV"),
        ]),
    ]

    static func title(_ key: String) -> String? { packs.first { $0.key == key }?.title }

    private static let version = 1
    // Each subscription has its own; the first one (no tag) keeps the old place.
    private static var ud: UserDefaults { UserDefaults(suiteName: "fire.curated" + (Api.account?.tag ?? "")) ?? .standard }

    // The saved lists, by pack key.
    static func saved() -> [String: [Item]] {
        var out: [String: [Item]] = [:]
        for p in packs {
            if let d = ud.data(forKey: p.key), let l = try? JSONDecoder().decode([Item].self, from: d), !l.isEmpty { out[p.key] = l }
        }
        return out
    }

    static func clear() {
        let d = ud
        for k in d.dictionaryRepresentation().keys { d.removeObject(forKey: k) }
    }

    // HD first, then FHD, unmarked, 4K/UHD, and SD/LQ last.
    private static func rank(_ name: String) -> Int {
        let u = name.uppercased()
        func has(_ p: String) -> Bool { u.range(of: p, options: .regularExpression) != nil }
        if has("\\bSD\\b|\\bLQ\\b") { return 4 }
        if has("\\bUHD\\b|\\b4K\\b|3840P") { return 3 }
        if has("ᴴᴰ|\\bHD\\b") { return 0 }
        if u.contains("FHD") { return 1 }
        return 2
    }

    // Twice a day; between times (or with no answer) the saved lists.
    static func refresh() async -> [String: [Item]] {
        let now = Date().timeIntervalSince1970
        let had = saved()
        if now - ud.double(forKey: "at") < 12 * HOUR && ud.integer(forKey: "v") == version && !had.isEmpty { return had }
        var cats: [String: [Item]] = [:]
        var out: [String: [Item]] = [:]
        for p in packs {
            var list: [Item] = []
            for w in p.wants {
                var pool: [Item] = []
                for c in w.cats {
                    if cats[c] == nil {
                        cats[c] = await Store.load(Q.streams(.live, Cat(id: c, name: "")), ttl: 6 * HOUR) { parseItems(.live, $0) } ?? []
                    }
                    pool += cats[c] ?? []
                }
                let rx = "^(?:" + NSRegularExpression.escapedPattern(for: w.name) + ")$"
                let best = pool.filter { !$0.name.contains("##") && Matches.label($0.name).uppercased().range(of: rx, options: .regularExpression) != nil }
                    .min { rank($0.name) < rank($1.name) }
                if let best { list.append(Item(kind: .live, sid: best.sid, name: w.shown, icon: best.icon, ext: best.ext)) }
            }
            if !list.isEmpty { out[p.key] = list }
            if Task.isCancelled { return had }
        }
        guard !out.isEmpty else { return had }
        let d = ud
        for (k, l) in out { d.set(try? JSONEncoder().encode(l), forKey: k) }
        d.set(now, forKey: "at")
        d.set(version, forKey: "v")
        return out
    }
}
