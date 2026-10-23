# Architecture

[简体中文](architecture.md) · English

| Component | Responsibility |
| --- | --- |
| `Sources/main.swift` | AppKit menu bar, SwiftUI settings/recipient panel, notifications, login item, CoreBluetooth peripheral and GATT |
| `Sources/ShareViewController.swift` | Finder Share extension; hands selected file URLs to the native host |
| `Sources/SharedFileStaging.swift` | Private copies of callback-scoped share files; legacy URL and encoded-media provider fallbacks |
| `Sources/motion_photos.py`, `live_photo_archives.py` | Moving-photo framing, bounded OShare ZIP validation and file-only `.pvt` receipt |
| `Sources/LivePhotoConverter.swift` | Bundled AVFoundation/ImageIO conversion and PhotoKit file-pair validation without library access |
| `Sources/BrandLogos.swift` | Cached, bundled official manufacturer images; no runtime image downloads |
| `Sources/TransferProgress.swift` | Sending phases, bounded percentage and recipient snapshot for the progress view |
| `Sources/discovery.py` | macOS repeat-advertisement delivery for live recipient expiry |
| `Sources/ReceiveAccessPolicy.swift` | GATT access checks using local trusted endpoint identifiers |
| `Sources/Peer.swift` | Recipient presentation, local alias keys and duplicate-name disambiguation |
| `Sources/peer_metadata.py` | Conservative advertisement metadata parsing and recipient identity across endpoint changes |
| `Sources/Localization.swift` | English/Simplified Chinese strings and system-language fallback |
| `Sources/engine.py` | BLE central scanning, protocol negotiation, local HTTPS/WebSocket transfer, archive validation and saving |

The native host and bundled engine communicate through JSON lines over process pipes. No network listener is used for this local IPC.

Discovery uses Bluetooth; file bytes use the existing local network. The receiving Mac advertises service `8881` and exposes the GATT service `9999`. The outgoing path scans compatible device service data and negotiates with the selected device. Platform and vendor variations still need physical-device tests.

The implementation uses P-256 key exchange and the observed protocol's AES-CBC format for negotiation. The sender serves a ZIP archive over HTTPS and exchanges control messages over a TLS WebSocket. The receiver pins the download certificate to the certificate from the same session's WebSocket. This is session consistency, not independently authenticated peer identity.

Incoming archives are checked for count, total size, unsafe paths and unsupported entry types. Completed files are placed without overwriting existing files, and receive a quarantine attribute. Acceptance is required for each transfer. The implementation has not undergone an independent security audit.

There is no runtime import of mtapy; [NOTICE.md](../NOTICE.en.md) records the earlier prototype's use and the research references. Wi-Fi Direct and Google Quick Share are outside the current implementation. Huawei Share is officially supported as the headline feature of 1.2.0, with dedicated native LAN discovery and a bundled Python runtime using RSA/AES-GCM and DFile transfer over the existing LAN. See [compatibility](compatibility.en.md) for tested models and [usage](usage.en.md) for transfer limits. 鸿蒙星河互联 coexistence remains experimental.

## Trusted-device receive filter

The host persists a user-managed list of CoreBluetooth central UUIDs separately from display aliases. The host gates GATT status reads and whole write batches before responding with application state or buffering data. Unlisted subscriptions receive no application notification; queued notifications are rechecked at delivery and are never broadcast using a nil subscriber list. The engine independently filters ready notifications and checks the UUID before deriving an incoming session key, and rechecks both the filter and enabled state after the acceptance prompt resolves. It never grants trust from a name or advertised ID. No file is downloaded before approval. Active transfers continue when trust is removed.

Trust candidates come from completed incoming transfers and require explicit enrollment. Alliance records use `sender:` plus SHA-256 of the self-reported protocol sender ID; these are not authenticated credentials. Huawei records use `huawei-key:` plus SHA-256 of the canonical DER RSA public key, supplied to the runtime only after a valid AES-GCM offer proves possession of the private key. Raw Huawei keys never enter probe evidence. Discovery IDs, names, IP addresses and account names do not establish trust. Huawei key continuity is local enrollment, not vendor/account authentication. Changed keys or sender IDs require a new Everyone-mode receipt and enrollment; older Huawei history has no key and cannot be migrated. Records remain available offline. Only Alliance sender IDs allow GATT metadata negotiation; Huawei keys do not open that path. In trusted-only mode, both protocols reject unlisted identities before prompting or receiving file data. Automatically accepting enrolled transfer identities defaults to on in both receive modes and can be disabled in Settings. Manual approvals recheck permission after the prompt resolves. Unlisted identities in Everyone mode always require manual approval. Already accepted transfers can finish after trust removal. Discovery remains public; see [trusted receiving versus discovery](trusted-discovery.en.md).

Receiving is enabled while the host is running and Bluetooth and Wi-Fi are available. There is no persisted on/off preference. Quitting stops advertising and terminates the engine. Bluetooth/Wi-Fi unavailability disables new receive requests and stops advertising.

Control Center integration is removed from the production build. The compact receive panel is preserved as a [standalone UI prototype](../Prototypes/ReceivePanel/README.en.md) with its native glass wrapper, SF Symbols and mock preview. The host no longer builds WidgetKit/App Intents components or publishes an App Group snapshot. Old control URLs open the ordinary Settings window.

The recipient popup starts a send immediately when a device is clicked and keeps discovery running so other recipients remain clickable during transfers. The first click retains the current file batch; later recipient clicks reuse that batch while preserving any newly queued Finder selection. The host retains a file list and request ID per recipient. The engine reserves outgoing sessions by request ID and destination, with separate keys, archives, sockets and cancellation tasks; Huawei sends also own separate subprocess groups. Incoming transfers remain exclusive, and new incoming requests are rejected while outgoing sessions are active. Repeating a request ID is idempotent; a second active send to the same destination is rejected.

Each tile shows its own progress, result, retry and cancellation. Cancel All stops active sends and pending retries. Done closes the result, and outside-click dismissal is enabled only after every recipient succeeds. Clicking another window during sending leaves all transfers running in the background.
