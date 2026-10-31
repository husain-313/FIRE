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

    private enum CodingKeys: String, CodingKey { case id, name, server, user, pass }

    init(id: String = "", name: String = "FIRE", server: String, user: String, pass: String) {
        self.id = id
        self.name = name
        self.server = server
        self.user = user
        self.pass = pass
    }

    // The account saved by older versions has no id or name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "FIRE"
        server = try c.decode(String.self, forKey: .server)
        user = try c.decode(String.self, forKey: .user)
        pass = try c.decode(String.self, forKey: .pass)
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

    static func live(_ id: Int) -> URL? { stream("live", id, "ts") }
    static func movie(_ id: Int, _ ext: String?) -> URL? { stream("movie", id, ext ?? "mp4") }
    static func episode(_ id: Int, _ ext: String?) -> URL? { stream("series", id, ext ?? "mp4") }

    static func data(_ query: String, account a: Account? = account, timeout: TimeInterval = 30, wifiOnly: Bool = false) async throws -> Data {
        guard let u = apiURL(query, account: a) else { throw ApiError.noAccount }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        let (d, resp) = try await (wifiOnly ? wifiSession : session).data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
        return d
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
        guard let u = apiURL(query) else { throw ApiError.noAccount }
        var r = URLRequest(url: u)
        r.timeoutInterval = 120
        let (f, resp) = try await (wifiOnly ? wifiSession : session).download(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.moveItem(at: f, to: mine)
        return mine
    }

    // Signs in: true when the server knows this account and it is active.
    static func check(_ a: Account) async -> String? {
        do {
            let d = try await data("", account: a, timeout: 20)
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
