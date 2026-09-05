# 05. ページ画像の表示とメモリ

## PageLoader(actor)

1冊につき1つ。責務は次のとおりで、**actor の隔離境界を壊さない**ことが最重要です。

- 書庫の reader と `CGPDFDocument` を actor の中に閉じ込める(スレッドセーフでないため)。
- デコード(`ImageDecoder`)は CPU 負荷が高いので actor の**外**の `Task` で行う。actor を
  ブロックすると他のページの要求が全部待たされる。
- 同じページへの同時要求は1つにまとめる(in-flight の辞書)。
- 同時デコード数を絞る: フル画像 2、サムネイルは CPU コア数。表示の要求は先読みより先に
  割り込む。
- 結果は3つの `PagePixelCache` へ入れる(ページ画像/進捗バー用サムネイル 240px/グリッド用
  サムネイル)。ページ画像の上限は環境設定(既定 300MB、1冊あたり)、件数上限 64。
- 現在ページの前後(環境設定「先読み」、既定 3)を先読みし、進行方向を優先する。速い
  ページ送りで不要になった先読みはキャンセルする。
- `releaseAllResources()` で全部を手放し、以後の要求を空振りにする(`isReleased`)。

## ImageDecoder ―― 解像度の上限

| 用途 | 長辺の上限 | 備考 |
|---|---|---|
| ページ表示 | 4096px | 表示に十分。それ以上は高解像度ソースへ |
| 進捗バー用サムネイル | 240px | ディスクキャッシュの対象 |
| グリッド用サムネイル | セル高さ×画面倍率を 120px 刻みで量子化、240〜720px | ぼやけ対策と再デコードの抑制 |
| ホバーの拡大プレビュー | 枠(440〜800pt)×最大の画面倍率 | 以前は原寸(最大 47MB/枚)を使っていた |
| 高解像度ソース(拡大鏡・ピンチ拡大) | 8000px | 必要なときだけ取得し、不要になったら捨てる |
| 書き出し | 20000px | 実質無制限 |

`kCGImageSourceShouldCache: false` で ImageIO のキャッシュを使いません(こちらで管理する)。

## PagePixelBuffer ―― なぜ CGImage を持たないのか

実測(→ [12](12-verification-and-debugging.md))で分かったこと:

- CGImage をそのまま表示すると、表示したページに CoreAnimation のテクスチャと CG のラスタコピーが
  付いて回り、**元の約3倍**のメモリになる。キャッシュ上限 300MB のつもりが 900MB 近くに膨らんでいた。
- malloc で確保した大きなブロックは、解放しても footprint が戻らないことがある。mmap/munmap なら戻る。
- ImageIO のサムネイルは purgeable。

そこで、キャッシュが持つのは **mmap 裏打ちの `NSData`(BGRA 8bit、またはグレー 8bit)**にし、
表示のたびに `CGDataProvider` で包んだ使い捨ての `CGImage` を作ります(`makeImage()`)。
CGImage が生きている限りバッファも生きるので、`ViewerViewModel.releaseResources` は
`currentImages` / `highResolutionSourceImages` / `loupeCombinedSourceImage` を明示的に空にします。
`LazyCellImageBudget`(下記)が要るのも同じ理由です。

`PagePixelCache` は **厳密な LRU**(NSCache は上限を守らない・追い出しの順が読めないため置き換えた)。
バイト上限と件数上限を持ち、メモリ逼迫の通知で刈り込みます。1枚が上限より大きい場合はその1枚だけ
残す仕様なので、リソースモニタの異常判定は3秒連続で超えたときだけ鳴らします。

## 見開きの高解像度ソース

拡大鏡とピンチ拡大は 8000px 上限のソースを共有します。「拡大していない ⇄ 拡大している」を
またいだときだけ取得・破棄を切り替え(`updateHighResolutionSourceIfNeeded`)、ページが変わったら
古い結果を捨てます。**見開きを1枚に結合した画像(最大 16000×8000×4 ≒ 512MB)は拡大鏡が ON の
間だけ**作ります(以前は無条件に作っていて、瞬間的に 1GB 近くになっていた)。

## 先読みと表示の順序

`ViewerViewModel.loadCurrentSpread` が世代番号で古い結果を捨て、`PageLoader.prefetch(around:
radius:displayedPageCount:direction:)` に「表示中の2ページの前後 radius 枚ずつ、進行方向優先」で
先読みさせます。素早い連続ページ送りでは `pageFlipQueue` に目的地を積み、通過ページを 10ms ずつ
実際に見せながら進みます(通過中は先読みしない。着地したページだけ本来のペア判定+先読み)。
アニメーションのループは世代番号で中断できるようにしてあります(以前、目的地を追い越す形で
`currentIndex` が外から書き換わると無限ループになった)。

## サムネイルの3段階

1. **進捗バー用(240px)**: プログレスバーのフィルムストリップとサイドパネルのページモード、
   編集ウインドウの行。`ThumbnailDiskCache`(既定 OFF、上限 200MB、`trimThreshold` の余裕付き)に
   載る。既定を OFF にしたのは、黙って数百 MB 使っていたことへの報告から。OFF のあいだは
   溜まっているものも削除する。
2. **グリッド用**: ページ一覧パネルのセル。セルの大きさに合わせた解像度。
3. **ホバー拡大プレビュー**: 4箇所(ページ一覧・サイドパネル・編集ウインドウ・書き出しウインドウ)
   共通の大きさと遅延。ディスクキャッシュには載せない。

本を開いた直後の下調べ(`warmUpWideImageCacheForEntireBook` → `PageLoader.scanPage`)は、寸法の
取得と**サムネイル生成を同時に**行います(飛ばすと近傍だけサムネイルが無い状態になる)。

## ソリッド 7z の読み方

7-Zip の既定はソリッド圧縮で、1ブロック=1本の LZMA ストリームです。フォーク
(→ [11](11-forked-dependencies.md))は前方へは無料で進めますが、後方は辞書(16〜64MB)の範囲を
超えるとブロック先頭からの伸長し直しになります。qooViewer 側の約束事:

1. 下調べは専用の reader で**書庫順**(現在位置→末尾、次に先頭→現在位置の手前)。前後交互は禁物
   (実測: 250MB・100 ページの cb7 で 275 秒 → 10 秒)。
2. 寸法は構造キャッシュへ永続化し、2回目以降は書庫に触らない。
3. 先読みは進行方向だけ。
4. ヘッダー情報は表示のために読んだバイト列から。
5. 「後方」の基準はデコーダの位置。

`residentDecompressionBufferBytes`(辞書+バッファ)はリソースモニタに「7z デコーダ」として出ます。
アクセス順を変えたら「ブロック先頭からのやり直し回数」を数えてください。

## コントラスト補正

本単位の設定(`BookLayoutSettings.contrastCorrectionEnabled`、既定 OFF)。`ContrastCorrector` が
デコード直後にチャンネルごとのオートレベル(黒点・白点を求めて引き伸ばす)を掛け、紙の黄ばみ
(青チャンネルの白点だけ低い)も同時に取ります。**カラーと判定したページには手を加えない**
(ユーザー要望)。ON/OFF はキャッシュを消して再デコードします。

## 拡大鏡(ルーペ)と GPU

`LoupeOverlayView` はマウス移動のたびに再描画が要るため、SwiftUI の `@State` を経由しない
生の `NSView`(`LoupeNSView`)で描きます(プログレスバーで「マウス移動のたびに `@State` を
更新するとメインスレッドが詰まる」を経験したため)。レンズの中の拡大は `GPUImageUpscaler`
(Core Image)で、画面のごく一部だけを対象にすれば Lanczos でも毎フレーム間に合います。
`CIContext` は生成が高いので1つを使い回します。

## 描画の実測から決めたこと

- SwiftUI の `Image.interpolation` は CALayer のフィルタに対応し、`.high` = `box`(面積平均)、
  `.medium` と `.low` はどちらも `linear`(同じ)。だから設定は「高品質/標準」の2択。
- ImageIO の縮小は `CG.high` 相当。
- 遅延デコードの直描きが最速。

## LazyCellImageBudget

SwiftUI の Lazy コンテナ(`LazyVStack` / `LazyVGrid` / `List`)は、画面外へ流れたセルの `@State` と
body の出力を破棄しません(300 セルで 170 個が生存)。`onDisappear` で nil を書いても、親を再描画
しても、`List` に替えても解放されないことを個別に確認しました。**唯一効いたのがコンテナに
`.id(epoch)` を付けて作り直すこと**で、Lazy コンテナならスクロール位置もずれません。
`LazyCellImageBudget` はセルが保持した画像のバイト数を数え、予算を超えたら `epoch` を進めます
(ページ一覧・サイドパネルのページモード・編集ウインドウの右ペインが使う。`List` だけは位置が
先頭へ戻るので、自前で控えて復元する)。

## リソースモニタと異常検出

サイドパネルの「リソース」モードは、v1.29 で直した種類の過剰消費(設定を無視してメモリが膨らむ・
一時ファイルが残る)が再発したときに、ユーザーがひと目で気づけるようにするためのものです。

- `ProcessResourceSampler`: `proc_pid_rusage`(自分宛てならサンドボックスで可)で CPU・
  メモリ(phys_footprint)・ディスク I/O を1秒ごとに計測。2分(1秒刻み)と1時間(10秒平均)の履歴。
  ネットワーク量と DB のメモリは公開 API では測れない。
- `ResourceMonitorSnapshot`: `PageLoader.cacheStatistics()` から、3つのキャッシュの使用量、
  入れ子書庫(メモリ/一時ファイル)、7z デコーダ、常駐ページの帯(前方は「既読」として分けて
  見せる)を組み立てる値型。
- `StorageUsageScanner`: コンテナのディスク使用量(サムネイル・構造キャッシュ・一時ファイル・
  DB)。シンボリックリンクは辿らない。15秒ごと。
- `ResourceAnomalyDetector`: 誤報を出さない設計。メモリの上限超過は3秒連続、先読みは「残留」では
  なく「走っているタスク」で見る、ディスクキャッシュは刈り込みの余裕を足した値を境目、孤児の
  一時ファイルは走査2回(30秒)連続。
- 再描画コスト: 節ごとに `Equatable` な子ビューへ分け `.equatable()` で、毎秒描き直すのは
  グラフの節だけにしてある(以前はパネル全体の再描画で CPU 3〜5%)。

## 解放の連鎖(まとめ)

| きっかけ | 呼ぶもの |
|---|---|
| `ViewerView.onDisappear`、ウインドウの `willClose` | `ViewerViewModel.releaseResources()` → `PageLoader.releaseAllResources()`、表示中画像の破棄 |
| 編集ウインドウの右ペインの切替 | `BookLayoutEditorViewModel.releaseResources()` |
| 本を閉じる/切り替える | `BookContentsBrowserState.releaseResources()`(入れ子書庫の一時ファイル) |
| 本を閉じる | `ViewerViewModel.flushPendingSave()`(読書位置の保留分を確定) |
| Lazy コンテナの予算超過 | `LazyCellImageBudget.epoch` を進めてコンテナを作り直す |
