# anDrop for iPhone and iPad

[简体中文](README.md) · English

A native iOS / iPadOS interoperability preview in this repository's `ios/` directory. The current version is **0.5.0 (9)** and requires iOS / iPadOS 17 or later. It builds separately from the released macOS app at the repository root. No App Store or TestFlight distribution is available.

## Features and limits

- Discover compatible Alliance sharing devices with CoreBluetooth; use P-256, the existing protocol's AES-CBC negotiation, TLS / WebSocket control and HTTPS ZIP transfer.
- Require manual incoming approval; validate names, paths, counts, total size, CRC and SHA-256. Preserve existing files on name collisions and never open received files automatically.
- Import from the system share sheet in Files, Photos and other apps, preserving names and bytes. Each batch supports **16 files and 64 MiB of original data**.
- On iOS / iPadOS 26 or later, use the system's continued background processing and progress presentation for transfers already started. Supported iPhones can show progress in Dynamic Island. The OS controls continued execution.
- **Experimental Huawei Share sending**: confirm a user-specified IPv4 endpoint on the same Wi-Fi, then use a separate RSA / AES-GCM / DFile transport. Huawei hardware remains unverified. Huawei-to-app receipt and automatic Huawei discovery are not implemented.

A user has reported successful OPPO–iPhone 16 transfers in both directions. This does not establish coverage of every model, format or the current background flow. Final hardware validation of the latest background paths remains pending. HUAWEI Pura 70 / HarmonyOS 7 is the planned Huawei target. See the [validation record](docs/VALIDATION.en.md).

Wi-Fi Direct, permanent background receiving, Google Quick Share, Live Photo conversion and sharing URL/text objects are unsupported. The app UI is currently Japanese.

## Use

1. Open anDrop, allow Bluetooth and Local Network access, and connect both devices to the same Wi-Fi.
2. In the main app, choose files and a nearby recipient. Enable compatible sharing and visibility on that device, then approve receipt there.
3. To receive, keep the main app in front until its request appears and choose “受信する”. Files are saved under Files → On My iPhone / iPad → anDrop → Received.
4. From another app, share to anDrop and choose a recipient. On iOS 26 or later, choose “準備を完了” and manually open the main anDrop app to begin sending. You can switch apps after transfer starts. Older systems require the share extension to stay open.
5. If the OS cannot grant continued background execution, keep the main app open until completion.

[Sharing](docs/SHARING.en.md) · [File formats](docs/FILE-FORMATS.en.md) · [Background transfers](docs/BACKGROUND.en.md) · [Huawei trial](docs/HUAWEI.en.md) · [OPPO testing](docs/OPPO-TESTING.en.md)

Diagnostics stay in the app and contain fixed stages, counts, sizes and bounded error codes. They exclude filenames, contents, IP addresses, device names and keys. Users choose whether to export and send them.

## Development

Use Xcode 27.2 / Swift 6.3 and XcodeGen from `ios/`. `project.yml` is the canonical configuration.

```sh
cd ios
xcodegen generate
swift test --no-parallel
xcodebuild -project anDrop.xcodeproj -scheme anDrop \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

No personal signing team is selected in the public configuration. For hardware builds, choose your own team in Xcode and configure available application IDs, extension IDs and App Group. If changing these identifiers, update `project.yml`, the generated project and the App Group / background-task prefix in `App/BackgroundTransfer.swift`. The app and extension must use the same App Group. Do not commit personal signing configuration, certificates or provisioning profiles.

Device scripts take the team through the environment: `ANDROP_DEVELOPMENT_TEAM=YOUR_TEAM_ID scripts/install-device.sh <device-udid>`. Background hardware tests use the same variable with `scripts/test-background-device.sh <unlocked-device-udid>`. These scripts install and run apps; invoke them only when intentionally testing hardware. Share-sheet UI tests use `scripts/test-simulator.sh <simulator-udid>`.

`Core/` is testable on macOS, `App/` contains the main app, `ShareExtension/` the sharing extension, and `TestSupport/` the test utilities. The helper app is not embedded in the product. The iOS product uses no Python runtime, external processes or private APIs.

## Licensing and publication

GPL-3.0-only, based on this repository's macOS protocol work. ZIPFoundation 0.9.20 is MIT licensed. Preserve [LICENSE](LICENSE), [NOTICE.en.md](NOTICE.en.md) and dependency notices. No manufacturer logos are bundled.

The public source contains reviewed code, configuration, synthetic test generators and documentation. Real diagnostics, screenshots, captures, private samples, development signing identities, device identifiers and build products are excluded. Existing macOS release assets are separate from this iOS source preview.
