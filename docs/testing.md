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

Thirty-four Python tests and ten Swift tests passed for version 0.1.1 (build 5). They cover:

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
- Discovery expiry at the ten-second boundary, removal of cached connection routes, and rejection of stale sends.
- Scanner startup/runtime failure, late callbacks, partial packets, sender-only advertisements and endpoint rotation.
- Closing the chooser during file preparation without losing the already-selected route.
- ZIP response byte counts including empty payloads, failed writes and cancellation.
- Correlated send rejection without replacing another active transfer.
- Progress range limits, indeterminate phases and the distinction between all bytes sent and receiver-confirmed completion in English and Chinese.

## Repository packaging verification

After moving the source into this repository, all nine automated tests passed and a full arm64 ad-hoc build passed deep/strict signature verification. The resulting bundle contains LICENSE, NOTICE and dependency notices and uses a neutral default bundle identifier. Physical-device transfers above predate these packaging and About-dialog changes; they were not repeated for this import.

## Recipient discovery follow-up

The phone and a second OPPO device advertising the tablet flag were visible simultaneously with the same account name. Their brand/type flags and separate protocol IDs were observed without a preconnection. Bluetooth endpoint IDs changed during testing; protocol IDs remained stable within the observation. The tablet's model was not established, and tablet file transfer was not tested.

The first native chooser revision was opened through Finder Share and showed the phone and tablet as distinct entries. A temporary tablet alias changed only that entry. The final version uses an official brand logo in a circle, phone/tablet badge and sharing name, with the same identity and alias handling.

The final chooser was visually checked through Finder Share in English and Simplified Chinese with two real recipients. Official OPPO artwork and the SF Symbols phone/landscape-tablet badges rendered correctly. The tablet alias persisted through restart without appearing on the phone, then was cleared. All ten bundled images loaded through AppKit and matched their manifest hashes. The full and subsequent UI builds passed deep/strict signature verification. No file-transfer request was sent during these UI checks.

## Recipient expiry follow-up

A phone and tablet were observed through live advertisements. During a user-operated visibility-off test on the phone, new phone advertisements stopped; none arrived for the remaining approximately 55 seconds of that observation. This was a radio observation, not a timestamped measurement of the native UI switch. The ten-second expiry and error paths were checked separately by automated tests. A natural ten-minute timeout was not timed in this run.

The installed build was opened from Finder Share after the visibility-off test. Discovery updates continued normally with zero recipients and no scan error; the stopped recipients did not reappear. The full signed build passed deep/strict signature verification. No file was sent in this follow-up.

The macOS scanner adapter explicitly requests repeat advertisement delivery while the chooser is open. It uses a custom Bleak backend with the pinned 3.0.2 implementation; dependency upgrades must recheck this adapter. It does not connect to a device just to keep its row alive. The UI additionally expires a silent discovery stream and clears on Bluetooth-off, engine restart and chooser closure.

## Outgoing progress follow-up

A 64 MiB test file was sent to the OPPO phone through Finder Share with build 5. The native app received outgoing byte updates at 0%, approximately 4%, 23%, 40%, 60% and 84%, followed by the full 67,109,030-byte ZIP response. It then entered Finishing and received the peer's completion acknowledgement. The file payload was 67,108,864 bytes; the difference is ZIP overhead. The final native window showed a full blue ring and Sent. A receiver-side file hash was not checked in this run because ADB was disconnected.

An earlier attempt timed out waiting for acceptance and showed the failure state. A separate native preview with synthetic data verified the final 37% ring, readable logo, device badge and English percentage label; that preview is not an additional real transfer measurement. Automated tests cover phase labels in English and Chinese.

The final full build and UI refinement passed deep/strict signature verification. The percentage is based on response bytes written by the Mac; receiver storage completion is reported separately after its protocol acknowledgement. Reopening progress through the menu bar is implemented but was not exercised during this short real transfer. The temporary test file remains on the receiving phone.

## Remaining validation

Other brands/models, Intel, older macOS, reboot/login, prolonged sleep/wake use, large files, full-disk conditions, interrupted real-device transfers and Notification Center action buttons need additional testing. The automated tests do not replace those checks.

Petal repair remains best effort. Repeated tests disproved the assumption that starting anDrop first always solves the advertisement conflict. See [usage](usage.md).

## Test cleanup

After the earlier file-transfer tests, temporary phone-wide discoverability was restored to the contacts/own-devices setting. The testing-only screen-awake setting was reset, the diagnostic app was uninstalled, and generated phone fixtures were removed. Raw logs, screenshots and protocol captures are not committed.

For the recipient follow-up, the user manually enabled temporary visibility on both devices. No permanent visibility, screen-awake or phone-app setting was changed by this follow-up.
