import SwiftUI

struct Card: View {
    enum Style { case poster, logo, wide }

    let item: Item
    let style: Style
    // In a grid the card takes the column's width instead of a fixed one.
    var flexible = false
    @EnvironmentObject private var lib: Library
    @Environment(\.metrics) private var m

    var body: some View {
        switch style {
        case .poster: poster
        case .logo: logo
        case .wide: wide
        }
    }

    private var poster: some View {
        let progress = item.kind == .movie ? lib.progress("m:\(item.sid)") : nil
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Color.card
                if item.icon == nil {
                    Text(cleanTitle(item.name)).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                        .foregroundColor(.soft).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                RemoteImage(url: item.icon, size: m.poster)
                HStack(spacing: 4) { ForEach(nameTags(item.name), id: \.self) { Badge(text: $0) } }.padding(6)
                if let progress {
                    VStack { Spacer(); ProgressLine(value: progress, height: 4).padding(6) }
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(width: flexible ? nil : m.poster)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(cleanTitle(item.name)).font(.system(size: m.compact ? 12 : 14, weight: .medium)).lineLimit(1)
                .foregroundColor(.white.opacity(0.9))
                .frame(width: flexible ? nil : m.poster, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var logo: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                LinearGradient(colors: [Color(white: 0.17), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                if item.icon != nil {
                    RemoteImage(url: item.icon, fill: false, size: m.logo).padding(m.logo * 0.14)
                } else {
                    Image(systemName: "tv").font(.system(size: 28)).foregroundColor(.soft)
                }
            }
            .aspectRatio(1 / 0.78, contentMode: .fit)
            .frame(width: flexible ? nil : m.logo)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.name).font(.system(size: m.compact ? 12 : 13, weight: .medium)).lineLimit(1)
                .foregroundColor(.white.opacity(0.9))
                .frame(width: flexible ? nil : m.logo, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var wide: some View {
        ZStack(alignment: .bottomLeading) {
            Color.card
            RemoteImage(url: item.backdrop ?? item.icon, size: m.wide)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(cleanTitle(item.name)).font(.system(size: m.compact ? 14 : 16, weight: .bold)).lineLimit(1)
                if let s = item.sub { Text(s).font(.system(size: 12)).foregroundColor(.soft).lineLimit(1) }
                if let p = item.progress { ProgressLine(value: p, height: 3).padding(.top, 4) }
            }
            .padding(12)
            Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: m.wide, height: m.wideH)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

// The featured title at the top of a tab, under the header.
struct HeroView: View {
    @ObservedObject var model: BrowseModel
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var lib: Library
    @Environment(\.metrics) private var m

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            LinearGradient(colors: [Color.bg.opacity(0.7), .clear, Color.bg.opacity(0.6), Color.bg], startPoint: .top, endPoint: .bottom)
            if !m.compact {
                LinearGradient(colors: [Color.bg.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
            }
            if let it = model.hero { info(it).padding(.horizontal, m.pad).padding(.bottom, 8) }
        }
        .frame(height: m.heroH)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var backdrop: some View {
        if model.kind == .live {
            ZStack {
                RadialGradient(colors: [Color.fire.opacity(0.28), .clear], center: .topTrailing, startRadius: 10, endRadius: m.heroH * 1.1)
                if let it = model.hero, it.icon != nil {
                    RemoteImage(url: it.icon, fill: false, size: m.heroH * 0.5)
                        .frame(width: m.heroH * 0.42, height: m.heroH * 0.32)
                        .padding(m.heroH * 0.06)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: m.compact ? .center : .trailing)
                        .padding(.trailing, m.compact ? 0 : m.pad * 1.5)
                        .padding(.bottom, m.compact ? m.heroH * 0.3 : 0)
                }
            }
        } else {
            RemoteImage(url: model.heroInfo?.backdrop ?? model.hero?.backdrop, size: max(m.width, m.heroH))
        }
    }

    private func info(_ it: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cleanTitle(it.name)).font(.system(size: m.compact ? 26 : 38, weight: .heavy)).lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 8)
            if model.kind == .live {
                let now = model.heroNow.0
                let next = model.heroNow.1
                HStack(spacing: 8) {
                    Text("● LIVE").font(.footnote.weight(.heavy)).foregroundColor(.fire)
                    if let now { Text(now.times).font(.footnote.weight(.semibold)).foregroundColor(.fireLight) }
                }
                if let now {
                    ProgressLine(value: now.progress, height: 3).frame(width: 260)
                    Text(now.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if let next { Text("Next  \(next.title)").font(.footnote).foregroundColor(.soft).lineLimit(1) }
            } else {
                HStack(spacing: 6) {
                    ForEach(nameTags(it.name), id: \.self) { Badge(text: $0) }
                    if let meta = model.heroInfo?.meta, !meta.isEmpty {
                        Text(meta).font(.footnote.weight(.semibold)).foregroundColor(.fireLight).lineLimit(1)
                    }
                }
                if let plot = model.heroInfo?.plot {
                    Text(plot).font(.subheadline).foregroundColor(.white.opacity(0.85)).lineLimit(m.compact ? 3 : 2)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
            HStack(spacing: 12) {
                Button { play(it) } label: {
                    Label(playLabel(it), systemImage: "play.fill").font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Color.white, in: Capsule()).foregroundColor(.black)
                }
                if model.kind != .live {
                    Button { app.path.append(it.kind == .movie ? .movie(it) : .series(it)) } label: {
                        Label("Info", systemImage: "info.circle").font(.headline)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(Color.white.opacity(0.18), in: Capsule()).foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func playLabel(_ it: Item) -> String {
        if let w = lib.watch(it.kind, it.sid) { return w.epLabel.map { "Resume \($0)" } ?? "Resume" }
        return it.kind == .live ? "Watch" : "Play"
    }

    private func play(_ it: Item) {
        if let w = lib.watch(it.kind, it.sid) { app.resumeWatch(w); return }
        switch it.kind {
        case .live: app.open(it, rail: lib.favList(.live).contains(it) ? lib.favList(.live) : [it], cats: [], cat: nil)
        case .movie: app.playMovie(it)
        case .series: app.path.append(.series(it))
        }
    }
}
