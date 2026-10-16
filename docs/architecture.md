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

The Control Center extension uses public WidgetKit controls and App Intents on macOS 26+. It launches the host through anDrop’s URL handler to open the compact receive panel. One anDrop control opens a host-owned panel with the receive switch in its header and two receive-scope rows; the system control is a native toggle used as a status indicator. Its disclosure intent opens the panel rather than committing the optimistically requested toggle value; the panel switch remains authoritative. The intent is not exposed as a discoverable Shortcuts action, and requests a reload before and after opening the panel. The public API cannot embed an arbitrary detail popover inside Control Center. The normal menu bar remains available on older macOS versions.

Receiving is enabled while the host is running and Bluetooth and Wi-Fi are available. There is no persisted on/off preference. The receive-panel header switch quits the host when turned off; quitting stops advertising and terminates the engine. Bluetooth/Wi-Fi unavailability disables new receive requests and stops advertising, and is reflected by the header switch. The Receive control launches the host when needed.

The receive panel follows the AirDrop reference geometry: 308 pt width, 42 pt header, 32 pt scope rows and 26 pt circular SF Symbols. Selection highlights the entire row. On macOS 26+, its content is embedded in Apple’s `NSGlassEffectView` with regular Liquid Glass, without custom blur layers or an opaque background. Earlier systems use the standard popover material. The native switch and semantic colors follow system appearance; increased contrast strengthens the selection background. The layout is app-owned, not a reused AirDrop system panel.

The host and control extension share only a Codable presentation snapshot (radio/receive availability, receive scope and UI language) through an entitled App Group; no device identities, names, files or trust lists are shared. The host publishes on launch, scope/language/radio changes and normal termination, and requests a WidgetKit reload. The provider also checks whether the host is running when refreshed. Reload scheduling remains under macOS control, particularly after a crash. Medium tiles show the status label. The symbol and native toggle appearance follow the system accent color. The native active tile background differs from Apple’s private AirDrop module.
