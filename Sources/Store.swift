import CryptoKit
import Foundation

let HOUR: TimeInterval = 3600
let DAY: TimeInterval = 24 * HOUR

// API answers kept on disk (and the parsed result in memory), so lists open at once and the
// app still works for a while when the server is briefly down.
enum Store {
    private final class Box { let value: Any; let time: Date; init(_ v: Any, _ t: Date) { value = v; time = t } }

    private static let mem: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 120
        return c
    }()

    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("store")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func hash(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func file(_ query: String) -> URL {
        dir.appendingPathComponent(hash((Api.account?.server ?? "") + (Api.account?.user ?? "") + query))
    }

    static func cached<T>(_ query: String) -> T? {
        mem.object(forKey: query as NSString)?.value as? T
    }

    // A fresh copy from memory or disk when younger than [ttl]; otherwise the server, falling
    // back to an older copy when the server can't be reached.
    static func load<T>(_ query: String, ttl: TimeInterval, _ parse: @escaping (Data) -> T?) async -> T? {
        if let b = mem.object(forKey: query as NSString), Date().timeIntervalSince(b.time) < ttl, let v = b.value as? T { return v }
        let f = file(query)
        let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        if let age, age < ttl, let v: T = await parsed(f, parse) {
            mem.setObject(Box(v, Date().addingTimeInterval(-age)), forKey: query as NSString)
            return v
        }
        for attempt in 0..<2 {
            do {
                let d = try await Api.data(query)
                if let v = await Task.detached(priority: .userInitiated, operation: { parse(d) }).value {
                    try? d.write(to: f, options: .atomic)
                    mem.setObject(Box(v, Date()), forKey: query as NSString)
                    return v
                }
            } catch {
                if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            }
        }
        if age != nil, let v: T = await parsed(f, parse) { return v }
        return nil
    }

    private static func parsed<T>(_ f: URL, _ parse: @escaping (Data) -> T?) async -> T? {
        await Task.detached(priority: .userInitiated) {
            guard let d = try? Data(contentsOf: f) else { return nil }
            return parse(d)
        }.value
    }

    static func clear() {
        mem.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

enum Q {
    static func cats(_ k: Kind) -> String {
        "&action=" + ["get_live_categories", "get_vod_categories", "get_series_categories"][k.rawValue]
    }

    static func all(_ k: Kind) -> String {
        "&action=" + ["get_live_streams", "get_vod_streams", "get_series"][k.rawValue]
    }

    static func streams(_ k: Kind, _ c: Cat) -> String { all(k) + "&category_id=" + c.id }
}

// Puts Arabic categories first; for live TV, Arabic sports before them and other sports after.
enum CatSort {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static let arabicLetters = re("[\\u0600-\\u06FF]")
    private static let arabicTag = re("(^|[^A-Z])(AR|ARA|ARAB|ARABIC|ARABE|MENA|KSA|UAE|GCC|KUWAIT|QATAR|SAUDI|EGYPT|IRAQ|SYRIA|LEBANON|JORDAN|MOROCCO|ALGERIA|TUNISIA|LIBYA|OMAN|BAHRAIN|YEMEN|PALESTINE|SUDAN|GULF|KHALEEJ|MAGHREB|SHAHID|OSN|MBC|ROTANA)([^A-Z]|$)")
    private static let sport = re("SPORT|BEIN|SSC|KASS|DAZN|ESPN|SKY ?SP|FOOT|SOCCER|FUTBOL|LIGA|LIGUE|LEAGUE|PREMIER|SERIE A|BUNDES|CHAMPIONS|UEFA|FIFA|NBA|NFL|NHL|MLB|UFC|WWE|BOXING|F1|FORMULA|MOTOGP|TENNIS|GOLF|CRICKET|RUGBY|MATCH|رياض|كورة|مباريات|دوري")
    // beIN and others also run entertainment and on-demand packages; those are not sport.
    private static let notSport = re("ENTERTAIN|MOVIE|CINEMA|DRAMA|KIDS|DOCU|NEWS|MUSIC|(^|[^A-Z])OD([^A-Z]|$)|ترفيه")
    // Persian and Urdu are written in Arabic letters too.
    private static let notArabic = re("(^|[^A-Z])(IR|PERSIAN|FARSI|IRAN|AFGHAN|PK|PAK|PAKISTAN|URDU)([^A-Z]|$)")

    static func has(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func sort(_ list: [Cat], live: Bool) -> [Cat] {
        list.enumerated().map { (rank($0.element.name, live), $0.offset, $0.element) }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { $0.2 }
    }

    private static func rank(_ name: String, _ live: Bool) -> Int {
        let up = name.uppercased()
        let arabic = (has(arabicLetters, name) || has(arabicTag, up)) && !has(notArabic, up)
        if !live { return arabic ? 0 : 1 }
        // The provider marks its sport packages with a football.
        let sp = name.contains("⚽") || (has(sport, up) && !has(notSport, up))
        switch (arabic, sp) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return 2
        default: return 3
        }
    }
}
