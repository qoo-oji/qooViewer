# 12. 検証とデバッグの方法

このアプリの単体テスト(`qooViewerTests`)は、UI を伴わない `nonisolated` のパイプライン ――
拡張子の判定・並び順、書庫の読み取りから `BookLoader` → `PageRef` まで、EPUB / PDF の構造解決 ――
を、小さな本のフィクスチャで通すものです(→ [02](02-project-and-build.md#テストターゲットqooviewertests))。
golden は `PageRef.sortKey` の列で、DB の pageKey がここに乗っています。画面まわりはテストで
押さえていません。そのぶん、次のような「実物を動かして測る」やり方を積み重ねてきました。
仕組みを変えるときは、同じやり方で前後を比べてください。

## 基本

- Xcode で `Cmd+R`。ビルドだけなら `xcodebuild -project qooViewer.xcodeproj -scheme qooViewer
  -configuration Debug build`、単体テストは同じ行の末尾を `-destination 'platform=macOS' test` に。
- SwiftLint / SwiftFormat の設定はありません。
- コミット前に `scripts/ci/check-all.sh` を走らせます(タグを打つ前は `scripts/ci/check-all.sh v1.42`
  のようにタグ名を渡すと、`MARKETING_VERSION` と CHANGELOG の見出しも照合します)。CI の `check.yml`
  が走らせるのと同じスクリプトです(→ [02](02-project-and-build.md#ci))。
- ビルドすると `Localizable.xcstrings` に差分が出ます。戻さずコミットします。
- 統合ログは `/usr/bin/log`(zsh の `log` ビルトインに注意)。`NSLog` した保存失敗
  (`lastSaveErrorMessage`)は Console.app で追えます。
- 「ハング」に見えるものは、Xcode から起動していると例外で止まっているだけのことがあります
  (`_crashOnException:`)。`sample` で確かめる。

## 再現を先に、仮説は後

報告時点の状態(どの本・どの設定・どの操作)を自分の記録から特定し、同じ条件で再現・一致を
確認してから修正を試します。発生しない条件での結果は判定に使いません。報告者の環境で再現しない
プラットフォーム起因の不具合は、堅牢な側の実装へ倒します(`RemappableKey.from(nsEvent:)` は
その例)。

## プラットフォーム API は実測より検索が先

AppKit / SwiftUI の挙動が不明なら、probe を書く前に既存の報告を検索します。「できない」と言う前に
選択肢を列挙して実測し、公式の手段が無いと分かったら非公式な回避策を自分の判断で試し始めず、
報告して止まります(`Settings` シーンのリサイズ、`.confirmationDialog` のボタン数、`ScrollGeometry`
の可動範囲は、この手順で結論が出たもの)。

## SwiftUI の最小再現ハーネス

AppKit のブートストラップ(`NSApplication` + `NSHostingView`)で SwiftUI のビューを直接実行する
小さなプログラムを、scratchpad に作って測ります。`LazyCellImageBudget` の設計(300 セルで
170 個生存、`onDisappear` で nil を書いても解放されない、`.id(epoch)` だけが効く)は、この
ハーネスでの実測から決まりました。

## 実物のアプリを外から操作する

- `open -a` でコンテナの `defaults` を書いてから起動し、シークレットモードで検証する。
  **ファイル選択ダイアログは自動操作しない**(サンドボックスの権限付与を伴うため)。
- System Events(アクセシビリティ)でメニューやボタンを叩き、`screencapture -R` で見た目を自分の
  目で確かめる。Dock からの再オープンは Dock タイルを AX でクリック、一瞬だけ出るウインドウは
  `CGWindowListCopyWindowInfo` で監視する。
- 検証を始める前にウインドウの位置・サイズと「隠す」系の設定のスナップショットを取り、
  終わったら元へ戻す。
- GUI の挙動は、推測で2回外したらコンテナ内にログを仕込んで自分で読む。

## メモリの測り方

- 数字は `task_vm_info.phys_footprint`(`ProcessResourceSampler` と同じ)。`vmmap` で内訳。
- 分かっていること: CGImage の表示は元の約3倍、malloc の大ブロックは解放しても footprint が
  戻らない(mmap は戻る)、ImageIO のサムネイルは purgeable。
- リソースモニタ(サイドパネル)は、このアプリに組み込まれた計測器です。「説明のつかないメモリ」
  (footprint − 意図して確保しているキャッシュ)が増えていないか、異常の欄が空か、を見ます。

## 描画経路の測り方

`NSHostingView` のレイヤーツリーを実測して、SwiftUI の補間設定が CALayer のどのフィルタに
対応するかを確かめました(`.medium` = `.low` = linear)。遅延デコードの直描きが最速でした。

## メニュー再構築の現行犯逮捕

macOS 26 でメニューが落ちる問題では、(1) `NSMenu` の変異(`setItemArray:`)をログに出す、
(2) 各 `@Published` の publish にプローブを仕込む、(3) 人工的な遅延を入れて「メニューを開いている
最中に publish が届く」状況を再現する、の3つで「App 直下の `@StateObject` の publish は全メニューを
作り直す」ことを突き止めました。`MenuBarMenuGate` と `AppStores`(publish しない箱)はその結果です。

## 7z のアクセス順を変えたとき

フォーク側の `sevenzip-bench`(`swift build -c release` → `.build/release/sevenzip-bench archive.7z
シナリオ`)と、`7zz` で作った scratchpad の複製で測ります。footprint は1プロセス1シナリオ。
qooViewer 側では**「ブロック先頭からのやり直し回数」**(`Archive.folderStreamRestartCount`)を
数えてください。前後交互のアクセスは禁物です(→ [11](11-forked-dependencies.md))。

## 書き出しの検証

- 実物の Exporter(`EpubExporter` / `PDFExporter` / `CbzExporter` は nonisolated で UI に依存しない)
  を SwiftPM のコマンドラインツールへ取り込めば、CLI から動かして出力を検証できます。
- EPUB は Kindle Previewer 3 の CLI と、同梱の JRE + EPUBCheck で検査します(`dc:language` の
  `und` と `group-position` の非数値は、この検査で見つかった)。
- 生成物は `unzip -l`、`xmllint`、`qpdf --check` などで中身を確認します。

## 用語と形を揃える

UI の文言は用語表(→ [01](01-overview.md#用語表))、一覧ウインドウは共通の形
(→ [09](09-ui-and-windows.md#一覧ウインドウの共通の形))に照らして確認します。
すりガラスの面に文字を足したら「ライト外観+黒 100%」「ダーク外観+白 100%」で見ます。

## git の扱い

コミット・プッシュ・履歴の書き換えは、その変更について明示的に指示があるときだけ行います。
方法が複数あるときは選んでもらいます。
