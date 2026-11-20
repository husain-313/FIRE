import Foundation

// Recently Added on the Movies and Series tabs (the same as FIRE on the TV, its 6.8 and 6.11): what
// the server added last, newest first (for series, the last change, so a series with a new
// episode moves up too). Taken from the full list while Search builds its index (one download
// does both), so only the newest few hundred are ever held. Titles marked for another language
// ("IN - …", "NO - …", "IR - …") and adult ones are left out; Arabic, Arabic-subtitled, dubbed and
// English titles stay. Kept per subscription; read again twice a day.
enum NewList {
    static let title = "🆕  Recently Added"
    private static let keep = 60

    static func file(_ k: Kind) -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("new_\(k.rawValue)_\(Store.hash(Api.account?.user ?? "")).json")
    }

    // The saved list (empty before the first read).
    static func saved(_ k: Kind) -> [Item] {
        guard k != .live, let d = try? Data(contentsOf: file(k)) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: d)) ?? []
    }

    // Missing, or older than half a day.
    static func stale(_ k: Kind) -> Bool {
        guard k != .live else { return false }
        let at = (try? file(k).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return at.map { Date().timeIntervalSince($0) > 12 * HOUR } ?? true
    }

    private static let adult = try! NSRegularExpression(pattern: #"(^|[^a-z])(xxx|adult|18\+)([^a-z]|$)"#, options: .caseInsensitive)

    // Language tags that keep a title out even when its name has Arabic letters (Persian "IR - …"
    // series carry a Persian title too). "EN" stays; any "AR" or dub tag lets the title in.
    private static let foreign: Set<String> = ["de", "fr", "gr", "ir", "fa", "al", "es", "pt", "nl", "sc", "se", "in", "tr", "it",
        "ru", "pl", "ro", "ph", "ku", "bg", "il", "la", "so", "ur", "pk", "cn", "jp", "kr", "us", "uk", "no", "dk", "fi", "is"]

    private static func split(_ n: String) -> (tags: [String], title: Substring) {
        if let r = n.range(of: " - "), (1...16).contains(n.distance(from: n.startIndex, to: r.lowerBound)) {
            return (n[..<r.lowerBound].lowercased().split { "- |:".contains($0) }.map(String.init), n[r.upperBound...])
        }
        return ([], Substring(n))
    }

    private static func isForeign(_ n: String) -> Bool {
        let t = split(n).tags
        return !t.contains("ar") && !t.contains { $0.hasPrefix("dub") } && t.contains { foreign.contains($0) }
    }

    private static func is4k(_ n: String) -> Bool { split(n).tags.contains { $0 == "4k" || $0 == "uhd" } }

    // Gets every title of the list; keeps the newest few hundred that pass, then one copy each.
    final class Collector {
        private let kind: Kind
        private var kept: [Item] = []
        private var floor = 0

        init(_ k: Kind) { kind = k }

        func add(_ i: Item) {
            guard let at = i.added, at > floor, !i.name.isEmpty else { return }
            if Search.vodRank(Search.norm(i.name)) == 4 || NewList.isForeign(i.name) { return }
            let head = String(i.name.prefix(12))
            if NewList.adult.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil { return }
            kept.append(i)
            // Cut back to the newest 400 now and then; anything older than the cut can't get in.
            if kept.count >= 2000 { trim() }
        }

        private func trim() {
            kept.sort { ($0.added ?? 0) > ($1.added ?? 0) }
            if kept.count > 400 { kept.removeLast(kept.count - 400) }
            if kept.count == 400 { floor = kept.last?.added ?? 0 }
        }

        func save() {
            trim()
            // The same title often comes in several copies ("4K-AR - X", "AR-EG - X"); keep one,
            // the lighter one when there is a choice (4K is heavy).
            var order: [String] = []
            var picked: [String: Item] = [:]
            for i in kept {
                let k = Search.norm(String(NewList.split(i.name).title)).trimmingCharacters(in: .whitespaces)
                if let had = picked[k] {
                    if NewList.is4k(had.name) && !NewList.is4k(i.name) {
                        var n = i
                        n.added = had.added
                        n.icon = i.icon ?? had.icon
                        n.backdrop = i.backdrop ?? had.backdrop
                        n.plot = i.plot ?? had.plot
                        n.meta = i.meta ?? had.meta
                        picked[k] = n
                    }
                } else {
                    picked[k] = i
                    order.append(k)
                }
            }
            let out = order.prefix(NewList.keep).compactMap { picked[$0] }
            if let d = try? JSONEncoder().encode(out) { try? d.write(to: NewList.file(kind), options: .atomic) }
        }
    }

    // The adult package lists its titles exactly newest first (its own order is only roughly so;
    // TV 6.9). Every other package keeps the server's order.
    private static let adultPkg = try! NSRegularExpression(pattern: #"(^|[^A-Z])(ADULTS?|XXX|18[+])([^A-Z]|$)"#, options: .caseInsensitive)

    static func order(_ k: Kind, _ title: String, _ items: [Item]) -> [Item] {
        guard k != .live, adultPkg.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil else { return items }
        return items.sorted { ($0.added ?? 0) > ($1.added ?? 0) }
    }
}
