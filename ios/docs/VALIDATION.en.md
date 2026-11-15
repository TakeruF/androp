# iOS / iPadOS validation scope

[简体中文](VALIDATION.md) · English

Recorded 2026-11-16 JST for **0.5.0 (9), a source preview**. This page publishes models, software, results and limits only. Raw diagnostics, personal screenshots, device identifiers and local test bundles are not repository attachments.

| Scope | Result and limit |
| --- | --- |
| OPPO ↔ iPhone 16 | The user reported successful transfers in both directions; coverage does not extend to every format or model |
| Multiple-photo sharing | 0.3.1 fixed import; 0.3.2 raised the original-data limit from 16 MiB to 64 MiB. The user reported being able to select a recipient for five photos, which alone does not prove all five were delivered |
| Core tests on macOS | 59 tests passed for 0.5.0, covering import, routing, real TLS / WebSocket / HTTPS, archives, background handoff and Huawei protocol |
| Independent Huawei receiver reference | This repository's macOS receiver participated in local interoperability tests for acceptance, rejection, a tampered completion response and cancellation. Seven files exceeding 20 MiB included an empty file, Japanese original names and `manifest.json`; every file's bytes and the DONE ACK were verified |
| iPhone 16 simulator / iOS 26.5 | 66 total: 63 passed, with two hardware-only background cases and one optional Photos case without seeded test images skipped. Core tests account for 58; UI cases include the main app, sharing handoff and Huawei settings |
| iPad mini simulator / iOS 26.5 | Main app, share-to-main handoff, Huawei IP entry and removal passed. A parent accessibility identifier overriding child input identifiers was fixed |
| iPhone 16 / iOS 26.7.1 | Signed 0.5.0 build and installed version verified; final background paths, persistent Keychain identity and current visible UI remain unverified |
| Earlier background development build | A local 20 MiB TLS transfer completed in the background on iPhone 16, with real byte progress shown by the system. This does not cover every later change or OPPO / Huawei background interoperability |
| HUAWEI Pura 70 / HarmonyOS 7 | Planned hardware target. The current iOS Huawei feature has not been verified on it; hardware testing is deferred |

The reference test changes only initiation of the first MetaNode notification, then uses the unchanged macOS authentication, decryption and file receiver. It does not prove Huawei hardware saving, gallery registration, throughput or stability. Huawei receipt and automatic discovery are not implemented.

The simulator cannot run the continued-processing task; tests verify foreground fallback. Concurrent TLS tests on the same host previously timed out, followed by a successful serial run. That is not evidence of a physical-device protocol failure.

See [README](../README.en.md) for commands and scripts. Optional reference interoperability needs the macOS development Python environment and `ANDROP_HUAWEI_REFERENCE_ROOT` set to the repository root; see [Huawei](HUAWEI.en.md). Publishing source is separate from App Store, TestFlight or a formal compatibility release.
