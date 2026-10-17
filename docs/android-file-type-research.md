# Android / OPPO受信通知のファイル種類宣言

調査日: 2026-10-17 JST。対象: 調査時点のanDrop作業ツリーと、既存のローカルOShare逆コンパイル資料（17.2.36として記録されている版）。以下は変更前の静的調査記録。後続の実装状況は末尾に記載。他社Androidの表示は未確認。

## 結論

**Mac→OPPOでは種類を宣言できる。ただし承認前の通知はBLE初期要求の暗号化された `type` を使う。後段のWebSocket `sendRequest.mimeType` だけを変えても、最初の通知は直らない。** この段階の見落としによりbuild11015は利用者のPDF再試験で表示改善に失敗した。後述のBLE修正を参照。

添付スクリーンショットの「？」アイコンは、この `file/*` が不明アイコンへ進む実装と整合する。ただし、その送信の実際のペイロードは採取していないため、当該通知の原因を実機で確定したわけではない。

## anDrop側

- `Sources/engine.py` の `Engine.send` は `sendRequest` に `fileName`、`fileCount`、`totalSize`、`mimeType` などを載せる。
- 現在の指定は `'mimeType':'file/*'` 固定。
- `fileName` には元の先頭ファイル名を渡しているが、下記のOPPO確認カード経路では、その名前から拡張子を自動補完しない。
- `/download` の HTTP `Content-Type: application/zip` は転送用ZIPの型。通知用 `sendRequest.mimeType` は中身の分類なので、両者は別。通知修正のためにHTTPヘッダーを画像やPDFへ変更しない。
- 現行のバージョン交渉はversion 1。

## OPPO側で追跡した経路

ローカル解析ルート: `work/oshare-source/sources/`。ベンダーコードやAPKはこのリポジトリへコピーしていない。

| 段階 | シンボルと確認事項 |
| --- | --- |
| 要求の読み込み | `eb.d.i` はJSONの `mimeType` を保持し、`f()` で返す。`thumbnail` と寸法のフィールドも存在する |
| LAN受信 | `fa.g.s0` は `sendRequest` を `eb.d` に読み込む |
| 確認カードへ引き渡し | `fa.g.E0/G0` → `ConfirmSeedlingCard.F0` → `C0`。ファイル名とMIMEを渡すが、明示的な拡張子・プレビューURIは渡していない |
| アイコンの決定 | `ConfirmSeedlingCard.b.g` は、URIがなければ明示的拡張子、さらにその指定がなければ `h0.a(mimeType)` の対応表を使い、`FilePreviewSrcUtils.a` へ渡す |
| カードへの反映 | `ConfirmSeedlingCard` の `startSeedling` 処理が `b.g()` の結果を `previewSrc` として採用する |
| メディア分類 | `h0.m/h/o` が `image/`・`audio/`・`video/` の前方一致で判定する |
| 文書・アーカイブ分類 | `h0` のMIME→拡張子表と `FilePreviewSrcUtils` の拡張子→アイコン規則でPDF、Word、PowerPoint、ZIPなどを選ぶ |
| フォールバック | `file/*` は上記に一致せず `images.preview_unknow` へ進む |

このLAN経路では、単に元ファイル名を `.pdf` にしても、確認カードのアイコン判定にその拡張子は渡らない。`application/pdf` を宣言することに意味がある。

## 宣言値と静的に確認できたアイコン

以下は解析コード上の選択結果であり、変更版anDropからの実機表示成功を意味しない。

| 内容 | 宣言するMIMEの例 | 選択されるアイコン |
| --- | --- | --- |
| JPEG / PNG | `image/jpeg` / `image/png` | 画像 |
| 動画 | `video/mp4` | 動画 |
| 音声 | `audio/mpeg` | 音声 |
| PDF | `application/pdf` | PDF |
| テキスト | `text/plain` | TXT |
| Word | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` | Word |
| Excel | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | Excel |
| PowerPoint | `application/vnd.openxmlformats-officedocument.presentationml.presentation` | PowerPoint |
| ZIPファイル自体の共有 | `application/zip` | ZIP |
| 分類不能・混在 | 現行互換の `file/*` | 不明 |

画像は `image/*` でも画像分類に入る。PDFや文書を一律 `text/*` に丸めると、具体的な拡張子への変換情報を失うため、専用アイコン目的には具体的MIMEが適している。

注意点:

- 種類アイコンと写真そのもののサムネイルは別。`thumbnail` の存在は確認したが、今回追跡した `fa.g.E0/G0` の確認カード呼び出しにはプレビューURIを渡していない。フィールドを追加するだけで写真プレビューが出るとは断定できない。
- `eb.d.i` の画像・動画個数の追加処理はprotocol version 4以降の分岐にあり、`image/*` / `video/*` の完全一致や `vision/*` + `number` の形式を使う。現行version 1で混在画像・動画の個数表示まで正しくなるとは仮定しない。
- 古いExcel用 `application/vnd.ms-excel` は、この版の対応表では `.xls`（先頭ドット付き）になるが、アイコン規則は `xls` を要求する。この組み合わせは専用アイコンにならない可能性がある。MIMEを偽る回避策は採らない。
- Android一般のアプリ間共有でも具体的なMIME指定が推奨されるが、Android IntentとOShareのネットワークプロトコルは別。上記の可否はAndroid一般論ではなく、OShareの該当経路を根拠にした。[Android公式: Send data to other apps](https://developer.android.com/develop/ui/compose/sharing/send)

## 実装する場合の範囲と検証

1. 単一ファイルは拡張子やmacOSの型情報から実際のMIMEを求め、`sendRequest.mimeType` に設定する。
2. 複数ファイルは、全件同一MIMEならそのMIME、全件画像・音声・動画の同一分類なら対応するワイルドカード、異種混在・不明なら現行 `file/*` を使う。先頭ファイルの種類だけで全体を宣言しない。
3. 転送用ZIP、HTTPヘッダー、保存名、受信承認の仕組みはそのまま保つ。
4. 合成のJPEG・PDF・TXT・ZIP・同種複数・異種混在で、送信要求の値、承認前のアイコンと文言、受信完了、保存先と内容一致を別々に確認する。動画は個数表示も確認する。

調査として確定したのは「種類宣言のフィールドがあり、OPPO側の通知アイコンまで利用される」という点。実装・設置版の更新・実機での表示改善は未実施。

## アプリへの反映（2026-10-17）

利用者の実装依頼に基づき、`Sources/file_types.py` に拡張子からのMIME分類を追加し、`Engine.send` の `sendRequest.mimeType` へ接続した。単一または全件同一MIMEは具体的な型、異なる画像形式同士などは `image/*`・`audio/*`・`video/*`、異種混在と不明形式は `file/*` を送る。圧縮済みファイルを中身の型として宣言しない。ファイル名やバイト列は変更しない。

分類テストとTLS/WebSocket送信統合テストで、PDF・JPEG・複数画像・画像/PDF混在の宣言、元のファイル名・件数・サイズ、HTTP ZIP型、展開後の全内容一致を確認。Python全202件成功。統合テストのBLE相手は模擬実装であり、OPPOの実機アイコン・文言・保存先は別途確認が必要。

完全ビルドしたローカル版1.1.1/build11015を `/Applications/anDrop.app` へ設置して再起動。既存の署名要件・アプリID・更新設定を維持し、旧build11014のバンドルを `build/android-mime-install/anDrop-before-install.app` に退避した。完全署名、macOS 14向けランタイム検査、凍結engine自己検査、設置済みengine内の分類モジュールとPDF/混在の判定、ホストとengineの起動を確認。再起動後のステータスは探索イベント・広告ON・エラーなし。テストログと設置検証記録は `build/android-mime-install/` に保存。公開リリースは行っていない。

## build11015で表示が変わらなかった原因と修正

利用者がPDFの承認前アイコンに変化がないと報告。設置版・実行中のバンドルを再確認しbuild11015と一致したが、`Engine.send` のBLE初期要求は暗号化 `type='file/*'` のままだった。

OShare `com.oplus.oshare.ble.impl.w.e` の初期要求処理は `type` を復号して保存し、`A()` → `B()` → `ConfirmSeedlingCard.C0` → `R0(..., false)` で承認前カードを表示する。この時点ではWebSocketはまだ接続していない。最初の調査が追った `fa.g` は後段であり、承認前表示の根拠としては不十分だった。

MIMEを一度計算し、BLEの暗号化 `type` とWebSocketの `mimeType` の両方に同じ値を設定するよう修正。統合テストにもBLE要求の復号検査を追加し、受信者が拒否してWebSocketまで進まない場合にもPDFの型が届くことを検証する。

修正版1.1.1/build11016を同一署名要件・IDで完全ビルド、設置、再起動した。旧版は `build/android-mime-fix/anDrop-before-install.app` へ退避。Python203件は再実行で全成功。初回は変更範囲外のHuawei広告テストがランダムトークン内の `0xff` をペイロード境界と誤認して失敗したため、当該テスト群と全体を再確認した（そのテストコードは変更していない）。署名・ランタイム検査・engine自己検査・ホスト/engineの起動も成功。

設置済みアプリへFinder共有から合成PDF `androp-oppo-mime-check.pdf`（618 bytes）を渡し、OPPOスマートフォンを選んで実機送信した。転送状態は2026-10-17 21:08:23 JSTに `complete`。利用者から「うまくいった」と表示改善の確認を得た。表示成功は利用者確認に基づく。今回、端末上の保存内容の独立ハッシュ照合や他形式の実機表示確認は行っていない。記録は `build/android-mime-fix/`。
