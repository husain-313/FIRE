import ImageIO
import SwiftUI
import UIKit

// Pictures are decoded at the size they are shown, so a screen of posters costs a few MB.
enum Images {
    private static let mem: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 60 << 20
        return c
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = disk
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.timeoutIntervalForRequest = 15
        c.httpMaximumConnectionsPerHost = 6
        c.httpAdditionalHeaders = ["User-Agent": Api.ua]
        return URLSession(configuration: c)
    }()

    private static let disk = URLCache(memoryCapacity: 8 << 20, diskCapacity: 300 << 20)

    private static let tmdb = try! NSRegularExpression(pattern: "(image\\.tmdb\\.org/t/p/)[^/]+/")

    // TMDB serves every picture in several sizes; the one that fits arrives several times faster.
    static func sized(_ url: String, _ px: CGFloat) -> String {
        guard url.contains("image.tmdb.org/t/p/") else { return url }
        let size = px <= 200 ? "w185" : px <= 400 ? "w342" : px <= 800 ? "w780" : "w1280"
        return tmdb.stringByReplacingMatches(in: url, range: NSRange(url.startIndex..., in: url), withTemplate: "$1\(size)/")
    }

    static func clear() {
        mem.removeAllObjects()
        disk.removeAllCachedResponses()
    }

    static func cached(_ url: String, _ px: CGFloat) -> UIImage? {
        mem.object(forKey: "\(Int(px))|\(url)" as NSString)
    }

    static func load(_ url: String, _ px: CGFloat) async -> UIImage? {
        let key = "\(Int(px))|\(url)" as NSString
        if let i = mem.object(forKey: key) { return i }
        guard let u = URL(string: sized(url, px)), let r = try? await session.data(from: u) else { return nil }
        let d = r.0
        let img = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceShouldCacheImmediately: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max(px, 64)]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let img { mem.setObject(img, forKey: key, cost: img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
        return img
    }
}

// [fill] crops to fill (posters, backdrops); otherwise the whole picture fits (channel logos).
struct RemoteImage: View {
    let url: String?
    var fill = true
    // Longest side in points; pictures are decoded for this size.
    var size: CGFloat = 200
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        let px = size * scale
        // The picture is an overlay, so it never changes the size of its frame: a backdrop
        // wider or taller than its slot is cropped instead of pushing the page off the screen.
        Color.clear
            .overlay {
                if let img = image ?? url.flatMap({ Images.cached($0, px) }) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                }
            }
            .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            if Images.cached(url, px) == nil { image = nil }
            image = await Images.load(url, px)
        }
    }
}

// MARK: - Look

extension Color {
    static let fire = Color(red: 1.0, green: 0.42, blue: 0.10)
    static let fireLight = Color(red: 1.0, green: 0.64, blue: 0.24)
    static let bg = Color(red: 0.055, green: 0.047, blue: 0.043)
    static let card = Color(white: 0.13)
    static let soft = Color.white.opacity(0.62)
}

// Sizes that follow the screen: an iPhone in portrait gets small posters and tight margins,
// a 13" iPad in landscape large ones.
struct Metrics {
    var width: CGFloat

    var compact: Bool { width < 600 }
    var pad: CGFloat { compact ? 16 : width < 1000 ? 28 : 40 }
    var poster: CGFloat { min(max(width / (compact ? 3.6 : 7.0), 104), 190) }
    var posterH: CGFloat { poster * 1.5 }
    var logo: CGFloat { poster * 1.25 }
    var logoH: CGFloat { logo * 0.78 }
    var wide: CGFloat { min(max(width / (compact ? 1.6 : 3.4), 230), 420) }
    var wideH: CGFloat { wide * 9 / 16 }
    var heroH: CGFloat { compact ? width * 1.05 : min(width * 0.5, 620) }
    var gap: CGFloat { compact ? 10 : 16 }
}

private struct MetricsKey: EnvironmentKey { static let defaultValue = Metrics(width: 800) }

extension EnvironmentValues {
    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.fire, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ProgressLine: View {
    let value: Double
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.fire).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}
