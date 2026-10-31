# Validation record

[简体中文](testing.md) · English

## Notification cleanup, 1.2.3 (2026-10-31)

The production AppModel regression harness covers the three-minute deadline for completed and failed notifications, preservation of approval/active-transfer notifications, and keeping the earliest cleanup deadline when more notifications arrive. The release source passed 289 Python tests and 45 Swift tests, plus the native synthetic Live Photo checks.

On the local signed build 12201, real Notification Center entries for completed, failed and active transfers were observed through 170 seconds. At 180 seconds, the completed and failed entries had disappeared while the active-transfer entry remained. The temporary test notifications were then removed. Settings, trusted-device records and history were preserved. This checks actual macOS notification removal; wake-from-sleep and menu-tracking behavior are implemented but were not separately timed on the Mac.

The 1.2.3/build 12300 candidate reuses the unchanged frozen engine and passes packaging/helper checks, Developer ID signature verification and compatibility checks for 81 arm64 Mach-O files targeting macOS 14 or earlier. Public release and notarization are verified separately.

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
| 鸿蒙星河互联 concurrent operation | Both directions | Succeeded in some runs; discovery failed again in later runs |

Tests checked that the nearby name obeys the byte limit and transfer confirmation uses the full Computer Name. Actual personal device names and local file paths are intentionally not recorded here.

## Automated tests

```sh
.venv/bin/python -m unittest discover -s tests -v
swift test
```

Forty-six Python tests and ten Swift tests passed for version 0.1.1 (build 7). They cover:

- Key exchange, encryption round trip and protocol parsing.
- Japanese filenames, empty files and collision handling.
- Rejection of traversal, absolute paths and symlinks.
- Declared-size mismatch without saved output.
- Transient local-route recovery, including aiohttp-wrapped errors.
- Bounded retry for persistent route failure and transient initial receive resets/refusals.
- TLS/HTTP rejection without retry, active receiver protection from the offer timer, and safe localized error messages.
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

The phone and a second OPPO device advertising the tablet flag were visible simultaneously with the same account name. Their brand/type flags and separate protocol IDs were observed without a preconnection. Bluetooth endpoint IDs changed during testing; protocol IDs remained stable within the observation. The tablet's model was not established. File transfer was not tested during this discovery probe; a later tablet-to-Mac result is recorded below.

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

鸿蒙星河互联 repair remains best effort. Repeated tests disproved the assumption that starting anDrop first always solves the advertisement conflict. See [usage](usage.en.md).

## Test cleanup

After the earlier file-transfer tests, temporary phone-wide discoverability was restored to the contacts/own-devices setting. The testing-only screen-awake setting was reset, the diagnostic app was uninstalled, and generated phone fixtures were removed. Raw logs, screenshots and protocol captures are not committed.

For the recipient follow-up, the user manually enabled temporary visibility on both devices. No permanent visibility, screen-awake or phone-app setting was changed by this follow-up.

## Titleless popup follow-up (build 6)

The UI-only build passed compilation and deep/strict signature verification. Native previews using the same AppModel and RecipientPanel checked title-bar removal, rounded corners and the original window background color. With a synthetic sending state, focusing an outside window and closing that window revealed the still-open progress popup. With a synthetic successful state, the same focus change dismissed the popup; closing the outside window left no recipient popup. The preview used no Bluetooth or file transfer. The earlier build-5 physical-device transfer result is unchanged; no new file transfer was performed for this UI-only change.

## Tablet receive recovery (build 7)

The user reported a failed tablet-to-Mac receive: the Mac had a connection-reset error before receiving file data, while the tablet displayed a recipient-rejected message. The original reset's precise cause was not established.

Build 7 adds a bounded retry only while establishing the initial WebSocket, before transfer metadata or file bytes are exchanged. Retryable startup errors include temporary route unavailability, connection reset, refusal and abort. The whole connection retry window is at most ten seconds with up to four attempts; TLS/certificate failures, HTTP rejection, permission failure and cancellation are not retried. There is no TLS downgrade or replay of partial downloads. The earlier fifteen-second offer timer now expires only before a receive task starts, avoiding cancellation of an already-active connection attempt. The timer flaw was verified by tests, not identified as the definitive cause of the user's original reset.

In a subsequent physical tablet-to-Mac test, the first connection attempt encountered the macOS host-unreachable error. Attempt two connected, and one 83,249-byte file completed download, saving and the completion exchange. The user confirmed success; local checks confirmed one saved file of that size directly in Downloads. A sender-side hash comparison was not performed. This demonstrates recovery in that attempt, not a guarantee that every connection reset is recoverable.

Notifications now use localized, actionable messages for transfer errors rather than raw exception strings containing endpoints, object addresses or filenames. Local diagnostic summaries record phase, error class, numeric error code and attempt number; raw captures are excluded from the repository.

## Inline rename control (build 8)

A native preview with the same recipient grid verified the SF Symbols pencil beside a short name and a two-line name. Clicking the tablet pencil opened that device's name editor without starting a transfer; the editor was cancelled. The UI-only build passed compilation and deep/strict signature verification. No additional physical transfer was performed for this layout change.

## Adaptive recipient layout (build 9)

A native preview using the production views checked a one-line “Example” label, centered independently of the pencil; compact one-row height; and the compact name-edit sheet. A 40-device fixture scrolled to the final recipients while retaining the fixed header and footer. Ten bundled manufacturer logos were also displayed with phone/tablet badges. Fixtures used synthetic peers and no Bluetooth or file transfer. The UI build passed compilation and deep/strict signature verification.

## Receive scope, Control Center and identity history update

- Python suite: 51 tests pass, including rejection before key exchange for unlisted devices, mandatory approval for listed devices, revocation while approval is pending, and name-independent filtering.
- Swift identity/progress suite: 10 tests pass.
- Native model smoke checks ran in a fresh UUID-named UserDefaults test suite, without modifying the installed app’s settings. Offline history candidates, same-name device separation, Add/Remove/Forget, persisted trust, running=receiving, endpoint metadata, and the one-time legacy-history cleanup passed.
- The installed build’s deep strict signature check passed. The one-time removal of history records without endpoint identifiers was independently read back by count; identified history was retained.
- macOS registered the control extension. A user confirmed gallery visibility and the initial control-to-file-picker invocation during development. At that development stage, one Receive control opened the host-owned receive-scope panel. This integration was subsequently removed in build 36; its UI is preserved in the standalone prototype.
- Production UI renders with fictional data cover English/Chinese receive scope and trusted-device history. Manufacturer artwork and phone/tablet badges are reused from the recipient chooser; OPPO/vivo use white logos on green/blue, and Xiaomi retains official orange artwork.
- These checks do not establish physical-device coverage for other manufacturers or cryptographic peer authentication.


## Historical GATT trust-boundary follow-up (superseded by sender-ID verification)

- Python suite: **54 tests pass**, including no ready notification for an unlisted
  or missing central, disabled-receiver subscription rejection, and a transfer
  already accepted before trust removal retaining its control channel.
- Swift suite: **13 tests pass**. New production-policy tests cover unknown,
  trusted, malformed and unavailable-receiver cases, case-insensitive UUIDs and
  the accepted-session exemption. A completed session grants no exemption for
  a new offer.
- Pending confirmation is excluded from the accepted-session exemption; existing
  revocation-before-acceptance tests continue to pass.
- GATT read/write/notification callbacks now apply that policy. Unit tests do
  not establish physical-device compatibility of the changed ATT responses.
- Read-only analysis of OShare `17.2.36` established that its `8881` discovery
  path adds a candidate directly from advertising data before any GATT read.
  These changes therefore do **not** implement selective visibility. See the
  [investigation and remaining limitation](trusted-discovery.en.md).

## Control Center removal and single Cancel action (build 36)

- The installed app contains only the Finder Share extension. The old WidgetKit extension was unregistered and its existing anDrop tile removed. The host has no control-state App Group entitlement or App Intents metadata. The signed bundle passed deep/strict verification.
- The compact receive panel is preserved outside the production build in `Prototypes/ReceivePanel`, with English/Chinese fictional captures and an independent interactive preview. Native preview checks verified scope selection, the switch disabling scope rows, Escape dismissal and the titleless system-glass wrapper. No production preferences or device trust records were changed by the preview.
- The recipient popup now has one footer action: Cancel closes an unsent picker, targets the active transfer while preparing/waiting/connecting/sending/confirming, and becomes Done after a terminal result. Escape uses the same action. Outside clicks during sending still allow background transfer.
- A disposable native-model check exercised the production cancel action with a local JSON-lines sink and no transfer engine: unsent closure, cancellation of the correct ID in all five active phases, and closure after a cancelled result passed.
- Existing Python tests: **54 passed**. Swift identity/progress/policy tests: **15 passed**. The English and Chinese sending screenshots were regenerated from production views with mock data and show one Cancel button.
- This UI/integration update did not repeat a physical-device file transfer.

## Version 1.0.0 release preparation

- The full app was rebuilt with the official Python 3.14.7 macOS runtime and pinned binary wheels. All **80 bundled Mach-O files** passed an arm64/macOS 14.0 deployment-target check; no load commands referred to the development machine’s library paths. This does not establish execution on physical macOS 14 hardware.
- The signed hardened-runtime engine started with Python/DYLD environment overrides removed, emitted ready and exited normally with no stderr output. No file transfer or Bluetooth scan was started by this engine smoke check.
- **54 Python tests and 15 Swift tests passed.** The future App Store build switch was separately typechecked without importing Sparkle; this is not store validation.
- A separate UUID-identified fixture compiled the production AppUpdates implementation and embedded Sparkle 2.10.0. It used a loopback-only HTTP feed, synthetic UI and a signed 1.0.0 DMG; it had no transfer engine or Bluetooth advertising. From 0.9.9, automatic checking/download produced the Chinese ready dialog, Later retained the old version, a simulated active transfer disabled installation, and Restart and Update installed and relaunched **1.0.0**. A manual check then displayed Sparkle’s Chinese up-to-date dialog.
- Disabling automatic checks/downloads was reflected in the UI, independently read back from that disposable fixture’s persistent preferences and retained after a cold relaunch. The fixture did not change the installed anDrop preferences.
- Both the signed feed and update archive were verified. Appending bytes to the test archive caused signature verification to fail, using both Sparkle’s tool and an independent verification with the embedded public Ed25519 key. Private signing keys were not exported.
- Frozen Python archives contained **479 code filenames**, none absolute; no project-owner name, private home path or signing-team identifier was found in their inspected string constants. The Git history and intended source changes were also screened for those private values. This is a focused publication check, not a claim that arbitrary data can be automatically anonymized.
- Chinese and English documentation captures were regenerated from production views with fictional data. The mock Settings viewport is expanded to show the update controls and license/repository links. Normal Settings remains scrollable.
- No additional physical-device transfer was performed for the updater/packaging change. Earlier physical test results above remain scoped to their recorded builds.

The minimum-OS check was also exercised with an actual macOS 26-only binary and correctly rejected it when macOS 14 was declared.

The 1.0.0 application subsequently passed Apple notarization. The exported application’s stapled ticket validated, deep/strict code-signature verification succeeded, and Gatekeeper reported `source=Notarized Developer ID`. The Developer ID-signed DMG mounted read-only, its checksums matched, and all **251 file/link entries** matched the notarized export. Installation from that DMG retained preferences/history and matched the same manifest. The installed Chinese Settings view showed 1.0.0, both update settings enabled, and the license/repository links. Host and bundled engine processes remained running.

Published on 2026-10-17 as [v1.0.0](https://github.com/TakeruF/androp/releases/tag/v1.0.0). All three assets were downloaded again without GitHub authentication and matched the local release artifacts. Their SHA-256 checksums and the Ed25519 signatures of both appcast and DMG verified independently with the embedded public key. The installed production app read that public feed and displayed Sparkle’s Chinese confirmation that 1.0.0 was current. With 鸿蒙星河互联 stopped, the installed host reported accessory activation policy (Dock hidden). macOS 14 physical-device testing remains outstanding.


## 1.0.1 connection and trusted-device fixes (2026-10-17)

### Changes

Physical consecutive receives from one phone used five different CoreBluetooth central UUIDs but the same protocol senderId. Outgoing peripheral UUID is also not incoming identity. Necessary control negotiation now precedes checking SHA-256 of senderId; only then are approval/download permitted. Names/accounts/IPs/models never automatically grant trust.

Choose enabled LAN interfaces, preferring the peer subnet and ignoring VPN default routes, disabled/inactive interfaces. Darwin interface binding is per-transfer socket, never a system-route/VPN change. Explicit refusal may try the next LAN address. Reachable endpoints from the same Bluetooth negotiation, including direct-link metadata, may be reused; an SSID alone does not fail negotiation. Inaccessible private vendor networks remain inaccessible and Wi-Fi is never switched automatically.

Bluetooth confirmation and TLS may arrive in either order; peer addresses must match before download. Failed UDP speed measurement does not abort established control, reporting actual zero instead. Permission/VPN/connectivity apps/isolation may affect transfers, so not every error is blamed on different Wi-Fi.

### Automated validation

90 Python/16 Swift tests passed, using real loopback TLS/WebSocket/HTTP with only BLE replaced. Both confirmation orders preserved contents; mismatched source addresses denied download; refused first LAN address fell back; VPN/inactive/invalid endpoints were excluded. Failed/absent UDP did not abort valid control. Same-name untrusted/missing/changed sender IDs, trust revocation/disabled receiving during approval, user decline and wrong file count never downloaded. Mid-download cancellation cleaned partials. Multiple Chinese/Japanese names, empty/8 MiB files matched. Alternating acceptance/refusal did not reuse authorization.

### Physical validation

A private diagnostic host ran production transfer code with automatic confirmation only for synthetic fixtures. Debug entry points/raw logs/real IDs/personal files are excluded from production/source. Phone→Mac succeeded while OPPO Connect linked a tablet or the phone, including8 MiB hashes. Mac→phone while Connect linked the phone passed actual-save readback/hash. A new BLE UUID retained trusted receipt. Removing the physical peer from trust rejected before prompting/download; equivalent Everyone decline also rejected. Japanese names and six alternating trusted-only/Everyone receipts matched. OPPO refused sending a standalone0 B file before anDrop connection, so that phone-originated empty-file case did not pass. Two early Mac sends timed out because the floating phone Accept button was not operated in time; neither counts as success.

The old “always fails when connected” report was not stable across all states; passing these states does not guarantee every vendor/network. Self-reported sender IDs are spoofable convenience filters, not cryptographic pairing; approval stays mandatory. UUID-only records require Everyone receipt/re-enrollment, never migration by name; changed account/protocol IDs need verification. Other brands/physical multi-interface switching/private vendor networks/macOS 14 remain untested. The Mac locked during final installation; startup/package proof is separate from diagnostic-host device transfers.

Production1.0.1/10001 installed at /Applications/anDrop.app with deep/strict Developer ID and80 arm64/macOS 14 Mach-O checks, no build-machine library paths. The installed production engine passed three real loopback TLS/HTTP cases: trusted receive, same-name untrusted refusal, trusted receive after BLE rotation. Japanese/empty contents matched, refusal never downloaded, no UDP packet was necessary, engine exited normally without stderr. Normal host/engine then started and phone sharing listed the Mac. No QA command endpoint, new GitHub Release or new notarization submission.

## 1.0.1/10002: phone→Mac failure with OPPO Connect

User testing reproduced failure on2026-10-17: earlier successes covered only their then-current state. The phone first supplied WLAN endpoint then closed it and advertised hotspot metadata/new port in the same negotiation. Old code ignored updates once a receive task existed and repeatedly connected stale ports, ending ECONNREFUSED/macOS 61. That does not prove missing Local Network permission.

Before TLS establishes, replace endpoints by cancelling the old attempt while retaining session/trust/approval. A new hotspot port may be reached through that session's existing phone WLAN address on its direct LAN. No network scan/other-device history/Wi-Fi switch. After TLS, endpoints cannot change; duplicates do not restart; replacement count is bounded; cancellation wins races. A busy UDP measurement port now still attempts TLS with measurement zero.

99 Python/16 Swift passed, including actual TLS/HTTP stale-refusal→new-port→same-session LAN success and untrusted refusal without download. Established/duplicate/expired/bounded/cancelled updates and busy UDP covered. Physical Connect-linked testing reproduced alternating old-build success/failure; the fix recorded receive_endpoint_replaced then matching contents without restarting phone sharing or disconnecting Connect. Two automation clicks on already-Sent cards started no transfer and count as neither success nor network failure; scripts subsequently reopened sharing without restarting services.

Production10002 installed/started; normal app approval received8 MiB with matching SHA-256 and complete history while Connect remained linked. Developer ID/80 arm64/macOS 14 checks passed. This handles same-session updates, not every vendor's WLAN-accessible hotspot. No new release/notarization.

## 1.0.1/10003: Finder focus handoff, incomplete fix

Completing the extension request before opening anDrop in its completion callback did not solve the user's disappearing window. Installed signed build tested sharing while running, after cancelling, and while initially quit. All showed correct files/recipients, but inspection reselected the app and disturbed focus, so these did not prove sustained foregrounding. No personal files sent/new transfer. Compilation/signature/80-binary checks passed. Handoff follows Apple's [completion API](https://developer.apple.com/documentation/foundation/nsextensioncontext/completerequest(returningitems:completionhandler:)); stale callbacks cannot reopen the app.

## 1.0.1/10004: application registration fixed focus

The bundle declared LSUIElement=false while runtime normally used accessory. Finder Launch Services restored regular; the two-second environment timer switched back to accessory, asynchronously deactivating to Finder. The window existed behind it. Diagnostics reproduced regular+active+key→accessory+inactive+not-key. Immediate reactivation after policy change or first deactivation still lost to Finder later, so was rejected.

LSUIElement=true now matches menu-bar behavior, avoiding that transition on share-open while retaining regular mode alongside 鸿蒙星河互联. This did not retest real 鸿蒙星河互联 BLE coexistence. Diagnostics stayed accessory/active/key without reselecting anDrop. Installed10004 shared from Finder while running and quit; independent read-only foreground inspection stayed anDrop. Installed/build parity verified, diagnostic host removed, no personal/new end-to-end transfer.

## 1.0.1/10006: failure diagnostics and mail

99 Python/21 Swift passed: field/sensitive-data filtering, persisted failure context, missing old logs, path-ID checks, event/export limits, file-type scope and running-app deduplication. A private host simulated outgoing/incoming failure notifications; clicking outgoing View Logs opened the matching Settings report, without implying physical transfer or shipping QA hooks.

Production preserved settings/trust. JSON preview, Finder reveal and system mail draft to support@takeruf.com with attachment/reproduction/expected/model/OS/VPN-connectivity fields verified. Both test drafts were discarded unsent. Old failures explicitly show no detailed log, never fabricated sampling. OS collection limitations stay in developer docs/structured fields, letting users supply their OS.

Installed10006 retained local bundle ID, Developer ID/80-binary checks, byte-identical host and no QA triggers. Two simulated histories were removed and logs privately archived. No phone transfer, feedback sending, re-notarization or release. The no-mail-client fallback is implemented but was not exercised by deleting the existing configuration.

## 1.1.0/11000: stable release build

Combines1.0.1 development fixes/diagnostics with 1.0.0 bundle ID/update public key and monotonic11000. Fully rebuilt host/extension/engine,99 Python/21 Swift passed. Apple notarization/stapling/Gatekeeper/Developer ID and80 arm64/macOS 14 checks passed without build-library references. DMG Developer ID and Sparkle feed/archive signatures, version/architecture/URL/length/hash verified. Only DMG/appcast.xml/SHA 256SUMS.txt published, no private records/raw device logs. No new physical transfer.

Unauthenticated GitHub Latest pointed to 1.1.0 and all three downloaded assets matched locally byte-for-byte, including canonical latest/download/appcast.xml and its signature. The same notarized app installed/started with unchanged ID/team. This verifies publication/download/signing, not a tested1.0.0→1.1.0 Sparkle installation.

## 1.1.1/11001: completed-receive Finder action

Removed foreground from notification Show in Finder so activating/reopening anDrop no longer also opens Settings. Existing file reveal remains.99 Python/21 Swift, full rebuild, Developer ID/80 arm64/macOS 14 checks passed; ID/update public key/feed retained, build 11000→11001.

Notification Center was not operable through this run's UI tool, so actual post-fix button clicking remains unverified. Temporary mock host wrote no history and was removed, no QA production hook or new phone/tablet transfer. Apple notarization/ticket/Gatekeeper/DMG content parity and signed feed/archive/version/architecture/OS/URL/length/hash passed. Only the three public assets were released.

## Recipient context menu and hidden devices (2026-10-17 development build)

The recipient pencil has been replaced with Rename Device / Hide from Candidates in the device icon context menu. Settings manages persistent hidden records and restores them without needing an active discovery result. Hiding only filters outgoing candidates; receive access and trust are unchanged. Identity changes can make a device reappear, matching the existing alias identity scope.

A native development build was operated against the real Pura 70 candidate: icon right-click showed both commands, renaming updated the label, hiding removed the candidate, restart preserved the hidden record and alias, Settings restored it, and rediscovery showed it again. The test alias and hidden entry were removed afterwards. A screenshot verified the pencil was absent. Four model tests cover stored metadata without raw identity, same-name devices, rediscovery persistence and restoration; all 26 Swift tests passed. UI compilation, deep/strict signature verification and the frozen engine self-check passed. The engine remained byte-identical to the phase 18 full build used for three-file physical transfers in both directions. Active-transfer UI preservation was reviewed in code, not separately exercised during a physical transfer in this UI test.

Private redacted evidence is under `build/huawei-research/phase19/`. Earlier pencil screenshots and notes above describe prior builds.

## Huawei artwork and computer presentation (2026-10-17 development build)

Added the unchanged official Huawei 96 px favicon locally (source and hash in the brand manifest), including both Huawei/HUAWEI brand spellings. Computer metadata now renders the `desktopcomputer` SF Symbol and localized Computer/电脑 label in candidate, history, remembered and hidden-device views. Production-view documentation fixtures cover Huawei phone/PC and HONOR/Xiaomi PCs alongside OPPO phone/tablet. The PC fixtures validate presentation only; they do not establish discovery or transfer compatibility with physical PCs.

Huawei Share type 12 maps to computer, following OpenHarmony TYPE_PC_ID=0x0C. The existing exception for idle phone/tablet replies without SHARE capability remains restricted to those mobile types; PC replies still need SHARE capability. No unverified HONOR/Xiaomi wire-type values were introduced. The new tests exercise the PC advertisement gate and localization/hidden-record round-trip across three brands.

All 176 Python and 27 Swift tests passed. The full frozen build passed signature, self-check and deployment-target checks. Native UI inspection of the real Pura candidate confirmed the Huawei logo and phone badge. No transfer was performed in this artwork/type change, and no physical PC compatibility is claimed. Evidence: `build/huawei-research/phase20/verification-redacted.json`.

## Photo preview compatibility fix (2026-10-17, local build 11002)

A reported Pura-to-Mac image failure was reproduced with a synthetic JPEG shared from Pura's Files image preview. Image sharing adds an authenticated preview tag 13 after tags 11/12; the previous exact two-field validator rejected it before file data. The bounded batch-preview parser now also accepts exactly 11/12/13, with an 8 KiB limit on tag 13, while rejecting unknown, empty, duplicate or oversized auxiliary fields and preserving all DFile name/size/crypto/content checks. An orderly byte-preview connection EOF after preview acknowledgement no longer prevents waiting for the file channel's verified DONE ACK; truncated headers/payloads remain failures. Fixed receive-stage tokens and transfer IDs improve diagnostics without logging remote text or image data.

All 179 Python and 28 Swift tests passed. A fully frozen, Developer ID signed local build (1.1.1/11002) replaced the installed application with its original identity and settings intact. The installed UI accepted a Pura-shared synthetic 76,263-byte JPEG, saved it to Downloads with quarantine, and recorded complete progress. File contents and SHA-256 matched, and Pura displayed Sent. Prior history was preserved and the app was left running for user testing. The user's original private photograph was not opened or retested by the agent. Evidence is under `build/huawei-research/phase22/`.

## Huawei trusted-device enrollment (2026-10-17)

Completed Huawei receipts now carry `huawei-key:` plus the SHA-256 fingerprint of the canonical transfer RSA public key. The handshake exposes that key only after a valid encrypted offer proves private-key possession. This permits explicit enrollment in Trusted Devices and trusted-only receiving; it does not authenticate a Huawei account. Older Huawei receipts have no key and require a new Everyone-mode receipt. Changed keys also require re-enrollment. Discovery IDs, names and IP addresses cannot enroll or authorize devices.

The 216-test Python suite and 30 Swift tests passed. A subsequently added configuration regression passed with all 36 Huawei runtime tests. Coverage includes unknown/changed keys, copied-key offers with invalid encryption, explicit acceptance/decline, trust removal or disabled reception while approval is pending, rejection of discovery IDs, and preventing Huawei trust from opening Alliance GATT negotiation. The production AppModel harness verifies completed-receipt enrollment, metadata, add/remove/forget, and persistence using isolated preferences. Both languages' documentation views were rendered and inspected.

The full frozen engine was rebuilt and signed. Local build 11019 retains the original local bundle identifier and designated signing requirements; installed host/engine contents and existing settings were checked. Native UI inspection confirmed the two existing trusted records and the Huawei enrollment instructions. A user-initiated Pura 70 receipt then completed: saved file sizes matched the declared/completed total, the transfer key was persisted, and the native trusted-device sheet displayed Add. Enrollment changed that row to Remove while retaining the two existing records. The file's private contents were not inspected. Backups and redacted verification are under `build/huawei-trust/`.

The next physical transfer in Trusted Devices Only mode used the same enrolled key and reached approval, confirming key continuity across those two sessions. It failed after approval because its single-photo thumbnail was 70,883 bytes, above the estimated 60,000-bytes-per-file limit (`receive_preview` / `thumbnail_size`). This was a preview validation failure, not an untrusted-device rejection. The protocol now permits thumbnail data within the existing 1 MiB preview transport budget independently of file count. The entire encrypted frame remains bounded by that MTU plus the 28-byte outer crypto overhead; integrity, known/unique fields, name/metadata limits and DFile validation remain enforced.

All 107 Huawei tests passed, including a synthetic double-encryption round trip matching the reported field lengths (23 / 70,883 / 97 bytes), larger one-photo thumbnails, rejection above the bound, fragmented reads and authentication failures. Signed local build 11020 updates the externally loaded protocol module in the frozen engine bundle and re-signs the host and extension with their existing designated requirements. The frozen Python archive and native implementation are unchanged. All three trusted records and trusted-only mode are retained. Successful physical receipt of the previously failing photo on build 11020 remains pending.

Build 11021 adds only whitelisted local module names and bounded source line numbers to Huawei failure diagnostics, without paths, exception text, locals or file contents. The full engine and host were rebuilt, with 108 Huawei tests and 31 Swift tests passing. A later 10,990,916-byte receive failed at `batch` line 151: the old 8 MiB per-file bound, despite fitting the 16 MiB accepted total. Two subsequent user-initiated photo receives completed in Trusted Devices Only mode (2,685,997 and 2,979,527 bytes). Both saved sizes matched their completed totals and used the enrolled key; the user confirmed success. Private photo contents were not opened. The earlier generic receive error on build 11020 was not reproduced in these two successful transfers and its exact cause remains unconfirmed.

Build 11022 aligns the per-file incoming limit with the existing 16 MiB total budget. Reference/synthetic send fixtures keep their prior limits, and the aggregate memory/file-count bounds are unchanged. The externally loaded batch protocol was updated and the bundle re-signed with existing requirements. All 109 Huawei tests passed, including the actual failed file-size boundary, 16 MiB acceptance and rejection above the total. The installed app was restarted with the three trusted records and trusted-only mode intact. Physical receipt of the 10,990,916-byte file after this final limit change has not been retested. Local backups and redacted results remain under `build/huawei-trust/`.

## Multiple recipients (2026-10-17, local build)

The recipient popup supports checkmarked multi-selection and a Send button. Each selected device gets an independent request, progress ring, result, cancellation and retry. The window dismisses on an outside click only after every recipient succeeds.

Validation: 213 Python tests and 29 Swift tests passed, followed by an additional Huawei-cancellation isolation test. The production Swift model was exercised for multi-selection, duplicate clicks, hidden/disappeared candidates, independent terminal events, retry while another send remains active, cancelling only active recipients and preserving later file selections. Loopback integration used two isolated BLE peer fixtures and real HTTPS/WebSocket clients to verify concurrent transfers and byte-identical Japanese-named, empty and binary files. A mocked Huawei subprocess overlapped the production OShare sender; cancelling either recipient did not cancel its sibling. English and Chinese production views were rendered and inspected with selected recipients and independent progress rings. Full app packaging and signature/runtime validation passed. The installed app was backed up, replaced with the matching signed host and engine, and restarted; the engine was observed running without a reported startup error.

This verifies the implementation with simulated peers. Concurrent delivery to the physical Huawei and OPPO devices has not yet been verified.

## Immediate recipient clicks (2026-10-17, local UI update)

Replaces the earlier checkmark-and-Send interaction: clicking a device starts it immediately, with other candidates remaining visible and clickable while sending. Discovery continues until the picker closes. Started recipients retain their own progress/results even when no longer advertising. No selection checkmarks or separate Send button remain.

The production Swift model regression passed for sequential recipient clicks during an active transfer, duplicate-click suppression, preserving the original batch when later Finder files are queued, adding a newly discovered recipient after earlier sends complete, hidden/missing/stale route rejection, receive exclusivity, independent retry and cancellation, and the previous file-selection regressions. All 30 Swift tests and the five parallel-send integration scenarios passed, together with the production Swift model regression. English and Chinese production views were rendered and inspected. The engine is reused from the installed build; physical simultaneous delivery is still unverified.

## 鸿蒙星河互联 quit recommendation (2026-10-17, source update)

The English and Chinese READMEs and Settings recommend finishing transfers in 鸿蒙星河互联, quitting it, and using anDrop's independent Huawei Share file-sharing support. Coexistence remains experimental. A newly failed send or receive checks the live 鸿蒙星河互联 bundle identifier, rather than waiting for the environment timer, and queues a localized recommendation popup. The popup is nonmodal so other transfers and approval windows remain usable; one pending or visible popup covers concurrent failures. It does not quit 鸿蒙星河互联 or assert that 鸿蒙星河互联 caused the failure.

The compiled production AppModel harness passed outgoing-selection, Huawei-trust and 鸿蒙星河互联-recommendation regressions using isolated preferences/logs, with only 鸿蒙星河互联 process detection and popup presentation substituted at the OS boundary. Coverage includes sending and receiving, both languages, no 鸿蒙星河互联 process despite stale UI state, a running process before the UI timer updates, success/decline/cancellation staying silent, duplicate and concurrent failures, dismissing the popup, continued transfer updates while it is open, 鸿蒙星河互联 exiting before presentation, and app termination. English and Chinese native alert layouts were rendered and inspected. Production Swift type-checking with Sparkle and the arm64/macOS 14 deployment target passed. No new physical transfer or installed-app replacement was performed for this source update.

## 1.2.0（12000）：release validation

Official Huawei Share support is the headline feature. The complete current-source suite passed **219 Python tests and 31 Swift tests**, including the compiled native AppModel harness, loopback concurrent sends, file classification, bounded Huawei receive/send protocols and trusted-device checks. A full frozen build using the existing official Python 3.14.7 environment passed the Huawei runtime self-check, Developer ID signing and the arm64/macOS 14 deployment-target checks. The existing distributed bundle identifier is retained. Dependency notices were refreshed against the exact runtime and matching official Python documentation.

Apple notarization, stapling and Gatekeeper validation passed. Public artifacts are the Developer ID signed DMG, signed Sparkle appcast and SHA-256 checksums. Public source/history and assets were reviewed separately from private logs, archives and device evidence. Eight English/Chinese mock documentation captures were regenerated from the current production views and visually inspected, including Huawei candidates, independent recipient progress, Huawei trust enrollment, hidden-device settings, automatic installation and the 1.2.0 version label. Documentation-only viewport expansion shows the complete controls; production windows remain scrollable.

No new physical phone transfer was performed during release packaging. Earlier explicit physical results and pending retests above remain the applicable boundaries, including the final 16 MiB receive-limit retest, GiB-scale Huawei sends and simultaneous Huawei/OPPO physical delivery. macOS 14 physical-device and Intel testing remain outstanding.

### Public distribution and installed update

GitHub Latest points to v1.2.0. All three public assets were downloaded again without GitHub authentication and matched the local release artifacts byte for byte; the canonical `latest/download/appcast.xml` matched as well. Independent verification covered the DMG's Ed25519 update signature, signed feed, version/build, minimum OS, architecture, DMG contents, notarization ticket, Gatekeeper and the unchanged designated signing requirement.

The existing installed 1.1.1/build 11022 application then updated through Sparkle to **1.2.0/build 12000** and relaunched. Installed host, engine and Finder extension bytes match the notarized release. Trust records, remembered devices, aliases, hidden devices, receive scope, save destination, sharing name and language were preserved. The installed Settings footer shows 1.2.0 and Huawei Share without the experimental label. A subsequent check against the public feed displayed Sparkle's confirmation that anDrop 1.2.0 is current. This proves the update/install/runtime path, not a new phone transfer.

## 1.2.1 trusted-device automatic acceptance (2026-10-18)

All **226 Python tests and 31 Swift tests** passed. New coverage verifies automatic acceptance by default in both receive scopes, disabling it to restore approval, untrusted senders still requiring approval in Everyone, rejection in trusted-only mode, disabled reception, and Huawei transfer-key matching. Real loopback TLS/WebSocket/HTTP receipts completed without an approval prompt for enrolled senders and preserved file contents. The compiled production AppModel harness verifies persisted choices and the configuration delivered to the engine in both scopes.

The complete frozen engine was rebuilt. Its extracted bytecode passed a smoke check for both protocols, both receive scopes, default-on behavior and opt-out. The Developer ID build passed the arm64/macOS 14 runtime checks for all 80 bundled Mach-O files. Both localized Settings screenshots were regenerated from production views using fictional data and inspected. No new physical phone transfer was performed for this change.

Apple notarization, stapling and Gatekeeper validation passed. The final signed DMG, signed appcast and SHA-256 manifest are the only public assets. The full frozen engine is included; existing distributed bundle identifiers and designated signing requirements are preserved.

Public verification confirmed GitHub Latest is v1.2.1. Unauthenticated re-downloads of all three release assets matched the verified local artifacts byte for byte. Both the canonical and legacy repository latest-appcast URLs returned the signed 1.2.1 feed.

The installed 1.2.0/build 12000 app discovered 1.2.1 through Sparkle, downloaded, installed and relaunched as **1.2.1/build 12100**. Installed host, engine and Finder extension bytes match the notarized release; signature, ticket and Gatekeeper checks passed. Preference fingerprints confirmed existing trust records, remembered devices, aliases, hidden devices, receive scope, destination, sharing name, language and enabled state were preserved. Native Settings shows automatic trusted-device acceptance enabled by default. A subsequent update check reports 1.2.1 is current. These checks prove publication, update installation and runtime UI, not a new physical transfer.

## OPPO control frames and diagnostics (2026-10-19, source update)

The user confirmed approving the Mac-to-OPPO request on the phone and reported working Huawei transfers in both directions. The earlier OPPO send remained in network negotiation waiting. A later OPPO-to-Mac report established TLS, received no UDP measurement and failed immediately in `negotiate`. The old report reduced the exception to `OtherError` and omitted BLE reply fields. It cannot distinguish binary control frames, peer closure or another exception; the approved request is not attributed to missing user approval.

The control protocol now also accepts UTF-8 binary WebSocket frames with the same size and format validation as text frames. Close frames are classified as connection closure. Filtered reports retain fixed frame types, action names and network-offer field names without message values. **45 targeted Python tests** passed, covering actual loopback TLS/WebSocket/HTTP sending and receiving, binary control frames, content integrity, trust and manual approval restrictions, missing UDP probes, invalid encoding and size limits. **3 targeted Swift diagnostics tests** passed; the added conversion-result privacy assertions also passed.

This validates compatibility handling and diagnostic boundaries. It does not establish the old report's unique cause or successful physical OPPO transfers after the change. No app installation, release or new physical transfer is included in this record.

## 2026-10-19: local Live Photo build 12102

Apple `.pvt`/matching image–MOV pairs, Android/OPPO Motion Photo XMP/MPF and Huawei moving-picture trailers are integrated with the production send/receive paths. The source file remains intact; receive creates an additional PhotoKit-validated `.pvt`. The native synthetic fixture checks JPEG scan preservation, H.264/AAC compressed content, presentation timestamps, rotation, microsecond still-photo timing, HEIC conversion, container round trips, `.pvt` resend and quarantine propagation. Gainmap/multi-image MPF and ambiguous XMP fail conversion while retaining originals.

253 Python and 32 Swift tests passed. `scripts/test-live-photo-native.py --app build/anDrop.app` passed against the bundled native executable. Runtime checks verified all bundled Mach-O deployment targets and library paths, complete Developer ID signature verification passed, and the frozen motion-photo/Huawei modules matched the current source bytecode. Local build 1.2.1 (12102) was installed and launched; installed host, engine and native helper matched the verified build, and the installed helper packaging check passed. No public release or new notarization was performed. Real Huawei/OPPO gallery recognition and OPPO transfer recovery remain unverified.

## 2026-10-21: Photos import and URL files, local build 12103

The new OPPO report stops at `connect` with `ConnectionTimeoutError` after eight seconds, before download or conversion. This transport issue remains separate from Photos import.

Only locally generated, marked Live Photo packages trigger add-only Photos authorization and one asset creation request containing both photo and paired video, followed by opening Photos. Tests cover ordinary-file exclusion, malformed packages, denied authorization, import/open failure and source preservation. Actual converted synthetic packages pass the production import planner. Personal library writes and a real permission prompt were not exercised; opening Photos does not claim selection of a particular asset.

The user chose URL-file compatibility without a companion app. Loopback TLS and the production AppModel verify outgoing shortcut bytes, approved receipt classification, Copy/Open, default-off always-open preference, replay rejection and private URL exclusion from history. Pure OPPO URL sharing remains unsupported; physical file-manager behavior is unverified.

All 265 Python and 40 Swift tests passed. Packaged conversion/PhotoKit/import-plan checks, runtime compatibility and Developer ID signature verification passed. Build 1.2.1 (12103) was installed and launched; its executables matched the signed build, and live Settings showed always-open unchecked. The installed helper check passed and frozen engine/link/motion/Huawei code matched source. No public release or new notarization was performed.

## 2026-10-21: remove received URL files, local build 12104

Recognized single-file links now have their carrier removed before link delivery. Copy/Open and always-open use the in-memory URL, and deleted paths are excluded from persisted history. Unrecognized files and mixed batches remain intact; cleanup failure or replacement during inspection retains an ordinary receipt. Eleven codec/cleanup tests, 23 loopback TLS receive tests and the production AppModel harness passed, including Copy/Open, always-open, replay rejection and history privacy. The complete engine was rebuilt; frozen link and engine modules match source. Runtime compatibility, helper packaging and Developer ID signature checks passed. Build 1.2.1 (12104) was installed and launched, and all four installed executables match the verified build. Physical phone behavior remains unverified; no public release or new notarization was performed.

### Local receive-connection diagnostics (12105)

Receive reports now retain the LAN/direct route classification, transfer association and bounded connection-attempt number. Errors without errno receive one of four fixed classifications; arbitrary exception messages are excluded. Connection retries and transfer behavior are unchanged. Targeted checks passed: 21 connection tests, 23 loopback receive tests and three Swift diagnostic/report tests. The connection tests also passed under the official Python 3.14.7 build environment. A complete Developer ID build passed runtime compatibility and helper checks and was installed as 1.2.1 (12105). Settings/trust retention, engine startup, all four executable hashes and the frozen connection-diagnostic functions were verified against the build/source. Physical tablet transfer recovery remains unverified; this was not a public release or new notarization.

### OShare Live Photo ZIP reception (12106)

OShare's `<UUID>@olive.zip` representation was previously saved as an ordinary archive. The receiver now validates and converts its flat image/video pair, keeps the original ZIP, and passes the generated Live Photo to the existing Photos import flow. A single converted item is labeled Live Photo. Ordinary ZIPs are excluded. Checks passed: 15 archive tests, 15 conversion/receipt tests, five XMP tests, six Swift Photos-import tests, and the native synthetic PhotoKit/import-plan round trip including an OShare ZIP. A copy of the actual received OShare archive also produced a validated Apple pair; validation did not write to the personal Photos library. The complete Developer ID build passed runtime checks and was installed as 1.2.1 (12106). Settings/trust retention, engine startup, executable hashes and frozen archive/conversion/completion code were verified. A fresh device receipt through actual Photos import still requires user verification. No public release or new notarization was performed.

### File-only Live Photo reception (12107)

The requested behavior now saves Live Photos as files without automatic Photos import or launch. Successful OShare ZIP conversion publishes the validated `.pvt` before deleting the unchanged transport ZIP, and removes the deleted path from completion/history data. Conversion, cleanup or source-replacement failures retain the original. Checks passed: 21 conversion/XMP tests, native synthetic package validation and one Swift diagnostic test. A private copy of a received archive left exactly one `.pvt`; existing user files and the Photos library were not changed by validation. Build 1.2.1 (12107) was fully rebuilt, signed and installed with settings/trust retained. Engine startup, executable hashes and frozen receipt code were verified; the host no longer links Photos or declares add-to-library usage. No public release or new notarization was performed.

### File-only sharing and Photos handoff (2026-10-23, local build 12108)

The selected report `e96da465-348c-4300-8286-577faa477891` records one JPEG sent to a Huawei phone failing with `PermissionError` during preparation, before any network transfer. The user identified Photos' Share menu as the source. The old ordinary-file share path forwarded the provider URL without copying it while its callback access was valid; the Live Photo path already made a private copy. The report alone does not identify the denied path or establish a unique OS permission cause.

The share extension now copies ordinary files and media inside the provider callback, with scoped access balanced around the copy. It uses file representations for image/movie providers, retains complete Live Photo bundles, and hands the host only private cache copies. Failed handoffs discard copies created by that attempt. Three Swift regressions cover an actual NSItemProvider callback, provider-source deletion, identical basenames, owner-only copies, symlink rejection and Live Photo resources. Huawei/OPPO end-to-end verification of a fresh Photos share still requires a physical retry.

URL and text sharing are now unsupported in both directions. Send Link, received-link actions, automatic opening, URL interpretation/deletion and text/URL activation rules were removed. Legacy URL/text commands are rejected; existing `.txt`, `.url` and `.webloc` files remain ordinary file transfers. Earlier link-sharing records above describe superseded development builds. Targeted checks passed: 21 receive integration, 11 send integration, 43 Huawei runtime, 21 motion-photo/XMP and one production AppModel regression harness, plus the three Swift staging tests.

The full signed build passed runtime compatibility and helper packaging checks. Local 1.2.1 (12108) replaced 12107 after mutual signing-requirement verification. Signature, all four executable hashes, settings/trust retention, engine startup and file/media-only extension activation were verified; evidence: `build/local-install/files-only-12108.json`. This is not a public release or new notarization, and does not prove the reported physical transfer now succeeds.

### Photos provider fallback and error layout (2026-10-23, local build 12109)

The user retried Photos sharing on 12108 and saw the share extension's copy error. A scoped unified-log check found a `public.jpeg` item-provider failure (`NSItemProviderErrorDomain`, outer code -1000); no photo contents, paths or raw error descriptions were retained. This identifies failure of the modern file-representation request, rather than proving that the callback copy itself failed.

The extension now tries the provider's file representation, legacy shared-file URL, legacy image item and encoded image/movie data. Every returned URL is copied within its callback; data is written to a private file with its declared media extension, without re-encoding. Direct URL/text items remain unsupported. Finite import stages, allowed error-domain names and bounded numeric error codes are available in unified logging; arbitrary errors, names and content are excluded. The error label now wraps within constrained bounds above the Close button.

Six Swift staging tests passed, including a forced modern-export failure followed by real Foundation legacy URL/data loading. One native AppKit layout harness passed for Chinese and English messages. The UI-only build reused the unchanged 12108 frozen engine payload, passed runtime/helper/signature checks and was installed as 1.2.1 (12109), with executable hashes, settings/trust and startup verified in `build/local-install/photos-handoff-12109.json`. The computer-use service failed to start, so an actual Photos share and phone receipt were not re-tested. No public release or new notarization.

## 1.2.2 release candidate (2026-10-23)

Version 1.2.2/build 12200 passes 282 Python tests from the release scope and 45 Swift tests. The separate, unpublished native OShare research fixtures are excluded from that count. The packaged native synthetic round trip passed PhotoKit file-pair loading, still/video identity and timing, JPEG compressed-pixel preservation, HEIC conversion, audio/video passthrough, rotation, Android/Huawei containers, `.pvt` resend, quarantine and OShare ZIP removal. These tests do not write to the personal Photos library or establish actual phone-gallery recognition.

The complete frozen-engine build passed runtime deployment/library checks for 81 Mach-O files and helper packaging validation. It retains the distributed bundle identifier, Developer ID requirements and Sparkle trust configuration. Public artifacts and publication are verified separately after notarization. The Photos provider fallback remains covered by synthetic provider tests; a fresh physical Photos-to-phone retry is still outstanding.

## 1.2.2 publication and installation (2026-10-23)

Release commit `d2f6d8e` is published as [v1.2.2](https://github.com/TakeruF/androp/releases/tag/v1.2.2). Apple notarization, stapling validation and Gatekeeper assessment passed for the app. The signed DMG contains only anDrop and the Applications shortcut. Sparkle signatures for the DMG and embedded appcast, version/build 1.2.2/12200, macOS 14 minimum, arm64 requirement and SHA-256 manifest were verified.

GitHub Latest reports v1.2.2. Unauthenticated downloads of the DMG, appcast and checksums match the checked local public artifacts byte for byte; the latest-download appcast endpoint serves the same signed feed. The idle local app was replaced with the notarized 1.2.2/build 12200 bundle. Signature, stapled ticket, Gatekeeper, all four executable hashes, engine startup and settings/trusted-device retention passed. This installation used complete-bundle replacement; it was not a new Sparkle installation-flow or physical-phone transfer test. Only the DMG, signed appcast and checksum manifest were uploaded; private release records remain excluded.
