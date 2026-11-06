import SwiftUI

@main
struct FireApp: App {
    @StateObject private var app = AppState()

    init() {
        Task.detached(priority: .background) { Store.trim() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if app.account != nil {
                    RootView().id((app.account?.id ?? "") + "/" + (app.account?.user ?? ""))
                } else {
                    LoginView()
                }
            }
            .environmentObject(app)
            .environmentObject(Library.shared)
            .environmentObject(Sports.shared)
            .preferredColorScheme(.dark)
            .tint(.fire)
        }
    }
}

enum Route: Hashable {
    case movie(Item)
    case series(Item)
    case package(PackageRef)
}

struct PlayRequest: Identifiable {
    enum Mode {
        case vod(url: URL, title: String, sub: String?, key: String, watch: Watch?)
        // [cats] and [cat] fill the channel guide; search results and favourites stand alone.
        case live(channels: [Item], index: Int, cats: [Cat], cat: Int?)
    }

    let id = UUID()
    let mode: Mode
    // The films this one was picked from (an open package or a search), for the player's Next.
    var movies: [Item] = []
}

final class AppState: ObservableObject {
    @Published var account: Account? = Api.account
    @Published var path: [Route] = []
    @Published var playing: PlayRequest?
    @Published var expiry: String?
    // The Live packages in the order the tab shows them, for the channel guide.
    static var liveCats: [Cat] = []

    // The films around the one just opened, when it came from a package or a search.
    private var movieQueue: [Item] = []

    // The sign-in screen: the first subscription keeps the old storage, so it gets no id.
    func signIn(_ a: Account) {
        var n = a
        if !Account.list.isEmpty {
            n.id = String(UUID().uuidString.prefix(8)).lowercased()
            n.name = URLComponents(string: a.server)?.host ?? a.server
        }
        Account.put(n)
        use(n)
    }

    // Everything that belongs to the old subscription goes from memory; RootView starts afresh.
    func use(_ a: Account) {
        Account.setCurrent(a)
        Api.account = a
        activate()
        account = a
    }

    func delete(_ a: Account) {
        let inUse = a.id == account?.id
        Account.remove(a)
        guard inUse else { return }
        if let next = Account.list.first {
            use(next)
        } else {
            Api.account = nil
            activate()
            account = nil
        }
    }

    private func activate() {
        Store.forgetMemory()
        Task { await Search.shared.forgetMemory() }
        Library.shared.reload()
        Hidden.shared.reload()
        Sports.shared.reload()
        path = []
        playing = nil
        expiry = nil
        movieQueue = []
    }

    func playMovie(_ it: Item) {
        let w = Library.shared.watch(.movie, it.sid) ?? Watch(kind: .movie, id: it.sid, name: it.name, icon: it.icon, ext: it.ext, backdrop: it.backdrop)
        guard let u = Api.movie(it.sid, it.ext) else { return }
        let around = movieQueue.contains { $0.sid == it.sid } ? movieQueue : []
        playing = PlayRequest(mode: .vod(url: u, title: cleanTitle(it.name), sub: nil, key: "m:\(it.sid)", watch: w), movies: around)
    }

    func playEpisode(series: Item, ep: Item, season: String, backdrop: String?) {
        guard let u = Api.episode(ep.sid, ep.ext) else { return }
        let label = "S\(season) E\(ep.num ?? "?")"
        let w = Watch(kind: .series, id: series.sid, name: series.name, icon: series.icon, ext: ep.ext, epId: ep.sid,
                      epLabel: label, backdrop: ep.icon ?? backdrop ?? series.backdrop)
        playing = PlayRequest(mode: .vod(url: u, title: cleanTitle(series.name), sub: [label, ep.name].filter { !$0.isEmpty }.joined(separator: "  •  "),
                                         key: "e:\(ep.sid)", watch: w))
    }

    // From Continue Watching a series carries straight on with its episode.
    func resumeWatch(_ w: Watch) {
        movieQueue = []
        if w.kind == .series, w.epId != 0, let u = Api.episode(w.epId, w.ext) {
            playing = PlayRequest(mode: .vod(url: u, title: cleanTitle(w.name), sub: w.epLabel, key: "e:\(w.epId)", watch: w))
        } else if w.kind == .movie {
            playMovie(Item(kind: .movie, sid: w.id, name: w.name, icon: w.icon, ext: w.ext, backdrop: w.backdrop))
        } else {
            path.append(.series(Item(kind: .series, sid: w.id, name: w.name, icon: w.icon, ext: nil, backdrop: w.backdrop)))
        }
    }

    // [queue]: the rail is an open package or a search, so a film's Next goes on through it.
    func open(_ it: Item, rail: [Item], cats: [Cat], cat: Int?, queue: Bool = false) {
        movieQueue = queue && it.kind == .movie ? rail : []
        switch it.kind {
        case .live:
            let i = rail.firstIndex { $0.sid == it.sid } ?? 0
            playing = PlayRequest(mode: .live(channels: rail.isEmpty ? [it] : rail, index: i, cats: cats, cat: cat))
        case .movie: path.append(.movie(it))
        case .series: path.append(.series(it))
        }
    }
}

struct LoginView: View {
    @EnvironmentObject private var app: AppState
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Image("Logo").resizable().scaledToFit().frame(height: 52).padding(.bottom, 12)
                    Text("Sign in with your IPTV account").font(.headline).foregroundColor(.soft)
                    VStack(spacing: 12) {
                        field("Server, e.g. http://example.com:8080", text: $server, keyboard: .URL)
                        field("Username", text: $user)
                        SecureField("Password", text: $pass)
                            .textContentType(.password)
                            .padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let error { Text(error).font(.subheadline).foregroundColor(.red.opacity(0.9)).multilineTextAlignment(.center) }
                    Button(action: signIn) {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "Signing in…" : "Sign In").bold()
                        }
                        .frame(maxWidth: .infinity).padding(14)
                        .background(Color.fire, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.white)
                    }
                    .disabled(busy || user.isEmpty || pass.isEmpty || server.isEmpty)
                    Text("Your account stays on this device only.").font(.footnote).foregroundColor(.soft)
                }
                .frame(maxWidth: 420)
                .padding(24)
                .padding(.top, 60)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func signIn() {
        let a = Account(server: Account.normalize(server), user: user.trimmingCharacters(in: .whitespaces), pass: pass.trimmingCharacters(in: .whitespaces))
        busy = true
        error = nil
        Task {
            let r = await Api.check(a)
            await MainActor.run {
                busy = false
                if let e = r.problem { error = e } else { app.signIn(r.account) }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Server", value: Api.account?.server ?? app.account?.server ?? "")
                    LabeledContent("Username", value: app.account?.user ?? "")
                    if let e = app.expiry, !e.isEmpty { LabeledContent("Expires", value: e) }
                    NavigationLink("Subscriptions") { SubscriptionsList() }
                }
                Section {
                    UpdateRow()
                } header: {
                    Text("App · Version \(Updater.version)")
                } footer: {
                    Text("Downloads the new Fire.ipa. Then open it with your signing app to install it; your account and progress stay.")
                }
                Section {
                    Button(cleared ? "Lists and pictures cleared" : "Refresh all lists") {
                        Store.clear()
                        Images.clear()
                        Task { await Search.shared.reset() }
                        Sports.shared.clear()
                        Sports.shared.refresh()
                        cleared = true
                    }
                    .disabled(cleared)
                } footer: {
                    Text("Channels, films, series and posters are kept on this device so they open at once. This clears them all and loads them fresh.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
