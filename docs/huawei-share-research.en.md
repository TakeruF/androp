# Huawei Share / HarmonyOS 7 physical-device research

[简体中文](huawei-share-research.md) · English · [Documentation](README.en.md)

Investigation: 2026-10-17 JST, HUAWEI Pura 70. This consolidated record preserves the investigation's stages, protocol findings, evidence pointers, failures and validation boundaries. Original phase numbers are retained; phase 33/34 contain separate icon and receive-fix tracks. Historical build status is distinct from the current release: see [compatibility](compatibility.en.md), [validation](testing.en.md) and [1.2.0](releases/1.2.0.en.md).

## Established results and open questions

- Without running 鸿蒙星河互联, loading its libraries or changing Wi-Fi, the anDrop app and standard Huawei Share completed three-file transfers in both directions over the existing LAN. Downloads placement, full contents, SHA-256, quarantine and complete history were verified. Duplicate receipt preserved originals. Phase 18's complete frozen build covered an empty file, a Japanese filename and 8 MiB.
- Phase 16 established screen-on discovery without opening the phone's share sheet, subsequent sending in “Devices shared with” using a persistent Mac identity, and retries after cancellation or forcibly closing Mac-side TCP. Screen-off/locked discovery, actual Wi-Fi loss recovery and long-term phone authentication remain incomplete.
- Photo-only type 1 classification entered build 11012 and remained in 11013. In phase 37, a notification test using the product's `offer()` produced a green image icon, confirmed by the user on the phone. Videos, documents and mixed batches are not declared photos. Dedicated pre-approval PDF/Office/video presentation remains unresolved.
- In standard `RecvSessionV1`, changing phone visibility to Everyone changed `verifyMode` from 0 (refusal) to 1 (certificate-chain verification). Obtaining a communication key does not authorize sharing. This route requires a chain rooted in Huawei trust and a certificate public key matching the exchanged key. These requirements cannot be assumed for the working Apple-compatible route.
- Phase 38 reproduced seven primary commands, six control commands and the receive-prompt event chain registered by the Apple receiver constructor. No additional icon input was found in that table. Other sessions, versions or later registrations are not ruled out. Phases 35–38 did not change the product or installed app.

## Device and comparison environment

| Item | Observation |
| --- | --- |
| Phone | HUAWEI Pura 70 / ADY-AL10 |
| Product software | `7.0.0.109(SP6C00E105R5P2)`; update screen HarmonyOS `7.0.0.109 SP6` |
| System property / API | `const.ohos.fullname=OpenHarmony-7.0.0.105`, API `26`; not the product version |
| Sharing app | `com.huawei.hmos.instantshare`, `7.0.0.545` |
| Diagnostics | HDC connected, no ADB target; USB assisted setup/readback, sharing used Wi-Fi |
| Comparison app | 鸿蒙星河互联 / `com.EMUIInterconnect.app`, `1.0.0` / build `1005.1`, `/Applications/EMUI Interconnect.app` |

The existing installation was used. `mas info 6775134178` returned 1.0.0 and `mas outdated` did not list 鸿蒙星河互联. A generic App Store page showing 1.0.1 did not establish a Mac update, so none was installed.

The requirement was sharing without changing Wi-Fi. 鸿蒙星河互联's enabled high-speed mode said it would directly connect to Huawei WLAN for each transfer. Disabling it allowed a 77 B synthetic Mac→Pura→Mac round trip with matching bytes and SHA-256. This supports, but does not isolate, high-speed mode as the earlier stall's cause. An 8 MiB Japanese-named send also completed while TCP used existing en0→wlan0 addresses, unchanged before and after; no hotspot was created or joined. This establishes an existing-LAN route, not router-free AirDrop-style direct connectivity.

## Evidence and test constraints

Evidence names below are relative to ignored `build/huawei-research/`. They identify local investigation artifacts, not downloadable repository attachments. Device serials, accounts, raw BLE captures, private keys, vendor binaries and decompiled source are excluded. Hashes identify the explicitly named synthetic fixtures and binary provenance. Ports are negotiated examples, never constants.

| Synthetic fixture | Size and SHA-256 |
| --- | --- |
| `androp-huawei-probe-20261017.txt` | 77 B; `a6464cd72f201b235a9e48ecdbd1c09a932b71af5992ef5a7e1039fd31e1fd2c` |
| `華為共有検証-20261017-8MiB.bin` | 8,388,608 B, repeated `bytes(range(256))`; `7d212b9c884f5c77896de960ae17cc341cda43b14d6a971f34ca29ebd4badf7f` |
| `androp-independent-HHMMSS.txt` | 60 B fixed synthetic text; `56a5e7134c90f0ddcfbfb96bd7c02c2607ed4bb2258059a06cd2b98b53acc0d3` |

Comparison evidence: `roundtrip-evidence.json`, `large-lan-sockets-redacted.json`, `network-final-redacted.json`. Ports 33651/33559/46713 were observed only as session-specific values.

Mac→Pura ping and Python UDP5683/5684 failed with `EHOSTUNREACH`, while reverse ping and 鸿蒙星河互联 LAN transfers worked. This does not establish a broken LAN. 鸿蒙星河互联/Python/anDrop Local Network permissions and 鸿蒙星河互联 location permission were observed enabled, without changes. Native `/usr/bin/nc` worked where Python sockets failed; the cause remains unknown, and `nc -s` also failed in one configuration. Closing TCP stdin immediately yielded 0 B; holding it open allowed replies. Zero bytes alone do not prove authentication refusal.

An early file-dialog row shift accidentally sent a 179 B candidate-diagnostics JSON to the same user's phone. The viewer showed it, so a later Decline cannot establish non-delivery. It contained a local BLE endpoint and scan attributes, not credentials, accounts or contacts. Subsequent sends used a dedicated `send-fixtures/` folder and checked the filename and 8.4 MB label. Phone fixtures/JSON and Mac returns were retained. New terms blocked the phone file manager; no consent was supplied on the user's behalf. Phase 11 later verified the 8 MiB return contents.

## BLE and static-analysis clues

| Observation | Content / boundary |
| --- | --- |
| Advertising | FE35 Service Data, manufacturer `0x027D`; 15/24 B, and 13/22 B in another observation |
| GATT | `11C8B310-80E4-4276-AFC0-F81590B2177F`, characteristics `2B00`/`2B01`, read/write/write-without-response/notify/indicate |
| Other services | FE35 (`2A00`–`2A03`), `C574EDB3-6551-473B-BAD8-65035F07E4A8`; values not interpreted |
| Comparison advertisement | `FE35`, `933E`, three generated 16-bit values, `0300`, local name; probes used random values, never borrowed account/device IDs |
| LAN clues | CoAP `/device_discover`, 5684, `coapUri`, `capabilityBitmap`, `wlanIp`, `serviceData` |
| Session clues | `IShareEcologyAuthSession`, `IShareReceiverBytesSession`/`IShareSenderBytesSession`, `IShareReceiverFileSession`/`IShareSenderFileSession` |
| Crypto/transport clues | `SoftBusEncryptDataWithSeq`, `TransTdcEncryptWithSeq`, `TransTdcUnPackData`, AES-GCM, ChaCha20-Poly1305, `SetSpeedMode`, WLAN handshake, `NETWORKINFO_NEGO`, `go ble`/`go tcp`, `ParseCompetencyNego`, `secure_version`, `ParsePubKeyHandShake` |

鸿蒙星河互联 was also running during the first GATT enumeration. Only explicitly selected candidates visible in the current scan were connected; stale endpoints stopped with `target_not_seen_in_current_scan`. Strict visibility causality, exact physical identity and persistent discovery were not established. Thirty-second synthetic advertisements/GATT without 鸿蒙星河互联 produced no reads/writes/subscriptions or file connection. Twelve-second invisible and subsequent Everyone scans both returned no candidates, so they do not isolate the visibility switch. CoreBluetooth advertisement success does not prove every intended byte reached the air.

Phone `hidumper -s 4700` exposed DSoftBus discovery/connection/transmission and masked iShare registrations. Public DSoftBus is not the complete proprietary iShare authentication/transfer layer. The existing MTA/OShare `3333`/`3334`, service `8881`, GATT `9999`, `9897`/`9898` differ; adding a brand or replacing UUIDs does not establish reuse of HTTPS/WebSocket transfers.

## Initial independent LAN, capabilities and key exchange

鸿蒙星河互联 and its libraries were unused; no phone app, certificate or account was added. HDC only inspected state. UDP5684 CoAP CON POST `/device_discover` to the explicitly specified existing-LAN phone returned an ACK and two JSON records totaling 756 B. `serviceData` supplied TCP33651. Probe names/IDs were synthetic; peer names, addresses and identifiers were omitted from public evidence.

A 24 B SoftBus header and `IShareEcologyAuthSession` opening received 263 B: magic `0xBABEFACE`, module 8, flags 1, CODE 4, API 2, MTU 39968. ROUTE_TYPE0 was not used as route proof. The module 9 capability response was 61 B, envelope version 1/protocol 101/TLV3; empty tag 1 secure_version was interpreted as bit0 following the comparison parser.

An ephemeral RSA-2048 request obtained 294 B SPKI DER in TLV6→2, 346 B overall. A 16 B nonce+32 B AES challenge encrypted with the peer key using OAEP-SHA 256/MGF1-SHA 256 yielded a reply decryptable with the probe's ephemeral private key. AES-256-GCM verification recovered a 32 B session key. Raw keys were never saved. This proved key negotiation, not authorization, identity or file receipt. The initial envelope hash did not match the comparison HMAC; no trust bypass was added.

Evidence: `independent-final-lan-redacted.json`, `independent-everyone-notify-redacted.json` (two subscriptions, three seconds each, zero spontaneous notifications), `independent-auth-open-held-redacted.json`, `independent-public-key-redacted.json`, `independent-key-challenge-redacted.json`, `independent-key-challenge-final-redacted.json`, `independent-lan-listener-redacted.json`. Early probes kept `authentication_complete`/`transfer_attempted` false and separately recorded `key_challenge.rsa_response_decrypted`, `aes_gcm_tag_verified`, `session_key_bytes`. Five offline tests covered redaction, Unicode CoAP, varints, split/oversized/truncated TCP and TLV lengths.

鸿蒙星河互联 1.0.0 arm64 locations: opening `0x100036f48/0x10006292c`, TCP header `0x10009f780`, envelope `0x10008ec80`, capabilities `0x10008c590/0x1000937bc`, public key `0x100093a6c`, challenge `0x100093ea8/0x1000940f8`, OAEP `0x10004d19c`, GCM `0x10004cd70`. These apply only to that binary. Excerpts/provenance are in `petal-relevant-disassembly.txt` and `petal-static-provenance.json`; the large intermediate disassembly was removed.

## LAN information and channel negotiation (phase 2–3)

An AES-GCM command 7 offer declared `anDrop LAN Probe`, one synthetic 60 B file, and was approved only after that standard prompt was checked. After verified `user_confirm`, command 4→5 must precede command 10; sending10 directly stalled. SSID was empty and only existing en0 private IP was supplied. There is no AP credential/hotspot creation/join operation. Module21 uses a 24 B `<IIQII>` authentication header followed by nonce12 B and GCM, with strict length checking. Initially offset24 was merely the framing hypothesis that passed GCM; subsequent work established the structure.

MetaNode fields were DEVICE_NAME/DEVICE_TYPE_ID/META_NODE_ID/FLAG: Pura14/100, probe12/100 and an ephemeral 64-character ID. A single trailing JSON NUL required handling. After verified `META_DEVICE_INFO_ACK\0`, inner type `0xffff0004`/module 16/CODE 3 negotiated the byte-channel port. `P2P_IP` contained existing LAN addresses despite its name; only the specified phone IP was accepted.

A separate TCP used module 6/flags `0x94`/CODE 1/API 2, encrypted with the control key and carrying another temporary 32 B key. Its ACK was flags `0x95`, MTU 4096. Inner module 17/CODE 1538 on the authentication channel negotiated files. BUSINESS_TYPE 0 returned CODE 6/ERR_CODE -426115067; correcting it to 3 returned normal1538, MY_CHANNEL_ID 8, P2P_PORT 46207. Neither port nor channel ID is fixed.

Evidence: `next-offer-redacted.json`, `next-network2-redacted.json`, `next-channel4-redacted.json`, `next-final-state-redacted.json` (10 offline tests); `phase3-meta-pc-nul-redacted.json`, `phase3-port-redacted.json`, `phase3-byte-redacted.json`, `phase3-file-business-redacted.json`, `phase3-final-state-redacted.json` (14 tests). The old successful file-port record lacks the later `file_channel_acknowledged` field. The first Settings stall was later traced to `next_recv` and an unfinished phone receive, not a missing opening reply. Cancelling that pending receive let negotiation continue. Defaults stop at file-port negotiation; Settings requires `--dfile-settings` or `--send-fixture`.

## Independent DFile sending and PC discovery (phase 4–5)

The first 60 B save succeeded at 12:18 JST. DFile type 8 Settings negotiated WLAN connection_type2, MTU 1472, headerEnc1, capsCheck876. Control encryption is negotiated separately with capsCheck bit8 (`0x100`), not headerEnc. Without it, encrypted file headers received empty confirmation. Type11 congestion control is plaintext and not an authenticated reply.

DFile GCM uses the first 16 B of the negotiated32 B key, AAD of 64 ASCII `A` bytes, and a trailing16 B tag+12 B nonce. Using all 32 B caused `AesGcmDecrypt: data verify error`; public `SetCryptPara` and 鸿蒙星河互联 `SetSessionCryptPara` clarified the correction. FileID1 data was sent only after type 2's GCM and inner/outer headers verified; DONE before data is not success. Verified type 6 DONE received a type 7 ACK, whose payload on this sender was empty. HDC readback of `androp-independent-121840.txt` matched60 B and SHA-256. Evidence: `phase4-aes128-controls-redacted.json`, `phase4-content-verification-redacted.json`, `phase4-received-fixture.txt`. The immediately following attempt returned `user_reject` and was not overridden. Cleanup attempts senderCancel but does not report an unreceived ACK as success. `next_recv` is only plaintext waiting. Nineteen offline tests passed.

At 12:22–12:25, two fresh60 B sessions verified encrypted DONE and independent readback, without restarting the phone service. No extra upper-level completion appeared within two seconds, and standard UI completion was not captured. Evidence: `phase5-repeat{1,2}-redacted.json` and their `-integrity-redacted.json` records.

`huawei-receiver-discovery-probe.py` advertised PC12 and a temporary TCP port to the explicit LAN target for at most 60 seconds, without default approval/saving. Mode 1 sent27 advertisements in 55 seconds and received52 CoAP chunks but no candidate/TCP. Mode 10 plus omitting `coapUri` produced a candidate; their individual contributions were not isolated. Mode 10 matches public `PUBLISH_MODE_PROACTIVE`. Selecting the77 B fixture and candidate delivered module 8/CODE 4/API 2/MTU 39968 opening, but no receiver reply existed yet, so the phone showed failure. This was not receipt. The PC icon visibly contained `Mac`; the separate effects of type 12 and `osType:2` were not isolated, and no HarmonyOS-PC identity is claimed. Twenty offline tests passed. Evidence: `phase5-receiver-publish-redacted.json`, private `phase5-picker-private.jpeg`, `phase5-final-state-redacted.json`.

## Receiver authentication failure and correction (phase 6–9)

Phase 6: minimal CODE 4 did not progress. Adding PKG_NAME/SRC_BUS_NAME/DST_BUS_NAME/REQ_ID yielded capabilities and RSA requests, without isolating required fields. Public-key replies then stalled for eight seconds, both with TRUE/TRUE capabilities and omitted flags. `--inspect-offer` gained ephemeral key/GCM offer handling and explicit rejection, never file approval. Source-IP matching only scopes the target. Twenty-two synthetic-peer tests passed, not physical Pura interoperability. Evidence: `phase6-receive-auth{2,3,4}-redacted.json`.

Phase 7: hilog `SessionManagerProtocolV2.cpp:260 ... hash code is not same.` localized rejection to public-key hashing. Secure version 1/MGF1-SHA 1 failed and was reverted to 0. Consistent temporary HMAC advertisement/opening IDs and matching `deviceHash` also failed. DER/PEM/Base64, SHA 256/SHA 1/MD5, HMAC and byte-order candidates did not match, without establishing the actual definition. Twenty-three tests passed. Evidence: `phase7-{version1,consistent-identity,advertised-hash,phone-diagnostics}-redacted.json`.

Phase 8: five read-only connections; three consecutive DER294 B keys,16-character envelopes and6-character opening IDs stayed equal. Capability/public-key envelopes within a session matched and were not simple request echoes. SPKI/PKCS#1/PEM/modulus in both endian orders, Base64/hex, SHA 512 and1/2/4/8 B reversals also failed. 鸿蒙星河互联 `0x10004c744` is HMAC-SHA 256, `0x10004c8c4→0x10004ca04` exports SPKI, and `0x10005dc08` has uppercase hex. No hash comparison was found inside `ParsePubKeyHandShake` (`0x100093c3c`); that function cannot be equated with the phone's ProtocolV2 validation. Evidence: `phase8-{hash-analysis,stability,echo}-redacted.json`; raw values stayed in memory.

Phase 9: ProtocolV2 needed the first 6 HMAC bytes as12 hex digits in original byte order, whereas the borrowed 鸿蒙星河互联 short-ID scheme grouped little-endian16-bit units:

```python
digest = HMAC_SHA256(key=public_der[:16], message=public_der)
protocol_v2_identity = digest[:6].hex().upper()
```

This ID feeds advertisement UDID and opening DEVICE_ID/PEER_NETWORK_ID; lowercase opening IDs work with `strcasecmp`. The envelope remains uppercase hex of the first 8 B. ROUTE_TYPE2 does not change actual en0 transport. The already-working sender identity was not changed. Two fresh-share sessions using new ephemeral RSA keys completed challenge/session-key reply/encrypted-offer verification, then returned `user_reject`, with no file approved. A repeat from the stale share sheet had no opening and was not counted as continuous success. Offer field7 was10 B, not the32 B fixed filename; `expected_synthetic_offer=false` remained.

Read-only `debugfs` extraction from existing SDK `HarmonyOS-7.0.0-B1/phone_all_arm/system.img` established the cause without booting/mounting/modifying the image. Service `Util::GetHashCode` (`0x9213c`) and plugin `0x13c1d0→0x20aca0→0x13c284` derive6 B, hex each byte, then compare case-insensitively. Emulator log line207 differs from physical260: these are distinct binaries. Public SoftBus maps `deviceHash` to decimal uint64 account-hash data, not a public-key hash. The phase 7 hypothesis was withdrawn and the probe restored an empty value, never copying the phone's account data. Twenty-four tests passed. Evidence: `phase9-hmos-hash{,-repeat,-repeat2}-redacted.json`, `phase9-static-provenance.json`, `hmos7-*`.

## Independent receiving, empty/large files and cancellation (phase 10–12)

Phase 10 added `--receive-fixture` and `huawei-receive-channels.py`, approving only the known77 B offer and rechecking names in preview/DFile. After command 4→5/10 and MetaNode/ACK, separate byte/file TCP listeners pin source IP. Phone opening flags are `0x90`; the `0x91` ACK needs DEVICE_ID/MTU_SIZE/PKG_NAME/AUTH_STATE. After opening, byte traffic uses a16 B data header. The3,599 B preview has outer byte-key GCM and an inner control-key envelope; command 8 field11 is the filename and field12 is3,503 B, not retained. DFile arrives after doubly encrypted command 1/field8=`previewOK`; byte/control/file must be read concurrently.

Type1 name/count/77 B checks precede type 2. Each type 4 verifies AEAD, ID, sequence, transaction and known contents. Saving is exclusive, followed by fsync/readback, type 6 and authenticated type 7 DONE ACK. Both `phase10-receive12/13-redacted.json` matched77 B, contents/hash/ACK, with sibling `.received.txt`; the second required no service restart. Phone success UI was not captured. An earlier failure recovered only after restarting the sharing app, not OS/Wi-Fi/Bluetooth; changing visibility did not help. Waiting for peer MetaNode before responding and restarting were not isolated. Cleanup BrokenPipe must not hide the original error. Default inspection still rejects and existing destinations fail early. Twenty-nine tests passed; `phase10-final-state-redacted.json` records cleanup.

| Stage / test | Result and evidence |
| --- | --- |
| phase 11 Pura→Mac Japanese8 MiB |5,900 encrypted DATA chunks, reconstructed matching hash and DONE ACK; `phase11-large1-redacted.json` and `.received.txt` |
| phase 11 empty round trip | No DATA, but header ACK still required before DONE; phone readback0 B, reverse save0 B/ACK; `phase11-empty-send2-redacted.json`, `phase11-empty-phone-readback.txt`, `phase11-empty-receive1-redacted.json` |
| phase 11 cancellation after preview | Control-channel field4 receiverCancel, no field5 ACK within 3  s, no save; immediate retry worked; `phase11-cancel1/reconnect1-redacted.json` |
| phase 12 Mac→Pura Japanese8 MiB |5,900 frames, DONE and full HDC readback matched; `phase12-large-send1-redacted.json` and readback |
| phase 12 send cancellation | After64 chunks/91,008 B queued, initial control cancellation had no ACK; doubly encrypted byte-channel field2 senderCancel obtained field3 ACK; `phase12-cancel1-redacted.json`, `phase12-cancel-bytes2-redacted.json` |
| phase 12 send retries | Both retries saved matching contents without service restart; `phase12-retry{1,2}-redacted.json` and readback |
| phase 12 receive cancellation | Byte field4→field5 ACK before previewOK, no save; next empty transfer succeeded; `phase12-receiver-cancel/receiver-retry-redacted.json` |

DATA payload is at most 1,422 B, full frame1,472 B. Each file checks ID, contiguous sequence, transaction and start0/middle1/end3 flags. Receiving then used at most 8 MiB memory and published only after full verification; logs aggregate5,900 frames. Nonblocking writes have deadlines and cannot accept DONE while data remains queued. The91,008 B figure is queue input, not phone disk writes. Absence from the final directory does not prove deletion of internal temporary files.

A command 1/field15 notification of 26,955 B can precede a cancellation ACK, requiring bounded skipping while retaining only structure/length. `--fixture-source` fixes local basename/size/hash; empty/large fixture switches generate only synthetic data. Initial shared-mode refusal followed by Everyone success does not prove account pairing. Phase 11/12 final readbacks confirmed shared selected=true, unchanged IPs/en0 and no 鸿蒙星河互联/test nc, retaining fixtures. Offline totals36/40. Final evidence: `phase11-final-state-redacted.json`, `phase12-final-state-redacted.json`.

## Explicit files and three-file batches (phase 13)

`huawei-file-batch.py` removed fixed-content dependence. Synthetic inputs: `androp13-日本語メモ.txt`81 B, `androp13-empty.txt`0 B, `androp13-random.bin`1,048,593 B; total 1,048,674 B. Three `--send-file` arguments formed one offer; all IDs1–3 completed and HDC readback matched. Reverse `--reference-file` matched reordered IDs by name/size. A subsequent `--accept-files` receive had no predefined names/content/hashes; protocol integrity was checked during receipt, then a separate comparison established the original name set, bytes and hashes. `reference_content_verified=false` only means no advance reference was supplied.

The first reverse transfer failed SendBytes with 4 KiB MTU. At65,536, the doubly decrypted preview was10,418 B (field11=67, field12=10,287);739 DATA chunks, one header and one encrypted DONE ACK completed. Field12 was not saved. Evidence: `phase13-batch-send1-redacted.json`, `phase13-send-readback-redacted.json`, `phase13-batch-receive{1,2}-redacted.json`, `phase13-unreferenced-receive-redacted.json`, sibling `.received/` directories, `phase13-receive-readback-redacted.json`.

Limits then:1–16 files,8 MiB each/16 MiB total; explicit regular files only, rejecting symlinks/directories and size/mtime changes during reading. Names are1–255 UTF-8 bytes, rejecting separators/NUL/control characters/`.`/`..`/trailing whitespace or dots/colons and normalization/case collisions. Preview names≤1,024 B, opaque preview≤60,000 B, byte frame≤65,536 B. Header fragmentation, per-ID ACK/DONE and offer/header count/total consistency are checked; partial DONE cannot finish the batch. Complete verified contents are saved into a new exclusive `.received/` without interpreting remote paths or auto-opening. Disk failure may leave some verified files: whole-batch atomic saving was not implemented. Explicit `--accept-files` is a one-transfer test approval for the specified target, not product confirmation or identity authentication. Forty-seven tests passed; `phase13-final-state-redacted.json` confirms shared/IP/en0/cleanup.

## App integration and full builds (phase 14–18)

Phase 14 added `Sources/huawei_runtime.py` and `Sources/HuaweiLANDiscovery.swift`, connecting existing recipients/request/decision/progress/history through isolated development bundles. Native UDP forwards a datagram plus kernel source; TCP uses verified native nc, with dedicated process groups. CoAP validates version/token/options/resource, Uri-Host, optional Content-Format, one trailing NUL, mode/capabilities. Uri-Host never chooses the peer; advertised IP must match kernel source and subnet. Duplicate JSON/ambiguous ports/extra data are rejected. Records expire after 10  s and refresh ports by ID; later channels pin phone IP. Keys stay in memory and diagnostics contain fixed code/phase/exception types.

Physical PC discovery, three-file prompt and Decline worked, producing declined history and no Downloads files. Acceptance verified staging only. `linkat` stalled without proving a permissions cause; replacement `renamex_np(RENAME_EXCL)` avoids overwrites, adds collision suffixes/quarantine and rolls back failures, withholding DONE until placement. The replacement was not yet physically retested. Historical Trusted-only rejected Huawei while long-term authentication remained unresolved; later enrollment is covered in [architecture](architecture.en.md). UI tooling also lost Finder windows; automated approval was not counted as proof.157 Python/21 Swift, full build/self-check/signature/macOS 14 checks passed. Homebrew Python was correctly rejected for minimum OS; sequential deep-first Sparkle signing avoided `.cstemp` races. Evidence: `phase14-decline-evidence-redacted.json`, `phase14-staging-recovery-redacted.json`, `phase14-app-receive1-redacted.json` (not complete), `phase14-final-state-redacted.json`.

Phase 15 resumed after the user unlocked the Mac and granted Downloads access. Finder Open With passed only the three fixtures to the development app; this was not Share-extension validation. Phone Everyone plus open share sheet allowed discovery. App sending81 B Japanese text/0 B/1,048,593 B totaled1,048,674, UI100%/engine complete and all HDC contents matched. Reverse standard Huawei Share→app approval→Downloads verified bytes/hash/quarantine/history; repeating produced ` (1)` while preserving originals.8 MiB remained probe-only at this stage. Evidence: `phase15-app-send-redacted.json`, `phase15-app-receive-redacted.json`, `phase15-history-redacted.json`, `phase15-app-receive-collision-redacted.json`, `phase15-final-state-redacted.json`. Shared visibility was restored; installed app unchanged.

Phase 16 fixed cold discovery: idle Pura bitmap192 lacks SHARE bit256, while an open share sheet reports448. The old required256 filter discarded idle responses. Phone14/pad17 now permit absent256, other types still require it. Discovery took3.5  s with the phone share sheet closed; a40 B send/readback matched. Screen-off/locked phone returned empty ACK/no response: BLE wake remains unimplemented. Everyone may still report192. Mac chooser discovery also incorrectly replied mode 1, hiding the Mac from the phone; unicast replies now always mode 10, while only proactive broadcast uses1. Physical observation confirmed the Mac remains visible while its chooser is open.

New IDs failed in shared mode. The same RSA keyK succeeded first with Everyone, then shared and after restart. RSA 2048 persists at `~/Library/Application Support/anDrop/Huawei/identity.pem`, mode 0600, deriving12-digit ID/envelope/UDID/META_NODE_ID. Corrupt or permissive files are not overwritten; an ephemeral key continues with `huawei_identity_unavailable`. Persistent Mac identity is not phone authentication; retention duration is unknown. Three transfers completed without an observed user tap, for unknown phone-side reasons, not attributed to anDrop.

A16 MiB send cancelled without a final phone file and retried with matching contents. Receiving cancelled around 6.5 MB left no Downloads file and removed staging; retry `(1)` matched. Killing Mac nc during receive/send failed promptly, then retry `(2)`/resend matched without a phone service PID change. Product cancellation then closed connections without cancel messages, so the phone displayed failure. This was not a Wi-Fi outage test. A completion/cancel race caused killpg EPERM and a false file-permission message; treating an exiting process as gone and preferring recorded completion fixed it. Other fixes: host exit BrokenPipe must not stop nc cleanup; file preflight/cleanup moved off the event loop (TCC was only suspected); only own non-symlink `.anDrop-Huawei-*` staging older than10 minutes is removed (session maximum90  s); deadline/closed/incomplete/BrokenPipe map to interrupted connection.170 Python/21 Swift passed, new regressions first failed old code. Thirteen sent and four received hashes matched. The rebuilt frozen app passed static checks but was not visible in that attempt, cause unknown.

This matrix used phase 15 host plus source engine and normal UI JSON commands, not the complete frozen rebuild. Evidence: `phase16-summary-redacted.json`, `phase16-cold-send1-redacted.json`, `phase16-sharedonly-send1-redacted.json`, `phase16-persist-{1,2,3}-*-redacted.json`, `phase16-ephemeral-everyone-redacted.json`, `phase16-phone-readback/`, `phase16-fixtures/`, `phase16-final-state-redacted.json`; research private key ignored.

Phase 17 configurationA copied the complete frozen build, changing only display name/start-settings Info key/host signature, and verified machine code/engine equality. Without changing network permissions it discovered and sent79 B Japanese text/empty/8 MiB, total 8,388,687, all HDC contents matching. Reverse opening stalled in a Downloads opendir worker before approval/save, while the event loop remained responsive; TCC was not established. ConfigurationB added native UDP `huawei_transport_failed`/phase/numeric errno diagnostics, suppressing repeats for 60  s without SO_REUSEPORT, retries after temporary interface/listener failures, threaded interface lookup and cleanup limited to the current Huawei future.173 Python/22 Swift passed. Starting against occupied5684 recorded EADDRINUSE once as transport_bind, without sending or stopping the existing listener. B built successfully but had not yet been physically tested. Evidence: `phase17/{full-build-send,build-provenance,transport-conflict,final-state}-redacted.json`. Historical work division gave Claude limited Swift diagnostic review and Codex UI/Python; unrelated AppUpdates was untouched.

Apple's ad-hoc-signing privacy guidance does not prove this stall's cause; OS permission databases were not edited.

Phase 18 followed user confirmation of Downloads access and phone unlock, making a fresh copy of the latest full build, with no source-engine substitution/command injection, matching host machine code/frozen engine and normal Downloads folder selection. Both directions verified79 B Japanese text/empty/8 MiB; incoming bytes/hash/quarantine/complete total 8,388,687 and repeated `(1)` with originals retained. First approvals on each side were not observed and are not called automatic; the second native Mac prompt was clicked. Visibility was shared before send but Everyone at finish, changed by unknown cause outside this test's actions; shared was restored and read back. Continuous shared mode during sending is not claimed. Discovery failures gained1/2/4/8/16/30  s backoff and aggregation without cancelling active sends.175 Python/22 Swift passed. Evidence: `phase18/{full-build-receive,full-build-collision-receive,full-build-send,build-provenance,final-source-manifest,final-state}-redacted.json`. Final IP/en0 unchanged, no 鸿蒙星河互联/dev host/engine/nc, persistent key unchanged0600. Installed app was observed Everyone but not modified or reset to an unproven prior value.

The cancel/TCP matrix was not repeated on this frozen build.

## Recipient UI and local installation (phase 19–21)

Phase 19 removed the name pencil and added icon context-menu Rename Device/Hide from Candidates, plus offline restoration through Hidden Devices in Settings. Only local aliasKey hashes/display metadata change, not trust, receiving or engine discovery. Filtering occurs on discovery/selection/pre-send; active tiles remain and editing active transfers is disabled. Changed identities may appear as new devices. A physical candidate verified context menu, rename, hide, restart persistence, pre-discovery list, restore and rediscovery, then original state was restored.26 Swift tests (four new), UI build/signature/self-check passed; engine matched phase 18. Active-transfer preservation was code-reviewed, not physically retested. Evidence: `phase19/{native-ui,restart-persistence,build-provenance,final-source-manifest}-redacted.json`.

Phase 20 bundled unchanged official96 px Huawei PNG with source/hash manifest; physical red logo/phone badge verified. Computer uses `desktopcomputer`/Computer/电脑 across recipients/history/remembered/hidden models. Synthetic Huawei/HONOR/Xiaomi PCs and Huawei phone rendered correctly. Huawei type 12→computer still requires SHARE; phone/pad exception was not broadened, HONOR/Xiaomi wire values were not guessed.176 Python/27 Swift, full build/signature/self-check/macOS 14 checks passed. No PC hardware or new transfer test. Evidence: `phase20/{verification,final-source-manifest}-redacted.json`.

Phase 21 installed at the user's request, preserving distributed bundle ID, Developer ID and designated requirement. Host/share extension rebuilt around phase 20 engine without development Info key.1.1.0/settings were backed up under `build/local-install-20261017/`; quitting applied a downloaded official1.1.1, which was separately backed up. Whole-bundle replacement installed local1.1.1/build 11001 at `/Applications/anDrop.app`. Host/engine each1, UDP5684, Finder extension, UI features, signature/build parity verified. Receive scope/trust/remembered peers/aliases/name/language/folder/update settings were retained;27 history records matched semantically despite JSON re-encoding. No new transfer or publication occurred. Evidence there: `build-verification-redacted.json`, `installed-redacted.json`, `running-verification-redacted.json`, `share-extension-redacted.json`.

## Photo receive compatibility (phase 22–23)

Phase 22: the user's568,811 B photo failed after approval with ValueError/0 B. Old diagnostics merged/dropped the phase, without evidence of size overflow. Without viewing private photos, a synthetic76,263 B JPEG was placed by USB for setup only, then Files→standard Share→LAN probe reproduced `unsupported batch preview`. Actual tags11=18 B,12=44,849 B,13=78 B exceeded the old11/12-only layout. Batch parsing accepted ordered, unique11/12/13, tag 13≤8 KiB, retaining UTF-8/60,000 B thumbnail/outer-frame limits and rejecting unknown/empty/oversized13. After a save, normal byte EOF could still cause failure; only frame-boundary EOF after authenticated preview ACK now removes that auxiliary channel. Partial header/payload remains failure and file DONE ACK stays mandatory.179 Python/28 Swift passed; fixed receive/preview/frame/metadata/data diagnostics exclude raw exceptions/images/names. Evidence: `phase22/reproduction-summary-redacted.json`, `jpeg-before-fix2-redacted.json`, `jpeg-after-fix-redacted.json`, `jpeg-after-eof-fix-redacted.json`. The first save-only attempt is not counted as DONE ACK success.

Complete build 11002 installed with the same official ID/Developer ID, settings/history retained, signature/self-check/macOS 14 checks passed. The installed app's actual Accept prompt yielded Downloads76,263 B, matching contents/hash/quarantine/complete and phone Sent. Evidence: `phase22/native-photo-receive-redacted.json`, `installed-fix-redacted.json`, `final-state-redacted.json`. This is synthetic-JPEG validation, not retesting the user's original photo.

Phase 23: two private photos totaling1,588,795 B failed about 9  s after approval; the report alone did not locate the cause. Two synthetic JPEG copies reproduced MTU 65,536 followed by no preview/`receive channels response deadline`, phone `CheckSendLen fail, len=89852`. Preview MTU became1 MiB, outer-frame bound includes28 B GCM, thumbnail limit approved count×60,000 B, all other checks retained. Physical preview89,852 B/tag 12 89,633 B and two files152,526 B matched bytes/hash/DONE ACK. Evidence: `phase23/{before,after-mtu,probe-integrity}-redacted.json`;181 Python/28 Swift. Complete local11003 installed after verified ZIP backup, official signature/self-check/module parity. Original private-photo receipt in the app was still unproven.

## Document classification, names and save ordering (phase 24–30)

| Phase | Change, result and boundary |
| --- | --- |
| phase 24 /11003 | PDF opened in Gallery: command 7/tag 1 sendType and tag 6 count were both fixed1. Ordinary files became type 3, tags3/6 actual count; mixed batches remain files.181 Python. Installed app already included this change by direct comparison, no extra replacement. Discovery did not respond; fixed PDF behavior unverified. `phase24/verification-redacted.json` |
| phase 25 /11004 | tag 7 previewSummary had raw first filename. SDK handling `0x1e54d4→0x1e5c94` expects extension-count JSON, e.g. `{".pdf":1}`. Count the whole batch, lowercase extensions, do not disguise unknown/missing extensions; this is not a MIME field.183 Python (Huawei84), signature/self-check/source parity. Actual type presentation awaited retest. `phase25/package-redacted.json` |
| phase 26 /11005 | Unknown type persisted. Added doubly encrypted byte command 8/tag 11 with `\|`-joined names and verified command 1/tag 8 previewOK before continuing.184 Python. Physical state showed preview ACK/DFile DONE but user saw zero files and old destination was empty. Protocol completion is not save proof. `phase26/package-redacted.json`, `phase25/preview-tests.log` |
| phase 27 /11006 | `GetTypeByCount` (`0x1884f8`) suggested single type 8/multiple3,184 Python. A107,735,062 B (102.74 MiB) PDF exceeded8 MiB before preparing/offer, so it did not test classification. Another685,593 B PDF still showed zero/unknown, disproving resolution by type 8. `phase27/package-redacted.json`, `reported-failure-redacted.json` |
| phase 28 /11007–11008 | Temporary metadata observation of Pura→Mac PDF1,302,264 B, `%PDF-1.7`, Downloads hash. Command7 order2/3/4/5/6/7/1, type 3, count1, folder0, extension JSON; command 8 name8 B/tag 12 preview37,226 B, no explicit MIME. Reverted speculative single-PDF8 to 3. Added 鸿蒙星河互联's always-sent tag 13 date_added/date_taken/detail_time with missing values -1/-1/empty, never fabricated times. Batch-count1592 initializes100, refuting a missing-tag 8/zero hypothesis.184 tests passed on rerun (old random CoAP-token0xff parsing flaked first).11008 installed without temporary observation; user still saw zero files. `phase28/native-pdf-receipt-redacted.json`, `package-redacted.json` |
| phase 29 /11009 | Phone logged `SessionOpenedEvent# in 12 status do not need session opened`; only states 6/8 register file schema. Moved preview after file connection/DFile Settings, before data header, with enforced preconditions and byte key `keys[-2]`.185 Python. State12 rejection stopped, but Mac rejected preview reply before data. `phase29/` |
| phase 30 /11010 | First reply was command 1/tag 15 avatar26,955 B (`ISHARE_ECOLOGY_SAVE_AVATER`), not previewOK. After double AEAD validation, skip only this auxiliary notice,≤64 KiB each/max4 reads; wait for tag 8 previewOK. Unknown/refusal/busy/wrong-key/no ACK remain failure.186 Python.618 B PDF and908 B DOCX physically saved under `Docs/Huawei Share`, phone SHA-256 matched Mac. Readback did not verify screen count/type/opening app. `phase30/send-state-private.json`, `synthetic-preview-redacted.json`, `synthetic-avatar-fixed-redacted.json`, `synthetic-word-redacted.json`, `receipt-redacted.json`, `package-redacted.json` |

Local installs retained old bundles and checked the same Developer ID/designated requirement, full signature, engine self-check, installed script parity and one host/engine. These are not physical proof for every format. Phase 30 identified that detailed temporary-state failures still disappeared from normal diagnostics; that gap remained.

## Pre-approval placeholder and native preview routing (phase 31–32)

The user confirmed build 11010 PDFs opened as PDFs. Saved PDF/DOCX icons were correct, but actual Word opening/editing remained untested. The pre-approval “?” document image and “1 file |374.2 KB” were generic presentation, not an unknown-format error. Adding initial command 7/tag 11 names in an independent618 B test completed transport but did not change the icon; the experiment was reverted to installed-source parity without a new installation. Evidence: `phase31/offer-name-experiment.py`, `offer-name-redacted.json`.

Older SDK HuaweiShare.hap7.0.0.205: `PreviewDialog.getBaseInfo` takes the first three previewData JSON items; `ReceiveNormalCard.isThumbnailValid` requires a nonempty array and `data:image/...;base64,`. Invalid thumbnails show83886525 `file_placeholder.svg` with the question mark. `UtdThumbnails.UNKNOWN`83886614 is a separate resource. Older Apple handler `0x1e5348` uses tag 7 extension summary,11 names,13 dates, not12. Physical UI is7.0.0.545 and was not extracted; older UI branches are not complete physical-version proof.

Phase 32 corrected the earlier inference that denied system-directory listing meant all individual reads were impossible. Normal HDC `file recv` read known paths without elevation/settings changes:

| Physical library | Bytes | SHA-256 |
| --- | ---: | --- |
| `/system/lib64/libshare_service_plugin.z.so` |1,835,304| `681c401dfe48931b8e57c0865a9f2f71a49797541c016412c3206e1d48437468` |
| `/system/lib64/libshare_service.z.so` |889,096| `5d8d04dd71916e8938c453cdad1e6c0e4f5ae92950863867ee68f48f2dbd4263` |

Physical Apple `HandlePreviewDataCommand` `0x16c134` accepts string tags2/7/10/11/13, not12/68; later `HandlePreviewRecvInfo` `0x16b5e0` only 11/13. Adding image fields to these two messages cannot deliver them; this does not rule out all image inputs in the Apple route.

Standard RecvSessionV1: `PackSendPreview` `0xb71d0` packs68, `HandleBytesDataString` `0xd1cfc` stores receiver+1504, `ProcessRecvPreview` `0xd12c4` copies to RecvPreview+64 previewData. Candidate format is `[{"thumbnail":"data:image/png;base64,..."}]`, not extension/MIME. `scripts/research/huawei_preview_dispatch.py` executes bounded real AArch64 fragments in Unicorn: all 256 initial/later Apple tags plus standard68,513 branches, and a132 B synthetic1 px PNG JSON copied intact. C++ strings are stubbed; full service/IPC/UI/authentication are not emulated.

ShareReceiver selects envelope101→Apple and100 with transType0–2→standard. Opening command 192/tag 215 is decimal transType, not file category. Standard `IShareAuthSession` opening returned module 8/CODE 4/API 2/MTU 39968; module 100/192/tag 215=0 was identified in physical logs. Capabilities234=0/215=0/213=1/211=31 returned234=15 and212 of 21 B, recorded only as tags/lengths; full capability semantics remain unknown. Protocol0/tag 16 public-key request was ignored in state 1, with static code requiring state 2. Replacing Apple's key exchange alone cannot implement this route. Additional initial negotiation did not establish state 2 and sent no names/images/data. With anDrop on5684, concurrent CoAP5685 yielded only ACKs; a separately verified opening to an explicitly known phone port is not fresh discovery.

`huawei_standard_capabilities.py` reproduces only opening/capabilities, at most two replies, with no accounts/persistent pairing/key files/previews/transfers. Evidence: `phase32/{dispatch-emulation,standard-opening-redacted,standard-knock-redacted,standard-capabilities-redacted,standard-capabilities-public-key-redacted,standard-file-session-public-key-redacted,standard-capabilities-repro-redacted,native-runtime-evidence-redacted,final-audit-redacted}.json`. A filename containing public-key does not prove sending; the attempt without `public_key_sent` sent none.513 branches, redaction, five malformed replies, syntax/diff and installed11010 source parity verified; research nc exited.

## Photo classification and restored-photo receipt (two phase 33–34 tracks)

Icon phase 33: the user's06:02 green image and06:59 question mark (both one file374.2 KB) matched the type 1→3 change. Physical `ProcessRecvPreview` at `0x16d9c0` routes3/4/8→file and1→`0x16dc70/0x16dd14` SendBean; four real-code offline branches confirmed it. Older UI sets isAllImageVideo for IOS+SendBean when previewText JSON fails. SendBean is a UI string, not wire integer1. Media without thumbnail uses83886599 `ic_file_image.svg` (green `#70df66`–`#4eba45`); ordinary files use83886525. Green therefore does not prove a real thumbnail, nor “?” a text classification.

Older `createFileShowInfo` only uses previewTextSummary/mime_type after JSON.parse/Object.values succeeds with records. Names and type information differ: receiver+1400→RecvPreview+88 allFileNameData, +1584→+112 previewInfo; serializer `0x182f14/0x182f24` names them separately. Tag13 `ParseMediaInfo` (`0x19b430→0x13592c`) builds date maps, not previewText. JSON names or initial tag 11 do not populate previewInfo. No product change at this stage.

Icon phase 34/build 11012: batches containing only JPEG/PNG/HEIC/HEIF/AVIF/WebP/GIF/BMP/TIFF use type 1. MOV/MP4/M4V/WebM and other videos are classified separately; videos/documents/mixed/unknown use type 3 and actual extension counts. Matching is case-insensitive and uses the final extension, with no content sniffing/thumbnail generation/speculative video type 2/batch splitting. File-registration/command 8 order, dates and bytes remain unchanged. Ninety Huawei tests passed. A copy of 11011 changed only the dynamically loaded Python module/build number, then self-check/same signature/designated requirement/source parity verified11012 installation. Physical icon/save retesting had not happened yet. Evidence: `phase34/`.

Receive phase 33/build 11011: a restored photo failed receive_preview while another completed nearby; corruption/restoration as cause was not established. Old batches required nonempty12 although ordinary sending produced11/13. B atch12/13 became optional/empty, retaining nonempty UTF-8 names≤1024, thumbnails60000×count, dates8192, ordering/duplicate/unknown/outer-frame and all DFile checks. Fixed-fixture criteria unchanged.188 Python passed; copied11010 changed plain module/build, then same-signature/self-check installation11011. Original-photo success unproven. Evidence: `phase33/package-redacted.json`, `python-tests.log`.

Receive phase 34/build 11013: user retry report ed9229b9 still failed; unresolved. Instead of guessing larger limits, added fixed previewIssue=`field_layout/name_size/thumbnail_size/metadata_size/repeated_preview` and previewFields containing only last authenticated command 8 tags/byte counts. Python/Swift allow at most 32 entries, tag 0–255/bytes0–1 MiB, dropping values/names/images/extra keys, with old-report compatibility.191 Python/29 Swift. Concurrent11012 was already installed; its other four modules were retained in 11013 with same signing/self-check/one host/engine. This was diagnostic instrumentation, not a resolution. `phase34/package-redacted.json`.

## Standard-route keys and dedicated icons (phase 35–36)

Phase 35,20:00–20:09 JST, used only ephemeral keys/synthetic metadata, no data/phone approval or settings/account/contact/pairing changes. `huawei_offer_classification.py` called product offer for photo1/video3/mixed3; all completed key exchange then received user_reject, unknown cause and no observed icon. Standard protocol 100/command 192 tag 193=3 triggered tag 195 `CMD_CAN_CONTINUE_CONNECT`;194 is not authentication start. This follows registration `0x10309c/0x1030a8` and `HandleAuthSendTypeCommand` `0xc67dc`.

Protocol0 tag 16 key→tag 17 key; tag 18 carries OAEP-SHA 256/MGF1-SHA 256 encrypted nonce16+temporary AES32, yielding tag 23/tag 19. GCM of 48 B tag 19 using the original nonce/temporary AES recovers32 B communication key. **Tag23=0 refuses sharing** (`0xbca3c–0xbcb14`),1 selects certificate chains,2 HiChain,3 contact mismatch. `HandleGetAesKey` `0x113d84` checks visibility and possibly recent/contact status. B efore0 was understood, one synthetic-PNG command 64 reached `Can not get preview data in: 2, try later`; tag 200 senderCancel followed about 3  s later, without ACK, state 14. This proves handler delivery, not JSON parsing/UI/save. Thereafter only keys were reproduced, every mode retaining `sharing_authorized=false`; unauthorized preview was not repeated.

Real-fragment emulation added16 standard-string and five state branches, preserving513/four classification cases/132 B copy:

| tag | Receiver field | Purpose |
| --- | --- | --- |
|65|+1472|String, not the filename list|
|68|+1504→RecvPreview+64|previewData image JSON|
|71/75|+1424→+88|allFileNameData|
|73|+1608→+112|previewInfo|
|76|+1528→+200|packageInfo|
|78|+1632→+136|previewExtra|
|80|+736→+264|Type summary|

`ParsePreviewData` `0xd3538→0x197980` parses only states 10/12 and defers1/2/14. Older UI ALL_PICTURE covers images; PICTURE_AND_VIDEO covers images/videos and even video-only, potentially sharing the green fallback. Different wording does not prove different icons.98 Huawei tests covered key/authorization separation, modes, modified GCM/nonce/key, duplicates/missing fields/bad frames. Installed11013 already matched source; not overwritten. Evidence: `phase35/*-redacted.json`, `dispatch-emulation.json`; research probes exited.

Phase 36 compared the existing anDrop RSA read-only, without borrowing another app's identity. Key alone and key+tag 22 MetaNode ID both verified communication keys but returned verifyMode0; the latter also returned tag 24 of 64 B. New `--identity-key`/`--send-node-id` reject symlinks/non-owner/permissive/nonregular/>8 KiB/non-RSA 2048 files and never create/modify keys.99 Huawei tests passed. Existing-key Apple photo offer had no accept/reject within 10  s and no cancellation ACK; no icon/receipt proof. DevEco showed an unlocked home screen but notification observation was unstable; visibility/product unchanged.

Older UI Office resources: Word83886618, Excel83886591, PowerPoint83886608, PDF83886607. These establish sending-thumbnail definitions, not automatic receive-icon choice from extension. Video overlay83886084 depends on `thumbnails[0].utd` belonging to VIDEO. `mime_type` feeds getUtdBelongsToType and must not blindly be treated as HTTP MIME; resource IDs are not UTD identifiers. previewData images, previewText types/counts and thumbnail.utd are separate.

Historical Claude read-only reviews were checked before adoption: “absolutely no other Apple route” lacked evidence; “no HiChain” incorrectly searched disassembly instead of annotated ELF strings. Physical `0x11d494/0x11d498` references HiChainVerify.cpp and `0x11d4a8/0x11d4ac` AuthDevice; after `0xbce00` an empty accountID is rejected. This proves neither PIN pairing nor same-account sufficiency; peerUserId fragments do not explain trust provisioning. Records: `phase36/claude-*.json`. No product update.

## Everyone, green photo icon and certificate trust (phase 37)

After the user confirmed Everyone visibility, the same existing anDrop key/MetaNode ID changed standard verifyMode0→1 with verified communication-key GCM. Visibility affected this refusal, but mode 1 only starts certificate verification. No preview/data was sent. `phase37/everyone-key-exchange-redacted.json`.

In the same state, a repeated photo/type 1 product-offer notification was user-confirmed to show the green image icon before approval. `everyone-photo-retry-redacted.json` separates probe results and user observation. This proves notification classification, not photo saving/contents/video/document presentation. Research nc timeout changed8  s→seconds+12 to cover10  s observation/cancellation. The second attempt wrote cancellation but obtained no ACK, with no approval/data. Fixed stop reasons and syntax checked; product/install unchanged.

`CheckCertChainValid` verifies root `0x11e6f8`, CA `0x11e704`, chain `0x11e710`, public-key certificate `0x11e72c`, then matches certificate and CCMP keys at `0x11e754`. Service ValidRootCert wrapper `0xb78dc→0x88bc0` creates an X509 store, loads three roots at `0x88bf0/0x88c04/0x88c18`, verifies input at `0x88c58`:

| ELF address | Root Subject CN |
| --- | --- |
|`0x37741`|Huawei CBG Root CA|
|`0x37436`|Huawei CBG Root CA G2|
|`0x37eb0`|Huawei CBG ECC Equipment Root CA 3|

InitCertChainMode `0xb78d0→0x89094` calls HksAttestKey at `0x891b0`. Public roots cannot issue a certificate for anDrop's key, and independent RSA satisfying this trust was not demonstrated. No self-signed/borrowed-private-key experiment. `root-store-addresses.json` records provenance. Claude's visibility/mode 1 prediction contradicted measurements and was rejected; PLT `0x19af30` is actually `DiscoverManager::GetDetectableType`, not an unknown mode selector.

Expanding SHT_RELR resolved AppleRecvSession vtable `0x1a0160`+120 (`0x1a01d8`)→`0x1745b4`, OnAuthBytesReceived. One authentication callback cannot exclude other data notifications; standard certificate conditions cannot be imposed on the Apple route already displaying pre-approval notifications using independent keys. Dispatcher `0x16c6d4` searches session+1672, comparing commandID/node at `0x16c708`. Apple `0x1711b4→0x1711d0` and lower `0x16c7c4` use tables whose construction was then unresolved. Capabilities contain four strings (`0x16c5c8/0x16c60c/0x16c614/0x16c61c`) and two booleans (`0x16c63c/0x16c65c`), not six booleans. AppleSendSession `0x1687ac/0x1689bc` at the same offset is not a receive table. Evidence: `apple-vtable-relocations.json`, `apple-bytes-target.txt`, `claude-command-map.json`.

## Receiver command registry reproduction (phase 38)

ShareReceiver::Init `0x1020c4` allocates2192 B; allocation+32 is AppleRecvSession and `0x1020f4–0x10210c` installs its known vtable, establishing constructor/class identity. `scripts/research/huawei_command_registry.py` accepts only the phase 32 SHA-256 and executes `0x102238–0x102a34` in Unicorn. C++ map/function-wrapper/destructor operations are stubbed to extract keys/handlers, not emulate service/authentication/network/UI.

Object+1736 (constructor call `0x102960`) holds seven entries. Function-wrapper vtable+48 resolves:

| wire command | Implementation | Role |
| --- | --- | --- |
|1|`0x16c6d4`|Lower control table|
|2|`0x16c530`|HandleCompetencyNegoReq|
|4|`0x16c3cc`|HandleNetworkinfoNegoReq|
|7|`0x16c128→0x16c134`|Initial preview/approval metadata|
|10|`0x16beb0`|HandleLogicalConnectionInfo|
|8|`0x16b5e0`|Filenames/dates|
|11|`0x16b4a4`|HandleCertifyInfo, OpenIdHash→session+920|

Command10 sub1/2 emits internal601/610 (`0x16bf40–0x16bfd4`);11 handles only sub1 (`0x16b518–0x16b598`), neither adding image input. Command2 sets four strings/two booleans,4 network strings. No new image/previewInfo assignment was found outside already-enumerated7/8.

Object+1664/root+1672 control map:2→`0x16c7ec` senderCancel;10→`0x16c8bc` transfer error;5→`0x16c9f8` receiver-cancel ACK;12→`0x16caa0` sender-cancelled notice;13→`0x16cb48` physical-info request;16→`0x16cd4c` authentication keep-alive. Object+1760 entries2/4/7/8/11 are post-field callbacks. Command7 completion `0x16b134` sets state 10 and emits internal11, mapped by+1360 to `0x16d758 ProcessRecvPreview`. The45 entries at+1360 are internal events, not wire command numbers.

Seven manually decoded vtables matched emulation; six controls/45 events/five completion callbacks extracted. A one-byte-modified binary was rejected before execution. Evidence: `phase38/registry-emulated.json`, `validation.json`, `claude-map.json`. Claude keys/ADR addresses matched, but classifying+1360 as level-one and+1736/+1760 as non-command maps contradicted the execution chain and was rejected. DevEco mirroring preparation failed to obtain the phone screen/noWindowsAvailable; menus closed and IDE restored. No notification/file was sent or 鸿蒙星河互联 started.

Constructor registration is now understood; dedicated icons remain unresolved. Green is the type 1 fallback, not a PDF/Office/video preview. No additional image input appeared in this constructor table, without disproving other implementations/versions/later registrations. Useful next evidence is legitimate authentication of anDrop's own key on the standard route, or a 鸿蒙星河互联→same-phone example with dedicated icons and its message structure. No speculative MIME/tag/type brute-force or product replacement followed.

## Large Mac→Huawei sends (2026-10-17)

Sending expanded from 8 MiB each/16 MiB total to 4 GiB each/16 GiB total, up to 16 files. Receiving at this stage remained8 MiB each/16 MiB total; later release limits are in [usage](usage.en.md), not inferred from history.

One-MiB reads create independent disk snapshots; workers encrypt1,422 B chunks without whole-file bytes, checking regular files/collisions/sizes/copy-time changes. Cancellation during preparation waits for copying then cleans up. Experimental sequence<16384 became wire uint32; public headers use32-bit blockSequence and64-bit file sizes. The60  s limit became stalled-write time, preserving auxiliary channels and draining ACKs during sending to avoid nc stdout deadlock; progress updates within file data.

A64 MiB socketpair verified every GCM chunk/hash,32-bit sequence,>128 ACKs, split headers and a simulated duration>60  s, with Python-tracked memory<16 MiB. A32 MiB disk snapshot stayed<8 MiB. Sparse files established early refusal above4 GiB/file or16 GiB total; pre-copy limits, preparation cancellation, snapshot independence after source changes and modified-snapshot rejection were checked.209 Python/29 Swift passed. This proves local implementation/memory behavior, not Pura64 MiB/GiB receipt; large physical content verification remains outstanding.

## Reproduction, public APIs and next work

```sh
python scripts/huawei-lan-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --private-endpoint build/huawei-research/peer-private.json
python scripts/huawei-auth-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<fresh advertised port>' --capabilities --public-key --key-challenge
python scripts/huawei-share-probe.py --seconds 15
python scripts/huawei-share-probe.py --seconds 15 --advertise
python scripts/huawei-share-probe.py --private-targets build/huawei-targets-private.json
python scripts/huawei-share-probe.py --seconds 8 \
  --connect-target '<current endpoint>' --inspect-share --notify-only
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<fresh advertised port>' --seconds 60 --network-lan --send-large-fixture \
  --output build/huawei-research/large-send-redacted.json
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<fresh advertised port>' --seconds 60 --network-lan --send-large-fixture \
  --cancel-after-chunks 64 --cancel-via-bytes \
  --output build/huawei-research/cancel-bytes-redacted.json
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<fresh advertised port>' --network-lan --send-file '<file1>' --send-file '<file2>' \
  --output build/huawei-research/batch-send.json
python scripts/huawei-receiver-discovery-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --seconds 60 --accept-files --output build/huawei-research/batch-receive.json
python3 scripts/research/huawei_standard_capabilities.py \
  --peer-ip '<current phone LAN IP>' --port '<confirmed advertised port>' \
  --output build/huawei-research/phase32/standard-capabilities-repro-redacted.json
build/huawei-research/phase32/venv/bin/python scripts/research/huawei_preview_dispatch.py \
  build/huawei-research/phase32/libshare_service_plugin.z.so \
  --output build/huawei-research/phase32/dispatch-emulation.json
```

Default BLE probes do not read/write/subscribe/pair/transfer or output names/addresses/raw payloads. `--inspect-share` reads/subscribes2B00/2B01, recording only lengths; `--notify-only` omits reads. `--serve-discovery --advertise` exposes an empty temporary GATT server and records counts/lengths. `--advertise` temporarily publishes `anDrop H Probe`, not a transfer service, stopping on exit. Explicit `--private-targets` saves endpoints0600. Emulation requires Unicorn in a research venv and matching local binaries, never product distribution.

DevEco `@hms.collaboration.harmonyShare.d.ts` knockShare/gesturesShare/dataReceive/SharableTarget.share are HarmonyOS app APIs, not a Mac interoperability SDK. Some system extensions need ACCESS_INSTANTSHARE_PRIVATE_ABILITY, not every public Share Kit API. HAP/modules.abc/resources.index remain denied; the two known libraries were normally readable. The older Share Engine codelab covers Android/Linux/Windows/EMUI and does not establish an independent HarmonyOS7/macOS SDK.

The target is anDrop↔standard Huawei Share without 鸿蒙星河互联 process/library/install requirements or an extra phone app replacing interoperability. Reuse Finder/menu/recipients/approval/progress/history/saving while separating discovery/authentication/framing/LAN/DFile. Remain on the existing LAN, without SSID/hotspot/high-speed fallback. Independently validate locked-screen BLE wake, long-term peer identity, product cancellation messages, actual Wi-Fi loss, a never-鸿蒙星河互联-installed Mac, large physical saves and dedicated icons. Protocol/discovery/authorization/disk/content/release each require their own evidence; synthetic peers, USB setup, GATT connections and key exchange do not establish complete interoperability.

Public references inherited from the investigation, not freshly web-verified during this documentation edit: [Huawei sharing with Apple](https://consumer.huawei.com/cn/support/content/zh-cn16090700/), [鸿蒙星河互联 instructions](https://consumer.huawei.com/en/support/content/en-us16107421/), [App Store](https://apps.apple.com/in/app/petal-interconnect/id6775134178?platform=vision), [older Windows codelab](https://developer.huawei.com/consumer/cn/codelab/ShareKit-Windows/), [DSoftBus](https://github.com/openharmony/communication_dsoftbus), [CoAP RFC7252](https://www.rfc-editor.org/rfc/rfc7252), [DFile reference](https://github.com/openharmony/communication_t2stack/tree/31448e0839d111ff99213c7de15aea6622e7c300), [SoftBus device types](https://github.com/openharmony/communication_dsoftbus/blob/master/interfaces/kits/lnn/lnn_device_info_struct.h), [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

Public DFile/TCP headers and implementations informed Settings/header/DATA/DONE,16 B TCP framing and opening ACKs; they were not added as a product dependency. Local reference checkout stays ignored.
