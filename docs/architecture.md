# Architecture

| Component | Responsibility |
| --- | --- |
| `Sources/main.swift` | AppKit menu bar, SwiftUI settings/recipient panel, notifications, login item, CoreBluetooth peripheral and GATT |
| `Sources/ShareViewController.swift` | Finder Share extension; hands selected file URLs to the native host |
| `Sources/Localization.swift` | English/Simplified Chinese strings and system-language fallback |
| `Sources/engine.py` | BLE central scanning, protocol negotiation, local HTTPS/WebSocket transfer, archive validation and saving |

The native host and bundled engine communicate through JSON lines over process pipes. No network listener is used for this local IPC.

Discovery uses Bluetooth; file bytes use the existing local network. The receiving Mac advertises service `8881` and exposes the GATT service `9999`. The outgoing path scans compatible phone service data and negotiates with the selected device. Platform and vendor variations still need physical-device tests.

The implementation uses P-256 key exchange and the observed protocol's AES-CBC format for negotiation. The sender serves a ZIP archive over HTTPS and exchanges control messages over a TLS WebSocket. The receiver pins the download certificate to the certificate from the same session's WebSocket. This is session consistency, not independently authenticated peer identity.

Incoming archives are checked for count, total size, unsafe paths and unsupported entry types. Completed files are placed without overwriting existing files, and receive a quarantine attribute. Acceptance is required for each transfer. The implementation has not undergone an independent security audit.

There is no runtime import of mtapy; [NOTICE.md](../NOTICE.md) records the earlier prototype's use and the research references. Wi-Fi Direct, Huawei Share and Google Quick Share are outside the current implementation.
