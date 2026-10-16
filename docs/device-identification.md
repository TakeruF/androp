# Device manufacturer and model identification

Investigation date: **2026-10-16**. Tested with the existing OPPO Find X9 Pro on Chinese ColorOS 17 / Android 17, sharing service 17.2.36. A follow-up passive test included an OPPO tablet with the same sharing/account name. Version 0.1.1 uses the observed brand and category metadata in its recipient UI.

## Results

| Information | Finding | Limit |
| --- | --- | --- |
| Sharing display name | Available in Bluetooth service data `3334` | A user-selected sharing/account label, not proof of model or real-world identity |
| Manufacturer/brand | **OPPO identified from the observed `3333` advertisement flags, before connecting** | Self-reported protocol metadata; not authenticated hardware identity |
| Phone/tablet category | **Phone and tablet distinguished in simultaneous passive discovery** | A broad category, not a product model |
| Exact hardware model | **Not obtained through the examined wireless sharing path** | No model field in the observed advertisement or sharing status response |
| Model over USB/ADB | Available as a local diagnostic baseline | Not a solution for anDrop's normal connection-free discovery |

## Physical-device evidence

The read-only probe selected the same device by its already-visible sharing name, then omitted that name and device addresses from the report. No settings were changed and no file-transfer request was sent.

The observed service data contained:

- `3333`: 22 bytes; receiver role, discovery format version `11`, flags `9` (`0x09`).
- `3334`: the sharing display name, intentionally omitted from this document.
- No manufacturer-specific advertisement data in that observation.

In this `3333` format, bit `0x08` is the OPPO brand indicator, bit `0x10` is the realme indicator, and bit `0x02` is the tablet indicator. The observed `0x09` has the OPPO bit set and the other two clear. A second passive scan reproduced the result without a Bluetooth connection. Manufacturer fields read separately over the existing USB diagnostic connection agreed with OPPO. The bit interpretations are protocol findings, not a claim that all brands or future software versions use this layout.

A temporary BLE connection was used to enumerate services and read the existing sharing status characteristic `9897`. Its JSON contained only `key`, `pv`, `state` and `version`; no model/manufacturer field was present. Public-key contents are not retained here. The standard Device Information service `180A`, Manufacturer Name characteristic `2A29` and Model Number characteristic `2A24` were absent. Bluetooth defines those optional information characteristics in its [Device Information Service specification](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/DIS_v1.2/out/en/index-en.html).

The diagnostic USB model identifier was `PLG110`. The examined Bluetooth advertisements and sharing response did not expose that identifier or the marketing name. Knowledge of the attached test phone must not be used to label arbitrary nearby devices with that model.

## Two devices with one account name

A subsequent passive scan observed an OPPO phone and tablet simultaneously. Both advertised the same sharing name, but they had different protocol device IDs. Their version-11 flags were `9` (`0x09`, phone) and `11` (`0x0B`, tablet), respectively. Neither supplied a Bluetooth local name or peripheral name, so a device-specific friendly name could not be recovered from those fields. The tablet's exact model was not established.

During the observation, macOS Bluetooth endpoint identifiers changed while each advertised protocol device ID remained unchanged. Keeping recipients only by the Bluetooth endpoint briefly produced duplicate rows. Version 0.1.1 groups a recognized version-11, nonzero 12-hex-digit device ID and updates its connection endpoint on rediscovery. Different advertised IDs remain separate even if their account names match. This is evidence of stability during this observation, not a claim of lifetime stability across resets, account changes or firmware updates.

Local aliases are keyed by a SHA-256 hash of that recipient identity. Unknown formats fall back to the Bluetooth endpoint. Identity fields are self-reported and only organize the chooser; they are never used to authenticate a sender or bypass transfer approval.

## Other brands and formats

The open-source [CatShare discovery implementation](https://github.com/kmod-midori/CatShare/blob/067348d3d9207206e120b2afe2837c6101f73f41/app/src/main/java/moe/reimu/catshare/ShareActivity.kt) decodes a different alliance advertisement format: a six-byte service-data record carries a brand code in its service UUID. Its [brand mapping](https://github.com/kmod-midori/CatShare/blob/067348d3d9207206e120b2afe2837c6101f73f41/app/src/main/java/moe/reimu/catshare/utils/DeviceUtils.kt) includes OPPO, realme, vivo, Xiaomi, OnePlus, Meizu, Samsung and Lenovo. This provides an implementation reference, not physical validation of those brands here. That mapping does not cover HONOR; an unknown code must remain unknown.

The tested phone emitted the `3333`/`3334` format during this observation, rather than that six-byte record. Brand bits cannot be interpreted interchangeably across advertisement formats. In particular, a bit used as a brand flag in one format can mean a capability in another.

## Implications for anDrop

The app now displays official brand logos in circles, a phone/tablet badge and the original sharing name, with optional Mac-local aliases. It parses the examined version-11 format without requiring prior pairing. Unrecognized or contradictory metadata stays unknown rather than being guessed from a name or service UUID alone. Support for a format is separate from validation of every manufacturer using it.

An exact model label requires an explicit model field from a supported protocol, an optional standard Device Information response, or a separately verified model-identification mechanism. A friendly name that happens to contain a product name is not reliable model metadata. Some vendor-specific transfer channels carry more information, but they have not been validated as a model-discovery path usable by this app before a transfer. The current evidence does not establish that exact model discovery is universally impossible; it establishes that the examined path did not provide it.

No vendor APK/source excerpts, device names, addresses, serial numbers or raw protocol captures accompany this report. The parsing and identity behavior are covered by synthetic tests; no personal capture is needed to run them.
