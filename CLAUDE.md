# CLAUDE.md

FIRE for iPhone and iPad: a SwiftUI Xtream IPTV player (iOS 16+, `TARGETED_DEVICE_FAMILY` 1,2, all orientations, always dark). It mirrors the Android TV app in `D:\ai\fire` (same logic for category sorting, Arabic-first search, name tags, resume rules); keep the two in step when behaviour changes.

## Building

No local build: development is on Windows. `project.yml` (XcodeGen) + `Podfile` (MobileVLCKit). Every push to `main` runs `.github/workflows/build.yml` on macOS: `xcodegen generate`, `pod install`, unsigned `xcodebuild` of `Fire.xcworkspace`, zips `Fire.ipa` and publishes Release `v<MARKETING_VERSION>` with the `## <version>` section of `CHANGELOG.md` as notes. Compile errors show as annotations. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) for each release, or the release step reuses the tag.

The repo is public: never commit account details. The account lives in the Keychain (`Account` in `Api.swift`); the login screen only pre-fills the server address.

## Layout

All sources are flat in `Sources/`.
- `Models.swift`: Item/Cat/Info/Prog/SeriesInfo, lenient Xtream parsing, `nameTags`/`cleanTitle`, `eachObject` (walks a huge JSON array object by object without loading it whole).
- `Api.swift`: Keychain account, URLs, requests. `Store.swift`: disk + memory cache with TTL and stale fallback; `Q` query strings; `CatSort`.
- `Search.swift`: actor; downloads the full list once a day to a TSV index and searches it in memory.
- `Library.swift`: favourites, Continue Watching, resume points (UserDefaults), `Epg` actor (now/next).
- `Images.swift`: downsampled image loader, `RemoteImage`, colours, `Metrics` (all sizes derive from screen width; `compact` < 600pt = phone layout).
- `FireApp.swift`: `AppState` (navigation path, player request), login, settings. `Updater.swift`: checks GitHub releases of this repo and hands the downloaded IPA to the share sheet (same as StampCam); keep the tag `v<version>` and asset `Fire.ipa`. `RootView.swift`: header + tabs, `BrowseModel`, rows. `Cards.swift`: cards and hero. `Details.swift`: film and series pages. `Player.swift`: VLC wrapper (polled every 0.5 s, not delegates), player UI, live guide.

VLC is used because AVPlayer can't play the provider's MKV/HEVC files. The account allows one connection: always `vlc.stop()` when leaving the player.
