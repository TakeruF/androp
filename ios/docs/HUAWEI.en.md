# Experimental Huawei Share sending

[简体中文](HUAWEI.md) · English

0.5.0 (9) adds sending to a specified IP on the same Wi-Fi. Huawei hardware compatibility is unverified. **Huawei-to-app receipt, automatic Huawei discovery and Wi-Fi Direct are not implemented.** HUAWEI Pura 70 / HarmonyOS 7 is the planned target; hardware testing is deferred.

## Use

1. Enable Huawei Share on the recipient and select Everyone visibility for first use.
2. Find its IPv4 address in the Huawei Wi-Fi settings.
3. Expand “Huawei Share（試験）” in the main anDrop app, enter that address and choose “端末を確認”.
4. After confirmation adds the recipient, select files and that device, then approve receipt on Huawei.
5. The app waits for peer completion acknowledgment; also verify the actual saved files on Huawei.

The limit is 16 files and 64 MiB of original data. The IP is saved only after confirming the device; “登録を解除” removes it. An IP is not a trusted identity. Sending uses confirmation from the past ten seconds or confirms the same IP again; a changed discovery identifier stops sending. Reconfirm after network or address changes.

The sharing extension also checks the device registered in the main app. On iOS 26 or later use recipient selection → “準備を完了” → manually open the main app. Once started, it uses continued processing and system progress. Huawei hardware background behavior is unverified; stay in front if the OS denies background execution.

## Protocol and limits

Directed CoAP unicast obtains the peer port; negotiated ports are not hard-coded. IPs inside encrypted replies must match the explicitly selected peer. There is no broadcast, subnet scan or hotspot switching. Multicast / broadcast on physical iOS requires an additional entitlement, so automatic Huawei discovery is disabled. See [Apple's explanation](https://developer.apple.com/news/?id=0oi77447) and [local network specification](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The implementation uses the macOS app's Apple-compatible session, not a bypass of the standard session requiring Huawei certificates. Current RSA support is Security.framework's RSA-2048 / OAEP-SHA256 / MGF1-SHA256; requests for a different protected variant stop. AES-GCM controls, data and inner DFile headers are integrity-checked.

The local RSA identity stays in Keychain for continuity of this app's identity, not Huawei manufacturer or account authentication. Diagnostics exclude IPs, filenames, contents and keys. The iOS product embeds neither Python nor another app's runtime libraries.

## Local validation and reproduction

The Mac receiver reference passed acceptance, rejection, a tampered completion response and cancellation. The successful path sent seven files exceeding 20 MiB, including an empty file, Japanese original names and `manifest.json`, and verified each file plus the DONE ACK. The reference only initiates the first MetaNode notification in observed phone order, then uses unchanged authentication, decryption and file receipt.

This does not prove Huawei hardware saving, gallery registration, throughput or stability. See this repository's `scripts/huawei-*.py` and `Sources/huawei_runtime.py` for the reference implementation.

Normal Swift tests need no Python. With the repository root's macOS development Python environment prepared, run optional reference communication from `ios/`:

```sh
ANDROP_HUAWEI_REFERENCE_ROOT="$(git rev-parse --show-toplevel)" swift test --no-parallel
```

Hardware validation should record the model, HarmonyOS version, direction, count / size, diagnostic stage and peer-side saved files. Do not treat the feature as formal compatibility support before that validation.
