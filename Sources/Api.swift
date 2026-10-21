import Foundation
import Security

// The Xtream account, typed in once on the sign-in screen and kept in the Keychain.
struct Account: Codable, Equatable {
    var server: String
    var user: String
    var pass: String

    private static let key = "fire.account"

    static func load() -> Account? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Account.self, from: d)
    }

    func save() {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: Account.key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = try? JSONEncoder().encode(self)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
    }

    // "103.211.100.215" or "http://host:8080/" both become "http://host[:port]".
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

    static func data(_ query: String, account a: Account? = account, timeout: TimeInterval = 30) async throws -> Data {
        guard let u = apiURL(query, account: a) else { throw ApiError.noAccount }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        let (d, resp) = try await session.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
        return d
    }

    // Big lists (the whole film list is ~75 MB) go straight to a file.
    static func download(_ query: String) async throws -> URL {
        guard let u = apiURL(query) else { throw ApiError.noAccount }
        var r = URLRequest(url: u)
        r.timeoutInterval = 120
        let (f, resp) = try await session.download(for: r)
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
