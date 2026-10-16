# Architecture

| Component | Responsibility |
| --- | --- |
| `Sources/main.swift` | AppKit menu bar, SwiftUI settings/recipient panel, notifications, login item, CoreBluetooth peripheral and GATT |
| `Sources/ShareViewController.swift` | Finder Share extension; hands selected file URLs to the native host |
| `Sources/BrandLogos.swift` | Cached, bundled official manufacturer images; no runtime image downloads |
| `Sources/TransferProgress.swift` | Sending phases, bounded percentage and recipient snapshot for the progress view |
| `Sources/discovery.py` | macOS repeat-advertisement delivery for live recipient expiry |
| `Sources/Peer.swift` | Recipient presentation, local alias keys and duplicate-name disambiguation |
| `Sources/peer_metadata.py` | Conservative advertisement metadata parsing and recipient identity across endpoint changes |
| `Sources/Localization.swift` | English/Simplified Chinese strings and system-language fallback |
| `Sources/engine.py` | BLE central scanning, protocol negotiation, local HTTPS/WebSocket transfer, archive validation and saving |

The native host and bundled engine communicate through JSON lines over process pipes. No network listener is used for this local IPC.

Discovery uses Bluetooth; file bytes use the existing local network. The receiving Mac advertises service `8881` and exposes the GATT service `9999`. The outgoing path scans compatible device service data and negotiates with the selected device. Platform and vendor variations still need physical-device tests.

The implementation uses P-256 key exchange and the observed protocol's AES-CBC format for negotiation. The sender serves a ZIP archive over HTTPS and exchanges control messages over a TLS WebSocket. The receiver pins the download certificate to the certificate from the same session's WebSocket. This is session consistency, not independently authenticated peer identity.

Incoming archives are checked for count, total size, unsafe paths and unsupported entry types. Completed files are placed without overwriting existing files, and receive a quarantine attribute. Acceptance is required for each transfer. The implementation has not undergone an independent security audit.

There is no runtime import of mtapy; [NOTICE.md](../NOTICE.md) records the earlier prototype's use and the research references. Wi-Fi Direct, Huawei Share and Google Quick Share are outside the current implementation.

## Trusted-device receive filter

The host persists a user-managed list of CoreBluetooth central UUIDs separately from display aliases. The engine checks the UUID before deriving an incoming session key, and rechecks both the filter and enabled state after the acceptance prompt resolves. It never grants trust from a name or advertised ID. No file is downloaded before approval. Active transfers continue when trust is removed.

CoreBluetooth identifiers are local remembered endpoints, not authenticated credentials. They can change; this feature is an allowlist for ordinary nearby-device use, not cryptographic pairing or a defense against a capable impersonator. Discovery advertisements remain public. Adding requires a remembered incoming CoreBluetooth central UUID or an outgoing CoreBluetooth peripheral UUID saved in transfer history, plus an explicit user action. Records remain available offline. An outgoing endpoint UUID may differ from the UUID observed when that device later sends; a mismatch remains rejected and requires registering an incoming request. Advertised protocol IDs and account names are never used as trust keys. The one-time endpoint-history migration removes legacy records without endpoint identifiers. Future failed requests without an identity remain ordinary transfer history but are never trust candidates.

The Control Center extension uses public WidgetKit controls and App Intents on macOS 26+. It launches the host through anDrop’s URL handler to open the compact receive panel. One Receive control exposes receive-scope choices in the host-owned native panel; the system control itself is an action button without shared live state. The public API cannot embed an arbitrary detail popover inside Control Center. The normal menu bar remains available on older macOS versions.

Receiving is enabled for the entire lifetime of the host app. There is no persisted on/off preference or UI switch; quitting stops advertising and terminates the engine. The Receive control launches the host when needed.
