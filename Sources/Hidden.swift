import SwiftUI

// Packages taken off a tab (the same as FIRE on the TV, its 5.1-6.7): a server package ("c:<id>"),
// a hand-picked one ("pk:…") or Big Leagues ("big"). Kept per tab and per subscription; Unhide
// brings them back.
final class Hidden: ObservableObject {
    static let shared = Hidden()

    struct Entry: Codable, Hashable {
        let id: String      // "<kind>|<key>"
        let title: String
    }

    @Published private(set) var all: [Entry] = [] { didSet { ids = Set(all.map(\.id)) } }
    // The same ids as a set: with hundreds hidden, a lookup per package per redraw froze the TV (6.4).
    private var ids: Set<String> = []
    // Live only: the tab shows just the matches and the hand-picked rows, none of the server's
    // packages; those all stay in the Packages list (TV 6.7). The hidden list is kept for All.
    @Published var mineOnly = false { didSet { if mineOnly != oldValue { ud.set(mineOnly, forKey: "mine_only") } } }
    private var ud = Hidden.defaults()

    private init() { load() }

    private static func defaults() -> UserDefaults {
        guard let tag = Api.account?.tag, !tag.isEmpty else { return .standard }
        return UserDefaults(suiteName: "fire.acc" + tag) ?? .standard
    }

    private func load() {
        all = ud.data(forKey: "hidden").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        mineOnly = ud.bool(forKey: "mine_only")
    }

    // Another subscription came into use.
    func reload() {
        ud = Hidden.defaults()
        load()
    }

    static func hideable(_ key: String) -> Bool { key.hasPrefix("c:") || key.hasPrefix("pk:") || key == "big" }

    private static func id(_ k: Kind, _ key: String) -> String { "\(k.rawValue)|\(key)" }

    func isHidden(_ k: Kind, _ key: String) -> Bool { ids.contains(Hidden.id(k, key)) }

    func list(_ k: Kind) -> [Entry] { all.filter { $0.id.hasPrefix("\(k.rawValue)|") } }

    func hide(_ k: Kind, _ rows: [PackageRef]) {
        let add = rows.filter { Hidden.hideable($0.key) && !isHidden(k, $0.key) }.map { Entry(id: Hidden.id(k, $0.key), title: $0.title) }
        guard !add.isEmpty else { return }
        all += add
        save()
    }

    func unhide(_ ids: Set<String>) {
        all.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(all) { ud.set(d, forKey: "hidden") }
    }
}

// Hidden packages of one tab: tick some (or Select All) and Unhide.
struct UnhideSheet: View {
    let kind: Kind
    @ObservedObject private var hidden = Hidden.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []

    var body: some View {
        let list = hidden.list(kind)
        NavigationStack {
            List {
                if list.count > 1 {
                    Button(picked.count == list.count ? "Select None" : "Select All") {
                        picked = picked.count == list.count ? [] : Set(list.map(\.id))
                    }
                }
                ForEach(list, id: \.id) { e in
                    Button {
                        if picked.contains(e.id) { picked.remove(e.id) } else { picked.insert(e.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: picked.contains(e.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22)).foregroundColor(picked.contains(e.id) ? .fire : .soft)
                            Text(e.title).foregroundColor(.white).lineLimit(2)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if list.isEmpty { Text("Nothing hidden").foregroundColor(.soft) } }
            .navigationTitle("Hidden packages · \(list.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unhide (\(picked.count))") {
                        hidden.unhide(picked)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}
