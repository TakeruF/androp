# Trusted devices and Bluetooth visibility

[简体中文](trusted-discovery.md) · English

Updated2026-10-17. **Trusted Devices Only limits receiving, not discovery.** Unregistered devices may still see this Mac in their system share picker, but their files are refused. This differs from AirDrop Contacts Only.

## Why sender identification changed

Physical consecutive receives from one phone rotated CoreBluetooth central UUIDs; the outgoing peripheral UUID also cannot identify an incoming sender. Trusting those UUIDs falsely rejected registered devices.

The filter now uses the protocol senderId learned from successful receipt, storing only SHA-256 locally. Display/account names, IPs, advertising names and transfer task IDs never authorize. Bluetooth rotation does not require enrollment if senderId remains unchanged.

Old entries lack senderId and cannot migrate safely by matching names. Select Everyone, successfully receive once, enroll the new record, then remove the old entry marked for re-enrollment. Peers without valid sender IDs may request receipt in Everyone but do not become persistent trust candidates.

## Receive order

1. Bluetooth negotiates current network endpoints.
2. TLS control reads sender identity and metadata.
3. Trusted-only checks senderId and rejects an unlisted ID before prompting or requesting any file download.
4. Listed senders still require approval; removing trust or disabling receipt while it is pending invalidates acceptance.
5. Download starts after approval and pins the control connection's certificate fingerprint.

With persistent trust entries, an unfamiliar Bluetooth address must be able to perform the first two steps to present the same senderId. This is not automatic file receipt. An empty trusted list rejects immediately. Already accepted transfers may finish; new ones check current policy.

**This is not cryptographic pairing or authenticated identity.** The sender supplies its own ID, so a client spoofing it may pass this convenience filter. Approval is never omitted. Reset or changed protocol IDs require verification and re-enrollment. Certificate pinning ensures session download consistency, not initial identity authentication. Huawei public-key enrollment is separately described in [architecture](architecture.en.md) and [usage](usage.en.md).

## Visibility limits

Inspected OShare17.2.36 adds names/protocol IDs directly upon hearing8881 advertising, before GATT reads. Denying GATT cannot hide the candidate.

Apple's public [CBPeripheralManager.startAdvertising](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)) offers no per-remote advertising allowlist. Disabling advertising also affects trusted devices. Selective discovery requires a separate compatible identity-discovery mechanism, currently absent.

Analysis used locally installed vendor apps; APKs/decompiled source/real IDs are not distributed. Other manufacturers' identity stability and discovery need their own physical tests.
