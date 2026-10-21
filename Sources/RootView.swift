import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var live = BrowseModel(.live)
    @StateObject private var movies = BrowseModel(.movie)
    @StateObject private var series = BrowseModel(.series)
    @State private var tab = Kind.live
    @State private var settings = false

    var body: some View {
        GeometryReader { g in
            let m = Metrics(width: g.size.width)
            NavigationStack(path: $app.path) {
                ZStack(alignment: .top) {
                    Color.bg.ignoresSafeArea()
                    // All three stay alive so switching tabs keeps their place and loads nothing.
                    ForEach(Kind.allCases, id: \.self) { k in
                        BrowseView(model: model(k), top: headerHeight(m))
                            .opacity(tab == k ? 1 : 0)
                            .allowsHitTesting(tab == k)
                            .accessibilityHidden(tab != k)
                    }
                    header(m)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { r in
                    switch r {
                    case .movie(let it): MovieView(item: it)
                    case .series(let it): SeriesView(item: it)
                    }
                }
            }
            .environment(\.metrics, m)
        }
        .fullScreenCover(item: $app.playing) { req in
            PlayerView(request: req)
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .task {
            app.expiry = await Store.load("", ttl: 6 * HOUR, parseExpiry)
        }
    }

    private func model(_ k: Kind) -> BrowseModel {
        switch k {
        case .live: return live
        case .movie: return movies
        case .series: return series
        }
    }

    private func headerHeight(_ m: Metrics) -> CGFloat { m.compact ? 104 : 64 }

    @ViewBuilder
    private func header(_ m: Metrics) -> some View {
        let tabs = HStack(spacing: m.compact ? 6 : 10) {
            ForEach(Kind.allCases, id: \.self) { k in
                Button {
                    if tab == k { model(k).scrollTop += 1 } else { tab = k }
                } label: {
                    Text(["Live", "Movies", "Series"][k.rawValue])
                        .font(.system(size: m.compact ? 15 : 17, weight: .semibold))
                        .foregroundColor(tab == k ? .fire : .white.opacity(0.85))
                        .padding(.horizontal, m.compact ? 14 : 18).padding(.vertical, 8)
                        .frame(maxWidth: m.compact ? .infinity : nil)
                        .background(tab == k ? Color.fire.opacity(0.16) : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        let gear = Button { settings = true } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 18)).foregroundColor(.white.opacity(0.85))
                .frame(width: 40, height: 40).background(Color.white.opacity(0.08), in: Circle())
        }
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image("Logo").resizable().scaledToFit().frame(height: m.compact ? 24 : 28)
                if !m.compact, let e = app.expiry, !e.isEmpty {
                    Text("Expires \(e)").font(.footnote).foregroundColor(.soft)
                }
                Spacer()
                if !m.compact { tabs }
                gear
            }
            if m.compact { tabs }
        }
        .padding(.horizontal, m.pad)
        .padding(.top, 6).padding(.bottom, 8)
        // Solid, so rows scrolling under it never mix with the tabs; a short fade below it.
        .background(
            Color.bg.opacity(0.97)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Color.bg.opacity(0.97), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14).offset(y: 14)
                }
                .ignoresSafeArea(edges: .top)
        )
    }
}

// One tab: its packages, the search inside it, and the featured title at the top.
@MainActor
final class BrowseModel: ObservableObject {
    let kind: Kind
    @Published var cats: [Cat]?
    @Published var failed = false
    @Published var query = "" { didSet { if query != oldValue { searchSoon() } } }
    @Published var results: [Item]?
    @Published var searching = false
    @Published var preparing = false
    @Published var hero: Item?
    @Published var heroInfo: Info?
    @Published var heroNow: (Prog?, Prog?) = (nil, nil)
    @Published var scrollTop = 0
    private var searchTask: Task<Void, Never>?
    private var started = false

    init(_ k: Kind) { kind = k }

    func start() {
        guard !started else { return }
        started = true
        Task { await load() }
    }

    private func load() async {
        failed = false
        guard let c = await Store.load(Q.cats(kind), ttl: 6 * HOUR, parseCats) else {
            failed = true
            // The server often comes back within seconds; keep trying while nothing is shown.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if cats == nil { await load() }
            return
        }
        cats = CatSort.sort(c, live: kind == .live)
        await pickHero()
        // Get search ready before it is needed (on Wi-Fi), a little after the rows have loaded.
        let k = kind
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: UInt64(8 + k.rawValue * 20) * 1_000_000_000)
            await Search.shared.prewarm(k)
        }
    }

    // The newest thing left part way, else the first title of the first package.
    func pickHero() async {
        if kind != .live, let w = Library.shared.watchList(kind).first {
            await setHero(w.item)
            return
        }
        if kind == .live, let f = Library.shared.favList(.live).first {
            await setHero(f)
            return
        }
        guard hero == nil, let first = cats?.first else { return }
        let k = kind
        if let items = await Store.load(Q.streams(k, first), ttl: 6 * HOUR, { parseItems(k, $0) }), let it = items.first {
            await setHero(it)
        }
    }

    private func setHero(_ it: Item) async {
        if hero?.id == it.id { return }
        hero = it
        heroInfo = nil
        heroNow = (nil, nil)
        switch kind {
        case .movie:
            heroInfo = await Store.load("&action=get_vod_info&vod_id=\(it.sid)", ttl: DAY, parseVodInfo)
        case .series:
            heroInfo = Info(backdrop: it.backdrop ?? it.icon, poster: it.icon, plot: it.plot, meta: it.meta ?? "")
        case .live:
            heroNow = Epg.nowNext(await Epg.shared.get(it.sid))
        }
    }

    private func searchSoon() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = nil; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            if await Search.shared.needsBuild(kind) { preparing = true }
            let r = await Search.shared.query(kind, q)
            if Task.isCancelled { return }
            preparing = false
            searching = false
            results = r ?? []
            if r == nil { failed = true }
        }
    }
}

struct BrowseView: View {
    @ObservedObject var model: BrowseModel
    let top: CGFloat
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var lib: Library
    @Environment(\.metrics) private var m
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: m.compact ? 18 : 26) {
                    Color.clear.frame(height: 0).id("top")
                    if model.results == nil && !model.searching {
                        HeroView(model: model).padding(.bottom, -6)
                    } else {
                        Color.clear.frame(height: top + 8)
                    }
                    searchField
                    if model.query.trimmingCharacters(in: .whitespaces).count >= 2 {
                        results
                    } else {
                        rails
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: model.scrollTop) { _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
        }
        .onAppear { model.start() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(.soft)
            TextField(["Search channels…", "Search movies…", "Search series…"][model.kind.rawValue], text: $model.query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !model.query.isEmpty {
                Button { model.query = ""; searchFocused = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.soft)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: 48)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(searchFocused ? Color.fire : Color.white.opacity(0.12), lineWidth: searchFocused ? 2 : 1))
        .padding(.horizontal, m.pad)
    }

    @ViewBuilder
    private var results: some View {
        if model.searching || model.results == nil {
            status(model.preparing ? "Preparing search… the first search of the day takes a minute." : "Searching…", spinner: true)
        } else if let r = model.results, r.isEmpty {
            status(model.failed ? "Can't reach the server right now." : "Nothing found.")
        } else if let r = model.results {
            VStack(alignment: .leading, spacing: 10) {
                Text("Results · \(r.count)").font(.title3.bold()).padding(.horizontal, m.pad)
                let w = model.kind == .live ? m.logo : m.poster
                LazyVGrid(columns: [GridItem(.adaptive(minimum: w, maximum: w * 1.3), spacing: m.gap, alignment: .top)], spacing: m.gap + 6) {
                    ForEach(r) { it in
                        Card(item: it, style: model.kind == .live ? .logo : .poster, flexible: true)
                            .onTapGesture { app.open(it, rail: r, cats: [], cat: nil) }
                    }
                }
                .padding(.horizontal, m.pad)
            }
        }
    }

    @ViewBuilder
    private var rails: some View {
        if model.kind != .live {
            let cw = lib.watchList(model.kind)
            if !cw.isEmpty {
                RailShell(title: "Continue Watching") {
                    ForEach(cw, id: \.self) { w in
                        Card(item: w.item, style: .wide)
                            .onTapGesture { app.resumeWatch(w) }
                            .contextMenu {
                                Button(role: .destructive) { lib.removeWatching(w.kind, w.id) } label: {
                                    Label("Remove from Continue Watching", systemImage: "xmark")
                                }
                            }
                    }
                }
            }
        }
        let favs = lib.favList(model.kind)
        if !favs.isEmpty {
            RailShell(title: model.kind == .live ? "Favorite Channels" : "My List") {
                ForEach(favs) { it in
                    Card(item: it, style: model.kind == .live ? .logo : .poster)
                        .onTapGesture { app.open(it, rail: favs, cats: [], cat: nil) }
                        .contextMenu { FavButton(item: it) }
                }
            }
        }
        if let cats = model.cats {
            ForEach(Array(cats.enumerated()), id: \.element.id) { i, c in
                CatRail(kind: model.kind, cat: c, index: i, cats: cats)
            }
        } else {
            status(model.failed ? "The server isn't answering. Trying again…" : "Loading…", spinner: true)
        }
    }

    private func status(_ text: String, spinner: Bool = false) -> some View {
        HStack(spacing: 12) {
            if spinner { ProgressView() }
            Text(text).foregroundColor(.soft)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }
}

struct FavButton: View {
    let item: Item
    @EnvironmentObject private var lib: Library
    var body: some View {
        let on = lib.isFav(item)
        Button { lib.toggleFav(item) } label: {
            Label(on ? (item.kind == .live ? "Remove from Favorites" : "Remove from My List") : (item.kind == .live ? "Add to Favorites" : "Add to My List"),
                  systemImage: on ? "minus.circle" : "plus.circle")
        }
    }
}

// A titled row that scrolls sideways.
struct RailShell<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: m.compact ? 18 : 21, weight: .bold)).lineLimit(1).padding(.horizontal, m.pad)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: m.gap) { content }
                    .padding(.horizontal, m.pad)
            }
        }
    }
}

// A package's row; its titles load when the row first comes on screen.
struct CatRail: View {
    let kind: Kind
    let cat: Cat
    let index: Int
    let cats: [Cat]
    @EnvironmentObject private var app: AppState
    @Environment(\.metrics) private var m
    @State private var items: [Item]?

    var body: some View {
        RailShell(title: cat.name) {
            if let items {
                if items.isEmpty {
                    Text("Empty").foregroundColor(.soft).frame(height: 60)
                } else {
                    ForEach(items) { it in
                        Card(item: it, style: kind == .live ? .logo : .poster)
                            .onTapGesture { app.open(it, rail: items, cats: cats, cat: index) }
                            .contextMenu { FavButton(item: it) }
                    }
                }
            } else {
                ForEach(0..<8, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10).fill(Color.card)
                        .frame(width: kind == .live ? m.logo : m.poster, height: kind == .live ? m.logoH : m.posterH)
                }
            }
        }
        .task {
            if items == nil {
                items = await Store.load(Q.streams(kind, cat), ttl: 6 * HOUR) { parseItems(kind, $0) } ?? []
            }
        }
    }
}
