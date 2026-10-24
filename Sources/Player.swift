import AVFoundation
import MediaPlayer
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

// The iPhone's own volume. iOS only lets an app change it through the slider inside an
// MPVolumeView, so a tiny invisible one sits in the player. While it is there iOS hides its
// own volume popup, so [level] also follows the side buttons and the player shows the change.
final class SystemVolume: ObservableObject {
    @Published private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var watch: NSKeyValueObservation?

    init() {
        watch = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let v = change.newValue else { return }
            DispatchQueue.main.async { self?.level = v }
        }
    }

    func set(_ value: Float) {
        guard let slider = view.subviews.lazy.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = min(max(value, 0), 1)
        slider.sendActions(for: .valueChanged)
    }
}

struct VolumeHost: UIViewRepresentable {
    let volume: SystemVolume
    func makeUIView(context: Context) -> MPVolumeView { volume.view }
    func updateUIView(_ v: MPVolumeView, context: Context) {}
}

// The screen the player is on, for its brightness.
private var currentScreen: UIScreen? {
    (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.screen
}

// A film or episode being played. An episode can hand over to the next one inside the same player.
private struct Vod {
    var url: URL
    var title: String
    var sub: String?
    var key: String
    var watch: Watch?
}

private struct QueuedEpisode {
    let season: String
    let ep: Item
}

struct PlayerView: View {
    let request: PlayRequest
    @EnvironmentObject private var lib: Library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var vlc = VLC()
    @StateObject private var volume = SystemVolume()

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

    // Films and episodes
    @State private var vod: Vod?
    // Every episode of the series in order, to find the next one.
    @State private var queue: [QueuedEpisode] = []
    @State private var seriesBackdrop: String?
    // Cancel on the Next Episode card: this episode ends and closes like before.
    @State private var upNextCancelled = false

    // Slide up or down: left half brightness, right half volume.
    enum Adjust { case brightness, volume }
    @State private var adjusting: Adjust?
    @State private var adjustStart: Float = 0
    @State private var shownAdjust: Adjust?
    @State private var adjustLevel: Float = 0
    @State private var adjustHide: Task<Void, Never>?
    // The brightness before the player changed it, put back when the player closes.
    @State private var savedBrightness: CGFloat?

    private var isLive: Bool { if case .live = request.mode { return true } else { return false } }

    private var next: QueuedEpisode? {
        guard let w = vod?.watch, w.kind == .series,
              let i = queue.firstIndex(where: { $0.ep.sid == w.epId }), i + 1 < queue.count else { return nil }
        return queue[i + 1]
    }

    // Seconds left while the Next Episode card shows (the last 15 seconds of an episode).
    private var upNextLeft: Double? {
        guard !isLive, !failed, !upNextCancelled, next != nil, vlc.length > 120 else { return nil }
        let left = vlc.length - vlc.time
        return left > 0 && left <= 15 ? left : nil
    }

    var body: some View {
        GeometryReader { g in
            let compact = g.size.width < 600
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(vlc: vlc).ignoresSafeArea()
                VolumeHost(volume: volume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .onTapGesture(count: 2) { if !isLive { vlc.setFill(!vlc.fill, size: g.size) } }
                    .onTapGesture { if guide { withAnimation { guide = false } } else { toggleControls() } }
                    .simultaneousGesture(adjustDrag(g.size))
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
                if let left = upNextLeft, let n = next, !guide { upNextCard(n, left, compact) }
                if let a = shownAdjust { adjustIndicator(a) }
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
        // The side buttons change the volume too; show it, since iOS hides its own popup here.
        .onChange(of: volume.level) { v in
            if adjusting != .volume { showAdjust(.volume, v) }
        }
        .onChange(of: phase) { p in
            if p == .background {
                save()
                vlc.pause()
                restoreBrightness()
            } else if p == .active, !failed {
                if isLive { play(index) } else { vlc.resume() }
            }
        }
    }

    // MARK: Start / stop

    private func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        switch request.mode {
        case .vod(let url, let t, let s, let key, let w):
            vod = Vod(url: url, title: t, sub: s, key: key, watch: w)
            let at = lib.resume(key)
            if at > 0 { show(toast: "Resumed at \(clock(at))") }
            hook()
            vlc.open(url, live: false, start: at)
            hideSoon()
            if let w, w.kind == .series { loadQueue(w.id) }
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
            if isLive {
                play(index)
            } else if let v = vod {
                let at = vlc.time > 1 ? vlc.time : lib.resume(v.key)
                hook()
                vlc.open(v.url, live: false, start: at)
            }
        }
    }

    // The end of a film closes the player; the end of an episode plays the next one.
    private func ended() {
        if let v = vod {
            let d = max(vlc.length, 1)
            lib.saveResume(v.key, pos: d, dur: d)
            if let w = v.watch { lib.update(w, pos: d, dur: d) }
        }
        if let n = next, !upNextCancelled { playNext(n) } else { close() }
    }

    // MARK: Next episode

    private func loadQueue(_ seriesId: Int) {
        Task {
            guard let info = await Store.load("&action=get_series_info&series_id=\(seriesId)", ttl: 6 * HOUR, parseSeriesInfo) else { return }
            queue = info.seasons.flatMap { s in s.episodes.map { QueuedEpisode(season: s.name, ep: $0) } }
            seriesBackdrop = info.backdrop
        }
    }

    // Plays [n] in this player: the same connection, no trip back to the series page.
    private func playNext(_ n: QueuedEpisode) {
        guard let v = vod, let w = v.watch, let u = Api.episode(n.ep.sid, n.ep.ext) else { close(); return }
        save()
        let label = "S\(n.season) E\(n.ep.num ?? "?")"
        let key = "e:\(n.ep.sid)"
        let nw = Watch(kind: .series, id: w.id, name: w.name, icon: w.icon, ext: n.ep.ext, epId: n.ep.sid,
                       epLabel: label, backdrop: n.ep.icon ?? seriesBackdrop ?? w.backdrop)
        vod = Vod(url: u, title: v.title, sub: [label, n.ep.name].filter { !$0.isEmpty }.joined(separator: "  •  "), key: key, watch: nw)
        upNextCancelled = false
        retries = 0
        failed = false
        scrub = nil
        let at = lib.resume(key)
        hook()
        vlc.open(u, live: false, start: at)
        show(toast: label)
        controls = true
        hideSoon()
    }

    private func upNextCard(_ n: QueuedEpisode, _ left: Double, _ compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Next Episode").font(.caption.weight(.heavy)).foregroundColor(.fire)
                Spacer()
                Button { upNextCancelled = true } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        .frame(width: 28, height: 28).background(Color.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
            }
            Text("S\(n.season) E\(n.ep.num ?? "?")" + (n.ep.name.isEmpty ? "" : "  •  " + cleanTitle(n.ep.name)))
                .font(.subheadline.weight(.semibold)).lineLimit(2)
            Button { playNext(n) } label: {
                Label("Play in \(Int(left.rounded(.up)))", systemImage: "play.fill")
                    .font(.subheadline.weight(.bold)).foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: compact ? 250 : 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, compact ? 14 : 28)
        .padding(.bottom, controls ? (compact ? 96 : 120) : (compact ? 24 : 36))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: Brightness and volume

    private func adjustDrag(_ s: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                if guide { return }
                if adjusting == nil {
                    // Only clear up-or-down slides, and not from the top or bottom edge (iOS uses those).
                    guard abs(v.translation.height) > abs(v.translation.width) * 1.3,
                          v.startLocation.y > 50, v.startLocation.y < s.height - 50 else { return }
                    let left = v.startLocation.x < s.width / 2
                    adjusting = left ? .brightness : .volume
                    if left {
                        let now = currentScreen?.brightness ?? 0.5
                        if savedBrightness == nil { savedBrightness = now }
                        adjustStart = Float(now)
                    } else {
                        adjustStart = volume.level
                    }
                }
                guard let a = adjusting else { return }
                let value = min(max(adjustStart - Float(v.translation.height / (s.height * 0.6)), 0), 1)
                if a == .brightness { currentScreen?.brightness = CGFloat(value) } else { volume.set(value) }
                showAdjust(a, value)
            }
            .onEnded { _ in adjusting = nil }
    }

    private func showAdjust(_ a: Adjust, _ value: Float) {
        shownAdjust = a
        adjustLevel = value
        adjustHide?.cancel()
        adjustHide = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.25)) { shownAdjust = nil }
        }
    }

    private func adjustIndicator(_ a: Adjust) -> some View {
        let icon: String
        if a == .brightness {
            icon = adjustLevel < 0.5 ? "sun.min.fill" : "sun.max.fill"
        } else {
            icon = adjustLevel == 0 ? "speaker.slash.fill" : adjustLevel < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        }
        return VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundColor(.white).frame(height: 22)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(height: 140 * CGFloat(adjustLevel))
            }
            .frame(width: 6, height: 140)
        }
        .padding(.vertical, 16).padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: a == .brightness ? .leading : .trailing)
        .padding(.horizontal, 28)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func restoreBrightness() {
        if let b = savedBrightness { currentScreen?.brightness = b }
        savedBrightness = nil
    }

    private func periodicSave() {
        if vlc.time > 0 && !vlc.buffering { retries = 0 }
        if Date().timeIntervalSince(lastSave) > 10 { save() }
    }

    private func save() {
        lastSave = Date()
        guard let v = vod, vlc.length > 0, vlc.time > 0 else { return }
        lib.saveResume(v.key, pos: vlc.time, dur: vlc.length)
        if let w = v.watch { lib.update(w, pos: vlc.time, dur: vlc.length) }
    }

    private func finish() {
        save()
        vlc.stop()
        restoreBrightness()
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
        if isLive { return (channels.indices.contains(index) ? channels[index].name : "", nil) }
        return (vod?.title ?? "", vod?.sub)
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
            if let n = next, upNextLeft == nil {
                HStack {
                    Spacer()
                    Button { playNext(n); hideSoon() } label: {
                        Label("Next Episode", systemImage: "forward.end.fill")
                            .font(.footnote.weight(.bold)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.white.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
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
