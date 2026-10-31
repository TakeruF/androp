# anDrop

**Send files between your Mac and a phone or tablet using its built-in compatible sharing feature.**

[简体中文](README.md) · English

[<img src="https://raw.githubusercontent.com/machiav3lli/oandbackupx/main/badge_github.png" alt="Get it on GitHub" height="60">](https://github.com/TakeruF/androp/releases/latest)

anDrop is a macOS menu bar app that officially supports the **互传联盟 (Mutual Transfer Alliance)** ecosystem and **Huawei Share**. No prior connection to a vendor desktop app, extra phone app, account or USB cable is needed. File transfers stay on the local network. **Both devices need Bluetooth enabled and must connect to the same Wi-Fi network (the same LAN).**

**[Download anDrop](https://github.com/TakeruF/androp/releases/latest)** · [Usage and troubleshooting](docs/usage.en.md) · [Compatibility](docs/compatibility.en.md) · [Privacy policy](https://takeruf.com/en/projects/androp/privacy)

**1.3.0: App Sandbox.** The app and transfer tools run in a sandbox with explicit file and save-folder grants. Huawei receive and Finder Share work across the sandbox boundaries. Custom receive folders may need reselection after upgrading. See the [1.3.0 release notes](docs/releases/1.3.0.en.md).

**1.2.2** added Live Photo conversion and improved photo sharing. Convert Apple, Android/OPPO and Huawei moving-photo formats; receive OPPO Live Photo ZIPs as `.pvt` files without automatic Photos import. Photo sharing adds alternative provider-loading methods. URL and text sharing are unsupported. See the [1.2.2 release notes](docs/releases/1.2.2.en.md) for scope and remaining device checks.

Version 1.3.0 provides a DMG for **Apple Silicon Macs running macOS 14 or later**. This sandbox build passed 4 MiB round trips with matching hashes on **OPPO Pad 4 Pro** and **Huawei Pura 70 running HarmonyOS 7**. OPPO Find X9 Pro passed multi-scenario testing in earlier releases; its 1.3.0 sandbox retest remains outstanding. Other brands and models remain untested. Build checks enforce the minimum OS for bundled binaries, but macOS 14 has not been tested on a physical Mac. Mock images do not establish compatibility with every brand shown.

**1.2.0** adds official Huawei Share support, concurrent sends to different devices, recipient renaming/hiding from the context menu, and automatic update installation with notifications. It also improves photo receipt and trusted-device management. See the [release notes](docs/releases/1.2.0.en.md) and [test record](docs/testing.en.md). When upgrading from 1.0.0, re-enroll old trusted-device entries after successfully receiving a file; see the [1.1.0 upgrade notes](docs/releases/1.1.0.en.md).

## Install and get started

1. Download the `.dmg`, open it and drag **anDrop** into **Applications**.
2. Open anDrop and allow Bluetooth, Local Network, notifications and destination-folder access as needed. A paper-plane icon appears in the menu bar.
3. Enable compatible sharing on the other device and connect both devices to the same local Wi-Fi. Guest networks or networks that isolate devices may prevent transfers.

**We recommend quitting 鸿蒙星河互联 before using anDrop.** anDrop handles Huawei Share file transfers on its own and can replace 鸿蒙星河互联's file-sharing function, so the two apps do not need to run together. Coexistence remains experimental and may affect discovery or transfers. Finish any transfers in 鸿蒙星河互联 before quitting it. If anDrop detects 鸿蒙星河互联 running when a send or receive fails, a popup recommends quitting 鸿蒙星河互联 and trying again.

Fresh installations default to **Simplified Chinese**. Choose English or System Default in Settings; an existing language choice is preserved. Receiving is enabled while anDrop is running; quit to stop receiving. No main window needs to stay open. The Dock icon normally stays hidden; it remains visible while 鸿蒙星河互联 runs to improve Bluetooth discovery.

## See how it works

These are production app views with fictional device names, filenames, Computer Name and progress. They contain no real accounts, device records or transferred content.

### Mac → phone or tablet

Enable sharing and nearby visibility on the receiving device. You may need to temporarily select Everyone; some systems automatically expire this mode after a few minutes.

Select files in Finder, then **Share → anDrop**, or choose **Send Files** in the menu bar. A badge beside the manufacturer logo distinguishes phones, tablets and computers. Click a device to start sending immediately, then approve receipt on it. Other devices remain clickable: click another to send the same files there too, including while the first transfer is running. Right-click the device icon to choose **Rename Device…** or **Hide from Candidates**. Names stay on this Mac. Restore hidden devices in Settings → **Hidden Devices…**.

<img src="docs/images/recipients-en.png" alt="Mock recipient chooser with fictional phone, tablet and computer names, Huawei/HONOR/Xiaomi and other manufacturer logos, and device type badges" width="600">

The progress ring and percentage show sending progress. Preparing, waiting and connecting have separate states. Sent appears only after the recipient confirms completion. Clicking another window moves anDrop into the background while sending continues.

<img src="docs/images/sending-en.png" alt="Mock sending view with separate 42 and 68 percent progress rings for OPPO and Huawei recipients" width="600">

Before sending, Cancel dismisses the picker. Each recipient has independent progress, cancellation and retry. **Cancel All** stops active sends and pending retries. After every recipient succeeds, clicking outside dismisses the popup.

### Phone or tablet → Mac

1. Select files on the device, open its built-in compatible sharing feature and choose the Mac.
2. Accept in anDrop’s notification or menu bar. **Trusted devices are accepted automatically by default; this can be turned off in Settings.**
3. Files go directly into **Downloads** by default. Duplicate names receive a numeric suffix; existing files are never overwritten and received files are not opened automatically.

Sends to different devices can run concurrently. Receiving remains exclusive. Compress folders first. Send files with identical base names in separate transfers.

### Settings

Change the destination folder, sharing name, language, Open at Login, receiving scope and update settings. License and GitHub links are at the bottom.

<details>
<summary>View Settings (mock data)</summary>

<img src="docs/images/settings-en.png" alt="Mock settings showing destination, trusted devices, language, sharing name, automatic updates and license links" width="600">

</details>

## Receive scope and trusted devices

Choose **Trusted Devices Only** or **Everyone** in the menu bar or Settings. **Automatically accept from trusted devices** is on by default in both modes. Turn it off in Settings to approve each transfer. Untrusted devices always require approval in Everyone mode.

**This differs from AirDrop Contacts Only: untrusted devices may still see this Mac. Trusted Devices Only rejects their transfer requests; it does not hide anDrop.** See [discovery limits and receive filtering](docs/trusted-discovery.en.md).

In Settings → **Trusted Devices…**, add devices from successful incoming transfers even when they are offline. New devices must first send a file to this Mac in Everyone mode. Rows show manufacturer artwork, a phone/tablet badge and a device name. Local identifier suffixes distinguish identical names. Remove trust or forget a device at any time.

<img src="docs/images/trusted-en.png" alt="Mock trusted-device management with manufacturer artwork and add, remove and forget controls" width="600">

The filter stores a hash of the protocol sender ID, so rotating Bluetooth addresses do not remove trust. Names and accounts do not authorize receipt. This is a self-reported ID, not cryptographic pairing or authenticated identity. After the control connection supplies the ID, unlisted senders are rejected before approval and before downloading files. Listed senders are accepted automatically when the setting is on; otherwise they require approval. Removing trust does not interrupt an already accepted transfer. Old UUID-only entries require one incoming transfer in Everyone mode and enrollment of the new record; matching a display name is not a safe migration.

Huawei devices can also be added: after updating, receive a file in Everyone mode, then add the device here. Huawei records use a SHA-256 fingerprint of the transfer public key, with proof of possession during each receive handshake. Names, IP addresses and discovery advertisements do not authorize receipt. This is local enrollment, not Huawei account pairing. If the key changes, receive and enroll again. Older Huawei history has no key and cannot be migrated automatically.

## Automatic updates

**Automatic checks and automatic installation are enabled by default.** anDrop checks GitHub Releases at launch and periodically afterward. Once an update is downloaded and its signatures are verified, anDrop installs it and restarts automatically, and a notification tells you which version was installed. Checks and restarts wait until transfers finish. With automatic installation off, a notification tells you when a new version is available.

Disable automatic checks or installation in Settings → Updates, or check manually from the menu bar. Updating needs access to GitHub; file sharing does not use a cloud service.

## Common questions

| What happened? | What to try |
| --- | --- |
| anDrop is missing from Finder’s Share menu | Open anDrop once and enable its Share extension in macOS settings, or send from the menu bar. |
| The Mac cannot find a device | Unlock it, reopen sharing, enable Everyone visibility and check the Wi-Fi. Visibility may have expired. |
| A device remains listed briefly after becoming undiscoverable | It normally disappears about 10–11 seconds after its last Bluetooth advertisement. The Mac cannot read the other system’s visibility countdown. |
| Two devices show the same person’s name | Sharing names can come from an account. Use the badge and right-click the device icon to rename or hide it locally. For identical entries, initially make only one discoverable. |
| No notification appears | Check macOS notification and Focus settings. Approval and progress are also available in the menu bar. |
| Discovery or transfers fail while 鸿蒙星河互联 runs | Finish any 鸿蒙星河互联 transfers, quit 鸿蒙星河互联 and retry. anDrop handles Huawei Share file transfers on its own. Coexistence remains experimental. |
| Finder’s Share menu still shows the old icon | macOS may retain the old extension icon in its cache. Restart the Mac later; this does not prevent file transfers. |

Names and privacy: local device aliases allow **40 characters** and do not rename the phone or account. The Mac uses its system Computer Name by default; change the sharing name with the pencil in Settings, or leave it blank to restore the default. Nearby names allow **15 UTF-8 bytes** (typically 15 ASCII characters, or about 5 Chinese characters); transfer confirmations use the full sharing name. Nearby devices can see the advertised name. History stays on this Mac and can be cleared in Settings. While 鸿蒙星河互联 runs, the nearby name temporarily becomes `A`.

## Logs and bug reports

After a transfer fails, choose **Show Logs** in its notification, or open **Diagnostics & Bug Report…** in Settings. Preview the report, reveal it in Finder, or choose **Report a Bug…** to compose an email to `support@takeruf.com` with the log attached. Add reproduction steps and the other device’s model and OS version, then review and send it yourself. anDrop does not send reports automatically. If composing mail fails, attach the log manually.

Reports contain transfer stages, error codes, file types and count, device manufacturer and type, Mac/anDrop versions, and names and identifiers of Mac apps running when the transfer started and failed. They exclude file names, contents, device names, network addresses and credentials. Logs stay on this Mac, retaining up to 300 recent events, 20 failure snapshots and 10 exported reports. Older failures may have no detailed log. See [diagnostic fields and limitations](docs/diagnostics.en.md) for developers.

## Which devices work?

The Mutual Transfer Alliance is a cross-brand ecosystem used by Xiaomi, HONOR, OPPO, vivo and other manufacturers. **It is separate from Google Quick Share and is not an Android-wide standard.** See [HONOR’s official overview](https://www.honor.com/cn/support/content/zh-cn15883773/). Compatibility depends on model, region and software version. Alliance membership or a displayed logo does not establish anDrop compatibility.

| Device or feature | Current status |
| --- | --- |
| OPPO Find X9 Pro | Physically tested across multiple scenarios, including same-Wi-Fi transfers in both directions, with file hashes checked. |
| OPPO Pad 4 Pro | Physically tested across multiple scenarios, including discovery, tablet identification and same-Wi-Fi transfers in both directions. |
| HONOR | Models supporting both Huawei Share and Android mutual transfer (安卓互传) are a priority for upcoming physical validation. We plan to test discovery and bidirectional file transfers separately through both sharing methods. Availability depends on model and OS version; physical testing remains outstanding. |
| Xiaomi, vivo and other brands/models | Compatible devices in the target ecosystem; not physically tested yet. |
| Apple Silicon Mac, macOS 27.0.1 | Tested development environment. Release targets macOS 14+. Physical macOS 14 and Intel testing remain outstanding; no Intel installer is provided in 1.3.0. |
| 鸿蒙星河互联 coexistence | Experimental. We recommend finishing any 鸿蒙星河互联 transfers and quitting it, then using anDrop for file sharing to avoid discovery or transfer conflicts. |
| Huawei Share | **Officially supported by anDrop on the same LAN. Test device: Huawei Pura 70 running HarmonyOS 7 (鸿蒙 7).** Three-file app transfers in both directions, Downloads receipt, duplicate-name receipt, and content verification passed. The phone is found while its screen is on, without opening its share sheet. The first transfer needs “Everyone” on the phone; afterwards “Devices shared with” also works. Transfers can be retried right after a cancel or dropped connection. Earlier physical checks passed bidirectional transfers with empty files, Japanese names and 8 MiB, including Downloads receipt and duplicate-name handling. Phone identity authentication, screen-off discovery, and Wi-Fi loss recovery remain under validation. See the [research record](docs/huawei-share-research.en.md). |
| Wi-Fi Direct, Google Quick Share | Not implemented. |

Physical transfer results come from development testing, not a fresh test after every UI or packaging change. See [compatibility](docs/compatibility.en.md) and [validation records](docs/testing.en.md). Brand/category recognition does not identify the exact model.

Current source allows Mac → Huawei sends of up to 16 files, 4 GiB per file and 16 GiB total, using disk snapshots and chunked encryption. A 64 MiB transfer passed local socket integrity and memory checks; GiB-scale physical transfers remain unverified. Huawei → Mac receipt remains limited to 16 MiB per file and 16 MiB total.

## Build from source

Most users should download the DMG. Developers need Xcode 26 or later, Swift 6.2+ and Python 3.14. **Use Python and dependencies built for older macOS versions**, such as the official python.org installer. A local Homebrew Python may require a newer OS. The build checks every bundled Mach-O binary against the declared minimum.

```sh
python3.14 -m venv .venv
.venv/bin/python -m pip install --only-binary=:all: -r requirements.txt
.venv/bin/python build.py
```

Output: `build/anDrop.app`. Local builds are ad-hoc signed by default; release builds use Developer ID. The build fetches a pinned, checksum-verified Sparkle framework. See [building, signing and releases](docs/building.en.md). Disabling macOS security features is not required.

<details>
<summary>Developers: tests, architecture and documentation images</summary>

```sh
.venv/bin/python -m unittest discover -s tests -v
swift test
python3 scripts/render-docs.py
```

- [All documentation and language conventions](docs/README.en.md)
- [Huawei Share physical-device research](docs/huawei-share-research.en.md)
- [Android/OPPO notification types](docs/android-file-type-research.en.md)
- [OPPO contacts and own-device research](docs/oppo-own-device-research.en.md)
- [Architecture and protocol boundaries](docs/architecture.en.md)
- [Detailed usage and troubleshooting](docs/usage.en.md)
- [Device identification](docs/device-identification.en.md)
- [Documentation image generation](docs/images/README.en.md)
- [Archived receive-panel prototype](Prototypes/ReceivePanel/README.en.md): source and standalone preview of the removed Control Center panel, excluded from release builds.

The repository is named **androp**; the app is named **anDrop**.

</details>

## License and affiliation

Project-authored source, documentation and app icons use **GPL-3.0-only**. Dependencies retain their own licenses. [Official manufacturer artwork](Resources/BrandLogos/README.en.md) retains its owners’ copyright and trademark rights and is excluded from the GPL grant, including artwork visible in documentation images. See [LICENSE](LICENSE), [NOTICE.md](NOTICE.en.md) and [licensing details](docs/licensing.en.md).

The project is not affiliated with, certified by or endorsed by manufacturers or Apple. Documentation images contain fictional data only. Real device logs, private screenshots, vendor APKs, decompiled vendor source, credentials and private keys are excluded. Developer ID certificates are inspectable and identify their signer; anonymous source metadata does not hide that identity.
