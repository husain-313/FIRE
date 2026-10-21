import Foundation

// Search runs over a small index of every name, built once a day from the full lists. The
// full list is downloaded to a file and read object by object, so it never sits in memory.
actor Search {
    static let shared = Search()
    private static let limit = 300

    private struct Entry { let norm: String; let item: Item; let arabic: Bool; let quality: Int }

    private var index: [Kind: [Entry]] = [:]
    private var building: [Kind: Task<Bool, Never>] = [:]

    private static func file(_ k: Kind) -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("idx_\(k.rawValue)_\(Store.hash(Api.account?.user ?? "")).tsv")
    }

    static func norm(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.lowercased() {
            switch ch {
            case "أ", "إ", "آ", "ٱ": out.append("ا")
            case "ة": out.append("ه")
            case "ى": out.append("ي")
            case "\t", "\n", "\r": out.append(" ")
            case "ـ": break
            default:
                if let u = ch.unicodeScalars.first, (0x064B...0x0652).contains(u.value) { break }
                out.append(ch)
            }
        }
        return out
    }

    // True when the list has to be fetched first (the first search of the day can take a minute).
    func needsBuild(_ k: Kind) -> Bool {
        index[k] == nil && !FileManager.default.fileExists(atPath: Search.file(k).path)
    }

    // nil when the list could not be had.
    func query(_ k: Kind, _ text: String) async -> [Item]? {
        guard await ready(k), let list = index[k] else { return nil }
        let words = Search.norm(text).split(separator: " ").map(String.init)
        guard let first = words.first else { return [] }
        var found: [(Int, Item)] = []
        for e in list where words.allSatisfy({ e.norm.contains($0) }) {
            let rank = (e.arabic ? 0 : 100) + e.quality * 2 + (Search.wordStart(e.norm, first) ? 0 : 1)
            found.append((rank, e.item))
            if found.count >= 3000 { break }
        }
        return found.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            .prefix(Search.limit).map { $0.element.1 }
    }

    // Builds the index ahead of the first search, on Wi-Fi only; skipped when it is still fresh.
    func prewarm(_ k: Kind) {
        let f = Search.file(k)
        let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        if let age, age < DAY { return }
        _ = build(k, wifiOnly: true)
    }

    func reset() {
        index = [:]
        for k in Kind.allCases { try? FileManager.default.removeItem(at: Search.file(k)) }
    }

    private func ready(_ k: Kind) async -> Bool {
        let f = Search.file(k)
        let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        if index[k] == nil, age != nil { index[k] = await Task.detached { Search.read(k, f) }.value }
        if index[k] != nil {
            // A day-old index still answers; a fresh one is built quietly behind it.
            if let age, age > DAY { _ = build(k) }
            return true
        }
        // A Wi-Fi-only build running ahead fails on mobile data; then the search fetches it itself.
        var ok = await build(k).value
        if !ok { ok = await build(k).value }
        return ok && index[k] != nil
    }

    private func build(_ k: Kind, wifiOnly: Bool = false) -> Task<Bool, Never> {
        if let t = building[k] { return t }
        let t = Task<Bool, Never> {
            let f = Search.file(k)
            guard let tmp = try? await Api.download(Q.all(k), wifiOnly: wifiOnly) else {
                self.building[k] = nil
                return false
            }
            let entries: [Entry]? = await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let d = try? Data(contentsOf: tmp, options: .alwaysMapped) else { return nil }
                var out = ""
                eachObject(in: d) { o in
                    guard let it = item(k, o) else { return }
                    let name = it.name.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                    out += "\(it.sid)\t\(name)\t\(it.icon ?? "")\t\(it.ext ?? "")\n"
                }
                guard !out.isEmpty, (try? out.write(to: f, atomically: true, encoding: .utf8)) != nil else { return nil }
                return Search.read(k, f)
            }.value
            if let entries { self.index[k] = entries }
            self.building[k] = nil
            return entries != nil
        }
        building[k] = t
        return t
    }

    private static func read(_ k: Kind, _ f: URL) -> [Entry]? {
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        var out: [Entry] = []
        s.enumerateLines { line, _ in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard p.count >= 4, let id = Int(p[0]) else { return }
            let name = String(p[1])
            let it = Item(kind: k, sid: id, name: name, icon: p[2].isEmpty ? nil : String(p[2]), ext: p[3].isEmpty ? nil : String(p[3]))
            let n = norm(name)
            out.append(Entry(norm: n, item: it, arabic: isArabic(n), quality: quality(n)))
        }
        return out
    }

    private static func wordStart(_ s: String, _ w: String) -> Bool {
        var from = s.startIndex
        while let r = s.range(of: w, range: from..<s.endIndex) {
            if r.lowerBound == s.startIndex { return true }
            let prev = s[s.index(before: r.lowerBound)]
            if !prev.isLetter && !prev.isNumber { return true }
            from = s.index(after: r.lowerBound)
        }
        return false
    }

    private static let qualityRes = ["8k|4320p?", "4k|uhd|2160p?|3840p?", "2k|1440p?", "fhd|1080p?", "hd|720p?", "sd|lq|480p?"]
        .map { try! NSRegularExpression(pattern: "(^|[^a-z0-9])(\($0))([^a-z0-9]|$)") }

    // Sharpest first: 8K, 4K, 2K, FHD, HD, unmarked, SD.
    private static func quality(_ n: String) -> Int {
        guard let i = qualityRes.firstIndex(where: { CatSort.has($0, n) }) else { return 5 }
        return i == 5 ? 6 : i
    }

    private static let arTag = try! NSRegularExpression(pattern: "(^|[^a-z])(ar|ara|arab|arabic|ksa|uae|gcc|kuwait|qatar|saudi|egypt|iraq|syria|lebanon|jordan|oman|bahrain|gulf|khaleej|mbc|rotana|osn|shahid)([^a-z]|$)")

    private static let arPrefix: Set<String> = ["ar", "ara", "arab", "arabic", "ksa", "uae", "gcc", "kw", "kuwait", "qa", "sa", "eg", "iq", "sy", "lb",
                                                "jo", "om", "bh", "ye", "ma", "dz", "tn", "ly", "ps", "sd", "mbc", "osn", "bein"]
    private static let otherLang: Set<String> = ["en", "de", "fr", "gr", "ir", "fa", "al", "es", "pt", "nl", "sc", "se", "in", "tr", "it", "ru", "pl", "ro",
                                                 "ph", "ku", "bg", "il", "la", "so", "ur", "pk", "cn", "jp", "kr", "us", "uk"]

    // A provider prefix decides when there is one: "AR-SUBS - …", "4K-AR - …", "AR: …" are Arabic,
    // "KU-S - Avatar" is Kurdish even though Kurdish (like Persian) uses Arabic letters.
    private static func isArabic(_ n: String) -> Bool {
        if let r = n.range(of: " - "), (1...16).contains(n.distance(from: n.startIndex, to: r.lowerBound)) {
            let tags = n[..<r.lowerBound].split { "- |:".contains($0) }.map(String.init)
            if tags.contains(where: { arPrefix.contains($0) }) { return true }
            if tags.contains(where: { otherLang.contains($0) }) { return false }
        }
        if let c = n.firstIndex(where: { $0 == ":" || $0 == "|" }), (1...8).contains(n.distance(from: n.startIndex, to: c)) {
            return arPrefix.contains(n[..<c].trimmingCharacters(in: .whitespaces))
        }
        if n.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return true }
        return CatSort.has(arTag, String(n.prefix(12)))
    }
}
