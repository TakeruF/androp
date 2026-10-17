# Huawei Share / HarmonyOS 7 実機調査

調査日: 2026-10-17 JST。対象は接続された HUAWEI Pura 70。

## 結論

最新の承認前アイコン調査（phase38）: 写真だけをtype1へ分岐する処理はbuild11012で反映し、設置版11013にも保持。**製品のoffer()を使う通知試験で、写真の緑アイコンを利用者が実機確認した。** 動画・文書・混在は写真として宣言しない。PDF/Word/Excel/PowerPointの専用リソースと動画オーバーレイの条件は旧UIで特定したが、実機での専用表示は未解決。標準RecvSessionV1では、利用者が全員公開にするとverifyModeが0（拒否）から1（証明書確認）へ変化した。通信鍵交換成功は共有認証完了ではなく、Huaweiルートを信頼する証明書チェーンと交換公開鍵の一致を要求する。Mac互換経路の初期登録表をエミュレーションで再現し、主要7通知・制御6命令と受信確認までの経路を特定した。この表には追加のアイコン画像入力は見つからず、専用表示は未解決。phase35–38では製品コード・設置版を変更していない。

**Petalなし・既存の同一Wi-Fi LANで、Pura 70の標準Huawei ShareとanDrop本体の双方向3点転送を実機で確認した。Mac→Puraは本体の宛先選択から送信し、端末の保存内容を照合。Pura→Macは本体の受信確認を経てDownloadsへ保存し、内容・SHA-256・quarantine・履歴completeが一致した。同名の再受信も元ファイルを保持し、別名で完成した。phase18では最新の完全ビルドで空・日本語名・8 MiBの双方向保存を追試済み。独立プローブでは空ファイル・日本語名8 MiBも往復済み。phase16では、Puraの共有画面を開かない状態での探索・送信、Mac側IDの永続化による「仅分享过的设备可见」での送信、送受信途中の取消・TCP切断からの再転送を実機で確認した。Puraの長期的な相手認証は未解明で、公開リリースへの反映は行っていない。**

前段の比較試験では、ホットスポットに接続せず、既存の同一 Wi-Fi 上で Petal + Pura 70 の双方向転送を確認している。今回の追加検証は Petal プロセスなしで実施し、Petal のライブラリも読み込んでいない。

ユーザーの要件は、Wi-Fi の接続先を変更せずに共有すること。Petal の「高速传输模式」は ON だったが、説明に「开启后，每次传输都将直连华为设备 WLAN」とある。この設定を OFF にすると、先の接続待ちから進み、77 B の合成ファイルを Mac → Pura → Mac と往復させ、バイト列と SHA-256 の一致を確認できた。高速モードが以前の停止原因だったとの推定は強まったが、他の状態変化を除外した比較試験ではない。

8 MiB・日本語名の合成ファイルも Petal で送信完了を確認し、その間に Mac の既存 en0 IP → Pura の既存 wlan0 IP の TCP 接続を観測した。両端の Wi-Fi 側 IP は試験前後で不変。ホットスポット接続操作やネットワーク設定変更は行っていない。

この比較試験は基準アプリによる **同一 LAN 経路の成立証明**。後述の独自プローブでも Mac → Pura の小ファイル転送を証明したが、ルーターなしで使える AirDrop と同等の直接接続は未検証。現行 MTA/OShare にブランド名を追加するだけでは対応できず、Huawei 専用の発見・認証・LAN 接続・転送処理が必要。

## 実機と比較環境

| 項目 | 今回確認した値 |
| --- | --- |
| 端末 | HUAWEI Pura 70 / ADY-AL10 |
| 製品ソフトウェア | `7.0.0.109(SP6C00E105R5P2)` |
| 端末の更新画面 | HarmonyOS `7.0.0.109 SP6` |
| `const.ohos.fullname` | `OpenHarmony-7.0.0.105`（製品版番号とは別） |
| API | `26` |
| 共有システムアプリ | `com.huawei.hmos.instantshare`, `7.0.0.545` |
| USB デバッグ | HDC 接続成功。ADB 対象なし |
| Mac 比較アプリ | 表示名 Petal Interconnect、`com.EMUIInterconnect.app` |
| 比較アプリのバージョン | `1.0.0` / build `1005.1` |
| 比較アプリ実体 | `/Applications/EMUI Interconnect.app` |

比較アプリは既存インストールを使用。Mac の `mas info 6775134178` は `1.0.0` を返し、`mas outdated` に Petal はなかった。Web の汎用 App Store ページに見える `1.0.1` は Mac 版の更新証拠にならないため、更新は行っていない。

## 確認できた層

| 検査 | 結果 | 限界 |
| --- | --- | --- |
| HDC による端末・OS 確認 | 成功 | USB は診断・受信内容の読み戻し用。転送は Wi-Fi 上の Huawei Share |
| Petal の宛先一覧 | Pura 70 を表示 | anDrop の一覧表示ではない |
| Petal → Pura、77 B | 受信承認後、送信完了。端末テキスト表示も原文と一致 | 端末側の直接ハッシュ取得は未実施 |
| Pura → Petal、77 B | Mac の Downloads に返送・保存 | 元ファイルとバイト列および SHA-256 一致 |
| Petal → Pura、日本語名 8 MiB | Petal の送信完了表示、端末の開くアプリ選択画面 | 返送・内容ハッシュ一致は未確認 |
| 既存 LAN 経路 | en0 → wlan0 の TCP ESTABLISHED を観測、前後の両 IP 不変 | 暗号化された通信の中身は未解析 |
| FE35 広告のスキャン | 成功 | FE35 だけでは共有対応・相手の認証を証明しない |
| GATT 接続とサービス列挙 | 成功 | 後述の独立追試では 2B00 / 2B01 の通知購読も成功。暗号認証とは別 |
| Petal なしの独自広告 + スキャン | 一部成功、再試験では候補なし | 発見は未安定化。製品単独の成功ではない |
| 独立 LAN 探索 | CoAP 応答と TCP ポート取得成功 | 既知の試験端末 IP への unicast。自動探索 UI は未実装 |
| 独立 WLAN チャネル開始・能力交渉 | module 8 / 9 の応答成功 | ファイル受信承認とは別 |
| 独立 RSA 公開鍵交換・セッション鍵交渉 | RSA 応答復号、AES-GCM タグ検証、32 B の鍵取得に成功 | 相手の長期的な同一性は未証明 |
| 独立送信オファー・標準受信確認 | Pura が「anDrop LAN Probe」、1 ファイル・60 B の受信確認を表示。承認後の `user_confirm` を検証 | 60 B の固定合成ファイルのみ |
| 独立 LAN 情報交換 | command 4 → 5、command 10 の応答を検証 | SSID は空、既存 LAN IP のみ通知。ホットスポット切替なし |
| MetaNode 端末情報交換 | module 21 / inner type `0xffff0002` に PC 種別 12 を応答し、`META_DEVICE_INFO_ACK` を検証 | 後続の探索試験では PC アイコン・Mac 表記を確認 |
| 制御用 TCP チャネル | CODE 3 のポート交渉後、同じ端末 IP の別ポートに接続。module 6 / flags `0x95` / CODE 1 の暗号化 ACK を検証 | MTU 4096。ファイル受領の証明ではない |
| ファイルチャネル交渉 | module 21 / inner module 17 / CODE 1538 の正常応答、端末の転送ポート取得 | ポートは毎回変わるため再交渉が必要 |
| 独立 DFile 送信 | WLAN 設定、暗号化ファイル確認、60 B 送信、暗号化 DONE 応答に成功 | 今回追加の2回連続送信も成功。60 B固定のみ |
| 独立送信の保存内容 | 端末の Huawei Share 保存先から HDC で読み戻し、60 B・SHA-256 一致 | 標準 UI の終了通知は別途検証 |
| PC 種別宣言 | LAN 探索の `type: 12` は公開 SoftBus の `TYPE_PC_ID = 0x0C` と一致 | 標準共有先に PC アイコン・Mac 表記を確認。HarmonyOS PC の表示ではない |
| Pura → 独自 Mac 待受 | 77 Bを2回、日本語名8 MiBを1回、空ファイルを2回受信し、保存内容・暗号化DONE ACKを検証 | 明示したローカル参照ファイル1個、最大8 MiB。長期的な相手認証と標準UIの終了表示は未証明 |
| 取消と再転送 | 送信途中のsenderCancelACK、受信開始前のreceiverCancelACKをbyteチャネルで検証。各取消後の再転送も成功 | 端末の一時ファイル削除、受信データ途中の取消、任意のネットワーク切断は未検証 |
| 明示した任意・複数ファイル | 3ファイルを一括送信し端末保存内容一致。標準共有からの一括返送を参照あり/なしで各1回受信し全内容一致 | 1〜16ファイル・各8 MiB/合計16 MiB・制御メタデータ上限あり。実機の一括試験は3点、参照なし受信は明示的な試験用自動承認 |
| anDrop本体の実験用アダプター | 受信確認・拒否・承認後のステージング内容一致まで実機確認。送受信を既存イベントへ接続 | phase15で本体UIの双方向3点転送、Downloads保存、同名再受信、内容一致と履歴completeを確認。ローカル開発用ビルドで、公開リリース未反映 |
| コールド探索（phase16） | Puraの共有画面を閉じたまま、起動3.5秒でPuraを宛先に表示し、送信・読み戻し一致 | 画面消灯・ロック中はPuraが応答しなかった。BLEによる起床は未実装 |
| Mac側IDの永続化（phase16） | 一度Everyoneで受け取られた同じIDは、「仅分享过的设备可见」でも受信確認が表示され完了。再起動後も同じ | 初回はEveryoneが必要。Pura側の記憶期間・解除条件は未確認。相手（Pura）の暗号学的認証ではない |
| 取消・切断からの復帰（phase16） | 16 MiBの送受信途中の取消、TCP強制切断の後、Puraの共有サービスを再起動せずに再転送・内容一致 | 切断はMac側ncの強制終了で再現。Wi-Fi自体の切断・Pura側の離脱は未試験 |

### 合成ファイルと内容確認

- `androp-huawei-probe-20261017.txt`: 77 bytes、返送先 `~/Downloads/androp-huawei-probe-20261017.txt`。
  SHA-256（送信元・返送ファイル共通）: `a6464cd72f201b235a9e48ecdbd1c09a932b71af5992ef5a7e1039fd31e1fd2c`。
- `華為共有検証-20261017-8MiB.bin`: 8,388,608 bytes、`bytes(range(256))` の反復による合成データ。
  送信元 SHA-256: `7d212b9c884f5c77896de960ae17cc341cda43b14d6a971f34ca29ebd4badf7f`。phase11の独立受信で同じSHA-256を確認。

追試の証拠は `build/huawei-research/roundtrip-evidence.json`、`large-lan-sockets-redacted.json`、`network-final-redacted.json` に保存。大容量試験で TCP の相手ポートは 33651 / 33559 / 46713 を観測したが、固定ポート・各用途の確定には使わない。

### 診断上の注意と試験後の状態

Mac → Pura の ping と Python の UDP 5683/5684 は失敗し、後者は `EHOSTUNREACH` だった。一方、Pura → Mac の ping と Petal の LAN 転送は成功した。したがって最初の失敗を LAN 全体の不通や Huawei Share 非対応とは解釈できない。Python 経路が失敗した原因は未確定。Mac のローカルネットワーク権限は Petal / Python / anDrop で ON、Petal の位置情報も ON と確認したが、OS 権限は変更していない。

8 MiB の初回選択でファイルダイアログの行が変わり、誤って 179 B の候補診断 JSON を同じユーザーの Pura に送信した。端末のテキストビューアで内容が表示されたため、拒否操作だけで未転送と判断しない。この JSON はローカル BLE endpoint ID とスキャン属性を含むが、認証鍵・アカウント・連絡先を含まない。その後、合成ファイルだけの `send-fixtures/` に移動し、選択したファイル名と 8.4 MB 表示を検査してから再送した。

端末に試験ファイルと上記 JSON が残っている。端末のファイル管理は更新されたユーザー規約・プライバシー声明の確認で止まったため、同意せずに戻った。この時点では8 MiB の返送・ハッシュ検証は未実施だったが、phase11で独立受信して一致を確認した。端末上の試験ファイル削除は未実施。Mac の返送テストファイルも証拠として保持した。

## Petal なしの独立検証（追加追試）

この追試では Petal を起動せず、HDC は端末の状態・設定確認のみに使用した。新しい端末アプリ、証明書、アカウント認証情報は導入していない。ホットスポット作成・参加・SSID 切替を行わず、最終 TCP 接続先への経路は `en0` と確認した。

### 成功した通信

1. 標準共有パネルが開いた状態で FE35 / manufacturer `0x027D` 候補を検出。2B00 / 2B01 の通知購読が各 3 秒間成立し、自発的な通知は 0 件だった。先の read / notify timeout は認証拒否の証拠にはならない。端末の可視性と BLE endpoint が途中で変わったため、改善原因は切り分け未完了。
2. `5684/UDP` に CoAP CON POST `/device_discover` を送信。ACK と 2 件の discovery JSON（合計 756 B）を取得し、`serviceData` から TCP `33651` を得た。試験名と一時 ID のみ使用。端末の応答に含まれる名前・アドレス・ID は公開ログに残していない。
3. 当該 TCP ポートに 24 B の SoftBus 形式ヘッダーと `IShareEcologyAuthSession` の開始 JSON を送信。263 B の応答を受信した。magic `0xBABEFACE`、module `8`、flags `1`、CODE `4`、API_VERSION `2`、MTU_SIZE `39968` を確認。返信の ROUTE_TYPE は `0` だったため、これを経路判定に使っていない。
4. module `9` の能力交渉に対し、61 B の応答を受信。envelope version `1` / protocol `101`、TLV tag `3`。先頭 tag `1` の secure_version 値は空であり、比較実装の parser と同じく bit `0` と解釈した。
5. メモリー上で生成した一時 RSA-2048 公開鍵を送信し、346 B の応答を受信。TLV `6 → 2` 内の 294 B を DER SubjectPublicKeyInfo として読み、RSA-2048 公開鍵であることを確認した。
6. 相手公開鍵で暗号化した一時 challenge（16 B nonce + 32 B AES 鍵）を送信。返答を自分の一時 RSA 秘密鍵で復号し、内部の AES-GCM タグを検証した結果、32 B のセッション鍵を取得できた。使用した方式は RSA-OAEP SHA-256 / MGF1 SHA-256 と AES-256-GCM。秘密鍵・セッション鍵・公開鍵の生値は保存していない。

**この結果は、Petal の実行環境や保存済み秘密鍵を使わずに、Pura と独自コードで暗号鍵を交渉できた証拠。ファイル転送完了、ユーザー承認、信頼された相手の認証の証拠ではない。** 応答の envelope hash と、比較実装由来の HMAC 計算による公開鍵 hash は一致しなかった。端末側の hash 定義や検証条件は未解明であり、製品でこの比較を無視して信頼済みにする実装は加えていない。

### 成功しなかった／未確認の点

- 一時 GATT サーバーと合成広告を各 30 秒出した試験では、Pura の標準送信先一覧に試験 Mac は現れず、read / write / subscription は 0 件だった。LAN 受信ポートを一時広告した試験も着信 0 B。Mac の受信先としての発見は未解決。
- Python からの直接 LAN socket は `EHOSTUNREACH` で失敗した一方、macOS の `/usr/bin/nc` は応答を受信できた。TCP の `nc -s` 指定も今回の環境では応答取得に失敗した。権限や OS 設定は変更しておらず、原因の特定は保留。実機成功は native `nc` を transport としたプローブの結果であり、製品 Python エンジンの動作証明ではない。
- TCP の stdin を送信直後に閉じた初回試験は応答 0 B。stdin を維持して返信を待つことで応答を取得した。0 B を認証拒否と解釈しない。
- 受信承認、ファイルメタデータ・データチャネル、転送完了通知、双方向の内容一致は独自実装では未検証。
- Petal を未導入の Mac での試験は未実施。今回のプローブ実行時に Petal のプロセス／ライブラリは使用していないが、開発上の仕様推定にはインストール済み Petal の静的解析を用いた。

試験中は一時的に「所有人可见 (10 分钟)」を選択した。最後に設定画面を読み戻し、「仅分享过的设备可见」が selected=true に戻っていることを確認した（10 分の期限経過後）。試験用サーバー・広告・TCP プロセスは終了済み。Petal も停止を再確認した。

### 再現と証拠

```sh
# 明示した試験端末の同一 LAN アドレスだけを探索する
python scripts/huawei-lan-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --private-endpoint build/huawei-research/peer-private.json

# 上記で新しく得たポートを指定。cryptography が必要。
python scripts/huawei-auth-probe.py --peer-ip '<Pura WLAN IPv4>' \
  --port '<advertised port>' --capabilities --public-key --key-challenge

# BLE は scan の結果に現れた endpoint のみを明示指定
python scripts/huawei-share-probe.py --seconds 8 \
  --connect-target '<current endpoint>' --inspect-share --notify-only
```

プローブの `authentication_complete` と `transfer_attempted` は常に false。鍵交渉の成否は `key_challenge.rsa_response_decrypted` / `aes_gcm_tag_verified` / `session_key_bytes` で別に記録する。

非公開のローカル証拠（gitignore 対象）:

- `build/huawei-research/independent-final-lan-redacted.json`: CoAP ACK と discovery 2 件。
- `build/huawei-research/independent-everyone-notify-redacted.json`: 2 特性の通知購読。
- `build/huawei-research/independent-auth-open-held-redacted.json`: stdin 維持による TCP 開始応答。
- `build/huawei-research/independent-public-key-redacted.json`: 公開鍵交換。
- `build/huawei-research/independent-key-challenge-redacted.json`: RSA 応答復号・AES-GCM 検証成功。
- `build/huawei-research/independent-key-challenge-final-redacted.json`: 別の新規一時鍵で成功を再現。Petal 停止、Pura WLAN IP 不変、元の可視性を確認。
- `build/huawei-research/independent-lan-listener-redacted.json`: 一時受信先の着信なし。

`tests/test_huawei_probes.py` のオフライン 5 テストが成功。CoAP の情報除外と Unicode レコード、独自 varint、TCP 分割受信、過大／途切れたフレーム、不正 TLV 長を検査した。製品コードを変更していないため、アプリのビルド・配布は実施していない。

再実装の主な静的解析箇所（Petal 1.0.0 / build 1005.1、arm64 virtual address）: WLAN 開始 JSON `0x100036f48` / `0x10006292c`、TCP header `0x10009f780`、アプリ envelope `0x10008ec80`、能力要求 `0x10008c590`、能力 parser `0x1000937bc`、公開鍵 TLV `0x100093a6c`、challenge `0x100093ea8` / `0x1000940f8`、RSA OAEP `0x10004d19c`、AES-GCM `0x10004cd70`。アドレスは当該バイナリに限定される。

該当箇所の抜粋を `build/huawei-research/petal-relevant-disassembly.txt`、比較バイナリの SHA-256 と解析コマンドを `petal-static-provenance.json` に保存。大きな全体逆アセンブルの中間ファイルは抜粋保存後に削除した。

## Pura → Mac 受信側の鍵交換（phase6）

Petal を起動せず、標準の共有先から `anDrop LAN Probe` を選択し、既存 LAN 上で受信側を追試した。選択対象は既存の77 B合成ファイルのみ。ファイルの受信承認は送っていない。

- 最小の CODE 4 応答では進まなかった。PKG_NAME・SRC/DST_BUS_NAME・REQ_ID を含む応答へ修正すると、Pura から能力要求（tag 2）と RSA 2048 公開鍵要求（tag 6 / subtype 1、DER 294 B）が届いた。どの追加フィールドが必須かは未確定。
- 公開鍵返答（tag 6 / subtype 2）の後は、8秒以内に次フレームを受信できなかった。ネイティブ応答と同じ能力フラグ TRUE / TRUE、フラグ省略の両方で再現。原因は未特定であり、RSA チャレンジや送信オファーの実機受信は未達。
- `scripts/huawei-receive-probe.py` に後続の一時鍵交換・AES-GCM オファー復号・明示的拒否を追加。これは `--inspect-offer` 指定時だけ動作し、ファイルデータは承認・保存しない。既存 LAN の指定端末と TCP 接続元が一致しない場合は鍵交換を開始しない。接続元 IP の一致は暗号学的な端末本人確認ではない。
- 合成 peer によるオフライン検証では、RSA/AES-GCM 鍵交換からオファー復号・暗号化した拒否応答まで通過した。誤ったセッション名は返信前に拒否。全22テスト通過。このテストは Pura との相互運用成功を意味しない。

証拠は `build/huawei-research/phase6-receive-auth{2,3,4}-redacted.json`。今回の変更を anDrop 本体へ統合する前に、公開鍵返答後の停止原因を解消し、実機でのオファー復号、受信承認、DFile 受信、内容一致を順に証明する。

## 公開鍵応答後の停止原因の切り分け（phase7）

Pura の hilog に `ShareService/SessionManagerProtocolV2.cpp:260` の `HandleGetRsaPublicKeyResponse# hash code is not same.` を確認した。公開鍵応答を端末側が受信し、ハッシュ照合で拒否していることが分かった。ただし、比較されるハッシュの入力・表現・対象フィールドはまだ特定できていない。

追試はいずれも同一 LAN・Petal 停止・77 B合成ファイルの選択で実施し、公開鍵応答後にタイムアウトした。

1. 能力応答の secure version を1（MGF1 SHA-1）に変更しても進まなかった。コードは元の version 0へ戻した。
2. 広告前に一時 RSA 鍵を生成し、広告 ID と接続応答 ID をその鍵の比較実装由来 HMAC から揃えたが、同じ停止点だった。
3. さらに広告の `deviceHash` に同じ鍵から算出した16桁のハッシュを設定しても進まなかった。

phase7時点のプローブは2・3の変更を保持していたが、互換性を証明した形式ではなかった（phase9で訂正）。Pura が返す公開鍵と envelope hash の対応も、DER/PEM/Base64 の SHA-256・SHA-1・MD5、先頭16 Bを鍵とする HMAC、一部のバイト順変換では一致しなかった。これだけでハッシュ定義を断定しない。

端末の `/system/lib64` と関連候補ディレクトリは通常の HDC シェルから列挙できず、該当ライブラリは取得していない。端末設定や権限の変更は行っていない。次は ProtocolV2 のハッシュ検証仕様、または公開鍵に対応する正しい discovery ID / envelope hash の生成条件を解明する必要がある。

証拠: `phase7-version1-redacted.json`、`phase7-consistent-identity-redacted.json`、`phase7-advertised-hash-redacted.json`、`phase7-phone-diagnostics-redacted.json`（すべて `build/huawei-research/`）。公開鍵応答後の RSA チャレンジ、送信オファー、逆方向ファイル受信は依然未確認。オフラインテスト23件通過。

## 受信側ハッシュ照合の追加切り分け（phase8）

Petal を起動せず、既存 en0 LAN 上で Pura の公開鍵応答までを5つの新規接続で問い合わせた。受信オファー・ファイルデータは送信せず、端末の設定・共有画面も変更していない。

- 連続3接続では DER 公開鍵（294 B）、応答 envelope の16文字、opening の6文字の識別値がそれぞれ同一だった。少なくとも今回の短時間の接続間では鍵・識別値の更新は起きていない。
- 同じ接続内の capability と public-key 応答で envelope の値は一致した。こちらが要求に付けた値の単純なエコーではなかった。
- SPKI DER、PKCS#1 DER、SPKI PEM、RSA modulus の big/little endian、それぞれの Base64・大小文字 hex を入力として、SHA-256 / SHA-1 / MD5 / SHA-512 / 先頭16 Bを鍵にしたHMAC-SHA256を比較。digest の1/2/4/8 B単位の反転と全hex位置を検査したが、envelope と opening のどちらにも一致はなかった。これは限定した候補の除外であり、公開鍵との関係がないという証明ではない。
- Petal の静的処理を再確認: `0x10004c744` は先頭16 Bを鍵にしたHMAC-SHA256、`0x10004c8c4` → `0x10004ca04` はSPKI DER出力。`0x10005dc08` の mode=1 の文字表は実際に `0123456789ABCDEF` で、大文字表記の解釈は合っている。
- Petal の `ParsePubKeyHandShake` (`0x100093c3c`) は公開鍵のimportと追加フィールド処理を行う。この関数内には公開鍵hashを生成・照合する呼出しは見つからなかった。**Petal側のこの関数と、Pura側でエラーを出す `SessionManagerProtocolV2::HandleGetRsaPublicKeyResponse` を同一の検証仕様として扱えない。** 他の場所での照合の有無は未確定。

比較時の公開鍵・識別値はメモリ内だけで扱い、結果にはサイズ・一致判定・候補名だけを記録した。証拠は `build/huawei-research/phase8-hash-analysis-redacted.json`、`phase8-stability-redacted.json`、`phase8-echo-redacted.json`。再実行用の限定調査ヘルパーは同ディレクトリの `phase8-hash-analysis.py`（ignored、製品コードではない）。

phase8終了時点ではハッシュ不一致の修正には未到達で、受信プローブの広告・鍵交換アルゴリズムは変更していなかった。次はPuraが広告上のどの識別値を保持し、公開鍵応答のどの値と照合するかを示す証拠が必要。単純なハッシュ候補の追加だけで仕様確定とはしない。逆方向の受信・本体統合は引き続き未完了。

## Pura → 独立プローブの鍵交換成功（phase9）

**新しい一時RSA鍵を使う2接続で、PuraからのRSA challenge、32 Bセッション鍵の返答、AES-GCMで保護された送信オファーの復号・タグ検証に成功した。** いずれも暗号化 `user_reject` を返して終了している。これは鍵交換とオファーの整合性の証明であり、長期的な相手認証・受信承認・ファイル保存の成功ではない。

### 原因と修正

Petal形式から流用した短縮識別値は、HMAC先頭6 Bをlittle-endianの16 bit単位で文字列化していた。HarmonyOS ProtocolV2側の照合には、同じ6 Bを**バイト順のまま12桁hex**にした識別値が必要だった。

```
digest = HMAC_SHA256(key=public_der[:16], message=public_der)
protocol_v2_identity = digest[:6].hex().upper()
```

通常順の識別値を広告 `deviceId.UDID` と接続応答 `DEVICE_ID` / `PEER_NETWORK_ID` に使用する。接続応答では小文字を使うが、静的コードの比較は `strcasecmp` である。envelope の16文字は引き続きdigest先頭8 Bの大文字hex。接続応答の `ROUTE_TYPE` は比較実装と同じ2だが、実際の通信は既存en0 LANで行い、ネットワーク切替は行っていない。

`auth.protocol_v2_identity()` と受信プローブへ修正を反映。byte順の回帰テスト、送信公開鍵とopening ACKの識別値の対応テストを含め、オフライン24テスト成功。Mac → Puraで既に成功していた送信側の識別値生成は変更していない。

### 静的解析の新しい根拠

実機のシステム領域へ権限変更する代わりに、既存の公式SDKエミュレーターイメージ
`~/Library/Huawei/Sdk/system-image/HarmonyOS-7.0.0-B1/phone_all_arm/system.img`
を `debugfs` の読み取り専用dumpで調べた。エミュレーターの起動・イメージのマウントや変更は不要だった。

- `/system/lib64/libshare_service.z.so`: `Util::GetHashCode` (`0x9213c`) が公開鍵先頭16 Bを鍵とするHMAC-SHA256を実行し、bool=trueでは先頭6 Bを返す。
- `/system/lib64/libshare_service_plugin.z.so`: `0x13c1d0` の公開鍵応答処理が上記関数にtrueを渡し、`0x20aca0` のbyteごとのhex化を経て、`0x13c284` で保持された相手識別値と `strcasecmp` する。エラー文は実機で観測した `hash code is not same.` と同じ。エミュレーター版のログ行番号は207、実機版は260であり、同一バイナリとは扱わない。
- 抽出物と逆アセンブルは `build/huawei-research/hmos7-*` に保管し、製品にリンク・同梱していない。出所・サイズ・SHA-256は `phase9-static-provenance.json`。

### 広告フィールドの訂正と対照試験

公開SoftBusの `nstackx_device.c` は広告 `deviceHash` を `hwAccountHashVal` へ渡し、`nstackx_device_local.c` はuint64を10進文字列化する。実機の広告も17桁の10進文字列だった。公開鍵ハッシュをここへ入れたphase7の推定を撤回し、アカウント識別情報を持たないプローブでは空文字へ戻した。実機の値はコピー・保存していない。

Pura自身の広告UDIDは64文字でopeningの6文字とは別だった。また、Pura自身のopening識別値はenvelope先頭6文字と一致したが、それを模した6文字ACKでは改善しなかった。PetalのACKフィールド（小文字・PEER_NETWORK_ID・ROUTE_TYPE）だけを合わせても改善しなかった。その後、12桁の識別値を通常byte順に変更して初めて鍵交換が通過した。

### 実機結果と残る課題

- `phase9-hmos-hash-redacted.json`: RSA challenge受信・セッション鍵送信・暗号化オファー検証成功、拒否で終了。
- `phase9-hmos-hash-repeat-redacted.json`: TCP開始要求なし。表示中の共有画面からの再試行では再現できなかったため、連続成功とは数えない。
- ファイル管理で既存77 B合成ファイルを選び直し、共有画面を新規に開いた `phase9-hmos-hash-repeat2-redacted.json` では再び鍵交換・オファー検証成功。count=1 / size=77は一致。
- 受信オファーのfield7は10 Bで、固定ファイル名（32 B）とは一致しなかった。送信実装と同じ意味のファイル名フィールドだと決めつけない。`expected_synthetic_offer=false` を保持し、どのオファーも受信承認していない。

次はオファーのフィールド定義、後続の制御・DFile受信を実装し、対象ファイル名・サイズを検査して77 Bだけを受信、内容一致まで確認する。今の段階でanDrop本体の対応済み表示は追加しない。発見の再試行・古い候補の残存も別の安定性課題として残る。

## Pura → 独立プローブのファイル受信成功（phase10）

2026-10-17。`--receive-fixture` と `scripts/huawei-receive-channels.py` を追加した。Pura のファイル管理から既存の `androp-huawei-probe-20261017.txt`（77 B）だけを選び、標準 Huawei Share の `anDrop LAN Probe` に送信した。Petal の起動・ライブラリ読み込み、端末への追加アプリ、ホットスポット接続は行っていない。

受信に成功した経路:

1. RSA/AES鍵交換と暗号化オファー検証後、明示した試験モードで count=1 / size=77 を承認。プレビューとDFileヘッダーでファイル名を改めて検証する。
2. コマンド4→5、10の既存LAN情報交換、PCメタ情報・ACKの交換。
3. 制御用TCPとファイル用TCPを別々に待ち受け、接続元が指定PuraのIPと一致することを検証。Puraのbyte開始要求はflags `0x90`、応答は `0x91`。応答に `DEVICE_ID`、`MTU_SIZE`、`PKG_NAME`、`AUTH_STATE` が必要だった。
4. byteチャネルは開始時の24 Bヘッダーから16 BのSoftBusデータヘッダーへ移行する。3,599 Bのプレビューはbyte鍵のAES-GCM内に、制御鍵で暗号化された別のenvelopeを持つ。二重の整合性検証後、コマンド8のfield11が固定ファイル名、field12が3,503 Bであることを確認した。field12の内容は保存・表示しない。
5. byteチャネルに暗号化した `command 1 / field 8 = previewOK` を返すと、DFileのファイルヘッダーとデータが到着した。byte/control/fileを並行して読む必要があり、DFileだけを待つ初期実装はここで停止していた。
6. DFile type 1の名前・件数・77 Bを検証し、type 2のACKを送信。type 4のAES-GCM、ファイルID・シーケンス・transaction・既知の全内容を検証して、新規ファイルに排他的に保存。`fsync`後に読み戻して一致を確認した。type 6 DONEを返し、type 7の暗号化DONE ACKを検証した。

`phase10-receive12-redacted.json` と `phase10-receive13-redacted.json` の両方で `file_received`、`saved_content_verified`、`dfile_done_ack_verified` が true。保存先は各JSONと同じbasenameの `.received.txt`。2回とも77 B、SHA-256は `a6464cd72f201b235a9e48ecdbd1c09a932b71af5992ef5a7e1039fd31e1fd2c` で、元の合成ファイルと一致した。2回目は共有アプリの強制再起動を挟まず、新しく共有画面を開いて再現した。標準UIの「成功」表示は捕捉できていないため、成功根拠は保存内容と暗号化プロトコル完了応答に限定する。

途中の失敗と回復:

- 初回のbyte接続は応答フラグと必須JSON項目が不足。公開SoftBus実装と端末エラーを照合して修正した。
- 失敗試行の後、端末ログに `CheckParamAfterPeerDevice: unexpected start verify again while already auth passed` が現れ、メタ接続が閉じられた。共有可視性を一度「不可见」にして元へ戻しても回復せず、共有アプリ `com.huawei.hmos.instantshare` の再起動後に復旧した。OS・Wi-Fi・Bluetoothは再起動していない。
- 自分のメタ情報をコマンド10直後に先行送信する処理をやめ、端末のメタ情報を待って返すよう変更した。この変更とアプリ再起動の効果は独立に分離できていない。失敗後の再接続・相手側状態の解放は製品化前の確認項目。
- 失敗時のcancel送信とnc終了処理でBrokenPipeが元の原因を隠さないよう修正した。

今回の受信処理は固定77 B専用で、任意の遠隔パスを保存先に使わない。保存先が既に存在する場合は開始前に拒否する。既定の `--inspect-offer` は引き続き拒否で終了する。接続先IPの一致と暗号化通信の成立は、信頼済みユーザー・アカウントの認証を意味しない。

オフラインテスト29件成功。受信内容改変、AEAD改変、ヘッダーサイズ・名前・件数、プレビューの重複field、byteフレームの分割・長さ上限、保存→DONE ACKまでの受信を検証した。公開の16 Bフレーム定義は [OpenHarmony trans_tcp_process_data.h](https://github.com/openharmony/communication_dsoftbus/blob/master/core/transmission/common/include/trans_tcp_process_data.h)、開始応答の必須項目は同リポジトリの `softbus_message_open_channel.c` に照合した。アプリ固有のプレビュー応答はローカル比較バイナリの静的解析（`0x10009260c`、`0x10009b3f8`）を手掛かりにし、実機で確認した。

終了時の設定・通信経路は `phase10-final-state-redacted.json` に記録。次は固定ファイル制限を一般化する前に、終了・拒否・取消・再接続の状態遷移と、空ファイル・日本語名・8 MiBの検証を実装し、その後 anDrop の受信確認・Downloads 保存・履歴へ統合する。

## 空ファイル・日本語名8 MiB・キャンセル後の再接続（phase11）

2026-10-17。Petalを停止したまま、既存LANで次の実機試験を行った。USB/HDCは操作と保存内容の読み戻しに使用し、共有データはHuawei ShareのTCP接続で転送した。

| 試験 | 実機結果 | 証拠（`build/huawei-research/`） |
| --- | --- | --- |
| Pura → Mac、日本語名8 MiB | `華為共有検証-20261017-8MiB.bin`、8,388,608 B。5,900個の暗号化DATAチャンクを検証・結合し、保存後のSHA-256が元ファイルと一致。暗号化DONE ACKも検証 | `phase11-large1-redacted.json` と同名の `.received.txt` |
| Mac → Pura、空ファイル | `androp-empty-131705.txt`、0 B。ヘッダー確認後、DATAフレームなしで暗号化DONEを受信してACK。端末の `Docs/Huawei Share/` からHDCで読み戻して0 Bを確認 | `phase11-empty-send2-redacted.json`、`phase11-empty-phone-readback.txt` |
| Pura → Mac、同じ空ファイル | 標準ファイル管理から共有。DATAフレームなしで0 Bを保存し、暗号化DONE ACKを検証 | `phase11-empty-receive1-redacted.json` |
| プレビュー受信直後のキャンセル | 名前を検証した後、previewOKを返す前に `command 1 / field 4 = receiverCancel` を制御チャネルへ送信。保存ファイルなし。3秒の確認中に暗号化 `field 5 = receiverCancelACK` は取得できず | `phase11-cancel1-redacted.json` |
| キャンセル試行直後の再共有 | 端末の共有サービスを強制再起動せず、同じ空ファイルを再受信。保存内容・DONE ACKを検証 | `phase11-reconnect1-redacted.json` |

大容量受信はDATAのファイルID・連続シーケンス・transaction・AES-GCMタグを各チャンクで検証する。開始flag 0、中間1、終了3をサイズと照合し、全内容のSHA-256がローカル参照と一致した後に排他的に新規保存する。途中データは保存先へ公開しない。メモリー使用を最大8 MiBに制限し、ログには全5,900フレームを列挙せず件数を集計する。公開のフレーム定義は [OpenHarmony nstackx_dfile_frame.h](https://github.com/openharmony/communication_t2stack/blob/master/nstackx_core/dfile/include/nstackx_dfile_frame.h) と照合した。

受信の `--fixture-source PATH` はローカル参照ファイルのbasename・サイズ・SHA-256を固定する検証モードで、任意の受信ファイルを保存する製品機能ではない。空ファイル送信には `--send-empty-fixture` を追加した。空ファイルでもヘッダーACK前のDONEを完了と扱わないようにした。

空ファイルの最初の送信は「仅分享过的设备可见」で `user_reject`。一時的に「所有人可见 (10 分钟)」にすると次の送信で `user_confirm` が返り、受信・保存が成立した。この変化をアカウント認証や恒久的な信頼登録の証拠にはしない。終了時に可視性を「仅分享过的设备可见」へ戻し、selected=trueを読み戻した。

キャンセル文字列のfieldは比較バイナリの静的解析に基づき修正した（receiverCancel=4、receiverCancelACK=5）。今回の確認は**キャンセル要求と接続終了の後に再共有できたこと**であり、相手がキャンセルを処理した証明ではない。ACKを受け取るチャネル、データ送信中の取消、途中切断からの復帰は残る確認項目。

オフラインテスト36件成功。空ファイルの送受信、多チャンク・日本語名、順序/flag/上限/ハッシュ不一致、途中切断、既存保存先の上書き拒否、キャンセルACKのfield違い・暗号改変を含む。最終のハッシュ再比較、可視性、経路、プロセス確認は `phase11-final-state-redacted.json` に記録した。両端のWi-Fi IPは不変で、経路はen0、Petal・試験用ncは0プロセス。試験ファイルは証拠として保持した。

## 日本語名8 MiB送信と取消ACKの実証（phase12）

2026-10-17。独立送信プローブに `--send-large-fixture` を追加し、固定合成データ `bytes(range(256)) * 32768` を日本語名 `華為共有検証-独立-HHMMSS-8MiB.bin` で送った。任意のローカルファイルを送るオプションではなく、名前・8 MiB・既知のSHA-256を送信前に検証する。ホットスポット接続や端末アプリ追加は行っていない。

| 試験 | 実機結果 | 証拠（`build/huawei-research/`） |
| --- | --- | --- |
| Mac → Pura、日本語名8 MiB | 5,900個のDATAフレームを送信し、暗号化DONEを検証してACK。端末保存先をHDCで読み戻し、8,388,608 B・SHA-256一致 | `phase12-large-send1-redacted.json`、`phase12-large-send1-readback-redacted.json` |
| 初期制御チャネルで送信取消 | 64チャンク・91,008 Bを送信キューへ渡した後にsenderCancel。専用ACKは取得できなかった。直後の8 MiB再送・保存内容一致は成功 | `phase12-cancel1-redacted.json`、`phase12-retry1-redacted.json` とreadback記録 |
| byteチャネルで送信途中の取消 | 同じ64チャンクで中断し、二重に暗号化した `command 1 / field 2 = senderCancel` を送信。`field 3 = senderCancelACK` を二重のAES-GCM検証後に確認 | `phase12-cancel-bytes2-redacted.json` |
| ACK確認後の8 MiB再送 | サービスの強制再起動なしで全5,900チャンク送信・DONE成立。端末保存内容を読み戻して元データと一致 | `phase12-retry2-redacted.json`、`phase12-retry2-readback-redacted.json` |
| Pura → Mac、受信開始前の取消 | 空ファイルのプレビューを検証した後、previewOKを返す前にbyteチャネルへ `field 4 = receiverCancel`。`field 5 = receiverCancelACK` を検証。Mac保存ファイルなし | `phase12-receiver-cancel-redacted.json` |
| 受信取消後の再共有 | サービスの強制再起動なしで同じ空ファイルを再受信し、0 Bの保存・暗号化DONE ACKを検証 | `phase12-receiver-retry-redacted.json` |

送信途中の取消ACKより先に、byteチャネルで `command 1 / field 15` の26,955 Bの通知が届いた。最初の応答だけを見る試行ではACKを見逃したため、無関係な制御通知を読み飛ばし、時間・件数を制限して専用ACKまで待つよう修正した。field 15の内容は意味未解明で、保存せず構造と長さのみ記録した。初期制御チャネルへの取消要求と、接続済みbyteチャネルへの取消を区別する必要がある。phase11の未確認だった受信側取消ACKも、この経路変更で確認できた。

送信DATAは1チャンク最大1,422 B、全フレーム最大1,472 B。UTF-8名長、連続sequence、開始0/中間1/終了3、暗号化内部のfile ID・sequence・transactionを受信側と照合した。送信pipeはnonblockingで期限付きにし、データが残っている間にDONEを完了と扱わない。64チャンクの取消試験で91,008 Bは送信キューへ渡した量であり、端末が保存した途中バイト数ではない。取消したファイルの最終保存先は読み戻せなかったが、内部一時ファイルの削除を証明するものではない。

送信元と3回の端末読み戻しのSHA-256はすべて `7d212b9c884f5c77896de960ae17cc341cda43b14d6a971f34ca29ebd4badf7f`。実機試験中にPetalを起動していない。受信可視性は一時的に「所有人可见 (10 分钟)」にし、終了時に元の「仅分享过的设备可见」へ戻してselected=trueを確認した。両端のWi-Fi IPは不変、経路はen0、Petal・試験用ncは0プロセス。最終確認は `phase12-final-state-redacted.json` に記録した。

オフラインテスト40件成功。追加検証は全5,900チャンクの復号・再結合・サイズ/flag/UTF-8ヘッダー、取消位置以降と最終フレームを送らないこと、合成データ改変をネットワーク書き込み前に拒否すること、取消ACKのfield・内側/外側AEAD改変・先行通知の処理。公開のDATA flag定義は [OpenHarmony nstackx_dfile_frame.h](https://github.com/openharmony/communication_t2stack/blob/master/nstackx_core/dfile/include/nstackx_dfile_frame.h) と照合し、byteチャネルの取消経路は上記の実機応答で検証した。

再現例（接続先は明示した同一LANの試験端末のみ）:

```sh
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' --port '<fresh discovery port>' \
  --seconds 60 --network-lan --send-large-fixture --output build/huawei-research/large-send-redacted.json
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' --port '<fresh discovery port>' \
  --seconds 60 --network-lan --send-large-fixture --cancel-after-chunks 64 --cancel-via-bytes \
  --output build/huawei-research/cancel-bytes-redacted.json
```

残る範囲は任意・複数ファイル、受信データ途中の取消、転送中のネットワーク切断、標準UIの終了表示、相手識別の検証条件、およびanDrop本体への統合。今回の結果だけで製品のHuawei対応済みとはしない。

## 任意ファイル指定・3ファイル一括送受信（phase13）

2026-10-17。`scripts/huawei-file-batch.py` を追加し、固定の内容・固定ファイル名への依存を外した。実機では新しく生成したテストデータだけを使用し、Petalを起動せず、同じWi-Fi LAN上で試験した。

| ファイル | サイズ | 内容 |
| --- | --- | --- |
| `androp13-日本語メモ.txt` | 81 B | 日本語・中国語・英語を含む合成テキスト |
| `androp13-empty.txt` | 0 B | 空ファイル |
| `androp13-random.bin` | 1,048,593 B | この試験で生成したランダムバイナリ。以前の固定パターンとは異なる |

結果:

- `--send-file PATH` を3回指定し、1回の共有としてMac → Puraへ送信。オファーの件数3/合計1,048,674 B、DFileのID 1〜3を通知し、全IDの暗号化DONEを確認してACK。端末の `Docs/Huawei Share/` から3点をHDCで読み戻し、すべて元データと一致した。証拠: `phase13-batch-send1-redacted.json`、`phase13-send-readback-redacted.json`。
- 標準ファイル管理で `androp13-` を検索し、検索結果がこの3点だけであること、3点すべての選択を確認してHuawei Shareへ返送。`--reference-file PATH` による事前照合モードでは、到着したIDの順序が送信時と異なっていても、名前・サイズで参照と対応させて受信。3点の保存・内容一致・暗号化DONE ACKを確認した。証拠: `phase13-batch-receive2-redacted.json`、同名の `.received/`。
- 続いて `--accept-files` を明示し、**受信プローブにはローカル参照の名前・内容・ハッシュを渡さず**同じ3点を再受信した。受信時は件数/合計サイズ/各ファイルのメタデータ/各チャンクの暗号化整合性を検証し、保存後の読み戻しハッシュを確認。その後、別の比較処理で元ファイルと名前集合・全内容・SHA-256が一致することを検証した。証拠: `phase13-unreferenced-receive-redacted.json`、同名の `.received/`、`phase13-receive-readback-redacted.json`。ログの `reference_content_verified=false` は事前参照を使っていないことを表し、事後比較は別記録に保持した。

返送の初回はプレビュー前で停止した。端末ログにSendBytes失敗があり、受信byteチャネルの応答MTUを4,096から65,536へ変更すると成功した。受信したプレビューは二重復号後10,418 B（field11=67 B、field12=10,287 B）で、以前の4 KB上限を超えていた。プレビューのfield12は保存せず、長さと構造だけを記録する。3ファイルのデータは739チャンク、ヘッダー1個、暗号化DONE ACK1個だった。初回の失敗ログは `phase13-batch-receive1-redacted.json` として保持した。

実装上の境界:

- 送信は明示した通常ファイルのみ。シンボリックリンク・ディレクトリを拒否し、読み取り中のサイズ/mtime変化を検出する。読み取ったスナップショットを送信し、入力ファイルは変更しない。
- 件数1〜16、各ファイル最大8 MiB、合計最大16 MiB。ファイル名はUTF-8で1〜255 B。パス区切り、NUL、制御文字、`.`/`..`、末尾の空白/ピリオド、コロンを拒否する。Unicode正規化と大文字小文字を考慮して同名衝突も拒否する。プレビューの名前要約は1,024 B、opaque部分は60,000 B、受信byteフレームは65,536 Bまで。これらを超える場合は拒否する。
- ヘッダーの複数フレームへの分割、ファイルごとのsequence/開始・中間・終端flag、ID別のヘッダーACKとDONEを扱う。全ファイルの送信前に到着したDONEで全体を完了にしない。受信はオファーとヘッダーの件数・合計サイズが一致することも確認する。
- 受信先はログ名に対応する新しい `.received/` ディレクトリ。全内容を受け取り検証してから排他的に作成し、既存ディレクトリやファイルを上書きしない。遠隔パスをそのまま解釈しない。ディスク書き込み途中の失敗ではディレクトリに一部の検証済みファイルが残り得るため、バッチ全体の原子的保存は未実装。
- `--accept-files` は、明示したLAN端末からの1回の転送だけを試験用に自動承認する。既定モードは引き続き拒否で終了する。製品の受信承認UIや、相手のアカウント・恒久的な信頼認証の代替ではない。受信したファイルの自動起動はしない。

47件のオフラインテストが成功。複数ファイルの送信→復号受信、部分DONE、ID順序、空ファイル、UTF-8名、長いヘッダーの分割、パス/同名衝突/上限、未知IDや不正ヘッダー、内容改変、既存保存先保護、参照なし受信のサイズ整合性、10 KBのプレビューを含む。DFileの繰り返しFileInfoUnitとID配列は [OpenHarmony nstackx_dfile_frame.c](https://github.com/openharmony/communication_t2stack/blob/master/nstackx_core/dfile/core/nstackx_dfile_frame.c) を照合し、今回の実機送受信で検証した。

```sh
# ファイルは明示したものだけを送信。--send-file は複数回指定可能。
python scripts/huawei-transfer-probe.py --peer-ip '<Pura WLAN IPv4>' --port '<fresh discovery port>' \
  --network-lan --send-file '<file1>' --send-file '<file2>' --output build/huawei-research/batch-send.json
# 元ファイルなしで、指定端末からの1回の受信を明示的に承認する試験モード。
python scripts/huawei-receiver-discovery-probe.py --peer-ip '<Pura WLAN IPv4>' --seconds 60 \
  --accept-files --output build/huawei-research/batch-receive.json
```

試験後は公開範囲を「仅分享过的设备可见」に戻してselected=trueを確認した。両端のWi-Fi IPは不変、経路はen0、Petal・試験用ncは0プロセス。`phase13-final-state-redacted.json` に確認結果を保存した。USB/HDCは操作と保存後の比較に使用し、実際の共有は既存LANのHuawei Share。試験ファイルは証拠として保持する。

次はanDrop本体に、Huawei用の宛先/受信イベントと利用者の承認・Downloads保存・進捗/履歴を接続する段階。プローブで使用しているnc transport、発見の安定性、相手識別、ネットワーク切断時の回復は引き続き製品化前の確認項目。

## anDrop本体への実験用LANアダプター接続（phase14）

2026-10-17。`Sources/huawei_runtime.py`、`Sources/HuaweiLANDiscovery.swift` を追加し、従来の互传とHuawei Shareを同じ宛先・受信確認・進捗・履歴イベントへ接続した。実機試験は設定を分離した開発用bundle（`org.androp.mac.huawei-dev` / `org.androp.mac.huawei-qa`）で実施し、インストール済みanDropの受信範囲・信頼リストは変更していない。

| 検証 | 今回の結果 |
| --- | --- |
| LAN探索・PC宛先表示 | Puraの標準Huawei ShareにMac名のPC宛先を表示。Petal停止、ホットスポット切替なし |
| 本体の受信確認 | Puraから前段の合成3点セットを選択し、anDrop自身の「3个文件／接收・拒绝」ダイアログを確認 |
| 拒否 | アプリの「拒绝」を操作。履歴イベントがdeclinedとなり、Downloadsに3点とも存在しないことを確認。`phase14-decline-evidence-redacted.json` |
| 承認と内容受信 | ダイアログの「接收」を操作。暗号化されたバッチを受信し、ステージングの3点の名前集合・全内容・SHA-256が元データと一致。`phase14-staging-recovery-redacted.json` |
| 最終保存 | 最初のhard-link配置が`linkat`で待機する状態を観測。許可不足と断定していない。Darwinの`renamex_np(RENAME_EXCL)`で完成ファイルを上書きせず移動する処理へ変更し、衝突・quarantine維持・失敗時rollbackの単体テストが成功。変更後の実機保存は未確認 |
| アプリからの送信 | 既存の宛先選択・送信コマンドをHuawei workerへ接続。事前検証と自動テストは成功。本体UIからの実機送信は未確認 |
| UI操作の停止要因 | anDrop以外のFinderも操作ツールが`cgWindowNotFound`で取得できない状態になった。Macのロック／画面セッションの可能性があり、利用者に確認を依頼。承認や保存完了を自動で代行して証明した扱いにはしていない |

`phase14-app-receive1-redacted.json` は初回の保存待機時点の記録で、completeではない。Downloadsに完成ファイルは未確認。ステージングの一致を、保存完了やDFile DONE ACK完了の証拠にはしない。

実装の接続点:

- Native hostのUDPソケットが、en0の同一サブネットから届いた1個のデータグラムとカーネル送信元をengineへ渡す。LAN探索と転送にSSID変更・AP認証情報・ホットスポットへのフォールバックはない。
- CoAPのバージョン・トークン長・option境界・resourceを解析する。HarmonyOSのUri-Host付き／Content-Format省略、LANブロードキャスト宛先、JSON末尾の単一NUL、mode 0と能力bitmaskを扱う。Uri-Hostは接続先には使わず、通知IPとカーネル送信元を一致させる。重複JSON field、曖昧なport、余分なデータ、LAN外の通知は拒否する。CoAP option定義は [RFC 7252](https://www.rfc-editor.org/rfc/rfc7252) と照合した。
- 通知を10秒で失効させ、更新されたportを同じ発見IDへ反映する。自動受信の永続的な信頼にはしない。受信TCPの接続元も、直近の探索端末とカーネル情報で照合し、後続チャネルのIPは同一端末に固定する。
- 受信は従来の`request`イベントとdecision futureを利用し、承認前にファイルデータを受け取らない。Huaweiの永続的な相手認証は未解明なので、Trusted Devices Onlyでは受信を拒否する。送信探索はその設定でも利用可能。設定画面にはEveryoneが必要な実験的受信であることを英中表示する。
- バッチの全内容を検証してから保存先へ配置する。既存名は保持し、衝突時は`(1)`等の別名を使う。quarantineを付け、自動起動はしない。配置が成功するまではDFile DONEを返さない。
- Python実行環境のネットワーク差を避けるため、UDPはnative host、TCPは実機確認済みのmacOS ncを使用する。内部workerとその子プロセスを専用process groupに入れ、取消・終了時に対象だけを停止する。受信待受のEOF/SIGTERM終了をloopbackで検証し、子ncが残らないことを確認した。
- 暗号化鍵はメモリー内のみ。アプリの診断出力には固定コード・段階・例外型だけを残し、データグラム、アドレス、鍵の生値は保存しない。Huaweiの一時的な発見IDを信頼済みIDとして登録しない。

ビルドと検証:

- Python全157件、Swift全21件が成功。既存MTAの回帰チェックを含む。追加テストは探索のIP/port偽装、重複field、CoAP optionとNUL境界、失効とport更新、既存の承認/拒否/取消、保存衝突と失敗時rollback、loopback待受のEOF/SIGTERM cleanup、送信元が変更されても選択時のスナップショットを送ること。
- macOS 14対応の公式Python 3.14.7ベース環境でフルビルド。最初のHomebrew Pythonビルドは最小OSチェックが正しく拒否した。通常ビルドにはAEAD/RSAモジュールを明示同梱し、ネットワークを使用しない`--huawei-check`を必須化した。
- 同梱Sparkleの内包helperを並列署名すると一時`.cstemp`との競合が起きたため、深い階層から順に署名するよう修正。完全バンドルの署名・最小OS検査を通過した。
- `build/anDrop.app` はローカル開発用bundle。テスト用複製は設定画面を起動時に表示するprivate Info.plist keyを使用する。通常ビルドは従来どおりメニューバー常駐。

最終状態は `phase14-final-state-redacted.json` に保存した。両端のWi-Fi IPは不変で経路はen0、Petal・検証用nc・開発用hostは0プロセス。元の端末共有範囲の説明表示と、インストール済みanDropのTrusted Devices Onlyを読み戻した。強制再起動した旧検証host由来の孤立待受も対象を限定して停止した。

次の実機完了条件は、Mac画面が操作できる状態で「承認→Downloadsへの完成配置→アプリ履歴complete→内容一致」を確認し、続いて本体の送信先選択から同じ3点をPuraへ送って保存内容を読み戻すこと。公開・インストール済みアプリの置換は今回行っていない。

## 本体UIの双方向転送とDownloads保存（phase15）

2026-10-17。利用者がMacのロックを解除した後、開発版の画面取得が復旧した。操作ツールはOS許可画面のアプリへのアクセスを安全上拒否するため、Downloadsアクセスの許可操作だけ利用者へ依頼し、利用者から「許可を押した」との返答を得て受信試験を再開した。許可を回避する設定変更はしていない。

- Finderの専用フォルダーで合成3点だけを選び、「このアプリケーションで開く」から設定を分離した`anDrop Huawei Dev`へ渡した。既定アプリの変更は選択していない。Finder共有拡張そのものの追試ではない。
- Puraの元の可視性は`shared`行の`selected=true`で確認し、一時的にEveryoneを選択した。Macの宛先選択には、Puraで標準Huawei Shareの共有先画面を開いた後に端末が現れた。この試験は共有UIを開いた状態での探索の証拠であり、端末側UIを開かないコールド探索の安定性は未確認。
- anDropのPura宛先を選択し、Pura標準の「接收」を承認。Mac画面の「已发送 100%」とengineの`complete`、`completed=total=1048674`を確認した。
- Puraの`Docs/Huawei Share/`から新規名の`androp15-日本語メモ.txt`（81 B）、`androp15-empty.txt`（0 B）、`androp15-random.bin`（1,048,593 B）だけをHDCで読み戻した。3点とも元の全内容とSHA-256が一致。HDCは照合専用で、端末への配置には使っていない。証拠は`phase15-app-send-redacted.json`。
- Petalは0プロセス。既存のWi-Fi経路を使用し、SSID切替・ホットスポット作成/参加はしていない。一般的なAirDrop相当の常時探索・認証・製品対応完了はこの証拠の範囲外。

- PuraのFilesで既存の合成`androp13-*`3点だけを選び、標準Huawei ShareのPC宛先から送信。本体の「接收」を承認すると、3点がDownloadsへ完成配置された。全内容・SHA-256が元データと一致し、3点すべてに`com.apple.quarantine`が付いた。engineの`complete`と`completed=total=1048674`、保存された本体履歴のcompleteと最終パスを確認。証拠は`phase15-app-receive-redacted.json`と`phase15-history-redacted.json`。
- そのまま同じ3点を再受信。元3点の内容を保持し、` (1)`付きの別名3点が完成した。別名側も全内容一致・quarantine・completeを確認した。証拠は`phase15-app-receive-collision-redacted.json`。初回に待機したhard-link方式は採用せず、検証済みの`renamex_np(RENAME_EXCL)`で配置する。
- 本体での実機マトリクスは日本語名81 B・空ファイル・約1 MiBの3点。8 MiBの往復は独立プローブの証拠であり、本体UIの8 MiB追試とは区別する。Finder共有拡張、受信データ途中の取消、ネットワーク切断からの復帰、長期的な相手認証は未完了。

最終状態は`phase15-final-state-redacted.json`。端末の可視性は元のshared選択へ復帰、両端のWi-Fi IPは不変、Macの経路はen0、Petalは停止。公開版やインストール済みアプリの置換はしていない。

## コールド探索・永続ID・取消と切断復帰（phase16）

2026-10-17。Petal停止、既存Wi-Fi（en0）のみ。試験は2系統で行った。①独立プローブ。②phase15の開発用ホストに、ソースのengineを載せたもの。②ではネイティブUIが送るのと同じJSONコマンド（send / decision / cancel）を注入した。UIのクリック経路はphase15で確認済みで、今回は探索・ID・復帰に絞った。端末の可視性は、試験ごとに設定画面の`selected=true`を読み戻した。読み戻せなかった1試行（実際にはEveryoneのままだった）は無効とし、やり直した。

### 共有画面を開かなくても探索できる

phase15の「Puraが共有画面を開くまで宛先に出ない」原因は、本体の探索フィルターだった。

- 待機中のPura（共有画面を閉じ、可視性はshared）は、Macのmode 1探索にunicast・broadcastのどちらでも応答した。ただし`capabilityBitmap`は`[192]`で、SHARE（bit 8 = 256）を含まなかった。共有画面を開いている間や直後は`[448]`だった。
- 旧runtimeはbit 256を必須としていたため、待機中の応答をすべて`not a Huawei Share discovery record`として破棄していた。phase15の診断で拒否が多かったのもこれに当たる。
- bit 256のない状態で、通知されたportへ独立プローブから送信した。標準の受信確認が出て40 Bが届き、端末から読み戻した内容が一致した（`phase16-cold-send1-redacted.json`）。
- 修正後のruntimeは、DSoftBusの端末種別がphone（14）またはpad（17）であれば、bit 256がなくても受け入れる。それ以外の種別には引き続きbit 256を要求する。開発版を起動すると、共有画面を閉じたPuraが3.5秒で宛先に出た。
- 画面消灯・ロック中は、Puraは探索に応答しなかった（空ACKのみ、またはなし）。AirDropのような消灯中の発見には、BLEでの起床（FE35広告）が別途必要とみられ、未実装。
- 可視性をEveryoneにしてもbitmapは192のままだった。bit 256が付く条件は未確定。

同時に見つかった不具合: 宛先選択を開いている間（discovering）、MacはPuraへの返信もmode 1で送っていた。mode 1の相手をPuraは共有先に表示しない（phase5と同じ）ため、宛先選択を開いている間はMacがPuraの共有先から消えていた。Puraへのunicast返信は常にmode 10（受信先としての通知）にし、mode 1は自分のbroadcast探索だけに使うよう修正した。実機で、宛先選択を開いた状態でもPuraに「我的苹果电脑」が表示されることを確認した。

### Mac側IDの永続化と「仅分享过的设备可见」

| 手順 | 結果 |
| --- | --- |
| shared・新しい一時ID（毎回生成） | 受信確認なしで拒否（phase11と同じ） |
| shared・新しい永続鍵K | 受信確認なしで拒否 |
| Everyone・鍵K | 完了 |
| shared・同じ鍵K | **受信確認が表示され完了** |
| 開発版アプリ: shared・アプリのID（初回） | 約1秒で拒否 |
| 同: Everyone → shared（読み戻しで確認） | どちらも受信確認が表示され完了 |
| 同: アプリ再起動後にshared | 完了。鍵のハッシュは不変 |

これに基づき、MacのRSA-2048鍵を`~/Library/Application Support/anDrop/Huawei/identity.pem`（0600）に保存し、受信待受・送信workerの両方で使う。ProtocolV2の12桁ID・envelope hash・広告UDID・META_NODE_IDは、すべてこの鍵から導出する。鍵ファイルが壊れている、または権限が緩い場合は上書きしない。一時鍵で動作を続け、`huawei_identity_unavailable`を記録する。この鍵はMac自身の名前であって、Puraの暗号学的な認証ではない。Puraの記憶期間や解除の条件も未確認。初回の拒否は、「最初の1回はEveryoneに」という案内で表示する。

なお、受信確認をタップしないまま、Pura側で承認されて完了した例が3回あった（約2.5秒・約4秒・約21秒）。カウントダウンなのか、画面消灯などの条件なのかは不明。これはPura側の挙動で、anDropは関与していない。

### 取消・切断からの復帰

| 試験 | 結果 |
| --- | --- |
| Mac→Pura 16 MiB、承認直後に取消 | `cancelled`。端末の保存先に途中のファイルなし。直後の16 MiB再送が完了し、読み戻し一致 |
| 取消と端末のDONEが重なった場合 | 端末は8 MiB全体を保存。旧runtimeはPermissionErrorで「文件访问被拒绝」と表示していた。終了途中の送信workerのプロセスグループに`killpg`すると、`poll()`がまだNoneでもEPERMになる。macOSで再現した。EPERMは終了済みとして扱い、完了の記録があれば`complete`と報告するよう修正 |
| Pura→Mac 16 MiB、約6.5 MB受信時に取消 | `cancelled`。Downloadsにファイルなし、ステージング削除。直後の再受信が完了し、`(1)`付きの2点が内容一致 |
| 受信中にMac側の全TCP（nc）を強制終了 | 即座に`failed`。ファイルなし、ステージング削除。再受信で`(2)`付きの2点が内容一致 |
| 送信中に送信workerのTCPを強制終了 | 約0.4秒で`failed`。再送は完了し、読み戻し一致 |

いずれもPuraの共有サービスは再起動していない（プロセスIDは不変）。Macが取消すると、Puraの表示は「已失败」になる。MacがreceiverCancel / senderCancelを送らずに接続を閉じるためで、取消メッセージの送信は未実装。切断の再現はMac側ncの強制終了であり、Wi-Fi自体の切断やPura側の離脱は試していない。

同時に修正した不具合:

- **ホスト終了時のnc残留**: ホストが先に終了すると、engineの終了処理が`emit()`のBrokenPipeErrorで中断し、受信待受の`nc -l`がPPID 1で残っていた（実機で2回再現）。待受を先に停止し、報告の失敗は無視する。実アプリへのSIGTERMで残らないことと、単体テスト（修正前は失敗）で確認した。
- **イベントループの停止**: 受信前の保存先確認と古いステージングの掃除を、イベントループ上で実行していた。署名の崩れた開発版の複製では、`~/Downloads`の`opendir`がカーネル内で止まり、探索・UIコマンドを含むengine全体が止まった。Puraは開始フレームを送った後、「待发送」のまま待っていた。原因はTCCと推定しているが、確定していない。ファイル操作をワーカースレッドへ移し、0.5秒止まってもループが動き続けることを単体テストで確認した。
- **古いステージング**: phase14で強制終了した受信の`.anDrop-Huawei-*`（合成3点）がDownloadsに残っていた。受信開始時に、自分の接頭辞・所有者・非symlinkで、10分以上前のものだけを削除する。受信は最長90秒で打ち切られるため、使用中のものは消さない。実機で残骸の削除を確認した。
- **切断の表示**: プロトコル層はタイムアウトもEOFもValueErrorで返すため、切断が「对方发送的文件信息无效」「无法准备所选文件」と表示されていた。`deadline` / `closed` / `incomplete frame`とBrokenPipe系は「与手机的连接已中断」と表示する。

### 検証

- Python 170件、Swift 21件が成功。追加したテスト: 待機中bitmap、端末種別、拒否コード、返信モード、鍵の権限・symlink・破損・同時生成、再起動後のID維持、送信workerへの鍵の受け渡し、`host_gone`の終了、EPERM、取消と完了の競合、ステージング掃除、ループ非停止、表示文言。新規の回帰テストは、修正前のコードで失敗することを個別に確認した。
- 独立プローブに`--identity-key`を追加した。受信チャネルは固定の`node_id`を受け取れる。
- 診断に固定の拒否コード（`discovery_record`など）と`huawei_identity_unavailable`を追加した。自由文は、ネイティブ側のホワイトリストで落ちるため送らない。
- フルビルド成功。凍結版`--huawei-check`（ID鍵のPEM往復を追加）、署名、macOS 14の最小OS検査も通過した。ただし、再ビルドしたホストではPuraの共有先にMacが現れず、ビルド版での端末試験は完了していない。新しい実行ファイルにLocal Network許可がないためと推定しているが、確定していない。上記の実機試験は、phase15のホストにソースのengineを載せた構成で行った。
- 送信した13ファイルを端末から読み戻し、すべてSHA-256が一致した。受信した4ファイルもDownloadsで一致し、quarantineが付いていた。

証拠: `phase16-summary-redacted.json`、`phase16-cold-send1-redacted.json`、`phase16-sharedonly-send1-redacted.json`、`phase16-persist-{1,2,3}-*-redacted.json`、`phase16-ephemeral-everyone-redacted.json`、`phase16-phone-readback/`、`phase16-fixtures/`、`phase16-final-state-redacted.json`。研究用の鍵`phase16-identity-private.pem`はgitignore対象。最終状態: 可視性はsharedで`selected=true`、両端のIPは不変、経路はen0、Petal・試験用プロセス・ステージングはいずれも0。公開版・インストール済みアプリは置換していない。

## 完全ビルドのUI追試とClaude Codeとの分担（phase17）

2026-10-17。Codexが実機UI・ビルド・Python側の修正を担当し、Claude Code CLIにコードレビューとSwift UDP診断の修正を分担した。Claude側の編集範囲は`HuaweiLANDiscovery.swift`、その`main.swift`初期化箇所、`Diagnostics.swift`のホワイトリストと診断テストに限定した。別作業の`AppUpdates.swift`は変更していない。

### 構成A: phase16の完全ビルドをソース差し替えなしで実機操作

`build/anDrop.app`から検証用コピーを作成した。変更は表示名、設定画面を起動時に開くprivate Info.plist key、ホスト再署名のみ。Swiftの`__TEXT,__text`と凍結エンジンのバイト列が元の完全ビルドと一致することを検査した。ソースのengineやJSONコマンド注入は使っていない。

| 項目 | 結果 |
| --- | --- |
| MacのLocal Network設定 | 表示されたanDrop関連項目はすべてON。ただし同名項目が複数あるため新ビルドへの対応付けは断定せず、設定も変更していない |
| Puraの可視性 | `shared`行の`selected=true`を確認。Everyoneへの変更なし |
| 共有画面を開かない探索 | Puraの設定画面を表示したまま、本体の宛先選択にPuraが現れた |
| 本体UI送信 | Finderで合成3点だけを「このアプリケーションで開く」から渡し、MacのPura宛先とPura標準の「接收」を実際にクリック。Macは「已发送」、engineはcomplete |
| 端末保存内容 | 日本語名79 B・空ファイル・8 MiBの3点、合計8,388,687 BをHDCで読み戻し、全内容とSHA-256が一致 |
| 逆方向 | 標準Huawei ShareにMacのPC宛先が1件表示され、選択後のTCP接続まで確認。Downloadsを開く`opendir`でワーカースレッドが待機し、Macの受信確認・最終保存には到達していない |

送信証拠は`phase17/full-build-send-redacted.json`、構成同一性は`phase17/build-provenance-redacted.json`。この試行ではLocal Network設定を変更せず探索・送信できた。phase16の表示失敗をLocal Network許可不足と確定する証拠はなく、当時の原因は未確定のまま。

逆方向の停止時に、engineの主スレッドはイベント待機、別スレッドが`__opendir2`内にいることをsampleで確認した。DownloadsのOSアクセス許可画面の有無と許可操作を利用者へ依頼中。操作ツールがOS許可画面のアプリへのアクセスを安全上拒否するため、その制限を回避する操作はしていない。許可不足は有力な切り分け候補だが、この待機だけから確定しない。完成ファイル・受信completeとは扱わない。

### 分担した修正と構成Bの再ビルド

- Claude Code: UDPのソケット作成、インターフェース、bind、設定、送受信の失敗を固定コード`huawei_transport_failed`・固定phase・数値errnoだけで記録。同一失敗を60秒抑制し、アドレス・端末名・生データグラム・鍵・OSメッセージを記録しない。ポートの単独所有を維持し、SO_REUSEPORT等は追加しない。
- Codex: 一時的なインターフェース取得／待受開始のOSエラーでHuawei探索が恒久停止しないよう、待受を解放して再試行する。インターフェース取得もワーカースレッドへ移した。後処理が別方式の承認futureを拒否しないよう、現在のHuaweiセッションだけを対象にした。
- Python全173件・Swift全22件成功。追加したPython3件は修正前の失敗も確認した。実際に使用中のUDP 5684に対してnative transportを起動し、`EADDRINUSE`を`transport_bind`として1回だけ記録することも確認した（`phase17/transport-conflict-redacted.json`）。この検査は送信せず、既存リスナーも停止していない。
- 修正を含む完全ビルド`build/anDrop.app`は、凍結版`--huawei-check`、完全署名検査、macOS 14の最小OS検査を通過。この再ビルド後の構成BをPuraで追試したとは扱わず、構成Aの実機結果と区別する。

レビューで見つかった送信・受信の12桁IDのバイト順の違いは、役割ごとの互換性確認が必要なため変更していない。Mac自身の永続鍵を維持できることと、相手が本物のPuraであることの暗号学的な検証は別である。後者は未完了。

開発版は引き続きアドホック署名。Appleは、この署名のdesignated requirementがコードの版に結び付き、開発時のプライバシー許可の継続性へ影響しうると説明している（[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)、[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)）。今回の特定の待機原因をこの説明だけから確定はしない。OS権限DBの編集や保護の無効化は行っていない。

最終状態は`phase17/final-state-redacted.json`。Puraのshared選択、両端IP不変、経路en0、Petal 0件を読み戻した。Downloads許可の確認待ちに備え、構成Aの開発用ホスト・engine・その子nc 1件だけを開いたままにしている。孤立した他のncは0件。構成Bは`build/anDrop.app`にあり、まだこの実機用コピーへ入れ替えていない。公開・インストール済みアプリの置換・コミットは行っていない。次の実機作業はDownloads待機の解消後、凍結版の受信確認・保存内容・履歴completeと、構成Bの再探索を確認すること。

## 最新の完全ビルドでの双方向追試（phase18）

2026-10-17。利用者からDownloadsアクセスの許可とPuraのロック解除の完了連絡を得て再開した。前の待機セッション自体を成功扱いせず、修正版の完全ビルドから開発用コピーを作り直して試験した。ソースengineの差し替えやUIコマンドの注入はしていない。開発用コピーと完全ビルドはホストの機械語と凍結engineが一致し、差分は表示名・設定起動用Infoキー・ホスト署名のみ。通常のアプリ内フォルダー選択でもDownloadsを再選択した。OS許可データベースやセキュリティ設定は操作していない。

| 試験 | 実機結果 | 証拠（build/huawei-research/以下） |
| --- | --- | --- |
| Pura → Mac、3点 | 空ファイル、日本語名79 B、8 MiBをDownloadsへ保存。全バイト・SHA-256一致、全点quarantine付き、履歴complete・completed=total=8,388,687 | `phase18/full-build-receive-redacted.json` |
| 同じ3点を再受信 | native受信確認の「接收」を操作。元ファイルを保持し、` (1)`付きで全点保存・内容一致・quarantine・履歴complete | `phase18/full-build-collision-receive-redacted.json` |
| Mac → Pura、3点 | 本体宛先アイコンから空・日本語名79 B・8 MiBを送信。端末保存先からHDCで読み戻して全点内容一致、履歴complete | `phase18/full-build-send-redacted.json` |

最初のMac受信とPura側受信の承認操作の主体は観測できていないため、自動承認とは断定しない。再受信ではMacのnative確認をこちらがクリックした。送信前にはPuraの共有画面が閉じており、可視性sharedのselected=trueを確認していた。終了時にはEveryoneの選択を観測したが、phase18中にこちらから切り替えておらず、変更の原因は不明。元のsharedへ戻しselected=trueを読み返した。この送信試験を通してsharedが維持されたとは主張しない。

追加修正として、一時的な探索エラーで進行中の送信を取消さないようにし、連続探索失敗には1・2・4・8・16・30秒（以後30秒）の待機とエラー通知の集約を加えた。追加2件は修正前に失敗することを確認し、Python全175件・Swift全22件成功。完全ビルドの署名・凍結版self-check・macOS 14向け検査も成功した。構成同一性は`phase18/build-provenance-redacted.json`、ソースは`phase18/final-source-manifest-redacted.json`。

終了時に両端IP不変、en0経路、Petal・開発用ホスト・engine・nc各0件、永続ID不変・鍵0600を確認した。インストール済みアプリの受信範囲はEveryone（trustedOnly=0）を観測したが、この試験では設定を書き換えていない。前段の値との違いの原因は未確認で、古い値へは戻していない。証拠は`phase18/final-state-redacted.json`。公開・インストール済みアプリの置換・コミットはしていない。

最新の完全ビルドでの双方向保存確認は完了した。相手の暗号学的認証、消灯中の発見、取消の相手通知、Wi-Fi自体の切断は引き続き未完了。phase16の取消・TCP切断試験はソースengineを載せた構成であり、今回の完全ビルドで同じ試験を再実施したとは扱わない。

## 端末アイコンの右クリックと非表示管理（phase19）

利用者の追加要望に合わせ、Claude Codeが`Peer.swift`・本体UI・モデルテストを担当し、こちらで差分レビュー、署名付きUIビルド、Puraの実候補を使うnative操作を担当した。候補名の鉛筆は撤去し、端末アイコンの右クリックに「Rename Device… / 重命名设备…」「Hide from Candidates / 从候选设备中隐藏」を追加。設定の「Hidden Devices… / 已隐藏的设备…」から、探索中でなくても記憶済みの端末を再表示できる。

非表示は送信候補のローカル設定で、受信許可・信頼リスト・探索engineは変更しない。保存するのは既存aliasKeyと同じ識別子のハッシュと表示用情報。再探索でも非表示を維持し、選択・送信直前にも候補を絞る。送信中のタイルは保持し、処理中の変更操作は禁止する。識別子自体が変わる端末は、既存の別名と同様に新しい候補として現れる可能性がある。

実候補のアイコン右クリックで2項目、名前変更、非表示で候補消失、再起動後の別名・非表示記録保持、探索前の設定リスト表示、設定からの再表示、再発見を順に確認した。最後に別名と非表示を元へ戻した。画面で鉛筆がないことも確認。Swift全26件成功（新規4件）、UIビルド・完全署名検査・凍結engine self-check成功。engineはphase18の完全ビルドと同一で、最終ビルドと操作したコピーのホスト機械語も一致した。進行中転送の表示維持はコードレビューで確認した範囲で、このUI変更後に転送中操作を実機で再試験したとは扱わない。

証拠: `phase19/native-ui-redacted.json`、`phase19/restart-persistence-redacted.json`、`phase19/build-provenance-redacted.json`、`phase19/final-source-manifest-redacted.json`。終了時、Puraのshared選択、開発用ホスト・engine・nc各0件を確認。インストール済みアプリの置換・コミットはしていない。

## Huaweiロゴとパソコン種別（phase20）

Huawei公式サイトのfavicon（96px PNG）を変更せず同梱し、Huawei/HUAWEIの両表記で使うようにした。ブランド素材の出典・SHA-256は`Resources/BrandLogos/manifest.json`に記録。Puraの実候補で赤いHuaweiロゴとスマートフォン角標を確認した。端末種別computerにはSF Symbolsの`desktopcomputer`と英中のComputer/电脑を追加。共有のPeerモデルを通し、候補・履歴・記憶済み端末・非表示リストでも同じ種別を扱える。Huawei・HONOR・XiaomiのPC、Huaweiのphoneを合成データの本体ビューで描画し、角標を確認した。

Huaweiの広告type 12（公開DSoftBusのTYPE_PC_ID=0x0C）をcomputerへ対応づけた。SHARE能力ビットなしで受け付ける例外は、これまで実測したphone/tabletに限定したまま。PC種別はSHARE能力がある場合に限る。HONOR/Xiaomiの未確認のwire値は推測して追加していない。PC実機との発見・送受信を実証したものではない。

Python176件・Swift27件成功。完全ビルド、凍結版self-check、署名・macOS 14向け検査成功。新規PCテストは広告ゲート、英中ラベル、同名phoneとの区別、非表示記録の往復を検査。検証は`phase20/verification-redacted.json`、ソースは`phase20/final-source-manifest-redacted.json`。今回新たな転送は行っていない。開発用アプリを終了し、インストール済みアプリの置換・公開・コミットはしていない。

## ローカルのインストール済みアプリへ反映（phase21）

2026-10-17。利用者が自分で試験するため、インストール済みanDropへの組み込みを明示的に依頼した。既存の配布IDとDeveloper ID署名を維持し、phase20の凍結engineを使ってホストと共有拡張をビルドし直した。元の署名とのdesignated requirement一致、完全署名、凍結版self-checkを確認。開発用の設定起動Infoキーは入れていない。

旧版1.1.0と設定を`build/local-install-20261017/`へバックアップした。終了時に旧版が保持していたダウンロード済みの公式1.1.1が適用されたため、それも置換直前の別バックアップへ保存。`/Applications/anDrop.app`をバンドル全体で入れ替え、今回のHuawei実験対応・右クリック・非表示管理・Huaweiロゴ・computer表示を含むローカル版1.1.1/build11001を起動した。公開版の発行やコミットはしていない。

同じ正式IDのホストとengine各1件、Huawei探索用UDP5684の待受、Finder共有拡張の登録を確認。設定UIでHuawei注記・非表示管理・新しい版番号を確認した。受信範囲・信頼リスト・記憶済み端末・別名・共有名・言語・保存先・更新設定を保持し、27件の履歴もJSONレコードとして全件一致した（再エンコードによりJSONバイト列の順序は変化）。インストール後のファイルはビルドと一致し、署名も有効。利用者の実機テストに備えて起動したままにしている。今回、インストール後の新たな転送は行っていない。

証拠: `local-install-20261017/build-verification-redacted.json`、`installed-redacted.json`、`running-verification-redacted.json`、`share-extension-redacted.json`。設定バックアップや署名情報を含む私用ログはgitignore対象で保持する。

## 写真共有のプレビュー差分と受信修正（phase22）

利用者からPura→Macの写真受信失敗と診断レポートの指定があった。該当転送は受信承認後、1点568,811 B・completed=0でValueErrorになっており、既存の診断では原因が「receive」へ集約され、native側のphase許可リストにもなかったため具体的な段階が残っていなかった。サイズ上限超過を示す証拠はない。Claude Codeにプロトコルと診断の読み取りレビューを分担し、こちらで再現・修正・実機試験を行った。

私用写真を開かず、合成UI画像から作成したJPEG（76,263 B）をUSBで試験準備として端末の既知の合成ファイル保存先へ配置した。実際の試験転送はPuraのFiles画像プレビュー→標準Huawei Share→同一LANの独立受信プローブ。USB配置を共有互換性の証拠とは扱わない。

修正前は`unsupported batch preview`で再現。認証済みのプレビューはtag 11（18 B）、12（44,849 B）、追加の13（78 B）だった。従来は11/12の2項目だけを許可していた。batchプレビューに限り、11/12/13という順序で重複のない追加項目を最大8 KiBで受け付ける。11のUTF-8・12の60,000 B上限・byteフレーム上限は維持し、未知のタグ・空や過大な13・重複は拒否。プレビューは保存パス・サイズ・信頼判定に使わず、DFile側で名前・合計・個別サイズ・暗号完全性・保存内容を引き続き検証する。

最初の修正後には内容一致で保存されたが、プレビュー用byte接続の正常終了を先に読んで失敗する順序も観測した。フレーム間の正常EOFだけを部分フレーム切断と区別し、認証済みプレビューへACKした後なら、その補助接続を待受集合から外す。ファイル側の検証済みDONE ACKは必須のまま。ヘッダー・暗号payload途中の切断は引き続き失敗扱い。再試験では保存内容・SHA-256一致とDONE ACKまで確認できた。

診断には固定語彙のreceive/preview/frame/metadata/data段階と転送IDを残し、例外の生テキスト・写真・サムネイル・名前は出さない。新規回帰テストは修正前の追加tag拒否を再現し、任意タグや重複・上限違反、正常EOFと途中切断、診断の情報除去を検査。Python179件・Swift28件成功。

証拠は`phase22/reproduction-summary-redacted.json`、`jpeg-before-fix2-redacted.json`、`jpeg-after-fix-redacted.json`、`jpeg-after-eof-fix-redacted.json`。最初の修正後の保存だけの試行は、DONE ACK成功とは扱わない。利用者が失敗した元写真そのものの再試験結果ではなく、同じ失敗段階を再現した合成JPEGによる検証である。

修正版を同じ正式ID・Developer ID署名で完全ビルドし、ローカルの`/Applications/anDrop.app`を1.1.1/build11002へ更新した。元の署名要件・設定・全既存履歴を保持した。凍結engine・完全署名・macOS 14向けの検査成功。インストールした本体へ同じ合成JPEGをPuraから送信し、nativeの「接收」を操作。Downloadsに76,263 Bを保存し、全内容・SHA-256一致、quarantine付与、履歴complete・completed=total、Pura側「已发送」を確認した。証拠は`phase22/native-photo-receive-redacted.json`、構成は`installed-fix-redacted.json`、終了状態は`final-state-redacted.json`。standaloneプローブは終了し、利用者の再試験に備えて通常のanDropホストとengine各1件を起動したままにしている。試験用JPEGは端末とDownloadsに保持した。

## 写真2枚のプレビューMTU修正（phase23）

利用者の診断 `anDrop-report-c2fb6eef-9caa-4711-be10-d726510dc81a.json` は、2点・合計1,588,795 Bの受信承認から約9秒後、保存前にValueErrorで失敗していた。診断単独では具体的な失敗箇所は特定できない。

私用写真を開かず、前段の合成JPEGを2つの別名でPuraのFilesから標準Huawei Shareへ渡して再現した。旧実装はbyteチャネルを開いてMTU=65,536を応答した後、プレビューが届かず `receive channels response deadline`。端末側ログに `CheckSendLen fail, len=89852` があり、Macが申告したMTUによってスマホ側の送信前チェックが失敗していた。利用者の元写真での同一原因は未確認だが、2枚の再現で原因を分離できた。

プレビュー用MTUを1 MiBに変更し、受信フレーム上限も同じ値と外側AES-GCMの28 Bに合わせた。サムネイル欄は承認済み点数×60,000 Bに制限し、タグ構造・補助欄・UTF-8・暗号完全性・ファイル数/サイズ/保存先の検証を維持した。修正後の実機プレビューは89,852 B、tag 12は89,633 B。2点計152,526 Bを保存し、元の2ファイルとの全内容/SHA-256一致とDONE ACKを確認した。

回帰テストは64 KiBを超える二重暗号プレビュー、分割読み出し、1 MiB境界と暗号オーバーヘッド、上限超過、点数とサムネイル上限の対応を検査する。独立プローブの証拠: `phase23/before-redacted.json`、`after-mtu-redacted.json`、`probe-integrity-redacted.json`。端末ログは私用ファイルに保持し、画像内容・端末識別子を公開資料へ転記しない。

ローカル正式ID・同一Developer ID署名の完全ビルドを1.1.1/build11003として`/Applications/anDrop.app`へ反映。旧版は検査済みZIPとして保持した。Python181件・Swift28件成功。署名・凍結engine自己検査・インストール済みホスト/engine/プロトコルのビルド一致を確認。設定と既存履歴は保持し、本体を起動して利用者の元写真2枚の再試験を待つ。今回の転送内容照合は独立プローブでの実機試験であり、元写真の本体受信成功とは区別する。

## Mac送信のファイル分類修正（phase24）

PDFもギャラリーで開くとの報告を調査。`offer()`のcommand 7 / tag 1（`sendType`）が全ファイルで`1`固定、tag 6（`fileCount`）も`1`固定だった。Petalの`PackFileShareInfoPayload`と送信ログ書式からタグの対応を確認。HarmonyOS 7の`AppleRecvSession::ProcessRecvPreview`は3/4/8をファイル向けの件数処理へ渡す。Finder・パス指定の転送は通常ファイルカテゴリ`3`とし、tag 3/6の両方に実際の件数を送るよう修正した。画像を含む混在バッチもファイル共有とし、個別ファイルの名前・拡張子・内容は変えない。

PDF・日本語名・画像先頭の複数ファイル・16件のオファーを検査する回帰テストを追加。Python全181件成功。確認中に別作業のphase23完全ビルドがインストールされ、本修正も`/Applications/anDrop.app`の1.1.1/build11003へ含まれていることを直接比較した。署名と凍結engine自己検査は成功。この調査からの追加置換は行っていない。実機探索では応答を取得できず、修正後PDFの受信・起動先は未検証。証拠は`phase24/verification-redacted.json`。

## Mac送信の拡張子情報修正（phase25）

通常ファイルとして届くが「不明なファイル形式」になるとの追加報告を調査。command 7 / tag 7（`previewSummary`）に生の先頭ファイル名を送っていた。HarmonyOS 7のタグ処理`0x1e54d4`→`0x1e5c94`はJSONオブジェクトを解析し、キーを拡張子、数値を件数として`UtdClient::GetUniformDataTypeByFilenameExtension`へ渡す。PDF単体は`{".pdf":1}`、Wordは`.doc`/`.docx`、混在バッチは全ファイルの拡張子別件数を送るよう修正した。大文字拡張子は小文字化し、拡張子なし・未知の拡張子は別形式へ偽装しない。

この欄はMIME文字列を直接指定する欄ではない。受信側には解決した型を`general.file`/`general.image`/`general.video`へまとめる処理もあるため、この修正だけで端末の表示が「PDF」や「Word」になるとは未確認。単一ファイル名を含む別プレビューとの関係も残る。

PDF・Word・画像先頭の混在・大文字・拡張子なし・未知拡張子と、件数/先頭名不一致の拒否を回帰検査。Python全183件（Huawei関連84件）が成功。外部プロトコルモジュールを更新し、同一Developer IDで署名した1.1.1/build11004を`/Applications/anDrop.app`へ反映。旧バンドルと設定は`phase25`へ退避。署名・指定要件・凍結engine自己検査・インストール済みモジュールのソース一致を確認し、ホストとengineを起動した。証拠は`phase25/package-redacted.json`とテストログ。修正版での実機の形式表示・起動アプリは利用者の再試験待ちで、確認済みと扱わない。

## Mac送信のファイル名プレビュー追加（phase26）

利用者の再試験でbuild11004でも「不明なファイル形式」が残った。拡張子サマリーだけでは解決しなかったことを確認。送信側はバイトチャネルを確立した後、そのチャネルにファイル名プレビューを送らずDFile転送へ進んでいた。

Petalの`SendFilePreview`はファイル名を`|`で連結し、`0x10009b180`でcommand 8 / tag 11へ格納する（tag 13はメディア時刻情報）。HarmonyOS側のtag 11処理は受信プレビュー名を更新し、`ProcessRecvPreview`がそれをファイル向け画面へ渡す。通常ファイル送信でtag 11をアプリ暗号とSoftBus暗号の二重暗号で送信し、command 1 / tag 8の`previewOK`を両方の暗号認証で検証してからファイルチャネル交渉へ進むよう修正した。サムネイルや架空の撮影時刻は追加していない。実際の保存名・内容は引き続きDFileが保持する。

プレビュー名の送達と、別制御応答・異なる鍵による応答を成功にしない回帰テストを追加。Python全184件成功。同一署名・指定要件を保持した1.1.1/build11005をインストールし、署名、凍結engine自己検査、ソース一致、ホスト/engine各1プロセスの起動を確認。旧build11004は`phase26/anDrop-before.app`へ保存。証拠は`phase26/package-redacted.json`、テストログは`phase25/preview-tests.log`。

実機再送中の一時state.jsonを監視し、`file_preview_ack_verified=true`、`dfile_done_ack_sent=true`、`status=dfile_batch_completed`を確認。ただし利用者は「送信完了と出るのにファイルが0件」と報告。通信層の完了を保存・形式認識の成功とは扱わない。旧来の`Docs/Huawei Share`保存先も調査時は空だった。

## 単一ファイル種別の追試（phase27）

HarmonyOSの`SessionUtil::GetTypeByCount`（`0x1884f8`）は種別8を1件のときだけ維持し、フォルダーなし・複数件なら3へ変更する。送信側も1件を8、複数件を3とするよう変更した。PDF・Wordと混在バッチの回帰テストを更新し、Python全184件成功。1.1.1/build11006へ反映し、署名・指定要件・凍結engine自己検査・ソース一致を確認した。旧build11005は`phase27/anDrop-before.app`へ保存。証拠は`phase27/package-redacted.json`と`phase26/single-file-tests.log`。

利用者が提示したbuild11006の診断レポートは、18:22:47 JSTの1件PDF送信が`preparing`に入る前に`TransferError`で停止した記録だった。該当履歴の送信元を読み取り専用で照合すると107,735,062 B（約102.74 MiB）の通常ファイルで、現行の1件8 MiB制限を超えていた。今回の失敗ではオファー・プレビュー・ファイル本体の送信に進んでおらず、形式認識の修正成否は分からない。`phase27/reported-failure-redacted.json`にファイル名を除いた証拠を保存。このレポートとは別に、利用者は685,593 BのPDF再送でも0件・不明な形式と報告した。したがってbuild11006の単一種別8への変更は解決になっていない。

## ネイティブPDF送信との比較（phase28）

利用者がHuawei→Macへ再送したPDFをbuild11007の期限付きメタデータ観測で確認。受信履歴1件、1,302,264 B、Downloads上の通常PDF（先頭`%PDF-1.7`）、SHA-256を読み返した。暗号鍵・文書本文・サムネイル本体は観測ログに出していない。ファイル名を含む原記録はignored領域のowner-onlyファイルに限定した。

実測のcommand7はtag順`2,3,4,5,6,7,1`、件数3/6は1、folderCount5は0、tag7は`{".pdf":1}`、sendType1は**3**。単一PDFでも種別8というphase27の推測は裏付けられなかった。command8はtag11（ファイル名8 B）とtag12（プレビュー37,226 B）。文書の明示的MIME文字列はこのオファーには存在しない。受信実績は逆方向送信の互換性を保証しない。

Mac側純正Petalの`PackFilePreviewPayload`（`0x10009b180`）はtag11に加えtag13の`date_added` / `date_taken` / `detail_time`配列を必ず送る。`SendFilePreview`の欠損日時値は-1/-1/空文字列。HarmonyOSはtag13受信時にtag11とともに`SessionUtil::ParseMediaInfo`を呼び、ファイル名別の補助情報を作る。anDropのtag11のみの通知にはこの配列が欠けていたため、同じ欠損値を含めるよう修正。種別は実測に従い3へ戻した。これは送信構造の不一致の修正であり、0件・不明形式の根本原因確定ではない。

受信側の全体件数1504とバッチ件数1592も比較したが、1592の初期値は100。tag8の欠落により0のままになるという仮説は棄却し、根拠のないtag8追加は行っていない。

Python184件成功。初回は既存discoveryテストがランダムCoAPトークン中の0xffをpayload区切りとして扱いUnicodeDecodeErrorになったが、再実行184件は成功（`tests.log` / `tests-retry.log`）。build11008へ反映、署名・指定要件・engine自己検査・設置スクリプト一致・ホスト/engine各1プロセスを確認。一時観測コードは設置アプリから除去した。`native-pdf-receipt-redacted.json`と`package-redacted.json`が証拠。build11008の利用者再送でも0件・不明形式だった。補助情報の追加だけでは解決していない。DFile完了だけを保存成功とは扱わない。

## プレビューとファイル用接続の順序（phase29）

build11008の再送時、端末のShareServiceログで`SessionOpenedEvent# in 12 status do not need session opened`を観測。HarmonyOSの`SessionOpenedEvent`（`0x1ddd94`付近）は状態6/8だけを処理し、状態8の処理でファイルセッションを記録して`RegisterFileSchema`（`0x21aa10`）を呼ぶ。その他の状態では登録をせずログを出して帰る。anDropはbyte接続直後にプレビューを送り、ACK後にfile接続を開始しており、この状態遷移の順序と矛盾していた。

プレビュー送信を、file接続・DFile設定交換を完了した後、本体ヘッダーを送る前へ移動。プレビュー関数にもfile接続と設定検証を前提条件として設け、準備前には1バイトも通知しないことを回帰テストで確認。byte接続の暗号鍵はfile鍵追加後の`keys[-2]`を使い、外側/内側暗号とACK検証は維持する。Python185件成功。build11009を署名・指定要件維持・engine自己検査後に設置し、設置コード一致とホスト/engine各1プロセスを確認。利用者の再送は失敗。端末側の状態12でのSessionOpenedEvent拒否は再発しなかったが、Mac側がプレビュー応答を拒否して本体送信前に中止していた（phase30）。

## プレビュー確認前のアバター通知（phase30）

build11009の診断レポート2件は`huawei_send_failed / ValueError`のみだった。一時state.jsonの保存により、byte/file接続・DFile設定交換は成功し、`file_preview_sent=true`の後に`file preview was not acknowledged`で停止、本体ヘッダー未送信と確定した。終了時にランタイムが一時stateを削除し、エラー理由が通常診断に残らない点は未改善。

同じ永続Mac鍵を使い、個人データを含まない618バイトのPDFを独立プローブで送信して再現。復号済み応答のタグと長さだけを記録すると、最初の応答はcommand1 / tag15 / 26,955バイトだった。Petalの`OnRecvPacket`（`0x100092968`付近）は`ISHARE_ECOLOGY_SAVE_AVATER`を処理し、`0x10009bcac`のパーサーはtag15を検証する。これはpreviewOKとは別のアバター通知。内容は保存・表示していない。当初候補だった`next_recv`は観測されておらず、その通知を無視する案は採用しなかった。

`send_file_preview`は二重の暗号検証後、command1/tag15だけを補助通知として読み飛ばして次の応答を待つ。補助通知の上限は1件64KiB、読み取りは合計4回。command1/tag8=`previewOK`を受け取るまで本体送信を始めない。未知の制御・拒否・busy、認証不一致、上限超過、ACK欠落は成功扱いしない。保存するのはタグ・長さ・既知制御名だけ。

修正後の実機送信はアバター通知→previewOK→DFile完了へ進行。PDF 618バイトとDOCX 908バイトを各1件送信し、Huaweiの`Docs/Huawei Share`に実ファイルが存在し、端末で計算したSHA-256がMacの元データと一致した。画面上の受信件数・形式名・開くアプリはこの読み戻しでは検証できず、利用者の確認が必要。証拠は`phase30/send-state-private.json`、`synthetic-preview-redacted.json`、`synthetic-avatar-fixed-redacted.json`、`synthetic-word-redacted.json`、`receipt-redacted.json`。

Python186件成功。build11010を署名・指定要件維持・engine自己検査後に設置し、設置スクリプト一致とホスト/engine各1プロセスを確認。`phase30/package-redacted.json`に記録。

## 受信承認前の「？」アイコン（phase31）

利用者はbuild11010でPDFをPDFとして開けると確認。その後のスクリーンショットでは、保存済みの`androp-name-check.pdf`にPDFアイコン、`androp-word-check.docx`にWordアイコンが表示されていた。一方、受信承認前のダイアログには「？」付きの書類画像と「1个文件 | 共374.2 KB」が表示されている。「不明な形式」というエラー文ではない。保存後の形式判定と承認前のプレビューを区別する。Wordの実際の起動・編集は未確認。

初期command7にもtag11のファイル名を追加する独立試験を行った。618バイトPDFは`dfile_batch_completed`になったが、利用者の確認では承認前の表示は変わらなかった。この試験変更と専用テストは撤回し、送信スクリプトを設置済みbuild11010と同一へ戻した。試験コード・結果は`phase31/offer-name-experiment.py`と`offer-name-redacted.json`に保持。新しいアプリ版は設置していない。

SDKのsystem.imgから読み出したHuaweiShare.hap（7.0.0.205）を静的解析。実機は7.0.0.545のため、以下は解析用旧版の根拠であり実機の全分岐を証明しない。

- `PreviewDialog.getBaseInfo`は`previewData`のJSON配列を読み、最初の3件を`thumbnails`へ渡す。
- `ReceiveNormalCard.isThumbnailValid`は空配列を無効とし、文字列画像には`data:image/...;base64,`を要求する。無効時の分岐はresource 83886525、`file_placeholder.svg`を固定表示する。この素材にはスクリーンショット同様の「？」付き書類が描かれている。
- 別の`UtdThumbnails.UNKNOWN`はresource 83886614 (`ic_file_unknown`)。PDF/WordのUTD用画像マッピングが存在しても、上記のプレビュー配列の代替処理では直接利用されない。両者を同じ判定と扱わない。
- ネイティブApple互換経路の`HandlePreviewDataCommand` (`0x1e5348`)ではtag7は拡張子件数の要約、tag11は名前、tag13はメディア日時として処理される。tag12はそのハンドラーの対応分岐にない。`ProcessRecvPreview`のファイル分岐はプレビュー画像用の別フィールドをUIへ渡す。初期通知の拡張子JSONをPDF用の画像として読む処理は確認できていない。

現時点で確認できたのは「ファイル自体は正常に保存・認識され、承認前の画像が汎用表示になる」こと。現在のApple互換経路でPDF/Wordの承認前画像を渡す方法は未確定。写真カテゴリへの再変更や、保存先登録前のcommand8送信は過去の誤分類・0件受信を再発させるため採用しない。比較用Petalは端末を発見できず、純正Macから同じOSへの表示比較は未成立。次に必要なのは、この互換経路で画像データを受け入れる箇所、または実機と同版の表示実装の確認。

## 実機版でのプレビュー画像の経路と標準セッション（phase32）

利用者の不在中に、承認前アイコンの入力経路を追加調査。**画像をUIへ渡す処理は特定できたが、Macからその経路で認証を完了してアイコンを表示するところまでは未実証**。製品の送信処理・設置済みbuild11010は変更していない。

### 実機のバイナリによる確認

通常のHDC `file recv`で、実機の次の既知パスを読み出せた。ディレクトリ列挙の拒否を、個別ファイルの読み出しも全て不可という意味に解釈していた点を訂正する。権限・端末設定の変更はない。

| ファイル | バイト数 | SHA-256 |
| --- | ---: | --- |
| `/system/lib64/libshare_service_plugin.z.so` | 1,835,304 | `681c401dfe48931b8e57c0865a9f2f71a49797541c016412c3206e1d48437468` |
| `/system/lib64/libshare_service.z.so` | 889,096 | `5d8d04dd71916e8938c453cdad1e6c0e4f5ae92950863867ee68f48f2dbd4263` |

`com.huawei.hmos.instantshare`の実機版は7.0.0.545。ただしネイティブライブラリをこのアプリの版番号だけで一意に同定せず、上記ハッシュで区別する。実機のHuaweiShare.hapとインストール先の`modules.abc`/`resources.index`は引き続きアクセス拒否。実機UIのコードそのものを取得できたとは扱わない。取得物はignoredな`build/huawei-research/phase32/`内に置き、アプリ・リポジトリへ同梱しない。

実機ライブラリの`AppleRecvSession::HandlePreviewDataCommand`（`0x16c134`）の初期通知には、文字列を受けるtagが`2, 7, 10, 11, 13`しかない。tag12とtag68は非対応。後続の`HandlePreviewRecvInfo`（`0x16b5e0`）が受けるtagも11/13のみ。従って**この2つの通知に画像フィールドを追加するだけでは画像が届かない**。Apple互換経路の全機能に画像入力が存在しないことまで証明したわけではない。

一方、標準の`RecvSessionV1`には次の経路がある。

| 段階 | 実機コードの確認箇所 | 入力・出力 |
| --- | --- | --- |
| 送信側の画像梱包 | `PackSendPreview`の`0xb71d0` | プレビュー内のtag68 (`0x44`) |
| 受信側の画像保存 | `HandleBytesDataString`の`0xd1cfc` | tag68の文字列 → receiver offset1504 |
| UI通知用構造への引き渡し | `ProcessRecvPreview`の`0xd12c4` | receiver offset1504 → `RecvPreview.previewData` (offset64) |
| UI側の画像形式 | phase31の旧版`PreviewDialog`/`ReceiveNormalCard` | JSON配列内の`thumbnail`に画像のdata URL |

画像データの候補形式は`[{"thumbnail":"data:image/png;base64,..."}]`。ファイル拡張子やMIME文字列をこのフィールドへ置く形式ではない。PDF用・Word用の画像を渡せる可能性を示すが、その画像生成・実機表示は未検証。

`scripts/research/huawei_preview_dispatch.py`を追加。上記ハッシュの実バイナリから限定したAArch64命令列をUnicornで実行し、初期/後続Apple通知の全256tagずつと標準tag68の計513分岐を確認した。さらに合成1px PNGのdata URLを含む132 BのJSONが、標準tag68の保存先から`RecvPreview.previewData`まで保持されることを確認。C++文字列操作はスタブで、全サービス・IPC・UI・認証のエミュレーションではない。

```sh
# Unicornを入れた調査専用venvで実行。バイナリはローカル取得物を指定する。
build/huawei-research/phase32/venv/bin/python \
  scripts/research/huawei_preview_dispatch.py \
  build/huawei-research/phase32/libshare_service_plugin.z.so \
  --output build/huawei-research/phase32/dispatch-emulation.json
```

### 標準経路への実通信

`ShareReceiver`の初回パケット処理から、envelope module101がAppleRecvSession、module100かつtransType0〜2がRecvSessionV1を生成する分岐を確認。標準側の初回本文はcommand192で、その中のtag215がtransTypeの十進文字列。`transType`は写真/PDF等のファイル種別とは別の値。

実機の既知LANアドレスが変わっていないことを確認し、直前の既知ポートへ限定して試験した。anDropがUDP5684を使用中だったため、併存CoAP探索は5685を使ったが、ACKのみで新しい広告レコードは得られなかった。既知ポートへのTCP開始応答により、その時点で接続可能なことを別途確認した。

1. 開始要求の`SRC_BUS_NAME`/`DST_BUS_NAME`を`IShareAuthSession`にすると、module8/CODE4/API2/MTU39968の応答が返った。
2. module100/command192/tag215=`0`を送ると、実機ログに`RecvSessionV1.cpp:2835 HandleIshareModuleData commandId is: 192`が出た。標準受信処理が実際に選ばれた根拠になる。
3. tag234=`0`, 215=`0`, 213=`1`, 211=`31`の能力問い合わせに対し、module100/command192/tag234=`15`と、tag212（21 B）の2応答を確認。能力ビット全体の意味は未確定。個人情報の可能性がある文字列値は保存せず、tag/長さだけ記録した。
4. 能力応答後に標準CCMPの公開鍵要求（module0/tag16）を送っても、実機は`data type is: 0, current send status is: 1`として処理しなかった。静的にもmodule0を認証処理へ渡す条件が受信state2であることを確認。標準経路は、Apple互換の鍵交換を単に置き換えるだけでは成立しない。
5. 送信種別通知を含む追加の初期交渉でも、state2へ進んだ根拠・認証継続応答は得られなかった。その試行では公開鍵送信まで進めず終了。ファイル名・プレビュー画像・ファイル本体は送信していない。

再現用の`scripts/research/huawei_standard_capabilities.py`には、成功した開始・能力問い合わせだけを実装した。明示した同一LANの対象1台へ最大2応答を待ち、接続を閉じる。アカウント情報、秘密鍵、永続ペアリング、プレビュー、ファイル送信処理はない。最終コードでも実機から上記2応答を再確認した。

```sh
python3 scripts/research/huawei_standard_capabilities.py \
  --peer-ip '<現在の対象端末LAN IP>' --port '<確認済みの広告ポート>' \
  --output build/huawei-research/phase32/standard-capabilities-repro-redacted.json
```

主要証拠: `dispatch-emulation.json`、`standard-opening-redacted.json`、`standard-knock-redacted.json`、`standard-capabilities-redacted.json`、`standard-capabilities-public-key-redacted.json`、`standard-file-session-public-key-redacted.json`、`standard-capabilities-repro-redacted.json`。`standard-file-session-public-key`という試行名でも、結果に`public_key_sent`がないため公開鍵送信は未実行。

最終検証: 実バイナリの513分岐と画像データ引き渡し、能力応答の文字列非出力、破損応答5種の拒否、追加Pythonの構文、`git diff --check`を確認。設置済み1.1.1/build11010の送信スクリプトと作業ツリーが一致。調査用nc接続は終了し、残るncはanDropEngine配下の受信待受のみ。`native-runtime-evidence-redacted.json`と`final-audit-redacted.json`に記録。

次の境界は、通常の認証開始通知でRecvSessionV1をstate2へ進め、認証を完了した後、command64/tag68の画像を承認前画面へ表示すること。その後にPDF/Wordの保存・内容一致を確認してから製品へ統合する。写真種別の偽装、承認の省略、保存先登録前へのcommand8の移動は行わない。今回は製品の改善版・修正完了とは扱わない。

## 緑の画像アイコンから「？」への変化（phase33）

利用者が提示した06:02と06:59の画面は、いずれも1件・374.2 KBの受信承認前通知。前者は緑の画像ファイルアイコン、後者は「？」のファイルアイコン。**この差は送信内容の解析成功／失敗だけではなく、こちらが全ファイル共通のsendTypeを1から3へ変更したことと整合する。** 現在の`offer()`も、JPEGを含めてtag1=`3`固定。PDFをギャラリーへ振り分けないための変更が、写真の通知経路にも適用されている。

### 大分類とサムネイルを区別する根拠

- 実機版ネイティブの`AppleRecvSession::ProcessRecvPreview`では、`0x16d9c0`以降が3/4/8をファイル通知側へ、それ以外の非BytesInfo種別を`0x16dc70`へ分岐させる。後者の`0x16dd14`に`SendBean`文字列と通知呼び出しがある。調査スクリプトに実命令の4ケース（1/3/4/8）を追加し、1→SendBean、3/4/8→fileを確認。IPCや画面の実行を含む検証ではない。
- 解析用HAP **7.0.0.205** の`ReceiveNotificationInfoUtils.createFileShowInfo`は、`previewText`のJSON解析失敗時、`osType == IOS && shareType == SendBean`なら`isAllImageVideo=true`にする。`RECV_TYPE_BEAN`の値は数値1ではなく文字列`SendBean`、`RECV_TYPE_FILE`は文字列`3`。生のwire値とUIの列挙値は混同しない。
- 同版の`ReceiveNormalCard`は`isAllImageVideoRecords=true`かつサムネイルなしの場合、resource **83886599 / `ic_file_image.svg`** を表示する。リソースは緑色（`#70df66`〜`#4eba45`）の画像ファイル用図柄。一般ファイル側でサムネイルが無効ならresource **83886525 / `file_placeholder.svg`** を表示する。
- 従って、以前の緑アイコン自体は実画像のサムネイルが届いていた証拠にならない。「？」もテキスト文書への分類を示すものではなく、一般ファイル側の代替表示として説明できる。現在の実機UIは7.0.0.545なので、旧UIで特定した条件が完全一致するとの断定は避ける。実機ネイティブ分岐と提示画面がこの説明を支持している。

### 名前・拡張子を追加するだけで解決しなかった手掛かり

同じ旧UIの`createFileShowInfo`はまず`JSON.parse(previewText)`と`Object.values`を実行し、成功かつレコードありの場合に初めて`previewTextSummary`、または各レコードの`mime_type`を分類に使う。解析失敗時は上記の代替分岐へ戻る。拡張子件数の要約だけが正しくても、このUIの分類処理に到達するとは限らない。

実機ネイティブ側でも名前と形式情報は別フィールド。`ProcessRecvPreview`の`0x16da10`はreceiver+1400（tag11の名前）→RecvPreview+88、`0x16da1c`はreceiver+1584→RecvPreview+112。シリアライズの`0x182f14/0x182f24`と各エラーログは、前者を`allFileNameData_`、後者を`previewInfo_`と区別している。旧UIも`allFileNameData`を`|`で分割して`fileNames`へ、別の`previewInfo`を`previewText`へ入れる。**名前をJSONに変えたり、初期tag11へ名前を入れたりしても、previewInfoを設定したことにはならない。**

tag13の呼び出し先は`SessionUtil::ParseMediaInfo(const string&, const string&, unordered_map<..., MediaInfo>&)`（PLT `0x19b430`、実体`0x13592c`）。名前と日時配列から日時用マップを作る処理であり、previewTextの生成とみなす根拠はない。これを根拠なく初期通知へ追加する実機試行は行っていない。

次の実装判断では、(1) 写真だけを適切なメディア経路で扱うこと、(2) PDF/Wordを含む受信前アイコン用の画像・形式情報を渡すこと、(3) 受信後の保存先と内容を維持することを別々に検証する。全ファイルを1へ戻すと、以前のPDF誤分類を再導入する。写真だけ1へ変える案も、保存先や受信件数への影響が未検証なので、この調査では製品へ入れていない。

変更は調査記録とオフラインの分岐検証のみ。既存513ケース・標準画像データの引き渡しと追加4ケースが成功。build11010の送信実装は維持し、受信前表示の修正完了とは扱わない。

## 写真だけを緑アイコンの経路へ分離（phase34 / build11012）

利用者の明示依頼により、全件共通だった送信種別を選択ファイルの拡張子で分岐。JPEG/PNG/HEIC/HEIF/AVIF/WebP/GIF/BMP/TIFFだけのバッチはApple互換のsendType=1（SendBean、既知の緑画像アイコン経路）へ戻す。動画は独立した`video`分類とし、MOV/MP4/M4V/WebM等を写真一覧へ含めない。動画単独、一般文書、写真と動画／文書の混在、未対応・不明拡張子はsendType=3で実際の拡張子件数を通知する。大文字拡張子も区別せず処理し、二重拡張子は最後の拡張子を使う。内容検査や実サムネイル生成ではない。

動画専用のwire種別は未確定。2を推測で割り当てていない。従って動画を写真と誤宣言しなくなるが、動画専用アイコンを実現したとの主張はしない。混在送信の全体を写真として扱わず、ファイルの分割送信もしない。command8と保存先登録の順序、日時メタデータ、ファイル本体は変更なし。

検証: `test_huawei*.py`の90テスト成功。写真のみ、動画のみ、写真＋動画（順序反転含む）、写真＋PDF/Word、未知拡張子を追加検証。反映前に実際の設置版を確認すると11011だったため、それを退避し11012へ更新した。変更対象は凍結runtimeが`spec_from_file_location`で読み込む同梱Pythonソース1個とbundle build番号のみ。設置済みの他のコード・資産を保持したコピーを作り、`--huawei-check`、同じDeveloper IDでの再署名、完全署名検証、designated requirement一致を確認。更新後の同梱スクリプトとソースの一致・アプリ起動も確認した。

証拠と退避物はignoredな`build/huawei-research/phase34/`。写真の受信承認前アイコン・保存・内容一致の実機再検証は未実施。build11012はこの限定的な写真分類の修正であり、PDF/Word/動画の専用プレビュー対応版ではない。

## 通信仕様の手掛かり

### 実際に列挙できたもの

- 広告: Service Data `0000FE35-0000-1000-8000-00805F9B34FB`、Manufacturer ID `0x027D`。
- 観測した Service Data / Manufacturer Data の長さ: `15 / 24` bytes、および別の観測で `13 / 22` bytes。
- GATT service: `11C8B310-80E4-4276-AFC0-F81590B2177F`。
- 同サービスの characteristic: `2B00`, `2B01`。列挙された properties は read, write, write-without-response, notify, indicate。
- 別サービスとして FE35（特性 `2A00`〜`2A03`）および `C574EDB3-6551-473B-BAD8-65035F07E4A8` も存在した。値の意味は未解析。

GATT 検査は近傍の一つの FE35 + Huawei manufacturer 候補を明示的に指定して実行した。接続時は Petal も動作していた。BLE エンドポイント ID の異なる観測があり、古い ID を指定した検査は `target_not_seen_in_current_scan` として接続を中止した。物理デバイスの厳密な認証や長期的な同一性は確立していない。

### 比較アプリの静的解析で見つかったもの

以下はバイナリ内の文字列・広告生成部分の逆アセンブルから得た実装の手掛かりであり、この端末で全経路が使われた証明ではない。

- 通常広告の Service UUID 配列: `FE35`, `933E`, 3 個の 16-bit 値, `0300` とローカル名。
- 3 個の値は実装で生成される。試験用プローブでは毎回ランダムな値を使用し、ユーザーのアカウントや端末 ID を流用していない。
- CoAP の `device_discover`、`5684`、`coapUri`、`capabilityBitmap`、`wlanIp`、`serviceData`。
- `SoftBusEncryptDataWithSeq`, `TransTdcEncryptWithSeq`, `TransTdcUnPackData`。
- `IShareEcologyAuthSession`, `IShareReceiverBytesSession`, `IShareSenderBytesSession`, `IShareReceiverFileSession`, `IShareSenderFileSession`。
- AES-GCM、ChaCha20-Poly1305 関連処理、認証チャネル、TCP/P2P チャネル処理。
- `SetSpeedMode`, `PackNakedChannelHandshakeWlan`, `ParseNakedChannelHandshakeWlan`。
- `ISHARE_APPLE_ECOLOGY_NETWORKINFO_NEGO_REQ_ID` / `RSP_ID` と `go ble` / `go tcp`、physical / logical connection info。
- `ParseCompetencyNego`, `secure_version`, `ParsePubKeyHandShake`。
- ローカライズ文言に「两端设备连接同一局域网」「局域网连接中」と、同一 WLAN が利用できない場合のホットスポット接続案内が別に存在。LAN と直接接続を分けた経路選択の手掛かり。

端末の `hidumper -s 4700` にも DSoftbus の discovery / connection / transmission モジュールがあり、マスクされた iShare 系セッション登録を確認した。OpenHarmony の DSoftBus は参考になるが、これだけで Huawei の独自 iShare 認証・転送層を代替できるとはいえない。

現行 anDrop は `3333`/`3334` の Service Data を読み、サービス `8881` / GATT `9999` と `9897`/`9898` を使う。Huawei の観測結果とは異なり、現行 HTTPS/WebSocket 転送をそのまま流用できる証拠はない。

## 公開 API と調査上の制限

- ローカル DevEco SDK の `@hms.collaboration.harmonyShare.d.ts` は `knockShare` / `gesturesShare` / `dataReceive` と `SharableTarget.share()` などを提供する。HarmonyOS 上のアプリからシステム共有へ参加する API であり、macOS 用の相互接続プロトコル実装ではない。
- システムアプリの設定・送受信 Extension の一部は `ohos.permission.ACCESS_INSTANTSHARE_PRIVATE_ABILITY` を要求する。全ての公開 Share Kit API がこの権限を要求する、という意味ではない。
- `/system/app/HuaweiShare/HuaweiShare.hap`と`/system/lib64`のディレクトリ列挙は通常HDCでPermission denied。ただしphase32で、既知パスの2つのライブラリは通常の`file recv`で取得できた。権限回避はしていない。
- 旧 Share Engine の公式 Codelab は Android/Linux/Windows SDK と EMUI 系の条件を示す。macOS / HarmonyOS 7 の独立クライアント用 SDK があるとの確認には使えない。

## 再現用プローブ

### 独立受信承認・LAN 交渉の追加検証

`scripts/huawei-transfer-probe.py` は鍵をメモリー内だけで受け取り、AES-GCM で command 7 の合成ファイル送信オファーを送る。ファイル名は `androp-independent-HHMMSS.txt`、内容は固定のテスト文 60 B。SHA-256 は `56a5e7134c90f0ddcfbfb96bd7c02c2607ed4bb2258059a06cd2b98b53acc0d3`。これは送信元の参照値であり、端末への受領を示さない。

```sh
python scripts/huawei-transfer-probe.py --peer-ip '<current phone LAN IP>' \
  --port '<freshly discovered port>' --seconds 45 --network-lan \
  --output build/huawei-research/transfer-redacted.json
```

標準 UI で受信を選択した試行では、暗号化された `user_confirm`、network response（5）、logical connection info（10）を受信。logical info（10）を直接送るだけの試行では後続応答がなく、network request（4）を先に送ることで進展した。Mac の SSID は当該プロセスから取得できなかったため空欄とし、既存 en0 の private IP のみ送信した。AP の認証情報・作成・参加の処理は持たない。後続の module 21 は受信・復号までで、ファイル本体を送る処理はまだない。

証拠は `next-offer-redacted.json`、`next-network2-redacted.json`、`next-channel4-redacted.json` と対応する非公開 UI dump。module 21 の復号は複数の framing 仮説のうち offset 24 / nonce 12 B だけが GCM タグ検証を通過した結果であり、24 B prefix の仕様確定ではない。最後の追加試行では `user_reject` が返り、追加オファーは行っていない。拒否はその試行の結果で、先の承認・LAN 交渉成功を取り消すものではない。

新しいプローブにも受信拒否・取消で終了する処理を加え、秘密値のログ除外、暗号改ざん検出、長さ上限、LAN アドレス制約をオフラインテストで確認する。受信先 IP の一致検査を追加した最終コードはオフラインで検証し、その追加後の実機再試行は行っていない。

最終確認: オフラインテスト 10 件成功、構文検査成功。Petal と nc のプロセスは終了、Mac の経路は en0、Pura の wlan0 IP は試験開始時と一致。終了時は HDC 対象が 2 台になっていたため、モデル `ADY-AL10` の対象を明示して読み返した。可視性は開始時からの「所有人可见 (10 分钟)」のまま、この追試では切替操作をしていない。状態記録は `next-final-state-redacted.json`。

### チャネル交渉の独立追試（次ステップ）

Petal 停止を維持し、同じ合成ファイル 60 B のオファーを使用した。端末の標準受信確認で `anDrop LAN Probe`・1 ファイル・60 B を確認した試行だけ承認した。端末名・識別子・暗号鍵は公開ログに出していない。

1. module 21 の payload は 24 B の auth header と nonce 12 B + AES-GCM 暗号文。header は `<IIQII`、末尾 length を厳密検査する。MetaNode JSON の `DEVICE_NAME`、`DEVICE_TYPE_ID`、`META_NODE_ID`、`FLAG` を確認。Pura は種別 14 / FLAG 100 を送った。
2. 独自クライアントは `DEVICE_NAME: anDrop LAN Probe`、`DEVICE_TYPE_ID: 12`、毎回生成する一時 ID 64 桁、FLAG 100 を応答。Pura が `META_DEVICE_INFO_ACK\0` を返し、暗号整合性を検証した。JSON には末尾 NUL がある場合もあり、最初の試行はこの処理不足で停止した。NUL 対応後に ACK まで進んだ。
3. ACK に応答した後、inner type `0xffff0004` / module 16 の CODE 3 を送信。`P2P_IP` というフィールド名だが値は既存 en0 IP、PROTOCOL_TYPE 4。返された IP が明示対象の既存 wlan0 IP と同じ場合だけ TCP 接続する。SSID・ホットスポット設定は操作しない。
4. 別 TCP 接続に module 6 / flags `0x94`、CODE 1、API 2、`IShareReceiverBytesSession` / `IShareSenderBytesSession` の開始要求を送信。制御鍵で暗号化し、別の一時 32 B セッション鍵を base64 で格納。Pura の flags `0x95`、CODE 1、API 2、MTU 4096 の ACK を検証した。
5. 元の認証接続に inner module 17 / CODE 1538 を送信。BUSINESS_TYPE を誤って 0 にした試行は CODE 6 / ERR_CODE -426115067。静的解析で 3 と確認して修正後、正常な CODE 1538、MY_CHANNEL_ID 8、MY_IP、P2P_PORT 46207、BUSINESS_TYPE 3 の応答を得た。これらのポート・channel ID は今回の値で、固定値として使わない。

成功した証拠: `build/huawei-research/phase3-meta-pc-nul-redacted.json`、`phase3-port-redacted.json`、`phase3-byte-redacted.json`、`phase3-file-business-redacted.json`。最後のファイルは正常なポート交渉応答を含むが、当時のプローブは受信後に停止する実装だったため、現行の `file_channel_acknowledged` フラグは含まない。

本体転送部分では、比較バイナリの呼び出しが `NSTACKX_DFileClient` / `NSTACKX_DFileServer` と対応することを静的に確認した。公開一次ソースは [OpenHarmony communication_t2stack](https://github.com/openharmony/communication_t2stack)（取得 commit `31448e0839d111ff99213c7de15aea6622e7c300`）。参照 checkout は ignored な `build/huawei-research/communication_t2stack`。`nstackx_core/dfile/include/nstackx_dfile_frame.h` と `core/nstackx_dfile_frame.c` に Settings / file header / data / done の構造がある。製品依存には追加していない。

この時点の DFile Settings 追試は停止した。当初「認証チャネルの最初の応答待ち」と記録したが、下記の追加計測で、開始応答後に `next_recv` を受けていたことを確認した。未完了の合成受信が端末に残っており、それを取り消すと先へ進んだ。既定ではファイル用ポート交渉で終了し、設定交換は `--dfile-settings` または `--send-fixture` 指定時だけ実行する。

この追試では本体データを一切送っていない。端末上のファイル受領・保存・ハッシュ一致、終了通知、逆方向送信、anDrop UI 統合は未完了。オフライン検証は 14 件成功（暗号整合性、末尾 NUL、フレーム長、秘密値の除外、接続先 IP の固定、DFile 長さ上限など）。

終了時の読み返しでは Pura の wlan0 IP は開始時と一致、Mac の経路は en0、Petal プロセスなし、nc プロセス 0 件。記録は `phase3-final-state-redacted.json`。端末の可視性・ネットワーク設定は変更していない。

### 追加追試: 独立 DFile 転送と受信内容一致

2026-10-17 12:18 JST の `phase4-aes128-controls-redacted.json` で、Petal プロセスなしの Mac → Pura 送信が成立した。標準の受信確認には固定の `anDrop LAN Probe` / 1ファイル / 60 B を表示し、この合成オファーだけを承認した。

- ファイル用 TCP に DFile Settings（type 8）を送り、WLAN（connection_type 2）、MTU 1472、headerEnc 1、capsCheck 876 の応答を確認。
- 制御メッセージの暗号化は headerEnc とは別に capsCheck の bit 8（0x100）を交渉する。未設定の試行で暗号化ファイルヘッダーを送ると、端末は空の確認を返して止まった。type 11 の輻輳制御は平文で、暗号認証済みの応答とは扱わない。
- DFile の AES-GCM は交渉鍵32 Bの先頭16 Bを使用する。AAD は ASCII `A` 64 B、暗号文の末尾は tag 16 B + nonce 12 B。32 B全部を使った本文送信では端末の `AesGcmDecrypt: data verify error` が出た。公開 [`nstackx_file_manager.c:SetCryptPara`](https://github.com/openharmony/communication_t2stack/blob/31448e0839d111ff99213c7de15aea6622e7c300/nstackx_core/dfile/core/nstackx_file_manager.c) と比較バイナリの `SetSessionCryptPara` を照合して修正した。
- 正しい交渉後、type 2 の確認と type 6 の完了を AES-GCM タグと内外ヘッダーの一致で検証した。ファイルID 1の確認後だけ本文を送り、本文送信前の DONE を成功とは扱わない。DONE_ACK（type 7）は空 payload。
- `androp-independent-121840.txt` が端末の `Huawei Share` 保存先に存在した。HDC でその合成ファイルだけを読み戻し、60 B、SHA-256 `56a5e7134c90f0ddcfbfb96bd7c02c2607ed4bb2258059a06cd2b98b53acc0d3` が元データと一致した。HDC は照合に使用し、端末へファイルを配置する用途には使用していない。

証拠は `phase4-content-verification-redacted.json` と `phase4-received-fixture.txt`。成功直後の再試行 `phase4-repeated-transfer-redacted.json` は暗号化された `user_reject` を受けて終了した。拒否を上書きして再試行していない。従って現時点の成功は1回で、連続送信の安定性は未証明。標準 UI の終了通知と上位制御チャネルの完了通知も未確認。

未完了時には `senderCancel` を送る後処理を追加した。送信と ACK を区別し、ACK 未受信を成功と記録しない。`next_recv` は平文の待ち状態として記録し、認証成功扱いしない。秘密鍵・セッション鍵は保存しない。`--send-fixture` は固定60 B専用。`--dfile-plain-headers` は切り分け用の明示的な実験設定であり、自動フォールバックではない（成功した試行では使用していない）。

試験開始時の可視性は UI の `selected=true` で「仅分享过的设备可见」を確認した。「所有人可见」の文言が画面内にあるだけでは選択状態を証明できないため、過去の文言だけに基づく判定を訂正する。今回は一時的に全員可視へ変更し、終了時に元の制限付き可視性の選択状態を読み返した。最終状態は `phase4-final-state-redacted.json` に記録。端末 wlan0 IP は開始時と一致、Mac の経路は en0、Petal プロセスなし、nc 0件。オフライン検証は19件成功。

次は独立実装での連続送信と標準 UI の完了処理、逆方向の受信・内容照合、Pura の共有先一覧での电脑分類を確認する。小ファイル片方向の成功を製品対応完了や双方向対応と表現しない。

### 追加追試: 連続送信と Pura 側の Mac 表示

2026-10-17 12:22–12:25 JST、Petal を停止したまま実施。

1. 可視性を一時的に全員可視へ変更し、CoAP で現在のポートを再取得。2つの新規セッションで順番に60 Bを送信し、両方で暗号化 DFile DONE を検証。端末の保存先から別々に読み戻し、どちらも60 B・元データと SHA-256 一致。途中で端末共有サービスの再起動や保留受信の手動取り消しは不要だった。証拠: `phase5-repeat1-redacted.json` / `phase5-repeat2-redacted.json` と各 `-integrity-redacted.json`。
2. 2試行とも上位の認証チャネルから追加完了メッセージは2秒以内に観測できなかった。ファイル受領は保存内容で確認済みだが、標準 UI の完了通知は未確認。任意サイズ・空ファイル・日本語名・8 MiBの独立転送は今回の試験範囲外。
3. `scripts/huawei-receiver-discovery-probe.py` を追加。既存 en0 の同一 LAN にいる明示対象だけに、合成名 `anDrop LAN Probe`、PC 種別12、一時的な受信 TCP ポートを通知する。最大60秒で終了し、受信ファイルの自動承認や保存は行わない。
4. 探索要求 mode 1 では55秒で27回通知し、CoAP応答52チャンクを得たが、共有先表示とTCP接続はなし。受信先公開 mode 10 に変更し `coapUri` を省略すると、標準共有先に `anDrop LAN Probe` が表示された。mode 10 は公開 [nstackx_struct.h](https://github.com/openharmony/communication_t2stack/blob/31448e0839d111ff99213c7de15aea6622e7c300/nstackx_util/interface/nstackx_struct.h) の `PUBLISH_MODE_PROACTIVE`。比較バイナリの生成処理 `0x1000520c8` にも mode 1 / 10 と URI 有無の分岐がある。2項目を合わせて変更した試験であり、それぞれの寄与は未分離。
5. 端末で既存の合成ファイル `androp-huawei-probe-20261017.txt`（77 B）だけが選択されていることを確認して、独自受信先を選んだ。直後に Mac の待受へ module 8 / CODE 4 / API 2 / MTU 39968 の開始要求が到着。`phase5-receiver-publish-redacted.json` に構造情報だけ保存した。受信側の応答処理は未実装のため、端末には「已失败」と表示された。これはファイル受信成功ではない。選択時刻と着信は対応するが、この試験では接続元IPを別途記録しておらず、端末の暗号学的な同一性も未確認。
6. 画面を確認し、対象のアイコンがパソコン形状で、アイコン内に `Mac` と表示されることを確認した。私用情報を含めない証拠画面は ignored な `phase5-picker-private.jpeg`。HarmonyOS PC のふりをする必要はなく、少なくともこの OS では Mac として表示できている。

終了時は可視性を「仅分享过的设备可见」に戻し、選択状態を読み返した。端末IPは不変、Mac経路はen0、Petalなし、nc 0件。`phase5-final-state-redacted.json` に記録。今回、製品本体のUI・エンジンには統合していない。オフライン検証は20件成功。次に実装するのは、受信側の認証開始応答、能力・鍵交換、合成オファーの検証、DFile受信と保存・内容照合である。長期的な相手識別、拒否・取消、同一LAN外への接続拒否も独立に検証する。

### 电脑としての宣言

ユーザーの希望に合わせ、PC としての宣言を維持する。公開 [SoftBus の device info 定義](https://github.com/openharmony/communication_dsoftbus/blob/master/interfaces/kits/lnn/lnn_device_info_struct.h) には `TYPE_PC_ID = 0x0C` があり、独立 CoAP 探索は当初からこの値（12）を送信していた。コードでは `DEVICE_TYPE_PC` として明示した。

最新の受信先公開試験では、PC 種別12と `osType:2` の組み合わせで、Pura の標準共有先にパソコンのアイコンと `Mac` が表示された。種別12だけの効果は分離していない。HarmonyOS PC の OS/モデル宣言、受信オファーと発見 ID の一貫性は別途確認が必要。「鸿蒙电脑として認識された」とは表現しない。

### BLE 発見

`scripts/huawei-share-probe.py` を追加。製品コードとは独立している。

```sh
# bleak が利用可能な Python 環境で実行
python scripts/huawei-share-probe.py --seconds 15

# macOS: 短時間の合成広告を出して検出。終了時に広告を停止する。
python scripts/huawei-share-probe.py --seconds 15 --advertise

# 明示的に保存する場合だけ、ローカル BLE endpoint ID を mode 0600 で記録
python scripts/huawei-share-probe.py --private-targets build/huawei-targets-private.json

# 現在のスキャンにも現れた指定 ID だけ、GATT 定義を列挙
python scripts/huawei-share-probe.py --connect-target '<local endpoint ID>'
```

既定の JSON 出力には端末名・アドレス・生の広告ペイロードを含めない。既定では GATT の読み取り・書き込み・購読・ペアリング・ファイル転送を行わない。`--inspect-share` を付けた場合だけ 2B00 / 2B01 の読み取りと購読を試み、値の長さのみ記録する。`--notify-only` で読み取りを省略できる。`--serve-discovery --advertise` は空の一時 GATT サービスを公開し、read / write / subscription の件数や長さだけ記録する。`--advertise` は `anDrop H Probe` という一時的な試験名を周辺に広告するが、転送サーバーは提供しない。

端末を「所有人可见 (10 分钟)」にした状態で Petal なしのプローブが候補を検出した。「不可见」にすると 12 秒間で候補 0 件だったが、その後に全員可視へ戻した 12 秒の再試験も候補 0 件だった。したがって可視性切替との厳密な因果関係、候補の完全な端末同定、発見の安定性は未確立。Petal の直前動作の残存効果や macOS の広告競合も排除できていない。CoreBluetooth の広告開始成功は、意図した全データが実際に電波へ出た証明ではない。

初回 BLE 調査後は端末の可視性を元の「仅分享过的设备可见」に戻し、説明文から反映を確認した。LAN 追試では可視性を変更していない。試験用広告と比較用 Petal は終了済み。Petal の高速伝送モードはユーザー要件に合わせて OFF のままとし、試験後にスイッチ値 0 を再確認した。

## 次の実装判断

### Petal 非依存で anDrop に統合する構成

製品の目標は **Mac の anDrop ↔ Pura の標準「华为分享」** とする。Petal は比較試験に限り、起動・インストール・Petal のライブラリ読み込みを製品の実行条件にしない。端末への独自受信アプリ追加も、この標準共有互換性の代替とは扱わない。

現行コードを確認した統合境界:

- `Sources/engine.py:Engine.scanning/discovered` は `3333` のスキャンと MTA 広告の解析に固定されている。Huawei の発見処理を別に持ち、プロトコル種別で転送処理を振り分ける必要がある。
- `Engine.send` は `9897` 読み取り、`9898` 通知、`9896` 書き込みと MTA の鍵交換・HTTPS/WebSocket を実装している。Huawei の UUID に置き換えるだけでは互換にならない。Huawei の認証、フレーム、LAN 交渉、完了確認が独立した実装範囲。
- `Sources/main.swift` の BLE peripheral は `8881` 広告と `9999` サービスに固定されている。Pura → Mac も実現するには、Huawei 側が発見・接続できる受信サービスを追加する必要がある。
- Finder 共有、メニューバー、宛先選択、受信確認、進捗・履歴、保存先は既存の UI とイベント契約を再利用する候補。Huawei 側の転送方式に合わせてファイル入出力の接続部分を設ける。

追加追試で **独自クライアントのセッション鍵交渉・標準受信承認・LAN 情報交換は成立した**。追加追試では DFile による60 B転送と端末保存内容の一致まで確認した。phase10では逆方向77 Bの受信・保存内容一致・DONE ACKも2回確認した。phase11では空ファイルの往復と日本語名8 MiBの受信、phase12では日本語名8 MiBの送信・送信途中と受信開始前の取消ACK・取消後の再転送も成立した。phase13では任意ファイルを明示指定する送信と3点の一括送受信、参照なし受信も成立した。phase14〜16で、本体の受信承認・保存・履歴への接続、共有画面を開かない探索、Mac側IDの永続化、送受信途中の取消・TCP切断からの再転送を確認した。残るのは、Puraの暗号学的な相手認証、消灯中の発見（BLEでの起床）、取消メッセージの送信、Wi-Fi自体の切断。phase18で最新の完全ビルドによる双方向3点（8 MiBを含む）の保存・内容一致まで確認した。Pura から Mac の共有先表示とPCアイコンは確認済み。本体統合と必要な検証が完了するまでは、製品に対応済み表示をしない。

完了条件は、Petal のプロセスがない状態で anDrop が双方に発見され、標準の受信確認を経て同一 LAN 上で双方向転送し、受領した内容が一致すること。その後、Petal を一度も導入していない環境でも依存がないことを検査する。

### 検証順序

1. **既存同一 LAN のみを対象にする。** SSID 切替・ホットスポット作成/参加・高速モードへのフォールバックは実装しない。同一 LAN で接続できない場合はその理由を表示する。
2. 独立プローブの発見を、可視性の切替・再起動・ロック解除・BLE ID 変更を含めて再現する。FE35 の候補を見つけただけで送信可能一覧に追加しない。phase16で、点灯中・共有画面を閉じた状態のLAN探索は成立した。消灯・ロック中は応答がなく、BLEでの起床が次の課題。
3. Huawei 用の広告解析、GATT フレーム分割、能力交渉、認証・鍵交換、LAN 経路交渉を既存 MTA/OShare と分離して実装する。WLAN handshake、能力・公開鍵・セッション鍵、受信承認、`NETWORKINFO_NEGO` の応答は追加追試で実通信を確認済み。ファイルチャネルと60 B送信・77 B受信は実証済み。相手識別の検証条件と任意ファイル転送は未確定。
4. 小ファイル・空ファイル・日本語名8 MiB・3点バッチの双方向転送と、参照なし受信、送信途中/受信開始前の取消ACK・再転送は独立プローブで実証済み。phase16で、本体での受信データ途中の取消とTCP切断からの再転送も確認した。Wi-Fi自体の切断と取消メッセージの送信は未検証。
5. その後に anDrop の送信先表示・受信承認・Downloads 保存・履歴へ統合する。BLE で発見、既存 Wi-Fi で転送、というユーザー操作を目標にする。

USB 上に独自アプリを入れてファイルを受け渡せても、それは標準の「华为分享」互換性の証明にはならない。今回、新しい端末アプリや独自証明書はインストールしていない。

## 参照

- [Huawei: Pura 70 を含む端末と iPhone/iPad/Mac の共有](https://consumer.huawei.com/cn/support/content/zh-cn16090700/) — 鸿蒙星河互联、可視性、対応 OS の公式説明。
- [Huawei: Petal Interconnect の共有手順](https://consumer.huawei.com/en/support/content/en-us16107421/) — EMUI 系の比較経路。
- [Petal Interconnect: App Store](https://apps.apple.com/in/app/petal-interconnect/id6775134178?platform=vision) — 複数プラットフォームの掲載。Mac の利用版は上記のローカル確認を優先。
- [Huawei: Share Engine Windows Codelab](https://developer.huawei.com/consumer/cn/codelab/ShareKit-Windows/) — 旧 SDK の対象・前提条件。
- [OpenHarmony DSoftBus](https://github.com/openharmony/communication_dsoftbus) — 公開通信層の構成。Huawei Share の完全な仕様ではない。
- ローカル DevEco SDK: `Contents/sdk/default/hms/ets/api/@hms.collaboration.harmonyShare.d.ts`。

非公開の一時出力は gitignore 対象の `build/huawei-research/` に保存。端末シリアル、アカウント情報、生の Bluetooth ペイロード、比較アプリのバイナリは本資料に含めていない。


## 復元写真のプレビュー受信互換性（phase33）

利用者のbuild11010診断では、Huawei → Mac、1件の受信が`ValueError / receive_preview`で失敗。同時間帯の別写真は受信completeだった。診断にプレビュー項目の形状は含まれず、復元写真が空または欠落サムネイルを送ったかは未確認。写真破損やゴミ箱復元そのものを原因と断定しない。

コード上では受信batchがtag12の非空サムネイルを必須にしていた一方、既存の通常ファイル送信はtag11/13のみを生成する不整合を確認した。この形式が修正前に`unsupported batch preview`になる回帰テストを追加。batch受信のtag12（サムネイル）とtag13（メディア日時）を省略・空値でも受け付ける。tag11の非空UTF-8・1024 B、サムネイルの60000 B×件数、日時8192 B、順序・重複・未知tagの拒否、外側フレーム上限、DFileの名前・サイズ・完全性検証は維持。固定fixtureの照合条件は変更しない。

Python全188件成功。build11010の完全bundleをコピーし、同梱の平文プロトコルモジュールとbuild番号のみ変更してbuild11011を作成。同一Developer IDで再署名し、指定要件一致、完全署名、凍結engineのHuawei self-checkを確認。旧bundleはignoredな`build/huawei-research/phase33/`へ保存。元の復元写真の再送成功は未確認で、この互換性修正による実機解決をまだ主張しない。

ローカルの`/Applications/anDrop.app`をbuild11011へ差し替え、同梱スクリプト一致とホスト・engine各1プロセスの起動を確認。診断モーダルを閉じてメニューから終了し、設定・履歴の消去は行っていない。記録は`phase33/package-redacted.json`、テスト結果は`phase33/python-tests.log`。


## 復元写真の再送失敗と診断追加（phase34）

build11011の利用者再送（report ed9229b9）も1件のHuawei受信が`ValueError / receive_preview`で失敗した。phase33の任意メディア欠落対応では当該問題は未解決。既存ログからは項目構成・名前長・サムネイル長・日時長・重複通知のどれかを判断できない。

追加の推測による上限変更はせず、失敗時の`previewIssue`を固定語彙（field_layout/name_size/thumbnail_size/metadata_size/repeated_preview）で記録する。認証済みcommand8の最後のフィールド番号とバイト数のみを`previewFields`へ記録。Python/Swift両方で32項目・tag0〜255・bytes0〜1MiBに制限し、値・名前・画像・任意の追加キーは落とす。旧ログは新しい任意項目がなくても読み込める。Python191件・Swift29件成功。診断追加版は原因採取用であり、復元写真の解決済み版とは扱わない。

ビルド中に別作業の送信側変更がbuild11012として設置されたことを確認したため、診断追加版をbuild11013へ変更。直前の設置版と他の4プロトコルモジュールが一致することを確認して保持した。正式ID・指定要件を維持し、署名とengine self-checkを検証して設置・再起動。ホスト/engine各1プロセスを確認。元写真の再送を利用者へ依頼中。証拠は`phase34/package-redacted.json`。

## 承認前アイコンの独立試験と標準経路の鍵交換（phase35）

2026-10-17 20:00–20:09 JST。利用者不在のため、一時鍵・合成ファイル名／件数／サイズだけで限定試験。ファイル本体は送らず、端末の設定・アカウント・連絡先・ペアリングを変更していない。通常HDCで端末のLAN経路と共有サービスログを読み、端末画面の承認操作は行っていない。

### 写真・動画・混在のMac互換オファー

`scripts/research/huawei_offer_classification.py`は製品と同じ`offer()`を使い、写真1件（type1）、動画1件（type3）、写真＋動画2件（type3）を別セッションで試した。3件ともApple互換経路の鍵交換後に`user_reject`が返り、プレビューの画面確認・ファイル保存には進まなかった。端末が自動的に拒否した理由は未確定。端末ロックや可視性を原因と断定しない。写真の緑アイコン復帰はこの試験では実証できていない。

### 標準経路の停止位置を一段先まで確認

phase32で止まっていた`IShareAuthSession` / protocol100は、**command192内tag193=3**を送ると`CMD_CAN_CONTINUE_CONNECT`（tag195）を返す。tag194は認証開始ではなく別ハンドラだった。実機ライブラリのハンドラ登録`0x10309c` / `0x1030a8`と`HandleAuthSendTypeCommand`（`0xc67dc`）から特定。

その後、protocol0 / tag16の一時RSA公開鍵へtag17のRSA公開鍵が返った。OAEP-SHA256（MGF1もSHA256）で暗号化したtag18（nonce16 B＋一時AES鍵32 B）へ、RSA暗号化応答tag23＋tag19が到着。tag19の48 Bを一時AES鍵・元nonceでGCM検証し、32 Bの通信鍵を得た。鍵はメモリのみ、識別子・鍵・応答本文を証拠JSONへ保存しない。

**ここで返ったtag23=0は、匿名共有の成功や認証省略を意味しない。** 同版の`HandleSenderStartVerify`は0を`The peer device refuses to share`として終了（`0xbca3c`〜`0xbcb14`）、1は証明書チェーン、2はHiChain、3は連絡先不一致へ分岐する。`HandleGetAesKey`（`0x113d84`以降）は`GetDetectableType`を参照し、条件により`IsRecentDevice` / `IsContactDeviceByAccountId`も確認する。この実装から、現在の可視性と新規の一時IDが拒否へ関係する可能性はあるが、設定を切り替えた比較試験は行っていない。

初回には0の意味を確定する前に、合成PNG付きcommand64を1回送った。端末ログは`ParsePreviewData: Can not get preview data in: 2, try later`を記録。約3秒後にtag200=`senderCancel`を送り、その後のログはstate14へ変わった。取消ACKは取得できず、接続を閉じて終了。後述のネイティブ実行でstate2/14はプレビュー解析対象外と確認した。この試験は**暗号化プレビュー通知が受信ハンドラへ達した証拠まで**で、JSONの項目解析・UI表示・受信承認・保存の成功ではない。

意味の確定後はプレビュー送信を繰り返さず、`scripts/research/huawei_standard_key_exchange.py`へ鍵交換だけを再現する処理を整理した。再現試験でも通信鍵のGCM検証成功とverifyMode=0を確認し、オファーを送らず終了。通信鍵は戻り値にも含めず、どのmodeでも`sharing_authorized=false`を維持する。受信側の共有可否・追加認証を完了するまでは、この経路を製品の送信処理へ接続しない。

### プレビュー項目と動画の代替アイコン

実機バイナリを使う`scripts/research/huawei_preview_dispatch.py`を拡張し、標準文字列dispatcherの16分岐と受信stateの5分岐を実行した。既存のApple通知513分岐・種別4分岐・132 Bの合成PNG JSONのコピー検証も成功。C++文字列操作はスタブであり、全サービス・UIのエミュレーションではない。

| 標準command64の項目 | 受信オブジェクトの格納先 | プレビューへの用途 |
| --- | --- | --- |
| 65 | +1472 | 文字列領域。ファイル名一覧と同一ではない |
| 68 | +1504 | `RecvPreview +64` / previewData、画像JSON |
| 71 / 75 | +1424 | `RecvPreview +88` / allFileNameData |
| 73 | +1608 | `RecvPreview +112` / previewInfo |
| 76 | +1528 | `RecvPreview +200` / packageInfo |
| 78 | +1632 | `RecvPreview +136` / previewExtra |
| 80 | +736 | `RecvPreview +264` / 形式集計 |

`ParsePreviewData`入口（`0xd3538`→`0x197980`）はstate10/12のみ解析し、1/2/14を延期する。ファイル名、形式レコード、画像は別項目であり、名前や拡張子だけの修正では画像が届くとは限らない。

旧UI 7.0.0.205の`CommonUtils.getFilesMixType`も追跡した。全画像は`ALL_PICTURE`、全件が画像または動画なら`PICTURE_AND_VIDEO`で、**動画だけでも後者**になる。`createFileShowInfo`はどちらも画像・動画グループへ渡し、既知の`ReceiveNormalCard`ではサムネイル欠落時に同じ緑画像アイコンを使う。`getOneFileType`の文言分類は画像・動画を区別するが、代替アイコンまで区別されるとは限らない。従って動画のUTDだけを写真から分けても動画専用の図柄になるとは主張できず、実プレビュー画像と形式情報の両方を検証する必要がある。実機UI 7.0.0.545そのものは取得できていない。

### 検証・保持した状態

- Huawei関連の98テスト成功。新規6テストは、通信鍵取得と共有拒否の分離、追加認証が必要なmode、GCM改ざん・別nonce・別鍵、重複／欠落フィールド、異常フレームを確認する。
- 設置版を読み直すと別の受信診断作業でbuild11013へ更新済みだった。同梱`huawei-transfer-probe.py`は現在のソースと一致し、写真／動画の分類修正を保持。今回、設置アプリは上書きしていない。
- 全独立プローブは終了。残るncはanDrop側の既存待受で、試験用の接続を残していない。
- 証拠はignoredな`phase35/*-redacted.json`と`dispatch-emulation.json`。端末IPを含む再接続用ファイルは同ディレクトリ内の0600ファイルのみ。

次の実通信の条件は、標準経路で正当な共有可否確認と追加認証を完了できること。その後にtag68/73/80の画像・形式情報を個別に比較する。現在の動作するMac互換転送へ未検証の標準経路や推測の動画種別を混ぜない。承認前のPDF/Word/動画専用アイコンは引き続き未解決。


## 既存anDrop ID比較と専用アイコンの構造（phase36）

2026-10-17。標準経路の鍵交換を、このMacの既存anDrop鍵でも比較した。鍵は所有者限定の既存ファイルを読み取り専用で利用し、他アプリ・アカウントのIDや証明書を借用していない。

- 既存RSA鍵のみでも、同鍵由来のMetaNode IDをtag22へ付けた場合でも、通信鍵の検証には成功するが`verifyMode=0`（共有拒否）。後者はtag24（64 B）も返す。プレビュー・本体は送っていない。一時鍵だけが拒否の原因だとは言えない。
- 標準プローブに`--identity-key`と`--send-node-id`を追加。読み込み時はsymlink、他ユーザー所有、広すぎる権限、通常ファイル以外、8 KiB超、RSA-2048以外を拒否し、既存鍵を変更・生成しない。
- Apple互換の写真オファーを既存鍵で比較した際は、認証後10秒以内に承認・拒否応答を得られず終了。取消ACKも未確認。前の一時鍵での即時拒否とは異なるが、実機の緑アイコンや受信成功の証拠ではない。
- DevEcoのScreen Mirroringでロック解除済みのホーム画面は確認できた。ただし座標操作でIDE本体へ操作先が変わり、対象通知を安定して観測できていない。端末の共有可視性設定は変更していない。
- Huawei関連99テスト成功。既存鍵の読み取りがファイルを生成・書換えしないこと、symlink・公開権限・FIFOの拒否を追加検証した。製品・設置版は今回上書きしていない。

旧UI解析の新しい根拠：`UtdThumbnail.static_initializer`（disassembly 648110行以降）にWord `83886618`、Excel `83886591`、PowerPoint `83886608`、PDF `83886607`の専用リソースがある。これは送信用サムネイル生成の定義であり、受信通知が拡張子だけで自動選択する証明ではない。`ReceiveNormalCard.isVideo`（110579行）は`thumbnails[0].utd`の型記述子が`VIDEO`に属すか調べる。動画の再生オーバーレイは`83886084`。従って画像データだけでなく、サムネイルレコードの`utd`も写真と動画の区別に必要。

利用者の依頼により、Claude Codeへ読み取り限定の解析を委譲。対象はこのリポジトリの逆アセンブルと調査コードで、鍵・個人診断・端末アドレスを含むファイルは対象外。最終的な実機表示の確認は引き続き未完了。


### Claude委譲の照合結果と未解決の境界

Claude Codeへ3回の読み取り限定タスク（経路調査、JSON/認証の再確認、注釈付き認証処理の限定レビュー）を委譲した。出力はignoredな`phase36/claude-*.json`に保持。**委譲結果をそのまま仕様とは扱わない**。初回の「Apple側には他経路が絶対にない」はレジスタ別検索だけでは証明できず、不採用。2回目の「HiChainが存在しない」は逆アセンブルから文字列本文を検索していたための誤りで、ELF由来の文字列注釈を使い訂正した。

採用できる追加根拠：

- 旧UIの`createFileShowInfo`（37972–37989行）は`mime_type`値を`getUtdBelongsToType`へ渡す。ここはHTTP MIME名を渡す欄とは限らず、UTDとして扱われる。文書の固有UTD値は未確認の推測を採用しない。
- `previewData`の画像と、`previewText`の形式・件数、動画オーバーレイ用`thumbnails[0].utd`は別情報。Officeの`83886618`等はリソースIDでありUTD値ではない。受信側へそれらの番号だけ送っても画像表示を指定したことにはならない。
- 実機版`0x11d494/0x11d498`は`HiChainVerify.cpp`、`0x11d4a8/0x11d4ac`は`AuthDevice`を参照。従来記録どおりmode2はHiChain系。`0xbce00`以降には空のaccountIDを拒否する経路がある。これはユーザーにPIN入力を求める方式の存在を証明しない。
- HiChainの認証要求にはpeerUserId等を含むが、この断片だけではMacと端末の信頼関係を新規に構築する手順は分からない。「同一アカウントさえあれば使える」とも断定しない。既存IDでのmode0拒否と合わせ、標準経路で実機プレビューを送る前提はまだ満たせていない。

次に必要なのは標準経路の正当な信頼関係の確立方法、またはMac互換経路に未発見のプレビュー更新経路があることの実証。型番号の当てずっぽうな変更や、認証未完了のcommand64再送は行わない。実機で専用アイコンが見えたという結論・製品更新は行っていない。DevEco本体は最小化試験後にFinder経由で復帰した。


## 全員公開での認証方式の変化・写真アイコン実機確認（phase37）

2026-10-17。利用者がHuawei Shareを「全員に公開」に変更したと回答した直後に、前回と同じ既存anDrop RSA鍵・MetaNode IDで標準プローブを再実行した。応答は**verifyMode=0から1へ変化**し、通信鍵GCM検証も成功。公開範囲が今回の共有拒否に関与したことを実測した。mode1は証明書確認の開始条件であり、認証完了ではない。プレビュー・ファイル本体は送っていない。証拠：`phase37/everyone-key-exchange-redacted.json`。

同じ全員公開の状態で、製品の`offer()`を使った写真1件/type1の通知を試した。利用者の「もう一度」に応じて再試行し、**受信許可前のアイコンは「緑の画像アイコン」だった**と利用者が回答した。これにより写真の通知分類は実機確認済みとなった。これは通知だけの試験であり、今回の写真保存・内容一致・動画や文書の専用表示は証明していない。`everyone-photo-retry-redacted.json`にプローブ結果と利用者の観測を分けて記録。

研究用`huawei_offer_classification.py`は10秒観測に対してncの待機が8秒だったため、接続を観測・取消期間中維持できるよう`seconds+12`へ修正。二回目は取消要求を書き込めたが、取消ACKは取得できず接続を閉じた。受信操作・ファイル本体の送信はしていない。固定語彙の停止理由も追加し、任意の例外文字列は保存しない。構文チェック成功。製品コード・設置版は変更なし。

### mode1の信頼条件

実機ライブラリの`CheckCertChainValid`は、`0x11e6f8`でルート、`0x11e704`で中間CA、`0x11e710`でチェーン、`0x11e72c`で公開鍵証明書を検証し、`0x11e754`で証明書の公開鍵とCCMPで交換した鍵を比較する。

service側`ValidRootCert`はexport wrapper`0xb78dc`→実装`0x88bc0`。新規X509 storeへ`0x88bf0/0x88c04/0x88c18`で3つの組み込みルートを追加して、`0x88c58`で入力証明書を検証する。ロード元の正確なELFアドレスで証明書を解析し、以下を確認した（`root-store-addresses.json`）：

| アドレス | ルート証明書Subject CN |
| --- | --- |
| 0x37741 | Huawei CBG Root CA |
| 0x37436 | Huawei CBG Root CA G2 |
| 0x37eb0 | Huawei CBG ECC Equipment Root CA 3 |

さらに`InitCertChainMode`はwrapper`0xb78d0`→`0x89094`、`0x891b0`で`HksAttestKey`を呼ぶ。公開ルート証明書は検証用の公開情報であり、anDrop自身の鍵に対する証明書を発行できる秘密鍵ではない。独自RSA鍵だけでこの信頼条件を満たすことは実証できていない。自己署名や他アプリの秘密鍵を使う実験はしていない。

Claude初回回答の「公開範囲だけではmode1に変わりにくい」は今回の実測と矛盾するため不採用。`0x19af30`の実際のPLT名は`DiscoverManager::GetDetectableType`であり、不明な認証mode selectorではない。`0x113d84`以降が公開範囲値を読み、その後に既知端末・連絡先の条件を加えて認証方式へ変換する。補足のPLT名と実測結果を渡して限定レビューを継続した。


### Mac互換経路の追加追跡と解釈の限界

ELFのSHT_RELRを展開し、AppleRecvSessionのvtable `0x1a0160`の+120（slot `0x1a01d8`）が`0x1745b4`を指すことを確認した。関数内のソースパスと`OnAuthBytesReceived`文字列により認証用受信コールバックと識別した。`apple-vtable-relocations.json`と`apple-bytes-target.txt`に証拠を保存。

Claudeへ限定した読み取り調査を委任したが、その回答の「この経路に追加の受信許可前プレビューはない」「Mac互換経路もHuaweiルート証明書で阻まれる」という結論は採用しない。認証の完了と利用者による受信許可は別であり、実際にMac互換経路の写真通知は独自鍵で認証後・利用者の受信許可前に表示できている。認証コールバック1個の確認だけで他のデータ通知を否定できない。標準RecvSessionV1の信頼条件をAppleRecvSessionへ流用しない。

コマンド処理本体の`0x16c6d4`はsession+1672の木を検索する。`0x16c708`で受信コマンドIDとノードのキーを比較し、該当ハンドラーを選ぶ構造であり、認証コールバックの文字列検索だけでは登録コマンドを網羅できない。追加の注釈付き範囲を保存し、受信データ側の限定レビューを続けた。

追加レビュー（`claude-command-map.json`）では`HandleAppleEcologyModuleData`の受信側`0x1711b4`→`0x1711d0`と下位コマンド側`0x16c7c4`が登録テーブル経由であることを追跡した。今回切り出した範囲にテーブル構築箇所はなく、追加の有効なプレビュー入力は確認できなかった。これは「追加入力が存在しない」の証明ではない。Claudeの表でcompetency subcommand 1–6をすべてboolとした箇所も採用しない。実際には`0x16c5c8/0x16c60c/0x16c614/0x16c61c`が文字列フィールドを設定し、bool比較は`0x16c63c/0x16c65c`の2分岐である。

残る具体的な解析点は、**受信側**session+1672のコマンド登録表の構築と各登録先の書き込み先。`0x1687ac/0x1689bc`の同じオフセットはAppleSendSessionのファイル管理であり、受信側の登録表ではない。オフセットだけの一致を根拠にクラスを混同しない。証明書認証を必要とする標準経路とは別に追跡する。

今回の到達点：写真type1の緑アイコンは実機確認済み。写真以外を写真宣言しない処理は維持。動画・PDF・Word・Excel・PowerPointの受信許可前専用表示は未解決。追加の有効入力が確認できなかったため、根拠のない種別値の実機総当たり・製品版の差し替え・追加の受信操作依頼は行っていない。研究用通知スクリプトの構文チェックは成功。全テストの再実行や新ビルドの作成は今回行っていない。

## Mac互換経路の受信コマンド登録表を再現（phase38）

2026-10-17。前回の未解決点だった登録表の構築箇所を特定した。`ShareReceiver::Init`の`0x1020c4`で2192 Bを確保し、allocation+32をAppleRecvSessionとして使う。`0x1020f4–0x10210c`で既知のvtable `0x1a0160`をallocation+32に設定するため、このコンストラクターとクラスの対応はオフセットの偶然の一致ではない。

`scripts/research/huawei_command_registry.py`を追加。phase32と同じSHA-256の実機バイナリのみ受け付け、`0x102238–0x102a34`の登録処理をUnicornで実行する。C++ map挿入・functionラッパー配列の構築・一時オブジェクト破棄をスタブにし、登録されるキーとハンドラーを読み取る。全サービスのエミュレーション、認証、通信、UIの実行ではない。結果は`phase38/registry-emulated.json`。

### 登録された主要通知

受信側オブジェクト+1736に7項目を登録する（構築呼出し`0x102960`）。各functionラッパーのvtable+48を読むと、次の対応になる。

| wire command | 実装アドレス | 処理 |
| --- | --- | --- |
| 1 | 0x16c6d4 | 下位制御命令の登録表へ分岐 |
| 2 | 0x16c530 | 能力交渉 (`HandleCompetencyNegoReq`) |
| 4 | 0x16c3cc | ネットワーク情報 (`HandleNetworkinfoNegoReq`) |
| 7 | 0x16c128 → 0x16c134 | 初期プレビュー／受信確認用メタデータ |
| 10 | 0x16beb0 | 論理接続情報 (`HandleLogicalConnectionInfo`) |
| 8 | 0x16b5e0 | 受信ファイル名・メディア日時 |
| 11 | 0x16b4a4 | 認証用OpenIdHash (`HandleCertifyInfo`)、session+920への代入 |

command10はsubcommand 1/2を内部イベント601/610へ渡す（`0x16bf40–0x16bfd4`）。command11はsubcommand1だけを扱う（`0x16b518–0x16b598`）。いずれも新しいアイコン入力ではなかった。command2は4つの文字列と2つのbool、command4はネットワーク文字列を設定する。既に全tag分岐を検証したcommand7/8以外に、新たな画像・previewInfo入力はこの登録表から見つからなかった。

オブジェクト+1664の下位制御表（木のrootは+1672）には以下の6項目が登録される。

| subcommand | 実装アドレス | 処理 |
| --- | --- | --- |
| 2 | 0x16c7ec | senderCancel |
| 10 | 0x16c8bc | 転送エラー |
| 5 | 0x16c9f8 | 受信側取消へのACK |
| 12 | 0x16caa0 | 送信側取消済み通知 |
| 13 | 0x16cb48 | 物理接続情報要求 |
| 16 | 0x16cd4c | 認証keep-alive |

オブジェクト+1760の5項目（2/4/7/8/11）は通知のフィールド処理を終えた後の処理。command7の終了処理`0x16b134`はstate10を設定し、内部イベント11を発行する。その内部イベント11は+1360の表で`0x16d758`（既に解析した`ProcessRecvPreview`）へ対応する。これで「command7の解析→終了処理→受信確認通知」の結び付きを確認できた。+1360の45件は内部イベントであり、その数字をwire commandとして直接送る根拠にはしない。

### 検証と委譲結果

- 手動で読んだ7個のvtableとエミュレーション結果が完全一致。下位制御6件、内部イベント45件、終了処理5件も抽出。
- 1 B変更したバイナリが実行前に拒否されることを確認。結果は`phase38/validation.json`。
- Claudeへの読み取り限定委譲は`phase38/claude-map.json`。キーとADRによる実装アドレスの列挙は一致した。一方、+1360を「level-one map」、+1736/+1760を「command mapではない」と分類した部分は、実際のコマンド呼び出しとエミュレーションに反するので採用しない。
- DevEcoの既存Screen MirroringをUI経由で開いて比較試験の観測準備を試したが、端末画面を取得できず、座標操作は`noWindowsAvailable`になった。メニューを閉じ、IDEの元の画面を確認。Petalは起動せず、新しい通知・ファイル送信はしていない。

### 結論と残る境界

これまでの「対応表が分からない」は解消した。確認したコンストラクターに登録される7通知・6制御命令に、未使用のアイコン画像通知は見つからない。写真の緑アイコンはtype1による既定表示で、PDF/Office/動画用プレビュー画像を指定できた証拠ではない。従って、現在のMac互換送信へ推測のMIME/tagを追加する変更には進まない。

専用アイコンの実現は未完了。次に有効なのは、標準経路でanDrop自身の鍵を正当に認証する手段の確立、または純正Petal→同じ端末の承認前表示で専用アイコンが出る実例と、その送信構造の比較。今回の表はコンストラクター時点の登録を証明するもので、別のセッション実装・更新版・後からの登録変更が絶対に存在しないという証明ではない。製品コード・設置版は変更していない。

## 大容量のMac→Huawei送信（2026-10-17）

利用者の送信失敗画面にあった1ファイル8 MiB・合計16 MiBの制限を、送信のみ1ファイル4 GiB・合計16 GiB（16件まで）へ拡張。受信側の8 MiB/16 MiB制限は維持した。

- 送信元は1 MiBずつ読み出して専用の一時ディレクトリへスナップショットを作成し、ワーカーは1422 Bずつ暗号化送信する。ファイル全体をbytesへ展開しない。通常ファイル・名前衝突・サイズ・コピー中の変更を検査し、準備中の取消ではコピー終了を待って一時ディレクトリを片付ける。
- DATAのsequenceにあった実験用16384未満の制限を、既存のワイヤー形式`uint32_t`の範囲へ変更。ローカルに取得済みのOpenHarmony `nstackx_dfile_frame.h`でも`blockSequence`は32 bit、ファイルサイズは64 bit。
- 60秒は転送全体ではなく書き込みが停止した時間の上限とし、別の認証・プレビューチャネルが大きなファイルの転送中に無通信で切れることも避ける。送信中もACKを読み、ncのstdoutが満杯になって双方向に詰まることを防止する。進捗はファイル単位でなくDATA送信途中でも更新する。
- 64 MiBのローカルsocketpairでAES-GCMの全チャンクとSHA-256を照合。32 bit sequence、128件を超えるACK、分割されたフレームヘッダー、転送全体が60秒を超える模擬時計でも完了し、Pythonの追跡メモリが16 MiB未満であることを検査した。32 MiBのディスクスナップショットも追跡メモリ8 MiB未満。
- 4 GiB超・合計16 GiB超は疎ファイルで事前拒否を検査。コピー前のサイズ確認、準備中の取消、元ファイル変更後のスナップショット独立性、変更されたスナップショットの拒否も検査した。Python 209件、Swift 29件が通過。

この追加検証はローカルの暗号化プロトコルと保存内容の検証であり、Pura 70での64 MiBやGiB級ファイルの受領を証明するものではない。大容量の実機保存・内容照合は未実施。既存の小容量実機結果を大容量の保証へ拡張しない。
