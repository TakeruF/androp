# Trusted receiving and Bluetooth visibility

Investigation: **2026-10-16**.

## Result

**Trusted Devices Only currently limits receiving, not who can discover this Mac.**
An unlisted device can still see anDrop in its standard sharing picker. It must
not be described as private discovery or as equivalent to AirDrop Contacts Only.
This is a real limitation of the implemented discovery path.

The receive filter now also guards GATT status reads, writes and application
notifications. An unknown device receives no sharing status/public-key response,
its write batch is rejected before buffering, and it receives no ready/session
notification. This closes access that was previously left open before the
engine's incoming-offer filter. **It does not remove the advertised candidate
from the Android picker.**

## Why GATT rejection cannot hide this candidate

The examined OShare version `17.2.36` handles service `8881` advertisements by
extracting a protocol identifier and sharing name from the Bluetooth local name.
Its `com.oplus.oshare.ble.impl.o.onScanResult` dispatches to `o(ScanResult)`, which
passes that advertisement-derived device to `v9.a.e`. The latter inserts the
candidate into the device list and notifies its observers. This path does not
require a GATT connection or characteristic `9898` read before listing.

This finding comes from read-only local analysis of the installed vendor app.
It applies to that examined implementation, not every alliance device. The
vendor APK and decompiled source are not redistributed here. This investigation
did not change Android visibility, pair devices, or establish a new successful
physical transfer after the GATT change.

anDrop currently broadcasts one local name and service `8881`. Apple's public
[`CBPeripheralManager.startAdvertising`](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:))
accepts local-name and service-UUID data. It offers no per-central destination or
allowlist parameter. A remembered CoreBluetooth UUID becomes available to the
host's GATT request callbacks; it cannot retrospectively restrict who heard the
public advertisement.

Stopping all advertisements would also remove discovery for trusted devices.
Advertising only while a trusted device is nearby would still expose the same
packet to untrusted devices nearby. Neither implements selective discovery.
Changing the sharing name or denying GATT status does not make a public packet
private.

## What the additional receive checks enforce

- In trusted mode, GATT reads and write batches are denied for unlisted central
  UUIDs before exposing sharing state or forwarding data to the engine.
- CoreBluetooth subscription callbacks cannot themselves be rejected, but
  unlisted subscribers receive no application notification. Queued notifications
  are checked against the current policy at delivery time; a nil destination is
  never used to broadcast to every subscriber.
- The engine independently checks ready-notification subscriptions and retains
  its incoming-offer check before key derivation and user confirmation.
- Removing trust while confirmation is pending still prevents acceptance.
  A previously accepted transfer may finish; this exemption is scoped to that
  receive session's central and ends with the session.
- Names and advertised protocol identifiers never grant trust. A locally
  remembered Bluetooth identifier is not cryptographic authentication.

## Remaining implementation requirement

Actual selective discovery needs a different interoperable discovery exchange
in which a supported peer proves or recognizes a provisioned identity before
showing anDrop. Current per-Mac UUID history does not create that shared identity.
Vendor account/contact discovery is a separate research direction; the existing
public advertisement cannot be made selective by a host-side GATT access check.
No universal impossibility claim is made for future protocol work.

The receive-control checks are covered by isolated Python and Swift tests.
Physical visibility/transfer behavior after the change remains a separate
verification step. The public candidate remains expected on the examined path.
