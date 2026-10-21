import SwiftUI
import UIKit

// Checks GitHub for a newer FIRE and downloads it, ready to install with the signing app.
enum Updater {
    static let repo = "husain-313/FIRE"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let url: URL
    }

    enum Failure: LocalizedError {
        case offline, noRelease
        var errorDescription: String? {
            switch self {
            case .offline: return "Couldn't reach GitHub. Check your internet and try again."
            case .noRelease: return "No version to download was found."
            }
        }
    }

    static func latest() async throws -> Release {
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10")!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 15
        guard let res = try? await URLSession.shared.data(for: r), (res.1 as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.offline }

        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Item: Decodable { let tag_name: String; let body: String?; let draft: Bool; let prerelease: Bool; let assets: [Asset] }
        let items = (try? JSONDecoder().decode([Item].self, from: res.0)) ?? []
        let all = items.compactMap { i -> Release? in
            guard !i.draft, !i.prerelease, i.tag_name.hasPrefix("v"),
                  let a = i.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }) else { return nil }
            return Release(version: String(i.tag_name.dropFirst()), notes: clean(i.body ?? ""), url: a.browser_download_url)
        }
        guard let newest = all.max(by: { isNewer($1.version, than: $0.version) }) else { throw Failure.noRelease }
        return newest
    }

    // Saved as "FIRE-1.3.ipa" in the app's temporary folder.
    static func download(_ r: Release) async throws -> URL {
        guard let res = try? await URLSession.shared.download(from: r.url), (res.1 as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.offline }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("FIRE-\(r.version).ipa")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: res.0, to: target)
        return target
    }

    // "1.10" is newer than "1.9"; "1.2.1" is newer than "1.2".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // Release notes as plain text, without the download line under them.
    private static func clean(_ t: String) -> String {
        (t.components(separatedBy: "\n---").first ?? t)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^- ", with: "• ", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// The settings row: check, download, then hand the file to the signing app.
struct UpdateRow: View {
    private enum Phase: Equatable { case idle, checking, upToDate, available(Updater.Release), downloading(Updater.Release), failed(String) }

    @State private var state = Phase.idle
    @State private var file: URL?

    var body: some View {
        Group {
            switch state {
            case .idle:
                Button { check() } label: { Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath") }
            case .checking:
                HStack(spacing: 10) { ProgressView(); Text("Checking…").foregroundColor(.soft) }
            case .upToDate:
                Button { check() } label: { Label("FIRE is up to date", systemImage: "checkmark.circle.fill") }
            case .available(let r):
                VStack(alignment: .leading, spacing: 8) {
                    Button { download(r) } label: { Label("Download Version \(r.version)", systemImage: "arrow.down.circle.fill").bold() }
                    if !r.notes.isEmpty { Text(r.notes).font(.footnote).foregroundColor(.soft) }
                }
            case .downloading(let r):
                HStack(spacing: 10) { ProgressView(); Text("Downloading \(r.version)…").foregroundColor(.soft) }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 6) {
                    Text(msg).font(.footnote).foregroundColor(.red.opacity(0.9))
                    Button("Try Again") { check() }
                }
            }
        }
        .sheet(item: Binding(get: { file.map(SharedFile.init) }, set: { if $0 == nil { file = nil } })) { f in
            ShareSheet(url: f.url)
        }
        .task { if state == .idle { check() } }
    }

    private func check() {
        state = .checking
        Task {
            do {
                let r = try await Updater.latest()
                state = Updater.isNewer(r.version, than: Updater.version) ? .available(r) : .upToDate
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ r: Updater.Release) {
        state = .downloading(r)
        Task {
            do {
                file = try await Updater.download(r)
                state = .available(r)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
