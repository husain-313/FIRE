import MobileVLCKit
import SwiftUI
import UIKit

// VLC behind a small observable face. Its state is read twice a second rather than through
// delegate callbacks, which keeps the Swift side simple and steady.
final class VLC: NSObject, ObservableObject {
    struct Track: Hashable { let id: Int32; let name: String }

    let mp = VLCMediaPlayer()
    @Published var time: Double = 0
    @Published var length: Double = 0
    @Published var playing = false
    @Published var buffering = true
    @Published var subs: [Track] = []
    @Published var audios: [Track] = []
    @Published var sub: Int32 = -1
    @Published var audio: Int32 = -1
    @Published var fill = false

    var onEnd: (() -> Void)?
    var onError: (() -> Void)?
    private var timer: Timer?
    private var wantPlay = false
    private var lastTime = -1.0
    private var stillSince = Date()
    private var pickedSubs = false
    private var live = false
    private var reported = false

    func open(_ url: URL, live: Bool, start: Double) {
        self.live = live
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(live ? 2500 : 4000)")
        media.addOption(":http-user-agent=\(Api.ua)")
        media.addOption(":http-reconnect")
        if start > 1 { media.addOption(":start-time=\(Int(start))") }
        // Arabic subtitles when the film has them, English otherwise.
        media.addOption(":sub-language=ara,ar,arabic,eng,en,english")
        mp.media = media
        let big = NSSelectorFromString("setTextRendererFontSize:")
        if mp.responds(to: big) { mp.perform(big, with: NSNumber(value: 16)) }
        wantPlay = true
        pickedSubs = false
        reported = false
        lastTime = -1
        stillSince = Date()
        time = start
        length = 0
        subs = []
        audios = []
        buffering = true
        mp.play()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        }
    }

    private func poll() {
        let st = mp.state
        let t = Double(mp.time.intValue) / 1000
        if let l = mp.media?.length.intValue, l > 0 { length = Double(l) / 1000 }
        if t != lastTime && mp.isPlaying {
            lastTime = t
            stillSince = Date()
            buffering = false
        } else if wantPlay && Date().timeIntervalSince(stillSince) > 1.2 {
            buffering = true
        }
        time = t
        playing = mp.isPlaying
        if !pickedSubs || subs.isEmpty || audios.isEmpty { readTracks() }
        if reported { return }
        if st == .error {
            reported = true
            onError?()
        } else if st == .ended || (st == .stopped && wantPlay && lastTime >= 0) {
            reported = true
            // A film that stops well before its end lost the connection; that is a retry.
            if !live && length > 0 && t > length - 180 { onEnd?() } else { onError?() }
        } else if wantPlay && Date().timeIntervalSince(stillSince) > 25 {
            reported = true
            onError?()
        }
    }

    private func readTracks() {
        func tracks(_ names: [Any]?, _ ids: [Any]?) -> [Track] {
            let n = (names as? [String]) ?? []
            let i = ((ids as? [NSNumber]) ?? []).map { $0.int32Value }
            return zip(i, n).map { Track(id: $0.0, name: $0.1) }
        }
        let s = tracks(mp.videoSubTitlesNames, mp.videoSubTitlesIndexes)
        let a = tracks(mp.audioTrackNames, mp.audioTrackIndexes)
        if s != subs { subs = s }
        if a != audios { audios = a }
        sub = mp.currentVideoSubTitleIndex
        audio = mp.currentAudioTrackIndex
        if !pickedSubs && s.count > 1 {
            pickedSubs = true
            let ar = s.first { $0.id >= 0 && ($0.name.lowercased().contains("arab") || $0.name.contains("عرب") || $0.name.lowercased().contains("[ar")) }
            if let ar, sub != ar.id { setSub(ar.id) }
        }
    }

    func setSub(_ id: Int32) {
        mp.currentVideoSubTitleIndex = id
        sub = id
    }

    func setAudio(_ id: Int32) {
        mp.currentAudioTrackIndex = id
        audio = id
    }

    func toggle() {
        if mp.isPlaying { mp.pause(); wantPlay = false } else { mp.play(); wantPlay = true; stillSince = Date() }
        playing = !playing
    }

    func pause() { mp.pause(); wantPlay = false; playing = false }

    func resume() {
        mp.play()
        wantPlay = true
        stillSince = Date()
    }

    func seek(to s: Double) {
        mp.time = VLCTime(int: Int32(max(s, 0) * 1000))
        time = s
        stillSince = Date()
    }

    func jump(_ s: Int32) {
        if s > 0 { mp.jumpForward(s) } else { mp.jumpBackward(-s) }
        stillSince = Date()
    }

    // Fill crops the picture to the screen; fit shows all of it.
    func setFill(_ on: Bool, size: CGSize) {
        fill = on
        if on, size.width > 0, size.height > 0 {
            mp.videoCropGeometry = strdup("\(Int(size.width)):\(Int(size.height))")
        } else {
            mp.videoCropGeometry = nil
        }
    }

    deinit { timer?.invalidate() }

    func stop() {
        wantPlay = false
        timer?.invalidate()
        timer = nil
        onEnd = nil
        onError = nil
        mp.stop()
    }
}

struct VideoSurface: UIViewRepresentable {
    let vlc: VLC

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        vlc.mp.drawable = v
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}
}

struct PlayerView: View {
    let request: PlayRequest
    @EnvironmentObject private var lib: Library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var vlc = VLC()

    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var retries = 0
    @State private var failed = false
    @State private var toast: String?
    @State private var scrub: Double?
    @State private var lastSave = Date()
    @State private var size = CGSize.zero

    // Live
    @State private var channels: [Item] = []
    @State private var index = 0
    @State private var cats: [Cat] = []
    @State private var playCat: Int?
    @State private var shownCat: Int?
    @State private var shownChannels: [Item]?
    @State private var guide = false
    @State private var now: (Prog?, Prog?) = (nil, nil)
    @State private var zapTask: Task<Void, Never>?

    private var isLive: Bool { if case .live = request.mode { return true } else { return false } }

    var body: some View {
        GeometryReader { g in
            let compact = g.size.width < 600
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(vlc: vlc).ignoresSafeArea()
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .onTapGesture(count: 2) { if !isLive { vlc.setFill(!vlc.fill, size: g.size) } }
                    .onTapGesture { if guide { withAnimation { guide = false } } else { toggleControls() } }
                // With the controls up, the wheel takes the play button's place instead.
                if vlc.buffering && !failed && !controls {
                    ProgressView().scaleEffect(1.6).tint(.white)
                }
                if failed { failedCard }
                if controls && !failed { overlay(compact) }
                if !vlc.playing && !vlc.buffering && !isLive && !failed && !controls {
                    Image(systemName: "pause.fill").font(.system(size: 34)).foregroundColor(.white)
                        .frame(width: 84, height: 84).overlay(Circle().stroke(Color.fire, lineWidth: 3))
                }
                if guide { guidePanel(g.size, compact) }
                if let toast {
                    Text(toast).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70)
                }
            }
            .onAppear { size = g.size }
            .onChange(of: g.size) { s in
                size = s
                if vlc.fill { vlc.setFill(true, size: s) }
            }
        }
        .statusBarHidden(!controls)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: start)
        .onDisappear(perform: finish)
        .onChange(of: vlc.time) { _ in periodicSave() }
        .onChange(of: phase) { p in
            if p == .background {
                save()
                vlc.pause()
            } else if p == .active, !failed {
                if isLive { play(index) } else { vlc.resume() }
            }
        }
    }

    // MARK: Start / stop

    private func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        switch request.mode {
        case .vod(let url, _, _, let key, _):
            let at = lib.resume(key)
            if at > 0 { show(toast: "Resumed at \(clock(at))") }
            hook()
            vlc.open(url, live: false, start: at)
            hideSoon()
        case .live(let list, let i, let c, let cat):
            channels = list
            cats = c
            playCat = cat
            shownCat = cat
            shownChannels = cat == nil ? list : nil
            play(i)
        }
    }

    private func hook() {
        vlc.onError = { retry() }
        vlc.onEnd = { ended() }
    }

    private func play(_ i: Int) {
        guard channels.indices.contains(i), let u = Api.live(channels[i].sid) else { return }
        index = i
        failed = false
        hook()
        vlc.open(u, live: true, start: 0)
        now = (nil, nil)
        let id = channels[i].sid
        Task {
            let n = Epg.nowNext(await Epg.shared.get(id))
            if channels.indices.contains(index), channels[index].sid == id { now = n }
        }
        controls = true
        hideSoon()
    }

    private func zap(_ d: Int) {
        guard !channels.isEmpty else { return }
        play((index + d + channels.count) % channels.count)
    }

    private func retry() {
        if retries >= 5 {
            failed = true
            vlc.buffering = false
            return
        }
        retries += 1
        let delay = UInt64(min(retries, 3)) * 1_000_000_000
        Task {
            try? await Task.sleep(nanoseconds: delay)
            switch request.mode {
            case .live: play(index)
            case .vod(let url, _, _, _, _):
                let at = vlc.time > 1 ? vlc.time : lib.resume(requestKey ?? "")
                hook()
                vlc.open(url, live: false, start: at)
            }
        }
    }

    private func ended() {
        if case .vod(_, _, _, let key, let w) = request.mode {
            let d = max(vlc.length, 1)
            lib.saveResume(key, pos: d, dur: d)
            if let w { lib.update(w, pos: d, dur: d) }
        }
        close()
    }

    private var requestKey: String? {
        if case .vod(_, _, _, let key, _) = request.mode { return key }
        return nil
    }

    private func periodicSave() {
        if vlc.time > 0 && !vlc.buffering { retries = 0 }
        if Date().timeIntervalSince(lastSave) > 10 { save() }
    }

    private func save() {
        lastSave = Date()
        guard case .vod(_, _, _, let key, let w) = request.mode, vlc.length > 0, vlc.time > 0 else { return }
        lib.saveResume(key, pos: vlc.time, dur: vlc.length)
        if let w { lib.update(w, pos: vlc.time, dur: vlc.length) }
    }

    private func finish() {
        save()
        vlc.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func close() {
        finish()
        dismiss()
    }

    // MARK: Controls

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() }
        if controls { hideSoon() }
    }

    private func hideSoon() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            if (vlc.playing || isLive) && scrub == nil && !guide { withAnimation { controls = false } }
        }
    }

    private func show(toast t: String) {
        toast = t
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == t { toast = nil }
        }
    }

    private var title: (String, String?) {
        switch request.mode {
        case .vod(_, let t, let s, _, _): return (t, s)
        case .live: return (channels.indices.contains(index) ? channels[index].name : "", nil)
        }
    }

    private func overlay(_ compact: Bool) -> some View {
        VStack(spacing: 0) {
            topBar(compact)
            Spacer()
            centerButtons(compact)
            Spacer()
            if isLive { liveCard(compact) } else { seekBar(compact) }
        }
        .background(
            VStack {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
        .transition(.opacity)
    }

    private func circle(_ icon: String, _ size: CGFloat = 44, action: @escaping () -> Void) -> some View {
        Button(action: { action(); hideSoon() }) {
            Image(systemName: icon).font(.system(size: size * 0.42, weight: .semibold)).foregroundColor(.white)
                .frame(width: size, height: size).background(Color.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func topBar(_ compact: Bool) -> some View {
        HStack(spacing: 12) {
            circle("xmark") { close() }
            VStack(alignment: .leading, spacing: 2) {
                Text(title.0).font(.system(size: compact ? 16 : 19, weight: .bold)).lineLimit(1)
                if let s = title.1 { Text(s).font(.footnote).foregroundColor(.soft).lineLimit(1) }
            }
            Spacer()
            if isLive {
                circle("list.bullet") { withAnimation { guide = true; loadShown() } }
            }
            if vlc.subs.count > 1 || vlc.audios.count > 1 { tracksMenu }
            if !isLive {
                circle(vlc.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    vlc.setFill(!vlc.fill, size: size)
                }
            }
        }
        .padding(.horizontal, compact ? 14 : 24).padding(.top, 10)
    }

    private var tracksMenu: some View {
        Menu {
            if vlc.subs.count > 1 {
                Section("Subtitles") {
                    ForEach(vlc.subs, id: \.self) { t in
                        Button { vlc.setSub(t.id) } label: {
                            if vlc.sub == t.id { Label(t.id < 0 ? "Off" : t.name, systemImage: "checkmark") } else { Text(t.id < 0 ? "Off" : t.name) }
                        }
                    }
                }
            }
            if vlc.audios.count > 1 {
                Section("Audio") {
                    ForEach(vlc.audios.filter { $0.id >= 0 }, id: \.self) { t in
                        Button { vlc.setAudio(t.id) } label: {
                            if vlc.audio == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                .frame(width: 44, height: 44).background(Color.white.opacity(0.14), in: Circle())
        }
    }

    private func centerButtons(_ compact: Bool) -> some View {
        let big: CGFloat = compact ? 66 : 80
        return HStack(spacing: compact ? 34 : 56) {
            if isLive {
                circle("backward.end.fill", big * 0.7) { zap(-1) }
            } else {
                circle("gobackward.10", big * 0.7) { vlc.jump(-10) }
            }
            if vlc.buffering {
                ProgressView().scaleEffect(1.5).tint(.white)
                    .frame(width: big, height: big).background(Color.white.opacity(0.14), in: Circle())
            } else {
                circle(vlc.playing ? "pause.fill" : "play.fill", big) { vlc.toggle() }
            }
            if isLive {
                circle("forward.end.fill", big * 0.7) { zap(1) }
            } else {
                circle("goforward.10", big * 0.7) { vlc.jump(10) }
            }
        }
    }

    private func seekBar(_ compact: Bool) -> some View {
        let len = max(vlc.length, 1)
        let shown = scrub ?? vlc.time
        return VStack(spacing: 6) {
            Slider(value: Binding(get: { min(shown, len) }, set: { scrub = $0; hideTask?.cancel() }), in: 0...len, onEditingChanged: { editing in
                if !editing, let s = scrub {
                    vlc.seek(to: s)
                    scrub = nil
                    hideSoon()
                }
            })
            .tint(.fire)
            HStack {
                Text(clock(shown)).monospacedDigit()
                Spacer()
                if vlc.length > 0 { Text("-" + clock(len - shown)).monospacedDigit() }
            }
            .font(.footnote.weight(.semibold)).foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, compact ? 18 : 32).padding(.bottom, compact ? 14 : 24)
    }

    private func liveCard(_ compact: Bool) -> some View {
        let ch = channels.indices.contains(index) ? channels[index] : nil
        return HStack(spacing: 14) {
            if let ch {
                RemoteImage(url: ch.icon, fill: false, size: 70).frame(width: 70, height: 50)
                    .padding(6).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("● LIVE").font(.caption.weight(.heavy)).foregroundColor(.fire)
                    if let n = now.0 { Text(n.times).font(.caption.weight(.semibold)).foregroundColor(.fireLight) }
                }
                if let n = now.0 {
                    Text(n.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    ProgressLine(value: n.progress, height: 3).frame(maxWidth: 300)
                }
                if let n = now.1 { Text("Next  \(n.title)").font(.caption).foregroundColor(.soft).lineLimit(1) }
            }
            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, compact ? 12 : 24).padding(.bottom, compact ? 12 : 20)
    }

    private var failedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundColor(.fire)
            Text("Can't play this right now").font(.headline)
            Text("The server didn't send the video. It may be busy, or another device is using the account.")
                .font(.footnote).foregroundColor(.soft).multilineTextAlignment(.center).frame(maxWidth: 320)
            HStack(spacing: 12) {
                Button("Close") { close() }.buttonStyle(.bordered)
                Button("Try Again") {
                    retries = 0
                    failed = false
                    retry()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Live guide

    private func loadShown() {
        guard let c = shownCat, cats.indices.contains(c) else { shownChannels = channels; return }
        if c == playCat { shownChannels = channels; return }
        shownChannels = nil
        let cat = cats[c]
        Task {
            let l = await Store.load(Q.streams(.live, cat), ttl: 6 * HOUR) { parseItems(.live, $0) } ?? []
            if shownCat == c { shownChannels = l }
        }
    }

    private func guidePanel(_ s: CGSize, _ compact: Bool) -> some View {
        let w = compact ? s.width : min(420, s.width * 0.45)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Channels").font(.title3.bold())
                    Spacer()
                    circle("xmark", 36) { withAnimation { guide = false } }
                }
                if !cats.isEmpty {
                    ScrollViewReader { p in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(cats.enumerated()), id: \.element.id) { i, c in
                                    Button {
                                        shownCat = i
                                        loadShown()
                                    } label: {
                                        Text(c.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .background(shownCat == i ? Color.fire : Color.white.opacity(0.1), in: Capsule())
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)
                                    .id(i)
                                }
                            }
                        }
                        .onAppear { if let c = shownCat { p.scrollTo(c, anchor: .center) } }
                    }
                }
                if let list = shownChannels {
                    ScrollViewReader { p in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, ch in
                                    GuideRow(channel: ch, playing: shownCat == playCat && i == index && channels.indices.contains(index) && channels[index].sid == ch.sid)
                                        .onTapGesture {
                                            if shownCat != playCat || channels.count != list.count {
                                                channels = list
                                                playCat = shownCat
                                            }
                                            play(i)
                                        }
                                        .id(ch.id)
                                }
                            }
                        }
                        .onAppear {
                            if shownCat == playCat, channels.indices.contains(index) { p.scrollTo(channels[index].id, anchor: .center) }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .frame(width: w)
            .frame(maxHeight: compact ? s.height * 0.62 : .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 22 : 0))
            .frame(maxHeight: .infinity, alignment: compact ? .bottom : .center)
        }
        .ignoresSafeArea(edges: compact ? .bottom : .vertical)
        .transition(.move(edge: compact ? .bottom : .trailing))
    }
}

struct GuideRow: View {
    let channel: Item
    let playing: Bool
    @State private var now: Prog?

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: channel.icon, fill: false, size: 56).frame(width: 56, height: 40)
                .padding(4).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundColor(playing ? .fire : .white)
                if let now {
                    Text(now.title).font(.caption).foregroundColor(.soft).lineLimit(1)
                    ProgressLine(value: now.progress, height: 2).frame(maxWidth: 160)
                }
            }
            Spacer(minLength: 0)
            if playing { Image(systemName: "speaker.wave.2.fill").foregroundColor(.fire).font(.footnote) }
        }
        .padding(8)
        .background(playing ? Color.fire.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .task(id: channel.sid) { now = Epg.nowNext(await Epg.shared.get(channel.sid)).0 }
    }
}
