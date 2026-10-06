# itube

A native iPhone video app (Swift / SwiftUI / AVFoundation) — not a web wrapper. Architecture is defined in
[`docs/adr-001.md`](docs/adr-001.md); how the code maps onto it is in [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md).

## Build

Requirements: Xcode 26 (Swift 6.2), iOS 18+ device or simulator, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen                 # generates iTube.xcodeproj from project.yml (not committed)
open iTube.xcodeproj
```

Set your signing team in the `iTube` target. Bundle ID: `com.tesmond.itube`.

Run the unit tests (no network needed):

```sh
xcodebuild test -scheme ITubeCore -destination 'platform=iOS Simulator,name=iPhone 16'
```

Background audio, PiP and Lock Screen controls need a **real device** to verify (see "Manual acceptance" in `docs/IMPLEMENTATION.md`).

## Layout

| Path | What |
| --- | --- |
| `Sources/ITubeCore` | All logic (models, networking, providers, media, filtering, persistence). UI-free except `PlayerLayerView`. |
| `Tests/ITubeCoreTests` | Unit tests + recorded-style JSON fixtures (no live network). |
| `App`, `Features` | SwiftUI app target (thin). |
| `UITests` | Smoke UI tests. |

## Distribution builds

The provider set is chosen at build time (ADR §27). Add `-D APPSTORE` to *Other Swift Flags* to build with **no** content
provider (the YouTube integration uses undocumented endpoints — see ADR §25 and the notes in `docs/IMPLEMENTATION.md`).
