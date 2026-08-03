# qooViewer

macOS向けの漫画ビューアアプリです。フォルダ、zip/cbz、rar/cbr、7z/cb7、PDF、EPUB(固定レイアウトの画像ベースのコミックEPUBのみ)に対応しています。
cooViewer (https://github.com/coo-ona/cooViewer) を参考に、その操作性・機能を元に作られています。 素晴らしいアプリを公開してくださった作者の coo-ona 氏に感謝します。

## 対応環境

macOS 15 (Sequoia) 以降

## できること

- フォルダ / zip・cbz / rar・cbr / 7z・cb7 / PDF / EPUB(固定レイアウトの画像ベースのコミックEPUBのみ)に対応
- 対応する画像フォーマット(フォルダ・アーカイブ内): JPEG(jpg/jpeg) / PNG / GIF / BMP / WebP / HEIC / TIFF(tif/tiff) / AVIF
- 見開き表示 / 単ページ表示の切り替え、横長画像の自動単ページ化
- 右開き(日本式) / 左開き(欧米式)の切り替え。EPUBがpage-progression-direction等で読み方向・
  見開き/単ページ・ページの見開き内配置を指定している場合は、それを優先して自動反映し、
  競合する設定項目は無効化(グレーアウト)する
- 表示モード切り替え(画面内に収める / 横幅に合わせる / 拡大縮小しない)
- キーボード・マウスホイール・画面クリックでのページ送り(キー/マウスの割り当ては環境設定でカスタマイズ可能、1つの操作に複数キーを割り当て可能)
- トラックパッドの「ページ間をスワイプ」フリック操作に対応
- 画面下部のプログレスバーでのページ移動、ホバーでのサムネイルプレビュー
- フルスクリーン表示中はツールバー/プログレスバーを自動的に隠し、カーソルを近づけると半透明で再表示
- ページ一覧(サムネイルグリッド)画面
- ブックマーク機能(追加・一覧・名前変更・削除・次/前のブックマークへジャンプ・一括リネーム)
- お気に入り機能(本をフォルダ階層で整理して登録・管理。メニューバー/ツールバー/右クリックメニュー/
  キーボードショートカットから登録、ホバーでサブフォルダが展開する一覧、専用の編集ウインドウで
  フォルダ作成・リネーム・削除・ドラッグ&ドロップ移動)
- ページレイアウト機能(本ごと・ページごとに読み方向、見開き/単ページ表示、ページ順序、
  ページの除外を指定可能。メニューバー「Layout」・右クリックメニュー・ツールバーの自動レイアウト
  ボタンから操作でき、変更の適用範囲(このページだけ/これ以降/本全体など)を選べる)
- 「ブックマーク・レイアウトの編集」ウインドウ(本を開いていなくても、すべての本のブックマーク・
  ページレイアウト設定を横断的に一覧・検索・絞り込み・編集。ページの並べ替え・除外、サムネイル
  プレビューにも対応)
- お気に入り・ブックマーク・ページレイアウト設定をJSONファイルとして書き出し/読み込みできる
  ライブラリデータのインポート・エクスポート機能
- 選択した本をEPUB形式で書き出す機能(カバー画像を本のページから選び直す、または本に含まれない
  画像ファイルを専用カバーとして追加することも可能)
- ウェルカム画面に「最近開いたファイル」「最近お気に入りに追加したファイル」を各最大10件表示
  (それぞれ個別にON/OFF可能)
- スライドショー(自動ページめくり)
- 実寸表示ウインドウ
- 同じフォルダ内の前/次の本への移動
- 複数ウインドウ・複数タブ対応
- 本ごとの続きから再開(表示モード・読み方向・スクロール位置を自動保存)
- zip/cbz 内ファイル名の文字コード自動判定(古い日本語zipの文字化け対策)
- 表示言語の切り替え(日本語 / English / システムに従う)

## 使い方

各機能の詳しい使い方は [MANUAL.md](./MANUAL.md) を参照してください。

## 変更履歴

[CHANGELOG.md](./CHANGELOG.md) を参照してください。

## 依存ライブラリ

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)(MIT License)
- [SevenZip.swift](https://github.com/mtgto/SevenZip.swift)(MIT License)
- [Unrar.swift](https://github.com/mtgto/Unrar.swift)(内部でRARLAB提供のunrarライブラリを使用)
- [UniversalCharsetDetection](https://github.com/fumoboy007/UniversalCharsetDetection)(MIT License、内部でMozilla由来のuchardetを使用)

## ビルド方法

### 前提

- Xcode(無料、App Store からインストール)。最新版を推奨します。
- 初回起動時にXcodeの追加コンポーネントのインストールを求められたら許可してください。

### 新規プロジェクトを作成する

1. Xcode を起動し、「Create New Project」を選択
2. macOS タブ → 「App」を選んで Next
3. 以下のように入力します
   - Product Name: `qooViewer`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - 「Use Core Data」「Include Tests」はチェック不要(SwiftDataは自分でコード側から使うので、ここはチェック不要です)
4. 保存先を選んで Create

### デプロイ対象 OS を設定する

1. 左のプロジェクトナビゲータで一番上の「qooViewer」(青いアイコン)をクリック
2. 「General」タブ → 「Minimum Deployments」の macOS を **15.0** に設定

### 依存ライブラリを追加する

「File」メニュー → 「Add Package Dependencies…」を選び、以下の4つを **1つずつ** 追加します。

1. `https://github.com/weichsel/ZIPFoundation`
   - Dependency Rule: 「Up to Next Major Version」のままでOK → Add Package
2. `https://github.com/mtgto/SevenZip.swift`
   - **注意**: このライブラリはバージョンタグではなく最新コードを指定する必要があります
   - Dependency Rule を「Branch」に変更し、`main` と入力 → Add Package
3. `https://github.com/mtgto/Unrar.swift`
   - Dependency Rule: 「Up to Next Major Version」のままでOK → Add Package
4. `https://github.com/fumoboy007/UniversalCharsetDetection`
   - zip内のファイル名の文字コード自動判定に使用(uchardetというMozilla由来のライブラリをSwiftから使えるようにしたもの)
   - Dependency Rule: 「Up to Next Major Version」のままでOK → Add Package
   - 内部でCライブラリ(uchardet)をソースからビルドするため、初回ビルドは少し時間がかかります

いずれも追加後に「Choose Package Products」という画面が出たら、対象を qooViewer ターゲットに追加してください。

SwiftData・ImageIO・AppKit(実寸表示ウインドウ・マウスカーソル制御用)はOS標準のフレームワークなので、
追加のパッケージは不要です(コード側で `import SwiftData` / `import ImageIO` / `import AppKit` する
だけで使えます)。表示モード・ブックマーク・スライドショー・環境設定・キー/マウスのカスタマイズも
すべて標準フレームワークのみで実装しているため、この節で追加するパッケージは変わらず上記4つだけです。

### 表示言語(日本語/English)を有効にする

qooViewerは日本語とEnglishを切り替えられます(環境設定の「一般」タブ→「表示言語」)。
これを実際に機能させるには、Xcodeプロジェクト側にも2つ設定が必要です。

1. `Sources/Resources/Localizable.xcstrings` が、手順4のドラッグ&ドロップで他のフォルダと
   一緒にプロジェクトに追加されていることを確認してください
   (`Resources`フォルダごとドラッグしていれば自動的に含まれます。個別に追加した場合は、
   `Localizable.xcstrings` ファイル単体を同様にドラッグ&ドロップし、`qooViewer`ターゲットに
   追加してください)。Xcodeはこの拡張子のファイルを自動的に「String Catalog」として認識し、
   ビルド時に翻訳データへ変換してくれます。特別な設定は不要です。
2. プロジェクトナビゲータで `Localizable.xcstrings` をクリックして開く(String Catalog専用の
   エディタが開きます)。エディタ左側の言語一覧の下端にある **+** ボタンから **Japanese** を
   追加してください(このファイルは英語をベースの言語として作られているため、Englishは
   最初から自動的に含まれています。明示的に追加が必要なのはJapaneseだけです)。
   - Xcodeのバージョンによっては、プロジェクト設定(「qooViewer」→「Info」タブ→
     「Localizations」セクション)からも同様に言語を追加できますが、バージョンによって
     この画面が見つかりにくいことがあるため、`Localizable.xcstrings` エディタから直接
     追加する上記の方法がより確実です。

この2点さえ済ませれば、あとはアプリ内の「表示言語」設定を切り替えるだけで、
メニューバー・ツールバー・環境設定画面などアプリ全体の表示が日本語⇔Englishで切り替わります
(macOS本体の言語設定とは独立して切り替えられます)。

**「日本語」に切り替えても英語のままになる場合**: `Localizable.xcstrings` を開いたときに
左側の言語一覧に「Japanese」が無ければ、上記2の手順で **+** ボタンから追加してください。
すべての項目に日本語の訳文をあらかじめ登録済みなので、Japaneseが言語として登録されて
いれば正しく切り替わるはずです。

**注意**: エラーメッセージ(ファイルが開けなかった場合など、ごく一部の文言)は、
アプリ内の表示言語設定ではなく、Macのシステム言語設定に従って表示されます。
これは実装上の意図的な簡略化です。気になる場合はお知らせください。

### サンドボックス設定(フォルダへのアクセス許可)

1. プロジェクトナビゲータで「qooViewer」→ 「Signing & Capabilities」タブを開く
2. 「App Sandbox」が既に追加されているはずです(なければ「+ Capability」から追加)
3. 「File Access」の項目にある「User Selected File」を **Read/Write** に設定

**注意**: サンドボックスを有効にすると、ユーザーがパネルやドラッグ&ドロップで直接選んだファイル/フォルダ
にしかアクセス権がありません。「同じフォルダ内の次の本」機能、およびFileメニューの
「同じフォルダのファイルを開く」機能は、まだアクセス許可のない兄弟ファイルを読もうとするため、
**ファイル単体(zip/cbz等)を直接開いた場合**は一覧が空になります(フォルダを開いた場合は、
その配下がまとめて許可されるため問題ありません)。これは開発中/配布後を問わず、サンドボックスが
有効な限り常に起きる制限です。

この場合は、環境設定(Cmd + ,)の「アクセス権」タブから「フォルダを追加…」で、漫画ファイルを
置いているフォルダ(ホームフォルダや外部ボリューム、ドライブのルートフォルダなど、どこでも
指定できます)へのアクセスをあらかじめまとめて許可しておくと、以後そのフォルダ配下では
「同じフォルダのファイルを開く」「前の本/次の本」が常に正しく機能します。
(Fileメニュー→「同じフォルダのファイルを開く」→「このフォルダへのアクセスを許可…」からも、
今開いている本のフォルダだけをその場で許可できます。どちらも一度許可すれば、次回起動後も
有効です(セキュリティスコープ付きブックマークとして保存されるため)。環境設定の「アクセス権」
タブでは、許可済みフォルダの一覧確認・取り消しもできます)

なお「最近開いたファイルを開く」機能は、開いた時点でセキュリティスコープ付きブックマークとして
アクセス許可を保存しておくため、サンドボックス下でも次回起動後に問題なく開けます。

### Finderから直接開けるようにする(任意)

1. プロジェクトナビゲータで「qooViewer」ターゲット → 「Info」タブを開く
2. 「Document Types」セクションで + を押し、`zip` `cbz` `rar` `cbr` `7z` `cb7` `pdf` `epub` の8つをそれぞれ
   Extensionsに登録します(Nameは何でもよいです。例: "Comic Archive")
3. これで対応ファイルを Finder でダブルクリック、または右クリック →「このアプリケーションで開く」→
   qooViewer で開けるようになります

### ビルド&実行

1. 画面左上の実行ボタン(▶)か `Cmd + R`
2. ウィンドウが開いたら「開く…」から、漫画のフォルダ、またはzip/cbz・rar/cbr・7z/cb7・PDF・EPUBファイルを選ぶ
   (ウインドウへのドラッグ&ドロップでも開けます)

## ライセンス

- qooViewer自体のソースコードはMITライセンスです(同梱の `LICENSE` 参照)。
- 文字コード自動判定は `UniversalCharsetDetection`(内部で Mozilla 由来の uchardet を使用)に依存しています。MITライセンスです。
- zip/cbz/7z/cb7 対応は `ZIPFoundation` に依存しています。 `ZIPFoundation` および、`SevenZip.swift` はMITライセンスです。
- rar/cbr 対応は `Unrar.swift`(内部で RARLAB 提供の unrar ライブラリを使用)に依存しています。[unrar のライセンス文](https://github.com/mtgto/Unrar.swift/blob/main/Sources/Cunrar/readme.txt)を参照してください。
