import Foundation
import Security

// A subscription. All of them are typed in on this device and kept in the Keychain. Each has its own
// favourites, Continue Watching and match rows; the first one (id "") keeps the old storage, so
// nothing saved before this list existed is lost.
struct Account: Codable, Equatable, Identifiable {
    var id = ""
    var name = "FIRE"
    var server: String
    var user: String
    var pass: String
    // Other links of the same subscription, tried in order when [server] stops answering; the
    // one that answers becomes [server].
    var backups: [String] = []

    private enum CodingKeys: String, CodingKey { case id, name, server, user, pass, backups }

    init(id: String = "", name: String = "FIRE", server: String, user: String, pass: String, backups: [String] = []) {
        self.id = id
        self.name = name
        self.server = server
        self.user = user
        self.pass = pass
        self.backups = backups
    }

    // The provider's Strong links as of 2026-11-06 (fastest first, as the TV app has them). The
    // first subscription (id "") falls back to them after its own links, so it carries on when
    // its server is retired without anything typed in.
    static let builtIn = [
        "http://cf.xrtyqp.xyz",
        "http://cf.qwctyr.xyz",
        "http://cf.tenvax.xyz",
        "http://magic47.xyz",
    ]

    // [server] first, then the backups (then the built-in links for the first subscription), each once.
    var servers: [String] {
        var seen = Set<String>()
        return ([server] + backups + (id.isEmpty ? Account.builtIn : [])).filter { seen.insert($0).inserted }
    }

    // The same subscription on another of its links; the old one goes to the backups.
    func on(_ host: String) -> Account {
        var a = self
        a.backups = servers.filter { $0 != host }
        a.server = host
        return a
    }

    // The account saved by older versions has no id or name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "FIRE"
        server = try c.decode(String.self, forKey: .server)
        user = try c.decode(String.self, forKey: .user)
        pass = try c.decode(String.self, forKey: .pass)
        backups = try c.decodeIfPresent([String].self, forKey: .backups) ?? []
    }

    // Added to the name of everything stored for this subscription.
    var tag: String { id.isEmpty ? "" : "." + id }

    private static let oldKey = "fire.account"
    private static let listKey = "fire.accounts"
    private static let currentKey = "fire.currentAccount"

    private static func read(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ list: [Account]) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: listKey]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = try? JSONEncoder().encode(list)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static var list: [Account] {
        if let d = read(listKey), let l = try? JSONDecoder().decode([Account].self, from: d) { return l }
        // First run after an update: the one old account becomes the first of the list.
        guard let d = read(oldKey), let a = try? JSONDecoder().decode(Account.self, from: d) else { return [] }
        write([a])
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: oldKey] as CFDictionary)
        return [a]
    }

    static func load() -> Account? {
        let l = list
        let id = UserDefaults.standard.string(forKey: currentKey) ?? ""
        return l.first { $0.id == id } ?? l.first
    }

    static func setCurrent(_ a: Account) { UserDefaults.standard.set(a.id, forKey: currentKey) }

    static func put(_ a: Account) {
        var l = list
        if let i = l.firstIndex(where: { $0.id == a.id }) { l[i] = a } else { l.append(a) }
        write(l)
    }

    static func remove(_ a: Account) {
        write(list.filter { $0.id != a.id })
        if !a.id.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: "fire.acc" + a.tag)
            UserDefaults.standard.removePersistentDomain(forName: "fire.matches" + a.tag)
        }
    }

    // "host:port", "http://host:port/" or a whole M3U link all give "http://host:port".
    // An M3U link also brings its user name and password.
    static func parse(_ text: String) -> (server: String, user: String?, pass: String?)? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let c = URLComponents(string: s), let host = c.host, !host.isEmpty,
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let port = c.port.map { ":\($0)" } ?? ""
        func item(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        return ("\(scheme)://\(host)\(port)", item("username"), item("password"))
    }

    // Backup links typed one per line (or with spaces or commas between them), each as "http://host[:port]".
    static func links(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ", \n\t")).compactMap { parse($0)?.server }
    }

    // "example.com" or "http://host:8080/" both become "http://host[:port]".
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "http://" + t }
        return t
    }
}

enum ApiError: Error { case noAccount, http(Int), bad }

enum Api {
    static let ua = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) Fire/1.0"
    static var account: Account? = Account.load()

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 600
        c.httpAdditionalHeaders = ["User-Agent": ua]
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    static func apiURL(_ query: String, account a: Account? = account) -> URL? {
        guard let a else { return nil }
        return URL(string: "\(a.server)/player_api.php?username=\(enc(a.user))&password=\(enc(a.pass))\(query)")
    }

    private static func stream(_ path: String, _ id: Int, _ ext: String) -> URL? {
        guard let a = account else { return nil }
        return URL(string: "\(a.server)/\(path)/\(enc(a.user))/\(enc(a.pass))/\(id).\(ext)")
    }

    // A stream link made on an older link of the subscription, moved to the server in use now.
    static func rehost(_ u: URL) -> URL {
        guard let a = account else { return u }
        let s = u.absoluteString
        for h in a.servers where h != a.server && s.hasPrefix(h + "/") {
            return URL(string: a.server + s.dropFirst(h.count)) ?? u
        }
        return u
    }

    static func live(_ id: Int) -> URL? { stream("live", id, "ts") }
    static func movie(_ id: Int, _ ext: String?) -> URL? { stream("movie", id, ext ?? "mp4") }
    static func episode(_ id: Int, _ ext: String?) -> URL? { stream("series", id, ext ?? "mp4") }

    static func data(_ query: String, account a: Account? = account, timeout: TimeInterval = 30, wifiOnly: Bool = false) async throws -> Data {
        guard let a else { throw ApiError.noAccount }
        return try await failover(a) { b -> Data in
            guard let u = apiURL(query, account: b) else { throw ApiError.noAccount }
            var r = URLRequest(url: u)
            r.timeoutInterval = timeout
            let (d, resp) = try await (wifiOnly ? wifiSession : session).data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
            return d
        }
    }

    // Runs [work] on the account's server, then on each backup link in turn when it can't be
    // reached. A backup that answers for the account in use becomes its server (kept in the
    // Keychain), so channels and films follow it. A cancelled request isn't a dead server.
    static func failover<T>(_ a: Account, _ work: (Account) async throws -> T) async throws -> T {
        var first: Error?
        for h in a.servers {
            let b = a.on(h)
            do {
                let v = try await work(b)
                if h != a.server { switchTo(b) }
                return v
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                if first == nil { first = error }
            }
        }
        throw first ?? ApiError.bad
    }

    private static let lock = NSLock()

    private static func switchTo(_ b: Account) {
        lock.lock()
        defer { lock.unlock() }
        guard let cur = account, cur.id == b.id, cur.server != b.server else { return }
        account = b
        Account.put(b)
    }

    // Called by the player when a stream keeps failing: finds a link of the account that
    // answers now (it becomes the server). True when the server changed.
    static func recheck() async -> Bool {
        guard let a = account, a.servers.count > 1 else { return false }
        _ = try? await data("", timeout: 10)
        return account?.server != a.server
    }

    // Background fetches that must not spend mobile data or Low Data Mode.
    static let wifiSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 600
        c.httpAdditionalHeaders = ["User-Agent": ua]
        c.urlCache = nil
        c.allowsExpensiveNetworkAccess = false
        c.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: c)
    }()

    // Big lists (the whole film list is ~75 MB) go straight to a file.
    static func download(_ query: String, wifiOnly: Bool = false) async throws -> URL {
        guard let a = account else { throw ApiError.noAccount }
        let f = try await failover(a) { b -> URL in
            guard let u = apiURL(query, account: b) else { throw ApiError.noAccount }
            var r = URLRequest(url: u)
            r.timeoutInterval = 120
            let (f, resp) = try await (wifiOnly ? wifiSession : session).download(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
            return f
        }
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.moveItem(at: f, to: mine)
        return mine
    }

    // Signs in on the first link of [a] that answers: nil and the account on that link when the
    // server knows it and it is active, otherwise the problem.
    static func check(_ a: Account) async -> (problem: String?, account: Account) {
        var last = "Can't reach the server. Check the address and your connection."
        for h in a.servers {
            let b = a.on(h)
            let p = await checkOne(b)
            if p == nil { return (nil, b) }
            last = p!
            // Wrong details or an ended account are the same on every link.
            if p!.hasPrefix("Wrong") || p!.hasPrefix("This account") { break }
        }
        return (last, a)
    }

    private static func checkOne(_ a: Account) async -> String? {
        do {
            guard let url = apiURL("", account: a) else { return "No account." }
            var r = URLRequest(url: url)
            r.timeoutInterval = 20
            let (d, resp) = try await session.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
            guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let u = o["user_info"] as? [String: Any] else { return "The server answered, but not like an IPTV server." }
            if int(u["auth"]) != 1 { return "Wrong username or password." }
            if let s = str(u["status"]), s.lowercased() != "active" { return "This account is \(s.lowercased())." }
            return nil
        } catch {
            return "Can't reach the server. Check the address and your connection."
        }
    }
}
