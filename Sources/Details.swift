import SwiftUI

// Shared top of the film and series pages: the backdrop fading into the page.
private struct Backdrop: View {
    let url: String?
    @Environment(\.metrics) private var m

    var body: some View {
        ZStack {
            Color.card
            RemoteImage(url: url, size: max(m.width, m.heroH))
            LinearGradient(colors: [Color.bg.opacity(0.55), .clear, Color.bg.opacity(0.5), Color.bg], startPoint: .top, endPoint: .bottom)
        }
        .frame(height: m.heroH * (m.compact ? 0.72 : 0.85))
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

private struct PillButton: View {
    let title: String
    let icon: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline).lineLimit(1)
                .padding(.horizontal, 22).padding(.vertical, 13)
                .background(primary ? Color.white : Color.white.opacity(0.16), in: Capsule())
                .foregroundColor(primary ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    // A see-through bar: the page shows under it and the back button stays.
    func detailChrome() -> some View {
        self.background(Color.bg.ignoresSafeArea())
            .ignoresSafeArea(edges: .top)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

struct MovieView: View {
    let item: Item
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var lib: Library
    @Environment(\.metrics) private var m
    @State private var info: Info?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Backdrop(url: info?.backdrop ?? item.backdrop)
                HStack(alignment: .top, spacing: 24) {
                    if !m.compact {
                        RemoteImage(url: info?.poster ?? item.icon, size: m.poster * 1.4)
                            .frame(width: m.poster * 1.4, height: m.poster * 2.1)
                            .background(Color.card)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.5), radius: 14)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(cleanTitle(item.name)).font(.system(size: m.compact ? 26 : 36, weight: .heavy))
                        HStack(spacing: 6) {
                            ForEach(nameTags(item.name), id: \.self) { Badge(text: $0) }
                            if let meta = info?.meta, !meta.isEmpty {
                                Text(meta).font(.subheadline.weight(.semibold)).foregroundColor(.fireLight)
                            }
                        }
                        buttons
                        if let p = lib.progress("m:\(item.sid)") {
                            let left = (lib.resume("m:\(item.sid)") / max(p, 0.001)) * (1 - p)
                            HStack(spacing: 10) {
                                ProgressLine(value: p, height: 4).frame(maxWidth: 260)
                                Text("\(duration(left)) left").font(.footnote).foregroundColor(.soft)
                            }
                        }
                        if let plot = info?.plot {
                            Text(plot).font(.body).foregroundColor(.white.opacity(0.85)).padding(.top, 4)
                                .frame(maxWidth: 720, alignment: .leading)
                        } else if info == nil {
                            ProgressView().padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, m.pad)
                .offset(y: m.compact ? -40 : -m.poster * 1.2)
                .padding(.bottom, m.compact ? -20 : -m.poster * 1.1)
            }
            .padding(.bottom, 40)
        }
        .detailChrome()
        .task {
            info = await Store.load("&action=get_vod_info&vod_id=\(item.sid)", ttl: DAY, parseVodInfo)
                ?? Info(backdrop: nil, poster: nil, plot: nil, meta: "")
        }
    }

    private var buttons: some View {
        let key = "m:\(item.sid)"
        let resumeAt = lib.resume(key)
        var it = item
        it.backdrop = info?.backdrop ?? item.backdrop
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { row(it, key, resumeAt) }
            VStack(alignment: .leading, spacing: 10) { row(it, key, resumeAt) }
        }
    }

    @ViewBuilder
    private func row(_ it: Item, _ key: String, _ resumeAt: Double) -> some View {
        PillButton(title: resumeAt > 0 ? "Resume" : "Play", icon: "play.fill", primary: true) { app.playMovie(it) }
        if resumeAt > 0 {
            PillButton(title: "Start Over", icon: "backward.end.fill") {
                lib.clearResume(key)
                lib.removeWatching(.movie, item.sid)
                app.playMovie(it)
            }
        }
        PillButton(title: lib.isFav(item) ? "In My List" : "My List", icon: lib.isFav(item) ? "checkmark" : "plus") { lib.toggleFav(item) }
    }
}

struct SeriesView: View {
    let item: Item
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var lib: Library
    @Environment(\.metrics) private var m
    @State private var info: SeriesInfo?
    @State private var failed = false
    @State private var season: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Backdrop(url: info?.backdrop ?? item.backdrop ?? info?.cover ?? item.icon)
                VStack(alignment: .leading, spacing: 14) {
                    Text(cleanTitle(item.name)).font(.system(size: m.compact ? 26 : 36, weight: .heavy))
                    HStack(spacing: 6) {
                        ForEach(nameTags(item.name), id: \.self) { Badge(text: $0) }
                        if let meta = (info?.meta).flatMap({ $0.isEmpty ? nil : $0 }) ?? item.meta {
                            Text(meta).font(.subheadline.weight(.semibold)).foregroundColor(.fireLight)
                        }
                    }
                    HStack(spacing: 12) {
                        if let t = target() {
                            PillButton(title: "\(t.resume ? "Resume" : "Play") S\(t.season) E\(t.ep.num ?? "1")", icon: "play.fill", primary: true) {
                                play(t.ep, t.season)
                            }
                        }
                        PillButton(title: lib.isFav(item) ? "In My List" : "My List", icon: lib.isFav(item) ? "checkmark" : "plus") { lib.toggleFav(item) }
                    }
                    if let plot = info?.plot ?? item.plot {
                        Text(plot).foregroundColor(.white.opacity(0.85)).frame(maxWidth: 720, alignment: .leading)
                    }
                    if let info {
                        seasons(info)
                        episodes(info)
                    } else if failed {
                        Text("Can't load this series right now.").foregroundColor(.soft).padding(.vertical, 30)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, m.pad)
                .offset(y: -40)
            }
            .padding(.bottom, 20)
        }
        .detailChrome()
        .task {
            if info == nil {
                info = await Store.load("&action=get_series_info&series_id=\(item.sid)", ttl: 6 * HOUR, parseSeriesInfo)
                failed = info == nil
                if season == nil { season = target()?.season ?? info?.seasons.first?.name }
            }
        }
    }

    private struct Target { let season: String; let ep: Item; let resume: Bool }

    // The episode left part way, else the one after the last finished, else the first.
    private func target() -> Target? {
        guard let info else { return nil }
        let flat = info.seasons.flatMap { s in s.episodes.map { (s.name, $0) } }
        guard !flat.isEmpty else { return nil }
        if let w = lib.watch(.series, item.sid), let e = flat.first(where: { $0.1.sid == w.epId }), !lib.done("e:\(w.epId)") {
            return Target(season: e.0, ep: e.1, resume: lib.resume("e:\(w.epId)") > 0)
        }
        if let last = flat.lastIndex(where: { lib.done("e:\($0.1.sid)") }), last + 1 < flat.count {
            let e = flat[last + 1]
            return Target(season: e.0, ep: e.1, resume: lib.resume("e:\(e.1.sid)") > 0)
        }
        return Target(season: flat[0].0, ep: flat[0].1, resume: lib.resume("e:\(flat[0].1.sid)") > 0)
    }

    private func play(_ ep: Item, _ season: String) {
        app.playEpisode(series: item, ep: ep, season: season, backdrop: info?.backdrop ?? item.backdrop)
    }

    private func seasons(_ info: SeriesInfo) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(info.seasons, id: \.name) { s in
                    Button { season = s.name } label: {
                        Text("Season \(s.name)").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(season == s.name ? Color.fire : Color.white.opacity(0.1), in: Capsule())
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    private func episodes(_ info: SeriesInfo) -> some View {
        let s = info.seasons.first { $0.name == season } ?? info.seasons.first
        let stillW: CGFloat = m.compact ? 130 : 220
        return LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(s?.episodes ?? [], id: \.sid) { ep in
                Button { play(ep, s?.name ?? "1") } label: {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack(alignment: .bottomLeading) {
                            Color.card
                            RemoteImage(url: ep.icon ?? info.backdrop ?? item.backdrop, size: stillW)
                            Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundColor(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if let p = lib.progress("e:\(ep.sid)") { ProgressLine(value: p, height: 3).padding(6) }
                        }
                        .frame(width: stillW, height: stillW * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("E\(ep.num ?? "?")").font(.subheadline.weight(.heavy)).foregroundColor(.fire)
                                if lib.done("e:\(ep.sid)") { Image(systemName: "checkmark.circle.fill").foregroundColor(.fire).font(.subheadline) }
                                if let len = ep.sub { Text(len).font(.footnote).foregroundColor(.soft) }
                            }
                            Text(ep.name.isEmpty ? "Episode \(ep.num ?? "")" : cleanTitle(ep.name))
                                .font(.system(size: m.compact ? 14 : 16, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                            if let p = ep.plot {
                                Text(p).font(.footnote).foregroundColor(.soft).lineLimit(m.compact ? 2 : 3).multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }
}
