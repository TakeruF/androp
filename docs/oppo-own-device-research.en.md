# OPPO contacts-only and own-device discovery

[简体中文](oppo-own-device-research.md) · English

Investigation: **2026-10-16**, anDrop revision `a1126e5`. This is the historical state at that revision; see [trusted devices](trusted-discovery.en.md) for the later receive policy.

## Result

OPPO distinguishes a contact from a device on the same OPPO/HeyTap account. The latter is the relevant target for a personal Mac. Changing anDrop's name, remembering its Bluetooth identifier, or adding a contact named after the Mac does not implement that relationship.

There is a plausible interoperability route through OPPO's Apple-device support, but **anDrop has not been demonstrated as an own-account device**. Its current public-discovery/file-transfer protocol does not implement the account-aware discovery channel. This investigation did not send an identity claim, change phone visibility, log into an account, pair devices, or transfer a file.

## Evidence and scope

The attached phone reported:

| Package | Version | Role |
| --- | --- | --- |
| `com.coloros.oshare` | `17.2.36` | Sharing UI and transfer orchestration |
| `com.heytap.accessory` | `17.6.16` | Pantaconnect discovery and distributed context service |

The existing local OShare APK matched the installed APK's SHA-256. AccessoryFramework was copied from the phone for read-only analysis and its SHA-256 was also checked against the installed file. No account database or address-book contents were read.

- OShare: `18a7b0eeda843a91379862a5f3b346befa18dbae6b8cc6cb7d2efb364c0704c4`
- AccessoryFramework: `538e5665ea6c709827063cc8b2f2dc86c82d432252c41ca4606526be7497ec78`

These are implementation findings for those versions, not a published cross-vendor specification. The decompiler reported errors, including visibly malformed control flow in some larger methods. The conclusions below use readable call chains and resource strings; uncertain branches are not treated as working protocol implementations. Private APKs and decompiled vendor code remain outside this repository.

## What “contact” means

OShare's contact helper queries Android phone-number contacts. It normalizes numbers to E.164 and compares derived hashes with peer-provided phone hashes. The examined 16-byte contact record contains a salt and three entries corresponding to SIM 1, SIM 2 and the account phone number.

The contact helper's individual entry combines truncated SHA-256-derived values with a salt byte. Pantaconnect also contains a newer contact data source with support for numbers without country codes, so that one helper must not be assumed to describe every current packet format.

The service tracks **local contact**, **remote contact**, **mutual contact**, and **no contact** separately. Merely adding the receiver's number to the sender's address book is therefore not proof that the receiver will permit discovery. In the examined discovery subscription, same-account, remote-contact and mutual-contact states can pass the contacts-only gate. A separate all-devices mode also passes that gate.

This is phone/account information, not a name comparison or a Bluetooth pairing-history check. No matching contact data is currently supplied by anDrop.

## What “my devices” means

There are multiple stages and protocol paths:

1. **Account-aware discovery.** OShare subscribes to Pantaconnect's `OSHARE_DISCOVERED_MODE` and receives `is_same_account` and `identity_relationship` along with device metadata. These are outputs of another service, not switches anDrop can set in its existing advertisement.
2. **Always-on Android discovery.** The examined Pantaconnect path parses an encrypted TLV payload containing account-related data. Its account manager has an explicit rough-match operation comparing peer and local account-hash bytes. That rough match is distinct from stronger connection authentication elsewhere in the framework.
3. **Transfer-time account comparison.** Some OShare BLE/P2P paths exchange an encrypted value derived from the account's `ssoid` and compare it with the local value. OShare normally SHA-256-hashes a short `ssoid`; an already-long value is retained. This is separate from Pantaconnect's discovery account hash: their equivalence was not established.
4. **Apple-device path.** OShare has a separate iBeacon/GATT route carrying device metadata and an `is_same_account` field. Its UI handler consumes that field. This alone does not demonstrate authenticated ownership, contacts-only discovery, or permission to transfer.

The always-on encrypted TLV path calls a GUK crypto provider. That provider asks the OPPO crypto engine for HKDF-derived key material using a configured key label/version, then encrypts/decrypts. A key label in the APK is not the underlying key. Consequently, copying an account hash into anDrop's existing BLE payload is not an established implementation of this path. This finding also does **not** prove that all supported Apple clients need OPPO Android secure hardware.

## Explicit Apple support

The installed OShare settings resources list two supported groups for the relevant discoverability feature:

- Compatible OPPO, OnePlus and realme devices belonging to the same account or contacts.
- iPhone/iPad with the latest OPPO Connect application signed into the same account.

**Mac is not explicitly listed in that particular on-device explanation.** It would be incorrect to turn the iPhone/iPad statement into a tested Mac compatibility claim.

Separately, [ColorOS's official Mac instructions](https://www.coloros.com/article/A00000087/) document automatic connection after the phone and Mac sign into the same account and join the same WLAN. That establishes a supported Mac account relationship in OPPO Connect, but not anDrop compatibility or the exact contacts-only share-sheet behavior.

The installed Mac O+Connect application was version `16.2.20`. Only application metadata was inspected; no session credentials were read or reused.

## Why current anDrop cannot do this yet

The current Mac host advertises service `8881` and serves GATT `9999`. The outgoing engine scans service data `3333`/`3334` and negotiates a transfer using characteristics including `9897`/`9898`. It has no OPPO account login, account identity exchange, or Pantaconnect always-on discovery implementation.

anDrop's **Trusted Devices Only** is a separate local receive filter using remembered CoreBluetooth identifiers. It does not register the Mac with the phone as an OPPO-account device, and adding the phone to that list cannot change the phone's contacts-only behavior.

There is also a platform constraint: [Apple documents](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)) only local-name and service-UUID keys for `CBPeripheralManager.startAdvertising`. Directly reproducing arbitrary Android advertising payloads is therefore not a drop-in extension of the current host. Scanning an Android advertisement and implementing an appropriate GATT client remain different possibilities; the supported Apple path deserves investigation before assuming a custom radio is necessary.

## Feasibility and next implementation target

| Approach | Assessment |
| --- | --- |
| Rename the Mac / add its name to Contacts / trust it locally | Does not supply the required phone/account identity |
| Add only an `is_same_account` flag | Could affect a particular presentation path; insufficient evidence for actual ownership or contacts-only operation |
| Reproduce Android always-on discovery | Requires additional packet handling and the GUK crypto path; not currently portable from the inspected code alone |
| Implement the supported Apple account/discovery route | Most relevant research direction; Mac eligibility, account provisioning and subsequent transfer behavior remain unverified |
| Use official OPPO Connect on Mac | Official same-account auto-connection exists; a separate product/workflow from the intended anDrop utility |

For the personal-device use case, the preferred product design is **one initial ownership/account setup, followed by normal Finder sharing without manually connecting each time**. That is a design target, not an implemented capability or a claim that account-free operation is possible.

A useful next proof should establish the Apple-route account setup and discovery exchange using the user's own devices, then independently verify:

1. The phone stays in contacts-only mode and is discoverable from the Mac after the public-visibility timeout.
2. OPPO itself identifies the Mac as an own-account device, beyond a copied display flag.
3. Transfers work in both directions with received contents checked.
4. The result survives app restart, Bluetooth address rotation and device lock/unlock.

Do not remove transfer confirmation or label the feature authenticated based on a matching name, short discovery hash, or peer-provided boolean alone. No production application behavior was changed by this research.

## Local implementation references

These are symbol pointers for reproducing the analysis against the matching private APKs, not vendor-source redistribution:

| Finding | Package-relative symbol |
| --- | --- |
| Phone-number matching | OShare `com.oplus.oshare.utils.p.g/h`, `d0` |
| Account identifier transform | OShare `com.oplus.oshare.utils.AccountManger.S/y` |
| Context-service boundary | OShare `com.oplus.oshare.utils.DcpManager.e/G/k/s` |
| Transfer-time account comparison | OShare `com.oplus.oshare.ble.impl.j`, `w`; `r9.b/g` |
| Apple UI metadata | OShare `w9.b.b` |
| On-device support text | OShare resources `feature_support_coloros_same_account_device_new`, `feature_support_oppo_link_latest_same_account` |
| Discovery eligibility | AccessoryFramework `com.oplus.pantaconnect.dcp.subscribe.a` |
| Encrypted discovery and account relation | AccessoryFramework `com.oplus.pantaconnect.alwaysonservice.b.h`, `account.a.e`, `account.f.e` |
| Crypto dependency | AccessoryFramework `se.f`, `com.oplus.ndsf.client.g.p/d/f` |
| Apple discovery construction | AccessoryFramework `com.oplus.pantaconnect.beacon.usecase.f.b/c` |
