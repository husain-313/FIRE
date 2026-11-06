import SwiftUI

// A row of a tab opened whole as a grid: a package from the server ("c:<id>"), or one of the rows
// above them (Continue Watching, My List, Recent Channels, Big Leagues, a match…).
struct PackageRef: Hashable {
    let kind: Kind
    let key: String
    let title: String

    var catId: String? { key.hasPrefix("c:") ? String(key.dropFirst(2)) : nil }
    var isWatching: Bool { key == "cw" }
}

// The first card of a row: opens everything in it as a grid.
struct AllCard: View {
    let count: Int?
    let style: Card.Style
    @Environment(\.metrics) private var m

    var body: some View {
        let size: CGSize = {
            switch style {
            case .poster: return CGSize(width: m.poster, height: m.posterH)
            case .logo: return CGSize(width: m.logo, height: m.logoH)
            case .wide: return CGSize(width: m.wide * 0.5, height: m.wideH)
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 24)).foregroundColor(.fire)
                Text("All").font(.system(size: m.compact ? 15 : 17, weight: .heavy))
                if let count { Text("\(count)").font(.footnote.weight(.semibold)).foregroundColor(.soft) }
            }
            .frame(width: size.width, height: size.height)
            .background(Color.fire.opacity(0.12), in: RoundedRectangle(cornerRadius: style == .logo ? 12 : 10))
            .overlay(RoundedRectangle(cornerRadius: style == .logo ? 12 : 10).stroke(Color.fire.opacity(0.45), lineWidth: 1))
            // The same title line as the cards beside it, so the row lines up.
            if style != .wide { Text(" ").font(.system(size: m.compact ? 12 : 14)) }
        }
        .contentShape(Rectangle())
    }
}

// Everything in one row, as a grid, with a search field that narrows it.
struct PackageView: View {
    let ref: PackageRef
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var lib: Library
    @EnvironmentObject private var sports: Sports
    @Environment(\.metrics) private var m
    @State private var loaded: [Item]?
    @State private var failed = false
    @State private var query = ""
    @FocusState private var focused: Bool

    private var all: [Item]? {
        if ref.catId != nil { return loaded }
        switch ref.key {
        case "cw": return lib.watchList(ref.kind).map(\.item)
        case "fav": return lib.favList(ref.kind)
        case "recent": return lib.recent
        case "big": return sports.big
        case "football": return sports.football
        case let k where k.hasPrefix("pk:"): return sports.curated[k] ?? []
        default: return sports.shown.first { "m:" + $0.id == ref.key }?.channels ?? []
        }
    }

    // Every word typed must be in the title.
    private var shown: [Item] {
        let words = Search.norm(query).split(separator: " ").map(String.init)
        let list = all ?? []
        if words.isEmpty { return list }
        return list.filter { i in
            let n = Search.norm(i.name)
            return words.allSatisfy { n.contains($0) }
        }
    }

    private var style: Card.Style { ref.isWatching ? .wide : ref.kind == .live ? .logo : .poster }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                searchField
                if let all {
                    let list = shown
                    Text("\(ref.title)  ·  \(list.count)").font(.title3.bold()).lineLimit(2)
                    if list.isEmpty {
                        Text(all.isEmpty ? "Nothing here" : "No results").foregroundColor(.soft)
                            .frame(maxWidth: .infinity).padding(.vertical, 50)
                    } else {
                        grid(list)
                    }
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(failed ? "Can't reach the server right now." : "Loading…").foregroundColor(.soft)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                }
            }
            .padding(.horizontal, m.pad)
            .padding(.top, 8).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.bg.ignoresSafeArea())
        .navigationTitle(ref.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let id = ref.catId, loaded == nil else { return }
            let k = ref.kind
            loaded = await Store.load(Q.streams(k, Cat(id: id, name: ref.title)), ttl: 6 * HOUR) { parseItems(k, $0) }
            failed = loaded == nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(.soft)
            TextField("Search in \(ref.title)…", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = ""; focused = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.soft)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: 46)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(focused ? Color.fire : Color.white.opacity(0.12), lineWidth: focused ? 2 : 1))
    }

    private func grid(_ list: [Item]) -> some View {
        let w: CGFloat = style == .wide ? m.wide * 0.8 : style == .logo ? m.logo : m.poster
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: w, maximum: w * 1.35), spacing: m.gap, alignment: .top)], spacing: m.gap + 6) {
            ForEach(Array(list.enumerated()), id: \.offset) { i, it in
                Card(item: it, style: style, flexible: true)
                    .onTapGesture { open(it, list) }
                    .contextMenu { menu(it) }
            }
        }
    }

    private func open(_ it: Item, _ list: [Item]) {
        if ref.isWatching, let w = lib.watch(it.kind, it.sid) {
            app.resumeWatch(w)
            return
        }
        // A package keeps the other packages beside it in the channel guide.
        let cats = AppState.liveCats
        let ci = ref.catId.flatMap { id in cats.firstIndex { $0.id == id } }
        // From an open package the player's Next goes through the films shown.
        app.open(it, rail: list, cats: ci == nil ? [] : cats, cat: ci, queue: true)
    }

    @ViewBuilder
    private func menu(_ it: Item) -> some View {
        if ref.isWatching {
            Button(role: .destructive) { lib.removeWatching(it.kind, it.sid) } label: {
                Label("Remove from Continue Watching", systemImage: "xmark")
            }
        } else {
            if ref.key == "recent" {
                Button(role: .destructive) { lib.removeRecent(it.sid) } label: {
                    Label("Remove from Recent Channels", systemImage: "xmark")
                }
            }
            FavButton(item: it)
        }
    }
}

// Packages: every row of the tab in a list, narrowed by the field above it; a tap opens that row
// whole. Select: tick packages (or Select All) and Hide them from the tab together.
struct PackagesSheet: View {
    let kind: Kind
    let rows: [PackageRef]
    let pick: (PackageRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var confirm = false

    private var shown: [PackageRef] {
        let words = Search.norm(query).split(separator: " ").map(String.init)
        if words.isEmpty { return rows }
        return rows.filter { r in
            let n = Search.norm(r.title)
            return words.allSatisfy { n.contains($0) }
        }
    }

    // Only packages can be hidden (not Continue Watching, favourites, matches…).
    private var hideable: [PackageRef] { shown.filter { Hidden.hideable($0.key) } }

    var body: some View {
        NavigationStack {
            List {
                if selecting && !hideable.isEmpty {
                    let every = hideable.allSatisfy { picked.contains($0.key) }
                    Button(every ? "Select None" : "Select All") {
                        if every { picked.subtract(hideable.map(\.key)) } else { picked.formUnion(hideable.map(\.key)) }
                    }
                }
                ForEach(shown, id: \.key) { r in
                    let can = Hidden.hideable(r.key)
                    Button {
                        if selecting {
                            guard can else { return }
                            if picked.contains(r.key) { picked.remove(r.key) } else { picked.insert(r.key) }
                        } else {
                            dismiss()
                            pick(r)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if selecting {
                                Image(systemName: picked.contains(r.key) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22)).foregroundColor(picked.contains(r.key) ? .fire : .soft)
                                    .opacity(can ? 1 : 0.25)
                            }
                            Text(r.title).foregroundColor(.white).lineLimit(2)
                            Spacer()
                            if !selecting {
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.soft)
                            }
                        }
                    }
                    .contextMenu {
                        if can && !selecting {
                            HideButton(kind: kind, key: r.key, title: r.title)
                            Button { selecting = true; picked = [r.key] } label: {
                                Label("Select Multiple", systemImage: "checkmark.circle")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty { Text("No packages found").foregroundColor(.soft) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search packages…")
            .navigationTitle(selecting ? "Selected · \(picked.count)" : "Packages · \(shown.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selecting {
                        Button("Cancel") { selecting = false; picked = [] }
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if selecting {
                        Button("Hide (\(picked.count))") { confirm = true }.disabled(picked.isEmpty)
                    } else {
                        Button("Select") { selecting = true; picked = [] }
                    }
                }
            }
            .confirmationDialog("Hide \(picked.count) packages from this tab?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Hide", role: .destructive) {
                    Hidden.shared.hide(kind, rows.filter { picked.contains($0.key) })
                    selecting = false
                    picked = []
                    dismiss()
                }
            } message: {
                Text("They come back with the eye button next to the search field.")
            }
        }
    }
}
