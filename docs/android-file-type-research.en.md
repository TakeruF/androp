# Android / OPPO receive-notification file types

[简体中文](android-file-type-research.md) · English

Investigation: 2026-10-17 JST. Scope: the then-current anDrop worktree and existing local OShare decompilation recorded as17.2.36. Initial sections describe pre-change static findings; implementation and physical feedback follow. Other Android vendors' presentation is unverified.

## Result

**Mac→OPPO can declare types, but pre-approval notifications use the encrypted `type` in the initial BLE request. Changing only the later WebSocket `sendRequest.mimeType` cannot fix that first notification.** Missing this stage left build 11015's PDF display unchanged in the user's retest; the BLE correction is recorded below.

The screenshot's question-mark icon agrees with `file/*` falling back to unknown, but that transfer's actual payload was not captured, so its specific cause was not independently proven on hardware.

## anDrop and OPPO paths

Before changes, `Sources/engine.py:Engine.send` supplied fileName/fileCount/totalSize/mimeType, with fixed `file/*` and the original first filename. The confirmation-card path below does not infer its extension from that name. HTTP `/download` `Content-Type: application/zip` describes the transport wrapper; notification MIME describes the contents. Do not change HTTP to an image/PDF type for an icon fix. Negotiation uses protocol version 1.

Local analysis root: `work/oshare-source/sources/`. No vendor source/APK was copied into this repository.

| Stage | Symbols and findings |
| --- | --- |
| Request parsing | `eb.d.i` retains JSON mimeType, returned by `f()`; thumbnail/dimension fields also exist |
| LAN receive | `fa.g.s0` parses sendRequest into eb.d |
| Confirmation card | `fa.g.E0/G0`→`ConfirmSeedlingCard.F0`→`C0`, passing name/MIME, not explicit extension/preview URI |
| Icon choice | `ConfirmSeedlingCard.b.g` uses explicit extension without URI, otherwise `h0.a(mimeType)`, then `FilePreviewSrcUtils.a` |
| Card update | startSeedling uses `b.g()` as previewSrc |
| Media | `h0.m/h/o` match image/audio/video prefixes |
| Documents/archives | MIME→extension map and extension→icon rules |
| Fallback | `file/*` matches none and reaches `images.preview_unknow` |

Consequently, merely renaming to.pdf does not suffice on this LAN path; application/pdf matters. This path alone does not establish initial BLE notification behavior.

## Statically established type/icon mappings

| Contents | MIME | Icon |
| --- | --- | --- |
| JPEG / PNG | `image/jpeg` / `image/png` | Image |
| Video | `video/mp4` | Video |
| Audio | `audio/mpeg` | Audio |
| PDF | `application/pdf` | PDF |
| Text | `text/plain` | TXT |
| Word | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` | Word |
| Excel | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | Excel |
| PowerPoint | `application/vnd.openxmlformats-officedocument.presentationml.presentation` | PowerPoint |
| Sharing a ZIP itself | `application/zip` | ZIP |
| Unknown/mixed | `file/*` | Unknown |

These are static selections, not physical display proof for a modified app. image/* also enters image classification; flattening PDF/documents to text/* loses extension specificity. Type icons differ from actual thumbnails: the inspected fa.g card call has no preview URI, so a thumbnail field alone does not guarantee image previews. Version 4+ has separate exact image/*/video/* and vision/*+number count handling; correct mixed-media counts cannot be assumed for version 1. Legacy application/vnd.ms-excel maps to `.xls` while icon rules require `xls`, potentially preventing its dedicated icon; MIME spoofing is not used. [Android's sharing guidance](https://developer.android.com/develop/ui/compose/sharing/send) is separate from the OShare network protocol; these findings come from the actual OShare path.

## Implementation and validation scope

1. Derive actual single-file MIME from extension/macOS types. Use concrete MIME for homogeneous batches, a media wildcard for one media category, and file/* for mixed/unknown. Never classify the whole batch from only its first file.
2. Preserve ZIP transport, HTTP headers, names, bytes and approval.
3. Separately verify JPEG/PDF/TXT/ZIP/homogeneous/mixed and video counts: request values, pre-approval icon/text, completion, save location and contents.

At the user's implementation request, `Sources/file_types.py` was added and connected to WebSocket mimeType. Archives are not declared as their internal contents. Classification/TLS-WebSocket integration covered PDF/JPEG/multiple images/mixed batches, original names/counts/sizes, HTTP ZIP and all extracted contents;202 Python tests passed. The BLE peer was synthetic, not proof of OPPO icons or saving.

Complete local1.1.1/build 11015 installed at `/Applications/anDrop.app` and restarted, preserving signing requirements, ID and update settings. Old11014 was backed up at `build/android-mime-install/anDrop-before-install.app`. Full signature/macOS 14 runtime/frozen-engine checks, installed PDF/mixed classification, host/engine startup and error-free discovery/advertising passed. Evidence: `build/android-mime-install/`. No public release.

## Build 11015's missing BLE declaration and build 11016 feedback

The user reported no PDF icon change. Installed/running bundles matched11015, but initial encrypted BLE type still said file/*. OShare `com.oplus.oshare.ble.impl.w.e` decrypts type, then `A()`→`B()`→`ConfirmSeedlingCard.C0`→`R0(..., false)` shows the pre-approval card before WebSocket connects. The original fa.g investigation covered only a later stage.

The correction calculates MIME once and supplies the same value to encrypted BLE type and WebSocket mimeType. Integration tests decrypt BLE and verify PDF typing even when the receiver declines without reaching WebSocket. Complete11016 installed/restarted with the same ID/signing requirement; previous bundle at `build/android-mime-fix/anDrop-before-install.app`.203 Python tests passed on rerun. An unrelated Huawei advertisement test initially mistook random-token0xff for the payload boundary; isolated and full reruns passed without modifying that test. Signature/runtime/engine self-check/host-engine startup passed.

Finder Share handed synthetic `androp-oppo-mime-check.pdf`618 B to the installed app and an OPPO phone was selected. Transfer completed2026-10-17 21:08:23 JST; the user confirmed improved presentation. This is user-observed display proof, without independent phone-content hashing or physical display checks for other formats. Evidence: `build/android-mime-fix/`.
