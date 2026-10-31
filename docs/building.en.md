# Building and releasing anDrop

[简体中文](building.md) · English

## Requirements

- Xcode 26 or later and Swift 6.2+ (`-default-isolation MainActor`). Version 1.3.0 was built on Apple Silicon with macOS 27.2, Xcode 27.1 and Swift 6.4.
- Python 3.14 and the pinned dependencies in `requirements.txt`. Version 1.0.0 uses the official python.org 3.14.7 runtime and binary wheels.
- The build resolves SDKROOT from the selected Xcode to avoid mixing its compiler with a newer Command Line Tools SDK.
- The build machine must match the target CPU architecture. The published 1.0.0 DMG is arm64 only; Intel is untested.
- Normal builds fetch official Sparkle 2.10.0 from the URL in `release.json`, verify its pinned SHA-256 and embed the framework. Build-time network access is required on the first run.

The deployment target is **macOS 14.0**. A Homebrew Python built for macOS 26 cannot be made compatible by changing only Info.plist. Use a Python distribution and native wheels built for the minimum OS, such as the official python.org macOS installer. The build rejects bundled Mach-O files whose deployment target exceeds the declared minimum or whose load commands refer to build-machine libraries. This is a packaging check, not a physical test on macOS 14.

```sh
python3.14 -m venv .venv
.venv/bin/python -m pip install --only-binary=:all: -r requirements.txt
.venv/bin/python build.py
```

Output: `build/anDrop.app`. The script compiles the Swift host and Finder Share extension, freezes the Python engine with PyInstaller, embeds Sparkle and licenses, signs nested code from the inside out and verifies the complete signature. Temporary staging avoids extended filesystem attributes invalidating signatures.

The build also compiles and signs `anDropLivePhoto`, an AVFoundation/ImageIO/PhotoKit helper. The frozen engine must resolve and execute this bundled helper during the packaging check. `python3 scripts/test-live-photo-native.py` verifies synthetic conversion and the production send/receive hooks without accessing the Photos library.

After a complete build, `build.py --ui-only` reuses its engine. Rebuild fully after changing engine code, Python or dependencies. The runtime compatibility check still runs for a UI-only build.

Version, monotonically increasing build number, minimum OS and public update feed live in `release.json`. `ANDROP_VERSION` and `ANDROP_BUILD` may override version/build for local tests. Release packaging rejects a mismatch with the release configuration.

## Signing

Default local builds are ad-hoc signed. Supply a configured Developer ID Application identity through the local `ANDROP_SIGN_IDENTITY` environment variable for a release. Real signatures use hardened runtime and secure timestamps. Certificates, identity strings, team identifiers and private keys must remain outside tracked files.

The distributed bundle identifier is `com.takeruf.anDrop`, fixed in `release.json`; `ANDROP_BUNDLE_ID` can override it for isolated local tests. Preserve the distributed identifier across updates. Changing it can reset permissions, preferences, login items and extension registration.

Developer ID certificates identify the signer. Anonymous Git metadata does not anonymize a signed app. Inspect the concrete signed artifact and resolve any publication/privacy constraint before uploading it.

## Automatic updates

The host and bundled tools now use App Sandbox. See [sandbox integration and validation](sandbox.en.md) for file grants, migration, isolated test builds and the remaining device/update checks.

The app embeds the public Ed25519 key in `Resources/UpdatePublicKey.txt`. The matching private key stays in the login Keychain under the account named in `release.json`; do not commit or export it. Create your own key when distributing a fork:

```sh
build/dependencies/Sparkle-2.10.0/bin/generate_keys --account org.example.your-app
```

The official Sparkle tools generate signed update archives and a signed appcast. Both signed feeds and verification before extraction are required. The feed is served from the public repository’s latest GitHub Release asset named `appcast.xml`. Automatic checks and automatic installation default to on; persisted choices are preserved. A verified automatic download installs and relaunches immediately when no transfer is active (otherwise right after the transfer finishes), with a user notification before and after the relaunch. When automatic installation is off, scheduled checks use Sparkle's gentle reminders: a notification is posted instead of the update alert, and clicking it opens the alert. Update dialogs follow the app language.

`build.py --app-store` excludes Sparkle, its feed and updater UI. This is a build switch for future store distribution, not a claim of App Store approval or complete store compliance.

Both distribution configurations set `LSApplicationCategoryType` to `public.app-category.utilities` (Utilities) and show Settings → Privacy Policy in the app language. The public policy is at `https://takeruf.com/en/projects/androp/privacy` (Chinese: `/zh/projects/androp/privacy`). When preparing an App Store listing, use that policy URL and select Utilities as the primary category in App Store Connect; the build does not change the listing automatically. The source policies are `docs/privacy.en.md` and `docs/privacy.md`; keep their copies in `TakeruF/me` (`src/content/androp/privacy.en.md` and `privacy.zh.md`) and the Japanese/Korean translations in sync when data handling changes.

## Notarization and DMG packaging

The release helper never publishes. It keeps public assets separate from private signing/notarization records. Set `ANDROP_SIGN_IDENTITY` locally first, then run:

```sh
.venv/bin/python scripts/release.py prepare
.venv/bin/python scripts/release.py submit
.venv/bin/python scripts/release.py package
```

`prepare --skip-build` uses an already completed build after validating it. By default, submit uses the account already configured in Xcode with `xcodebuild -exportArchive` and `-allowProvisioningUpdates`. Package exports the notarized app with `-exportNotarizedApp` and refuses to continue unless signature verification, stapling validation and Gatekeeper assessment succeed. If notarization is still processing, retry package later.

Alternatively, set `ANDROP_NOTARY_PROFILE` to your own existing Keychain profile before prepare. Submit uses notarytool, and package checks the saved submission status for Accepted before stapling. Keep credentials in the configured Keychain/Xcode account; do not put them in command arguments or source. All export and notarization diagnostics remain private.

The helper packages the stapled app and an Applications link into a DMG, signs the DMG, generates a signed appcast with embedded Chinese notes and writes checksums. **The application is notarized and stapled; the DMG container is Developer ID signed. The helper does not claim a separate DMG notarization.**

Only these files in `dist/<version>/public/` are release assets:

- `anDrop-<version>-arm64.dmg`
- `appcast.xml`
- `SHA256SUMS.txt`

Use `docs/releases/<version>.md` as the GitHub release body. Never upload `dist/<version>/private/`, exported archives, raw build logs, ExportOptions or notarization records. Inspect assets and privacy before the separate explicit GitHub publication step. The repository must be public for unauthenticated update downloads.

## Installation and validation

Quit the old app and replace its complete bundle in Applications. Do not merge bundles: the archived Control Center extension could otherwise remain inside an older installation. Open the app and grant Bluetooth, Local Network, notifications and destination-folder access as requested. Follow macOS’s normal approval flow; do not disable system security protections.

```sh
.venv/bin/python -m unittest discover -s tests -v
swift test
python3 scripts/check-runtime.py build/anDrop.app --minimum 14.0 --arch arm64
codesign --verify --deep --strict build/anDrop.app
```

Refresh dependency notices using `collect-licenses.py` from the exact build environment and inspect native-library provenance. See [licensing](licensing.en.md), [publication privacy](publication.en.md) and [validation records](testing.en.md). The normal build excludes the archived receive-panel prototype and creates no Control Center extension, App Intents metadata or control-state App Group entitlement.

## Huawei Share LAN adapter

A full engine build includes the bounded Huawei protocol modules and explicit AES-GCM/RSA imports for the official Huawei Share support introduced in 1.2.0. The build runs `anDropEngine --huawei-check` without network access before packaging. UI-only builds must reuse an engine built after those changes. Hardware integration evidence and remaining discovery/authentication/recovery checks are tracked in [Huawei Share research](huawei-share-research.en.md). Local validation can use a separate `ANDROP_BUNDLE_ID` to preserve the installed app’s settings.
