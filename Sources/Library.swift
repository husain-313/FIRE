import Foundation

// A film or series left part way, for the Continue Watching row. For a series it is the
// episode watched last (epId, ext and epLabel belong to that episode).
struct Watch: Codable, Hashable {
    var kind: Kind
    var id: Int
    var name: String
    var icon: String?
    var ext: String?
    var epId: Int = 0
    var epLabel: String? = nil
    var pos: Double = 0
    var dur: Double = 0
    var time: Date = Date()
    // Wide picture for the card: the episode's still, or the series' backdrop.
    var backdrop: String? = nil

    var item: Item {
        var it = Item(kind: kind, sid: id, name: name, icon: icon, ext: ext)
        it.backdrop = backdrop
        if dur > 0 { it.progress = pos / dur }
        let left = dur > 0 ? duration(dur - pos) + " left" : nil
        let sub = [epLabel, left].compactMap { $0 }.joined(separator: "  ·  ")
        it.sub = sub.isEmpty ? nil : sub
        return it
    }
}

// Favourites, Continue Watching and where each film or episode was left, saved on the device.
final class Library: ObservableObject {
    static let shared = Library()
    private let ud = UserDefaults.standard

    @Published private(set) var favs: [Item] = []
    @Published private(set) var watching: [Watch] = []

    private init() {
        if let d = ud.data(forKey: "favs"), let v = try? JSONDecoder().decode([Item].self, from: d) { favs = v }
        if let d = ud.data(forKey: "watching"), let v = try? JSONDecoder().decode([Watch].self, from: d) { watching = v }
    }

    // MARK: Favourites (newest first)

    func favList(_ k: Kind) -> [Item] { favs.filter { $0.kind == k } }

    func isFav(_ i: Item) -> Bool { favs.contains { $0.kind == i.kind && $0.sid == i.sid } }

    func toggleFav(_ i: Item) {
        if isFav(i) {
            favs.removeAll { $0.kind == i.kind && $0.sid == i.sid }
        } else {
            var plain = i
            plain.progress = nil
            plain.sub = nil
            favs.insert(plain, at: 0)
        }
        if let d = try? JSONEncoder().encode(favs) { ud.set(d, forKey: "favs") }
    }

    // MARK: Continue Watching (newest first)

    func watchList(_ k: Kind) -> [Watch] { watching.filter { $0.kind == k }.sorted { $0.time > $1.time } }

    func watch(_ k: Kind, _ id: Int) -> Watch? { watching.first { $0.kind == k && $0.id == id } }

    // Kept while part way; dropped once finished (or barely started).
    func update(_ w: Watch, pos: Double, dur: Double) {
        guard dur > 0 else { return }
        if pos > 60 && pos < dur - 120 {
            var n = w
            n.pos = pos
            n.dur = dur
            n.time = Date()
            watching.removeAll { $0.kind == w.kind && $0.id == w.id }
            watching.insert(n, at: 0)
        } else if pos >= dur - 120 {
            watching.removeAll { $0.kind == w.kind && $0.id == w.id }
        } else { return }
        saveWatching()
    }

    func removeWatching(_ k: Kind, _ id: Int) {
        if let w = watch(k, id) { clearResume(w.epId != 0 ? "e:\(w.epId)" : "m:\(w.id)") }
        watching.removeAll { $0.kind == k && $0.id == id }
        saveWatching()
    }

    private func saveWatching() {
        if let d = try? JSONEncoder().encode(watching) { ud.set(d, forKey: "watching") }
    }

    // MARK: Resume points ("m:<film id>", "e:<episode id>"), in seconds

    func resume(_ key: String) -> Double { ud.double(forKey: "r:" + key) }

    // Also keeps the length (for progress bars) and remembers what was watched to the end.
    func saveResume(_ key: String, pos: Double, dur: Double) {
        guard dur > 0 else { return }
        if pos > 60 && pos < dur - 120 {
            ud.set(pos, forKey: "r:" + key)
            ud.set(dur, forKey: "d:" + key)
        } else if pos >= dur - 120 {
            clearResume(key)
            ud.set(true, forKey: "done:" + key)
        } else {
            clearResume(key)
        }
        objectWillChange.send()
    }

    // 0...1, nil when not started.
    func progress(_ key: String) -> Double? {
        let p = ud.double(forKey: "r:" + key), d = ud.double(forKey: "d:" + key)
        return p > 0 && d > 0 ? p / d : nil
    }

    func done(_ key: String) -> Bool { ud.bool(forKey: "done:" + key) }

    func clearResume(_ key: String) {
        ud.removeObject(forKey: "r:" + key)
        ud.removeObject(forKey: "d:" + key)
    }
}

// Now / next for live channels; hundreds of small answers, kept apart from Store.
actor Epg {
    static let shared = Epg()
    private var cache: [Int: (Date, [Prog])] = [:]
    private var waiting: [Int: Task<[Prog], Never>] = [:]

    func get(_ id: Int) async -> [Prog] {
        if let c = cache[id], Date().timeIntervalSince(c.0) < 600 { return c.1 }
        if let t = waiting[id] { return await t.value }
        let t = Task<[Prog], Never> {
            guard let d = try? await Api.data("&action=get_short_epg&stream_id=\(id)&limit=3", timeout: 15) else { return [] }
            return parseEpg(d)
        }
        waiting[id] = t
        let list = await t.value
        waiting[id] = nil
        if cache.count > 800 { cache.removeAll() }
        cache[id] = (Date(), list)
        return list
    }

    // The programme on now, then the one after it.
    static func nowNext(_ list: [Prog]) -> (Prog?, Prog?) {
        let now = Date()
        let i = list.firstIndex { $0.start <= now && $0.end > now } ?? list.firstIndex { $0.end > now }
        guard let i else { return (nil, nil) }
        return (list[i], i + 1 < list.count ? list[i + 1] : nil)
    }
}
