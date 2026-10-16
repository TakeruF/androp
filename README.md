# anDrop

[简体中文](README.zh-CN.md)

anDrop is a macOS menu bar app for sending and receiving files with devices in the **互传联盟 (Mutual Transfer Alliance)** ecosystem. This repository is named **cn-android-share**; the app is named **anDrop**.

Use a device's built-in compatible sharing feature, without first connecting to a vendor desktop app. Both devices need Bluetooth enabled and the same local Wi-Fi network. No extra phone app, account, cloud service or USB connection is required at runtime.

互传联盟 is a cross-brand ecosystem used by Chinese device manufacturers, including Xiaomi, HONOR, OPPO and vivo. It is separate from Google Quick Share and is not an Android-wide standard. See [HONOR's official cross-brand sharing guide](https://www.honor.com/cn/support/content/zh-cn15883773/).

## Features

- Menu bar On/Off, transfer progress, cancellation, recent transfers and Settings.
- Finder **Share → anDrop** and a compact recipient grid with official brand logos in circles, phone/tablet badges and shared names.
- Optional device names saved only on this Mac; devices sharing an account name stay separate.
- Incoming-transfer approval and completion notifications through macOS Notification Center.
- Receive directly in **Downloads** by default; choose another folder in Settings.
- English, Simplified Chinese and System Default language options.
- Device name follows the Mac's system Computer Name.

## Compatibility and current status

**Development version 0.1.1.** Physical-device send/receive verification: **OPPO Find X9 Pro**. An additional OPPO tablet was verified for discovery/type display and one tablet-to-Mac file receipt; Mac-to-tablet remains untested. **Other brands and models: untested.** This is the tested device, not a restriction to OPPO. Alliance membership does not establish compatibility with this implementation.

Petal Interconnect coexistence is **experimental**. Transfers have succeeded with both apps running, but discovery conflicts can recur; the manual repair is not a guaranteed fix. Same-Wi-Fi transfer is implemented; Wi-Fi Direct and Huawei Share are not implemented.

See the [compatibility matrix](docs/compatibility.md), [test report](docs/testing.md) and [usage and troubleshooting guide](docs/usage.md).

## Build

On macOS with Python 3.14 and a Swift 6.2+ compiler:

```sh
python3.14 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python build.py
.venv/bin/python -m unittest discover -s tests -v
swift test
```

The result is `build/anDrop.app`, ad-hoc signed by default. The recorded development environment used Apple Silicon, macOS 27.0.1, Swift 6.4 and Python 3.14.7. Other toolchain/OS combinations need verification. See [build instructions](docs/building.md) for signing and installation.

## Repository

| Path | Purpose |
| --- | --- |
| `Sources/` | Native menu bar app, Finder extension, localization and transfer engine |
| `tests/` | Protocol, file handling, local-network retry and recipient identity tests |
| `docs/` | Usage, compatibility, validation, architecture and distribution notes |
| `build.py` | Builds and signs the native app and bundled engine |
| `ThirdPartyNotices/` | Dependency license texts and research-reference notices |

## License

Project-authored source, documentation and icon assets are licensed under **GPL-3.0-only**. See [LICENSE](LICENSE), [NOTICE.md](NOTICE.md) and [licensing details](docs/licensing.md). Third-party components retain their own licenses. [Official brand artwork](Resources/BrandLogos/README.md) has separate rights and is excluded from the project license grant.

This project is not affiliated with, certified by or endorsed by the device manufacturers or Apple. Device logs, screenshots, vendor APKs, decompiled vendor source, credentials and signing material are excluded from this repository.
