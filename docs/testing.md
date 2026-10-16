# Validation record

Recorded on 2026-10-16. This is a summary of observed tests, not a certification or a claim that all file sizes, devices or network configurations work.

## Physical-device results

Environment: Apple Silicon Mac on macOS 27.0.1 and OPPO Find X9 Pro on Chinese ColorOS 17 / Android 17, sharing service 17.2.36. Both devices used the same Wi-Fi. No vendor desktop preconnection was needed. USB/ADB assisted test setup and inspection; file transfer used Bluetooth negotiation and the local network. The diagnostic phone app was removed before final validation.

| Direction | Test | Result |
| --- | --- | --- |
| Finder → anDrop → phone | 8 MiB binary, empty file, 49-byte file with a Japanese filename in one transfer | All three received; SHA-256 matched |
| Phone's built-in 互传 → Mac | 8 MiB binary | Received directly in Downloads; SHA-256 matched |
| Phone → Mac with an existing same-named file | Name collision | Existing file preserved; new file received with numeric suffix |
| Mac received file | Quarantine metadata | Attribute present |
| UI | English and Simplified Chinese settings, Finder share entry | Visually checked |
| Petal concurrent operation | Both directions | Succeeded in some runs; discovery failed again in later runs |

Tests checked that the nearby name obeys the byte limit and transfer confirmation uses the full Computer Name. Actual personal device names and local file paths are intentionally not recorded here.

## Automated tests

```sh
.venv/bin/python -m unittest discover -s tests -v
swift test
```

Fifteen Python tests and six Swift tests passed for version 0.1.1. They cover:

- Key exchange, encryption round trip and protocol parsing.
- Japanese filenames, empty files and collision handling.
- Rejection of traversal, absolute paths and symlinks.
- Declared-size mismatch without saved output.
- Transient local-route recovery, including aiohttp-wrapped errors.
- Bounded retry for persistent route failure.
- Permission errors and cancellation without retry.
- Same-account phone/tablet metadata and separate recipients.
- Unknown/conflicting metadata and future-version fallback.
- Bluetooth endpoint rotation while retaining one protocol recipient and the latest connection route.
- Alias persistence by device identity, same-name disambiguation and the 40-character Unicode limit.

## Repository packaging verification

After moving the source into this repository, all nine automated tests passed and a full arm64 ad-hoc build passed deep/strict signature verification. The resulting bundle contains LICENSE, NOTICE and dependency notices and uses a neutral default bundle identifier. Physical-device transfers above predate these packaging and About-dialog changes; they were not repeated for this import.

## Recipient discovery follow-up

The phone and a second OPPO device advertising the tablet flag were visible simultaneously with the same account name. Their brand/type flags and separate protocol IDs were observed without a preconnection. Bluetooth endpoint IDs changed during testing; protocol IDs remained stable within the observation. The tablet's model was not established, and tablet file transfer was not tested.

The first native chooser revision was opened through Finder Share and showed the phone and tablet as distinct entries. A temporary tablet alias changed only that entry. The final version uses an official brand logo in a circle, phone/tablet badge and sharing name, with the same identity and alias handling.

The final chooser was visually checked through Finder Share in English and Simplified Chinese with two real recipients. Official OPPO artwork and the SF Symbols phone/landscape-tablet badges rendered correctly. The tablet alias persisted through restart without appearing on the phone, then was cleared. All ten bundled images loaded through AppKit and matched their manifest hashes. The full and subsequent UI builds passed deep/strict signature verification. No file-transfer request was sent during these UI checks.

## Remaining validation

Other brands/models, Intel, older macOS, reboot/login, prolonged sleep/wake use, large files, full-disk conditions, interrupted real-device transfers and Notification Center action buttons need additional testing. The automated tests do not replace those checks.

Petal repair remains best effort. Repeated tests disproved the assumption that starting anDrop first always solves the advertisement conflict. See [usage](usage.md).

## Test cleanup

After the earlier file-transfer tests, temporary phone-wide discoverability was restored to the contacts/own-devices setting. The testing-only screen-awake setting was reset, the diagnostic app was uninstalled, and generated phone fixtures were removed. Raw logs, screenshots and protocol captures are not committed.

For the recipient follow-up, the user manually enabled temporary visibility on both devices. No permanent visibility, screen-awake or phone-app setting was changed by this follow-up.
