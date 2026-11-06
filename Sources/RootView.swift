import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var live = BrowseModel(.live)
    @StateObject private var movies = BrowseModel(.movie)
    @StateObject private var series = BrowseModel(.series)
    @State private var tab = Kind.live
    @State private var settings = false
    @State private var subscriptions = false
    @Environment(\.scenePhase) private var phase

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
                    case .package(let r): PackageView(ref: r)
                    }
                }
            }
            .environment(\.metrics, m)
        }
        .fullScreenCover(item: $app.playing) { req in
            PlayerView(request: req)
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $subscriptions) {
            NavigationStack {
                SubscriptionsList()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { subscriptions = false } } }
            }
        }
        .task {
            Sports.shared.refresh()
            app.expiry = await Store.load("", ttl: 6 * HOUR, parseExpiry)
        }
        // Back in the app: the match rows look again (a match may have come into the window).
        .onChange(of: phase) { p in if p == .active { Sports.shared.refresh() } }
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
                        .lineLimit(1)
                        .fixedSize()
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
        let account = Button { subscriptions = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.fill").font(.system(size: 14))
                Text(app.account?.name ?? "").font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.85))
            // As wide as the name needs, so the tabs beside it keep their room.
            .frame(height: 40)
            .padding(.horizontal, 12)
            .frame(maxWidth: 150)
            .fixedSize()
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image("Logo").resizable().scaledToFit().frame(height: m.compact ? 24 : 28)
                if !m.compact, let e = app.expiry, !e.isEmpty {
                    // The first to give way on a phone on its side.
                    Text("Expires \(e)").font(.footnote).foregroundColor(.soft).lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if !m.compact { tabs }
                account
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
        if kind == .live, let cats { AppState.liveCats = cats }
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
        if kind == .live, let f = Library.shared.favList(.live).first(where: { !$0.name.contains("##") }) {
            await setHero(f)
            return
        }
        guard hero == nil, let first = cats?.first else { return }
        let k = kind
        // Names like "##### beIN SPORTS SD #####" only divide a package; they play nothing.
        if let items = await Store.load(Q.streams(k, first), ttl: 6 * HOUR, { parseItems(k, $0) }),
           let it = items.first(where: { !$0.name.contains("##") }) {
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
    @EnvironmentObject private var sports: Sports
    @State private var packages = false
    @State private var unhide = false
    @ObservedObject private var hidden = Hidden.shared
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
                    HStack(spacing: 10) {
                        searchField
                        packagesButton
                        if model.kind == .live { refreshButton }
                        if !hidden.list(model.kind).isEmpty { unhideButton }
                    }
                    .padding(.horizontal, m.pad)
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
        .alert("No Wi-Fi", isPresented: Binding(get: { model.kind == .live && sports.notice != nil },
                                                set: { if !$0 { sports.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sports.notice ?? "")
        }
        .sheet(isPresented: $packages) {
            PackagesSheet(kind: model.kind, rows: rows) { r in app.path.append(.package(r)) }
        }
        .sheet(isPresented: $unhide) { UnhideSheet(kind: model.kind) }
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
    }

    // Packages: every row of this tab in a list to search and open.
    private var packagesButton: some View {
        Button { packages = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                if !m.compact { Text("Packages") }
            }
            .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
            .padding(.horizontal, m.compact ? 0 : 18)
            .frame(minWidth: 48, minHeight: 48)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(rows.isEmpty)
    }

    // Live: drops finished matches and looks for channels again; it spins while the search runs.
    private var refreshButton: some View {
        Button { sports.refresh(force: true) } label: {
            HStack(spacing: 8) {
                if sports.busy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                if !m.compact { Text("Refresh") }
            }
            .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
            .padding(.horizontal, m.compact ? 0 : 18)
            .frame(minWidth: 48, minHeight: 48)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh matches")
    }

    // Hidden packages of this tab: the eye with their number; opens the list to bring them back.
    private var unhideButton: some View {
        Button { unhide = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                Text("\(hidden.list(model.kind).count)")
            }
            .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hidden packages")
    }

    private func shows(_ key: String) -> Bool { !hidden.isHidden(model.kind, key) }

    // The server's packages less the hidden ones.
    private var shownCats: [Cat]? { model.cats.map { $0.filter { shows("c:" + $0.id) } } }

    private func ref(_ key: String, _ title: String) -> PackageRef { PackageRef(kind: model.kind, key: key, title: title) }

    // Every row of the tab, in the order they show.
    private var rows: [PackageRef] {
        var out: [PackageRef] = []
        if model.kind == .live {
            out += sports.shown.map { ref("m:" + $0.id, Sports.title($0.game)) }
            if !sports.big.isEmpty && shows("big") { out.append(ref("big", Self.bigTitle)) }
            for p in Curated.packs where !(sports.curated[p.key] ?? []).isEmpty && shows(p.key) { out.append(ref(p.key, p.title)) }
            if !sports.football.isEmpty { out.append(ref("football", Self.footballTitle)) }
            if !lib.recent.isEmpty { out.append(ref("recent", "Recent Channels")) }
        } else if !lib.watchList(model.kind).isEmpty {
            out.append(ref("cw", "Continue Watching"))
        }
        if !lib.favList(model.kind).isEmpty { out.append(ref("fav", model.kind == .live ? "Favorite Channels" : "My List")) }
        out += (shownCats ?? []).map { ref("c:" + $0.id, $0.name) }
        return out
    }

    static let bigTitle = "⚽  Big Leagues"
    static let footballTitle = "⚽  LaLiga  ·  Copa del Rey  ·  Champions League"

    private func openRow(_ key: String, _ title: String) { app.path.append(.package(ref(key, title))) }

    // A row of channels made here (matches, Big Leagues…): its own channels beside the picture.
    @ViewBuilder
    private func channelRail(_ title: String, _ list: [Item], all key: String? = nil, recent: Bool = false) -> some View {
        RailShell(title: title) {
            if let key {
                AllCard(count: list.count, style: .logo).onTapGesture { openRow(key, title) }
                    .contextMenu { if Hidden.hideable(key) { HideButton(kind: model.kind, key: key, title: title) } }
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, it in
                Card(item: it, style: .logo)
                    .onTapGesture { app.open(it, rail: list, cats: [], cat: nil) }
                    .contextMenu {
                        if recent {
                            Button(role: .destructive) { lib.removeRecent(it.sid) } label: {
                                Label("Remove from Recent Channels", systemImage: "xmark")
                            }
                        }
                        FavButton(item: it)
                    }
            }
        }
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
                            .onTapGesture { app.open(it, rail: r, cats: [], cat: nil, queue: true) }
                    }
                }
                .padding(.horizontal, m.pad)
            }
        }
    }

    @ViewBuilder
    private var rails: some View {
        if model.kind == .live {
            // The big teams' matches from a day and a half before kickoff until full time.
            ForEach(sports.shown) { r in channelRail(Sports.title(r.game), r.channels) }
            if !sports.big.isEmpty && shows("big") { channelRail(Self.bigTitle, sports.big, all: "big") }
            // The hand-picked packages: US films & series, news, Shia channels.
            ForEach(Curated.packs, id: \.key) { p in
                if let list = sports.curated[p.key], !list.isEmpty, shows(p.key) { channelRail(p.title, list, all: p.key) }
            }
            if !sports.football.isEmpty { channelRail(Self.footballTitle, sports.football) }
            if !lib.recent.isEmpty {
                SelectableRail(title: "Recent Channels", elements: lib.recent, idOf: { $0.sid }, itemOf: { $0 },
                               style: .logo, allKey: nil, showFav: true, removeTitle: "Remove from Recent Channels",
                               onOpen: { app.open($0, rail: lib.recent, cats: [], cat: nil) },
                               onRemove: { lib.removeRecent($0) }, onOpenAll: nil)
            }
        }
        if model.kind != .live {
            let cw = lib.watchList(model.kind)
            if !cw.isEmpty {
                SelectableRail(title: "Continue Watching", elements: cw, idOf: { $0.id }, itemOf: { $0.item },
                               style: .wide, allKey: ("cw", "Continue Watching"), showFav: false,
                               removeTitle: "Remove from Continue Watching",
                               onOpen: { app.resumeWatch($0) },
                               onRemove: { id in if let w = cw.first(where: { $0.id == id }) { lib.removeWatching(w.kind, w.id) } },
                               onOpenAll: { openRow($0, $1) })
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
        if let cats = shownCats {
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

// A row where a long press starts picking several cards to delete at once (Continue Watching,
// Recent Channels). Long press a card → Select Multiple; tap to tick, Select All, Delete together.
struct SelectableRail<T>: View {
    let title: String
    let elements: [T]
    let idOf: (T) -> Int
    let itemOf: (T) -> Item
    let style: Card.Style
    // (key, title) for the All card at the front, or nil for none.
    let allKey: (String, String)?
    var showFav = false
    let removeTitle: String
    let onOpen: (T) -> Void
    let onRemove: (Int) -> Void
    let onOpenAll: ((String, String) -> Void)?

    @EnvironmentObject private var lib: Library
    @Environment(\.metrics) private var m
    @State private var selecting = false
    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text(title).font(.system(size: m.compact ? 18 : 21, weight: .bold)).lineLimit(1)
                Spacer()
                if selecting {
                    Button(selected.count == elements.count ? "Clear All" : "Select All") {
                        selected = selected.count == elements.count ? [] : Set(elements.map(idOf))
                    }
                    Button(role: .destructive) {
                        for id in selected { onRemove(id) }
                        selecting = false
                        selected = []
                    } label: { Text("Delete (\(selected.count))") }
                        .disabled(selected.isEmpty)
                    Button("Done") { selecting = false; selected = [] }
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, m.pad)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: m.gap) {
                    if !selecting, let a = allKey {
                        AllCard(count: elements.count, style: style).onTapGesture { onOpenAll?(a.0, a.1) }
                    }
                    ForEach(elements.indices, id: \.self) { i in
                        let e = elements[i]
                        let eid = idOf(e)
                        Card(item: itemOf(e), style: style)
                            .overlay(alignment: .topLeading) {
                                if selecting {
                                    let on = selected.contains(eid)
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 24)).foregroundColor(on ? .fire : .white)
                                        .padding(8).shadow(color: .black.opacity(0.6), radius: 3)
                                }
                            }
                            .onTapGesture {
                                if selecting {
                                    if selected.contains(eid) { selected.remove(eid) } else { selected.insert(eid) }
                                } else {
                                    onOpen(e)
                                }
                            }
                            .contextMenu {
                                if !selecting {
                                    Button(role: .destructive) { onRemove(eid) } label: {
                                        Label(removeTitle, systemImage: "xmark")
                                    }
                                    Button { selecting = true; selected = [eid] } label: {
                                        Label("Select Multiple", systemImage: "checkmark.circle")
                                    }
                                    if showFav { FavButton(item: itemOf(e)) }
                                }
                            }
                    }
                }
                .padding(.horizontal, m.pad)
            }
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
                    AllCard(count: items.count, style: kind == .live ? .logo : .poster)
                        .onTapGesture { app.path.append(.package(PackageRef(kind: kind, key: "c:" + cat.id, title: cat.name))) }
                        .contextMenu { HideButton(kind: kind, key: "c:" + cat.id, title: cat.name) }
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

// Long press on a package's All card: take the package off this tab (Unhide brings it back).
struct HideButton: View {
    let kind: Kind
    let key: String
    let title: String
    var body: some View {
        Button(role: .destructive) {
            Hidden.shared.hide(kind, [PackageRef(kind: kind, key: key, title: title)])
        } label: {
            Label("Hide this package", systemImage: "eye.slash")
        }
    }
}
