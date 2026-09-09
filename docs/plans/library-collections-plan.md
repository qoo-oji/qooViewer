# 改善要望5 実装計画 ―― お気に入りの無効化・ウェルカム画面の再構成(ライブラリ/コレクション)・ウェルカム画面へ戻る操作

立案日: 2026-09-08 / ブランチ: `feature/library-collections` / 検討メモ: [library-collections-study.md](library-collections-study.md)(決定事項は同 §5)

段階は §5 の決定どおり 1 → 5 の順。各段階は単独でビルド・テストが通り、レビューできる大きさにする。
段階 1・2 は小さく独立しているので先に見てもらえる。段階 3 は UI を持たない(テストで検証)。段階 4 で初めて
ウェルカム画面が変わる。段階 5 でコレクションの中とメタデータ/カバー。

この計画に出てくる行番号は立案時点(`d4fa3ef`)のもの。

---

## 段階 1. お気に入りの無効化

### 1.1 フラグ

`Models/FavoritesFeature.swift`(新規):

```swift
/// お気に入り機能の入り口をまとめて塞ぐスイッチ(改善要望5)。機能は廃止したが、将来復活させられるよう
/// モデル・ストア・ウインドウ・JSON はすべて残し、UI からの入り口だけをこのフラグで隠している。
/// 復活させるときはここを true に戻す。データ(FavoriteBook/FavoriteFolder)は消えていないので、
/// 戻した時点で以前の登録がそのまま見える。
enum FavoritesFeature {
    static let isEnabled = false
}
```

### 1.2 変更箇所(すべて `if FavoritesFeature.isEnabled` の分岐。消さない)

| ファイル | 箇所 | 変更 |
|---|---|---|
| `App/QooViewerApp.swift` | `CommandGroup(after: .pasteboard)` の先頭 `Divider` + 3項目(891–931) | `if FavoritesFeature.isEnabled { ... }` で囲む。続くブックマーク項目の前の `Divider` は残す |
| 同 | `Window(id: "favoritesOrganizer")`(1172) | 残す(入り口が無ければ開かない)。コメントに無効化の旨を追記 |
| `Views/ViewerView.swift` | ツールバーの星ボタン(1994–2005) | 分岐で出さない |
| 同 | 右クリックメニューの2項目(2116–2125) | 分岐で出さない |
| 同 | `perform(_:)` の `.toggleFavorite / .showFavoritesList / .showFavoritesOrganizer`(3952–3959) | `guard FavoritesFeature.isEnabled else { return }` を各 case の先頭に。既定の ⌥A/⌥B を押しても何も起きない |
| 同 | `.sheet(isPresented: $showFavoriteFolderPicker)`(1606) | そのまま(`showFavoriteFolderPicker` が true にならない) |
| `Views/SidePanelView.swift` | ブックマークモード(345 付近の `SidePanelFavoritesSectionView` と上下分割) | フラグ false なら上段を出さず、ブックマーク一覧が全高を使う(履歴モードと同じ1列構成)。`SidePanelMode.bookmarks` のコメントも「上段=お気に入り(無効化中)」に更新 |
| 同 | `SidePanelMode.systemImage` のコメント | 触らない |
| `Views/KeyBindingSettingsView.swift` | `favoriteGroup`(57)/`hidden`(62) | `FavoritesFeature.isEnabled ? favoriteGroup : []` を `ordered` に、hidden 側にはその逆を足す(`placed` の集合に入れておかないと末尾のセーフティネットが拾って出てしまう) |
| `Views/MouseBindingSettingsView.swift` | `assignableActions`(26) | お気に入り操作は元々無い。変更なし |
| `ViewModels/KeyBindingStore.swift` | 既定辞書(125–126) | **消さない**(`fillingMissingDefaults` が「割り当てが無い操作」を補う仕組みなので、消すと復活時に既定が戻らない) |
| `Views/GeneralSettingsView.swift` | 「最近のお気に入りを表示」(100) | 分岐で出さない |
| `Views/OpeningSettingsView.swift` | 「お気に入りから」(45) | 分岐で出さない |
| `ViewModels/AppPreferences.swift` | `favoriteOpenBehavior` / `showRecentFavoritesOnWelcome` | 触らない(`keys(for:)` に残す) |
| `Views/ContentView.swift` | `isCurrentBookFavorited: ...`(360) | `FavoritesFeature.isEnabled && ...` |
| 同 | `sidePanelView` の `onAddFavorite` / `onEditFavorites` などの閉包(1026–1050) | そのまま(上段が出ないので呼ばれない) |
| `Views/LibraryExportWindow.swift` | `Toggle("Favorites")`(50) | 分岐で出さない。`includeFavorites` の初期値は `FavoritesFeature.isEnabled`(**無効化中は含めない**。含めると「何を書き出したのか分からない」項目が JSON に混ざる。既存の書き出しファイルからの読み込みは下で残す) |
| `Views/LibraryImportWindow.swift` | `policyPicker("Favorites")`(88) | 分岐で出さない。`favoritesPolicy` の初期値は `FavoritesFeature.isEnabled ? .merge : .ignore`(ファイルに `favorites` があっても取り込まない。取り込んでも見えない) |
| `Views/LibraryCleanupWindow.swift` / `ViewModels/LibraryCleanupViewModel.swift` | お気に入り列 | 列を出さない。`Row.favoriteCount` と削除の実体は残す(残骸を掃除できる) |
| `Views/WelcomeView.swift` | 「最近のお気に入り」列 | 段階 4 で画面ごと作り直すので、ここでは `recentFavoriteBooks` を `FavoritesFeature.isEnabled` で空にするだけ |

`ViewerView` の `.help(...)` 文字列や環境設定の help(「favorites, bookmarks and reading history」)は触らない(段階 6 で文言をまとめて見直す)。

### 1.3 テスト・確認

- 既存テスト(`FavoritesLimitTests` / `LibraryImportTests` / `LibraryCleanupTests` など)は変更なしで通ること。
- `KeyBindingStoreTests` に「フラグが false のとき `assignableActions` にお気に入り操作が無い」は書けない(private)。
  `KeyBindingSettingsView.assignableActions` を `static` にして参照できるようにするかは段階 2 で判断(同じ場所を触る)。
- 実機: 編集メニュー・ツールバー・右クリック・サイドパネル「ブックマーク」・環境設定「一般」「本を開く」・
  書き出し/読み込み/削除ウインドウで、お気に入りが**どこにも見えない**こと。⌥A/⌥B で何も起きないこと。
- docs: `docs/06`(一覧表の行に「無効化中」)、`docs/09`(サイドパネル・ウェルカム画面)、`docs/13`(経緯)。

---

## 段階 2. ウェルカム画面へ戻る操作

### 2.1 `ViewerAction.returnToWelcome`

- `Models/ViewerAction.swift`: `.nextBook` の後に `case returnToWelcome`。`titleKey` は `"Return to Welcome Screen"`
  (`PageBoundaryBehavior` が同じキーを既に持つ。String Catalog に訳あり)。`isMouseOnly` は false。
- `ViewModels/KeyBindingStore.swift`: 既定辞書に**入れない**(要望: 既定はどちらも割り当て無し)。`renamedActions` 不要。
- `Views/KeyBindingSettingsView.swift`: `bookNavigationGroup` を `[.previousBook, .nextBook, .returnToWelcome]`。
- `Views/MouseBindingSettingsView.swift`: `.previousBook, .nextBook,` の直後に `.returnToWelcome`。
- `Views/ViewerView.swift`:
  - `private func returnToWelcome()` を新設: `viewModel.flushPendingSave(); appState.closeBook()`。
    既存の2か所(`onPageBoundaryRequest` の `.returnToWelcome`(338–343)と `handlePageBoundary` の同(1138–1143))を
    これに寄せる(コメントは片方に集約)。
  - `perform(_:)` に `case .returnToWelcome: returnToWelcome()`。
  - ツールバー(1839 `toolbar`)の `HStack` 先頭に:
    ```swift
    Button { returnToWelcome() } label: { Image(systemName: "books.vertical").panelIconButtonLabel() }
        .buttonStyle(.borderless)
        .help("Return to Welcome Screen")
    ```
    ページ送りの chevron 群と区別するため、この後に `Spacer().frame(width: 8)`(既存の spacing 8 と合わせて 16)。
- サイドパネル:
  - `SidePanelView` に `var onReturnToWelcome: (() -> Void)?` を追加(nil = 本を開いていない = 無効)。
  - `SidePanelModeSwitcher` に `let onReturnToWelcome: (() -> Void)?` を渡し、`HStack` の先頭に
    モードボタンと同じ 30pt 高・**幅は高さと同じ 30pt 固定**(等分に加えない)のボタン + 幅 1pt の `Divider`。
    アイコン `books.vertical`、`.disabled(onReturnToWelcome == nil)`、`.help("Return to Welcome Screen")`。
    地は未選択モードボタンと同じ `Color.primary.opacity(0.07)`、`.panelOutlinedContent()`。押しても `mode` は変えない。
  - `ContentView.sidePanelView(...)`: `onReturnToWelcome: appState.currentBook == nil ? nil : { appState.performViewerAction?(.returnToWelcome) }`。
    `performViewerAction` 経由にするのは `flushPendingSave` を持つ ViewerView に実行させるため(直接 `closeBook()` を呼ぶと保留中の読書位置が落ちうる)。

### 2.2 テスト・確認

- `KeyBindingStoreTests`: 「`returnToWelcome` には既定の割り当てが無く、`fillingMissingDefaults` も補わない」。
- `InputMappingTests`: `ViewerAction.allCases` の rawValue が一意(既存があれば流用)。
- 実機: キー設定・マウス設定の一覧に出る/割り当てて効く。ツールバー左端・サイドパネル左端のボタンでウェルカム画面へ。
  ウェルカム画面ではサイドパネルのボタンがグレー。読書位置が保存されている(戻って開き直すと同じページ)。
  「ライト+黒100%」「ダーク+白100%」で輪郭を確認。
- docs: `docs/09` 入力の節(語彙に追加)・サイドパネルの節(スイッチの左のボタン)。

---

## 段階 3. モデル・ストア・カバー・JSON・削除・テスト(UI なし)

### 3.1 SwiftData モデル(`Models/`、新規3ファイル)

```swift
@Model final class BookLibrary {
    var id: UUID
    var name: String
    var sortOrder: Int            // 帯に並ぶ順(作成順。手動並べ替えは無いが FavoriteFolder と同じく持つ)
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \BookCollection.library) var collections: [BookCollection]
}

@Model final class BookCollection {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date           // 本の追加・削除・名前変更で更新
    var library: BookLibrary?
    @Relationship(deleteRule: .cascade, inverse: \CollectionItem.collection) var items: [CollectionItem]
}

@Model final class CollectionItem {
    var id: UUID                  // カバーファイル名にも使う(CollectionCoverStore)
    var bookID: String            // MangaBook.id(パス)
    var bookmarkData: Data        // セキュリティスコープ付きブックマーク(FavoriteBook と同じ)
    var title: String             // 登録時のファイル/フォルダ名(ツールチップ用。表示はしない)
    var addedAt: Date
    var sortOrder: Int
    var coverStatus: Int = 0      // CollectionCoverStatus: 0 pending / 1 ready / 2 failed
    var coverCropSide: Int = 0    // CoverCropSide: 0 そのまま / 1 横長を左側でトリミング / 2 右側(§3.4。読み方向が変わったときに作り直す対象を選ぶため)
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?
    var collection: BookCollection?
}
```

- 規約(docs/06): `@Attribute(.unique)` 無し・`Identifiable` 無し・全属性に宣言時デフォルトか init で必ず代入・
  `#Predicate` は使わない(`FavoritesStore.reload` の `parent == nil` だけが例外だが、ここは全件フェッチ+辞書で統一)。
- `QooViewerApp.modelSchema`(67)に3型を追加。ライトウェイトマイグレーションで済む(追加のみ)。
- `qooViewerTests/Support/InMemoryLibrary.swift` のスキーマにも追加。

### 3.2 `ViewModels/CollectionStore.swift`(新規、`FavoritesStore` と同じ作り)

```swift
@MainActor final class CollectionStore: ObservableObject {
    init(modelContext: ModelContext, coverStore: CollectionCoverStore)

    @Published private(set) var libraries: [BookLibrary]          // sortOrder 順
    @Published private(set) var existenceByItemID: [UUID: Bool]   // 非同期の存在確認(FavoritesStore.existenceByFavoriteID と同じ)

    // 読み取り
    func collections(in library: BookLibrary, sort: FavoritesSortOption) -> [BookCollection]
    func items(in collection: BookCollection, sort: FavoritesSortOption) -> [CollectionItem]   // dateUpdated は addedAt で解釈
    func library(withID:) / collection(withID:) / item(withID:)
    func allRegisteredBookIDs() -> Set<String>
    func membershipCount(forBookID:) -> Int
    func anyBookmarkData(forBookID:) -> Data?
    func hasCollectionNamed(_ name: String, in library: BookLibrary, excluding: BookCollection? = nil) -> Bool   // 前後空白除去・完全一致
    func hasLibraryNamed(_ name: String, excluding: BookLibrary? = nil) -> Bool
    func resolvedURL(for item: CollectionItem) -> URL?                     // ブックマーク解決のみ(存在確認なし)
    func resolvedExistingURL(for item: CollectionItem) -> URL?             // 存在確認つき(開くとき)
    func cachedFileExists(for item: CollectionItem) -> Bool
    func scheduleExistenceRefresh()

    // ライブラリ
    func ensureDefaultLibrary()                                            // 0件なら「Library」(ローカライズ)を1つ作る。reload() の末尾で呼ぶ
    func createLibrary(name:) -> BookLibrary?                              // 空・重複は nil(呼び出し側が事前に検証しているので二重防御)
    func rename(_ library: BookLibrary, to:)
    func delete(_ library: BookLibrary)                                    // 2つ以上あるときだけ(1つしか無ければ何もしない)。配下の item の id を集めてからカスケード削除 → coverStore.remove(itemIDs)

    // コレクション
    func createCollection(name:, in library:, items: [PendingItem]) -> BookCollection?   // 1冊以上を伴って作る(空のコレクションは作らない)
    func rename(_ collection: BookCollection, to:)
    func delete(_ collection: BookCollection)                              // item の id を集めてから削除 → coverStore.remove

    // 本
    struct PendingItem { let url: URL; let bookmarkData: Data; let title: String; let identifier: FileNodeIdentifier? }
    static func makePendingItem(for url: URL) -> PendingItem?              // ブックマークが作れなければ nil(FavoritesStore.makeBookmarkData と同じ)
    @discardableResult func add(_ items: [PendingItem], to collection: BookCollection) -> [CollectionItem]   // 同じコレクションに同じ本(パス一致 or inode 一致)は飛ばす。save と通知は1回
    func remove(_ item: CollectionItem)                                     // → coverStore.remove([id])
    func removeItems(forBookID:)                                            // 「保存データの削除」から
    func setCoverStatus(_ status: CollectionCoverStatus, for item: CollectionItem)   // 抽出結果の記録(通知は bookID 付き)

    // 追従(他ストアと同じ)
    func reconcileBookIDIfMoved(book: MangaBook)
    func backfillFileNodeIdentifier(forBookID:, identifier:)
    func deleteAll()                                                        // 「すべてのデータを削除」/ 読み込みの overwrite。coverStore.removeAll() も
    func releaseResources()                                                 // テスト用(購読を外す)
}
```

- 通知 `Notification.Name.collectionsDidChange`(`Models/BookCollection.swift` に置く。userInfo `"bookID"` は本に関わる変更のときだけ)。
- `MenuBarMenuRefresher` には**登録しない**(コレクションはメニューバーに出ない。`FavoritesStore` の publish が
  メニュー全体を作り直していた轍を踏まない。`AppStores.allObjectWillChangePublishers` に足さないだけ)。
- `AppStores` に `collectionStore` と `collectionCoverStore` を追加。`QooViewerApp` で `.environmentObject(collectionStore)`
  をウインドウの content に付ける(`favoritesStore` と同じ場所: 328 付近と各補助ウインドウ)。
- `AppState.open`(977)の追従の列に `self.collectionStore?.reconcileBookIDIfMoved(book:)` と backfill を足す(`weak var collectionStore`)。
- `AppState.isPrivateWindow` のコメントの列挙に「コレクションの登録・編集・カバー抽出」を足す。

### 3.3 `Services/CollectionCoverStore.swift`(新規、ディスク)

```swift
/// コレクションのカバー画像(登録時に1回だけ抽出した JPEG)。~/Library/Application Support/<bundleID>/CollectionCovers/<itemID>.jpg
/// Caches ではないので OS に消されない(消されると「全部読み直し」になる)。SwiftData の外部ストレージを使わない理由は検討メモ §2.2。
actor CollectionCoverStore {
    init(directory: URL?)                       // nil = Application Support。テストは scratchpad の一時フォルダ
    let directory: URL
    static let maxPixelSize: CGFloat = 512
    static let jpegQuality: CGFloat = 0.8
    func url(for itemID: UUID) -> URL
    func write(_ image: CGImage, for itemID: UUID) throws       // ImageIO で JPEG 化(ThumbnailDiskCache と同じ書き方)
    func image(for itemID: UUID) -> CGImage?                     // CGImageSource から。無ければ nil
    func remove(_ itemIDs: [UUID])
    func removeAll()
    func sweepOrphans(keeping itemIDs: Set<UUID>)                // 起動時に1回(CollectionStore.reload 後)
}
```

`QooViewerApp.performPendingStoreResetIfNeeded` の `cacheDirectories` の既定に `CollectionCoverStore` のフォルダを足す
(全削除で消える)。`ResetDataSettingsView` 側の予約時削除も同様。

### 3.4 `Services/CoverImageResolver.swift`(新規、`nonisolated`)

```swift
/// 「この本のカバーは何か」を1か所で決める。書き出し(EpubExporter/CbzExporter)・EPUB/CBZ 書き出しウインドウの
/// カバー列・コレクションのカバー抽出が同じ答えになるように。
nonisolated enum CoverImageResolver {
    /// DB(BookLayoutSettings/PageLayoutOverride)から MainActor の外へ持ち出すための値のスナップショット。
    struct OverrideSnapshot: Sendable {
        var coverPageKey: String?
        var externalCoverURL: URL?            // resolvedExternalCoverURL の結果
        var pageOrderOverride: [String]?
        var excludedKeys: Set<String>
    }
    /// 実効1ページ目(または上書き)を最大 maxPixelSize で復号。BookLoader.load → PageLoader.gridThumbnail(usesDiskCache: false)。
    /// 外部ファイルなら ImageDecoder.decode。失敗は nil。
    static func coverImage(bookAt url: URL, snapshot: OverrideSnapshot, maxPixelSize: CGFloat) async -> CGImage?

    /// グリッド向けの整形(ユーザー要望 2026-09-09)。横長(width > height)の画像は、読み方向に合わせて
    /// **左右どちらかの端を残して** 縦長(2:3)にトリミングする。右開き(rightToLeft)なら左側、左開きなら右側
    /// ―― 見開き1枚の画像なら、表紙にあたる側が残る。縦長・正方形の画像はそのまま。
    /// 2:3 はコレクションのタイル(3×2)とコレクションの中のセルの縦横比と同じ値(CollectionCoverThumbnail.aspectRatio)。
    /// anchor が nil(自動)のときだけ読み方向で決める。ユーザーが明示的に選んだ anchor(左端/中央/右端)はそれに従う。
    static func croppedForGrid(_ image: CGImage, readingDirection: ReadingDirection, anchor: CoverCropAnchor?) -> (image: CGImage, cropSide: CoverCropSide)
}

/// 保存する側(実際にどこを切ったか)。CollectionItem.coverCropSide。
enum CoverCropSide: Int, Sendable { case none = 0, left = 1, center = 2, right = 3 }
/// ユーザーの指定(BookLayoutSettings.coverCropAnchorRaw)。nil = 自動(読み方向で決める)。
enum CoverCropAnchor: String, Sendable, CaseIterable { case left, center, right }
```

読み方向は「その本の実効値」= `BookLayoutSettings.readingDirectionOverride` があればそれ、無ければ環境設定の既定
(`AppPreferences.defaultReadingDirection`)。`OverrideSnapshot` に `readingDirection: ReadingDirection` と
`cropAnchor: CoverCropAnchor?` を足し、`LayoutStore.coverOverrideSnapshot(forBookID:defaultReadingDirection:)` が解決する。
トリミング済みの画像を保存するので表示時の処理は無い。`CollectionCoverStore.write` の前に `croppedForGrid` を通し、
結果の `cropSide` を `CollectionItem.coverCropSide` に記録する。

**ユーザーによる位置の指定(要望追加 2026-09-09)**: `BookLayoutSettings` に `var coverCropAnchorRaw: String?`(後追加なので
Optional。nil = 自動)を足し、`LayoutStore.setCoverCropAnchor(forBookID:sourceURL:anchor: CoverCropAnchor?)`(`saveAndNotify` で
`layoutDataDidChange` を投げる)で書く。カバー画像そのもの(`coverPageKey` / 外部ファイル)とは独立した属性で、
`hasCoverOverride` には**含めない**(「カバーを既定に戻す」で位置指定まで消えないように。位置指定は本の属性として残る)。
書き出し(EPUB/CBZ)のカバーはトリミングしない(元画像のまま)。この指定はコレクションのグリッド表示にだけ効く。
入り口はメタデータ編集シートと「メタデータの編集」ウインドウのカバー列(§5.3・§5.4)。

`LayoutStore.coverOverrideSnapshot(forBookID:)`(MainActor)がスナップショットを作る。`BookExportViewModel.resolveDefaultCoverName` の
「構造キャッシュがあれば本体を読まない」最適化はカバー**名**の話なのでそのまま残し、画像の復号だけをここへ寄せる。

### 3.5 `Services/CollectionCoverExtractor.swift`(新規、MainActor の司会役)

```swift
@MainActor final class CollectionCoverExtractor: ObservableObject {
    init(collectionStore:, coverStore:, layoutStore:)
    @Published private(set) var inFlightItemIDs: Set<UUID>
    func enqueue(_ items: [CollectionItem])           // 同時1、順番どおり。各 item: resolvedURL → startAccessing → CoverImageResolver → write → setCoverStatus
    func cancelAll()
    func refill()                                     // coverStatus == 0 の行を全部 enqueue(ウェルカム画面の onAppear と JSON 読み込み後)
    // layoutDataDidChange(bookID 付き)を購読し、その bookID の item の直前のスナップショット(coverPageKey/externalCoverFileName/
    // 実効の読み方向)と違えば enqueue(ViewerViewModel.reloadLayoutData と同じ「自分の現在値と比べる」方式)。
    // 環境設定の既定の読み方向(AppPreferences.defaultReadingDirection)が変わったら、coverCropSide != 0 かつ本ごとの読み方向の上書きが無く
    // かつ coverCropAnchorRaw == nil(自動)の item を全部 enqueue(トリミングする側が入れ替わるため。上書き・明示指定がある本は影響を受けない)。
    // coverCropAnchorRaw の変更は layoutDataDidChange(bookID 付き)でスナップショットの差分として拾う(上の行と同じ経路)
}
```

`AppStores` が1つ持つ(ウインドウをまたいで1本の待ち行列)。シークレットウインドウからは呼ばない(登録自体ができないので自然にそうなる)。

### 3.6 `Services/CollectionDropClassifier.swift`(新規、`nonisolated`)と `ShelfFolderResolver` の一般化

```swift
nonisolated enum CollectionDropClassifier {
    enum Item: Sendable, Equatable {
        case book(URL)                                   // 書庫/PDF/EPUB、画像が直下にあるフォルダ、画像フォルダだけが並ぶフォルダ
        case shelf(name: String, books: [URL])           // 直下に本のファイルがあるフォルダ。books は直下の本だけ(SiblingBookOrder 順)
        case ignored(URL)
    }
    static func classify(_ urls: [URL], order: SiblingBookOrder) -> [Item]
    static func classifyAsync(...) async -> [Item]        // Task.detached
}
```

`ShelfFolderResolver` に `static func directBooks(in folder: URL, order:) -> [URL]?`(棚でなければ nil)を足し、`firstBook` の規則 1〜3 を
そのまま使う。`CollectionDropClassifier` は「まず `ShelfFolderResolver` の判定、棚でなく本でもなければ ignored」。

### 3.7 JSON(`formatVersion 4`)

- `LibraryJSONSchema.swift`: `var libraries: [ExportedLibrary]?`。
  ```swift
  struct ExportedLibrary: Codable { var name: String; var collections: [ExportedCollection] }
  struct ExportedCollection: Codable { var name: String; var createdAt: Date; var books: [ExportedCollectionBook] }
  struct ExportedCollectionBook: Codable { var bookID: String; var inodeNumber: Int64?; var volumeDeviceNumber: Int64?; var title: String; var addedAt: Date }
  ```
  カバーは含めない。ブックマーク(`bookmarkData`)も含めない(お気に入りの書き出しも含めていない。読み込み側で inode → パスの順に
  実体を探してブックマークを作り直す。`LibraryImportExportService.apply` のお気に入りの経路と同じ)。
- `ExportSelection.includeCollections` / `ImportPolicies.collections` / `ImportSummary.collectionsImportedLibraries / ...Collections / ...Books / collectionsSkippedBookIDs`。
- `apply`: `overwrite` は `deleteAll()` してから、`merge` は同名ライブラリ/同名コレクションへ合流(本は重複を飛ばす)。取り込んだ本は
  `coverStatus = 0` のまま(抽出は `CollectionCoverExtractor.refill()`)。
- `LibraryExportWindow` / `LibraryImportWindow` に「Collections」のトグル/ポリシー行を追加。
- 旧バージョンのファイル(v1〜3)は `libraries == nil` として今までどおり読める。

### 3.8 「保存データの削除」と「知っている本」

- `LibraryCleanupViewModel.Row` に `collectionCount: Int`。`bookIDs.formUnion(collectionStore.allRegisteredBookIDs())`、
  bookmarkData の解決の列に `collectionStore.anyBookmarkData(forBookID:)`、`deleteAllData(forBookIDs:)` に `removeItems(forBookID:)`。
  `LibraryCleanupWindow` に「Collections」列(お気に入り列の位置)。
- `MetadataEditorViewModel.collectKnownBookIDs` に `collectionStore.allRegisteredBookIDs()`。
- `BookExportViewModel.resolveURL` の列に `collectionStore?.anyBookmarkData` を足す(`init` に `collectionStore: CollectionStore?` を追加。
  3つのサブクラスと `BookExportViewModelTests` の呼び出しを更新)。

### 3.9 テスト(`qooViewerTests/`)

| テスト | 内容 |
|---|---|
| `CollectionStoreTests`(新規) | 既定ライブラリが1つできる / 同名コレクションはライブラリが違えば可・同じなら不可(空白除去・大小区別) / 同じコレクションに同じ本は1つ(パス・inode) / ライブラリ削除で配下がカスケードし、カバーファイルも消える(`CollectionCoverStore` を一時フォルダで) / 1つしか無いライブラリは消せない / `reconcileBookIDIfMoved` / 並び(名前・作成日・追加日 × 昇降) |
| `CollectionDropClassifierTests`(新規) | フィクスチャの `folder` 本 → book、書庫が並ぶ一時フォルダ → shelf(直下だけ)、空フォルダ・画像1枚 → ignored、複数を同時に |
| `CoverImageResolverTests`(新規) | 上書きなし=実効1ページ目(除外・並べ替えを反映。フィクスチャの golden と一致)/ `coverPageKey` / 外部ファイル / 壊れた本で nil / `croppedForGrid`: 横長 4:3 を右開きで左側・左開きで右側の 2:3 に、`anchor` が left/center/right なら読み方向に関わらずその位置、縦長と正方形はそのまま(`cropSide == .none`)、極端に横長(パノラマ)でも幅は `height * 2/3` |
| `CollectionCoverStoreTests`(新規) | write → image → remove → sweepOrphans |
| `LibraryJSONSchemaTests` | v4 の往復、v3 ファイルの読み込みで `libraries == nil` |
| `LibraryImportTests` | overwrite/merge/ignore、取り込み後 `coverStatus == 0`、重複の飛ばし |
| `LibraryCleanupTests` | `collectionCount` と削除 |
| `InMemoryLibrary` | `collections: CollectionStore`(一時フォルダの `CollectionCoverStore` 付き)、`close()` で `releaseResources()` |

「お気に入りの登録は実体のあるファイルでないと失敗する」(docs/13)のとおり、コレクションの登録テストもコンテナ内のフィクスチャを使う。

---

## 段階 4. ウェルカム画面の帯とコレクション一覧

### 4.1 状態: `ViewModels/WelcomeLibraryState.swift`(新規、`ContentView` が `@StateObject` で所有)

```swift
@MainActor final class WelcomeLibraryState: ObservableObject {
    @Published var selectedLibraryID: UUID?                 // UserDefaults "qooViewer.welcome.selectedLibraryID"
    @Published var openedCollectionID: UUID?                // 本を開いて戻ってきても同じコレクションの中(Kindle と同じ)。保存しない
    @Published var isEditing = false                        // 一覧の編集モード。本を開いたら false に戻す
    @Published var collectionSort: FavoritesSortOption      // "qooViewer.welcome.collectionSort"(既定 nameAscending)
    @Published var itemSort: FavoritesSortOption            // "qooViewer.welcome.itemSort"
    @Published var tileSize: CGFloat                        // "qooViewer.welcome.tileSize"(120…320、既定 180)
    @Published var coverSize: CGFloat                       // "qooViewer.welcome.coverSize"(80…300、既定 140)
    @Published var pendingCreations: [PendingCollectionCreation]   // 名前入力待ちの列(Q4: 棚を複数ドロップしたら順番に)
    @Published var addingTo: BookCollection?                // 「本を追加」パネルを出しているコレクション
    struct PendingCollectionCreation: Identifiable { let id = UUID(); var defaultName: String; var books: [URL]; let fromShelf: Bool }
}
```

`qooViewer.pref.*` ではないので環境設定の「初期設定に戻す」の対象外(全削除ではドメインごと消える)。

### 4.2 `Views/Welcome/`(新規フォルダ。既存 `Views/WelcomeView.swift` は削除して置き換え)

| ファイル | 役割 |
|---|---|
| `WelcomeView.swift` | 全体。`VStack(spacing: 0) { WelcomeTopBar; Divider; WelcomeLibraryPane }`。すりガラス背景・`panelContentOutline` は既存のものを移す。onAppear で `appState.welcomeDropHandler` を登録、onDisappear で外す。`isEditing = false` に戻すのは本を開いたとき(`ContentView` の `currentBook` の onChange) |
| `WelcomeTopBar.swift` | 高さ 44pt。左から: 「Open Book…」「Open from History」(2つは `WelcomeButtonWidthEstimator` で実測した大きい方の幅に揃える)/ ライブラリ名の並び(`ScrollView(.horizontal)`、選択中はアクセント地 + `.panelOutlinedAccent`、他は `.panelOutlinedContent`。右クリック: Rename… / Delete…(2つ以上のとき))/ 右端に `+`。シークレットウインドウでは「Open from History」を無効化 |
| `RecentBooksPopover.swift` | `.popover` の中身。`RecentFilesStore.entries` を `SidePanelHistorySectionView` の行と同じ見た目で(検索欄は付けない。行の右クリック「Remove from History」と `BookOpenContextMenuItems`)。ポップオーバーの中身なので輪郭不要 |
| `WelcomeLibraryPane.swift` | `openedCollectionID == nil` なら `CollectionGridView`、あれば `CollectionDetailView`(段階 5)。右上の操作列 `LibraryPaneControls`(`+` / 編集 / 並び替えメニュー / スライダー)は両画面で共通の部品にして引数で差し替える |
| `CollectionGridView.swift` | `LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 24)])`。空なら「No collections to show」+「You can also open by dragging and dropping here」。`LazyCellImageBudget` で画面外のカバーを手放す |
| `CollectionTile.swift` | 角丸正方形(`cornerRadius: tileSize * 0.08`)の中に `Grid` 3×2(各セル `CollectionCoverThumbnail(item)`。6冊未満は空)、右下に冊数バッジ(塗り地、輪郭なし)、下に名前(`.panelOutlinedContent()`、1行中央省略)。クリック → `openedCollectionID = id`。編集モード中の右クリック: Rename… / Delete…(非編集モードでは `.contextMenu` を**付けない**) |
| `CollectionCoverThumbnail.swift` | セルの縦横比は 2:3 固定(`static let aspectRatio: CGFloat = 2/3`。横長のカバーは保存時に同じ比へトリミング済み。§3.4)。`CollectionCoverStore.image(for:)` を `.task(id:)` で読む。`coverStatus == 0` は `ProgressView` 風の薄い地、`2` は灰色地+`FormatBadgeView`。存在しない本は `opacity(0.35)`(段階 5 の一覧でも同じ部品) |
| `CollectionNameSheet.swift` | タイトル(New Collection / Rename Collection / New Library / Rename Library)、`TextField`、欄の下に検証メッセージ(赤)、下に Cancel / Create(または Rename)を同幅(`.frame(minWidth: 80)`)。空欄 → "Enter a collection name."、重複 → "A collection with this name already exists."(ライブラリ版も同様)。**検証はストアの `hasCollectionNamed` で、確定ボタンは通らない間 `disabled`** |
| `AddBooksPanel.swift` | シート。上に「Add Books…」(NSOpenPanel: `canChooseFiles/Directories = true`、`allowsMultipleSelection = true`、`allowedContentTypes` は書庫/PDF/EPUB/フォルダ)、中央は追加済みの本の一覧(タイトル+形式バッジ+抽出の状態)兼ドロップ面(**シートは別 NSWindow なので自前の `.onDrop`**。`BookFileDropTarget` のコメントに例外を追記)、下に「Done」。1冊も無ければ Done = 取り消し(コレクション行は最初の本が入るときに `createCollection` で作る)。抽出は `CollectionCoverExtractor.enqueue` |
| `WelcomeButtonWidthEstimator.swift` | `MetadataButtonWidthEstimator` と同じ実測(2つのボタンのローカライズ済み文字列の幅の最大) |

既存の `WelcomeQuickOpen*`(列幅の実測)と `qooViewerTests` のそのテストは削除(docs/13 の記録を更新)。
シークレットウインドウの説明文(`Private Window` + 本文)は空状態のメッセージの上に残す。

### 4.3 ドロップの振り分け(`AppState` + `ContentView.applyFileDropTarget`)

```swift
// AppState
/// ウェルカム画面が表示されている間だけ登録される。true を返したらそのドロップは処理済み(「開く」に回さない)。
var welcomeDropHandler: (([URL]) -> Bool)?

// ContentView.applyFileDropTarget
.bookFileDropTarget(isTargeted: $isFileDropTargeted) { urls in
    if let handler = appState.welcomeDropHandler, handler(urls) { return }
    appState.open(urls: urls)
}
```

`WelcomeView` のハンドラ:
- 非編集モード・一覧表示 → `false`(従来どおり開く)。
- 編集モード・一覧表示 → `CollectionDropClassifier.classifyAsync` → 本だけを集めて1件の `PendingCollectionCreation(defaultName: "", books:)`
  (本が無ければ作らない)、続けて棚ごとに1件ずつ(`defaultName` = フォルダ名、`fromShelf: true`)を `pendingCreations` に**積む**。
  シートは `pendingCreations.first` を出し、Create/Cancel で先頭を取り除いて次を出す。`true` を返す。
- コレクションの中(段階 5)→ 本だけを `addingTo` のコレクションへ直接追加(パネルは出さない。要望「追加と見なす」)。棚・その他は無視。`true`。
- シークレットウインドウでは編集モードに入れない(編集ボタン・`+` を `disabled`)ので、ハンドラは常に `false`。

編集モードのドロップからの作成は、Create を押した時点で本が入った `AddBooksPanel` を開く(要望: 「作成」後は本が追加済みの状態)。
その後は普通に追加/Done。

### 4.4 その他

- `Views/PanelIconButtonLabel` / `SidePanelNavButton` を右上の操作列に流用。編集モード中の編集ボタンはアクセント地 + `checkmark`。
- スライダー2つは `.panelControlWell()`。
- 並び替えメニュー: `Menu { Picker(Field) ; Divider ; Picker(Ascending/Descending) }`(サイドパネルの並べ替えと同じ形)。
  コレクションの中では Field の `dateUpdated` の表示名を「Date Added」にする(`FavoritesSortOption.Field` に `titleKey(forCollectionItems:)` を足すか、
  `dateUpdated` を選べないようにして `dateAdded` だけ出す ―― **後者**。並び替え3種は「名前・作成日(=追加日)・…」で要望を満たす)。
- 実機確認: 帯の幅が狭いとき(ライブラリ名が多いとき)横スクロールで崩れない。輪郭2条件。ウインドウをまたいで同じライブラリを選択(UserDefaults)。
  `MenuBarMenuRefresher` に登録していないので、コレクションを変えてもメニューバーが作り直されない(`menu-rebuild` のログで確認)。

### 4.5 実装時に計画から変えたところ(2026-09-09)

段階 4 を実装した時点で、計画と違えた点と理由。

- **`CollectionDetailView`(5.1)を段階 4 に前倒し。** `WelcomeLibraryPane` が参照する型なので、
  無いと段階 4 だけではタイルを押しても何も起きない。段階 5 に残したのは 5.2〜5.4
  (カバー上書きの共通部品化・メタデータ編集シート・「メタデータの編集」ウインドウのカバー列)。
- **`AppState.missingCollectionItem` は作らず、`CollectionDetailView` のローカルな `@State` にした。**
  お気に入りは本を開いている最中にもサイドパネルから開けるためアラートを `ContentView` が持つ必要が
  あったが、コレクションの本を開けるのはこの画面だけで、渡す先が1つしか無い。
- **コレクションの中の名前の編集は `TextField` ではなくリネームのシート。** 空欄・重複の知らせ方を
  作成のシートと1つに揃えるため(トースト用の仕組みを新設せずに済む)。
- **既にあるコレクションへ棚(本が並んだフォルダ)を落としたら、中の本を展開して追加する。**
  計画では「棚は無視」だったが、コレクションを**作る**場面と違い、開いているコレクションへ
  本の並んだフォルダを落とす操作に他の意味は無く、何も起きないと黙って失敗したようにしか見えない
  (`CollectionDropClassifier.booksToAdd`)。
- **ドロップを引き受けるのは編集モード中だけ**(一覧でもコレクションの中でも)。「編集モード中だけ
  ドロップの意味が変わる」という1つの規則にした。
- **`WelcomeButtonWidthEstimator` は作らず `MetadataButtonWidthEstimator` を直接使う。** 中身が
  同じ薄い包みになるため。ただし**幅はボタンではなくラベルに与える** ―― `Button(...).frame(width:)`
  では実際に描かれるベゼルが文字列の長さのままになり、2つのボタンが揃わない(実測)。
- **名前入力の欄は `SelectAllTextField`**(ブックマークのリネームシートから共通部品として切り出し)。
  開いた瞬間に今の名前が全選択される。切り出しに伴い、コーディネータが握る構造体を
  `updateNSView` で毎回差し替える修正を入れてある(古い写しのままだと `onSubmit` が
  「まだ何も入力していない状態」を見てしまう)。
- **ライブラリの作成・リネーム・削除も編集モード中だけ。** 帯には編集モードのボタンが無いが、
  下のペインの編集モードと同じ鍵で開ける ―― 閲覧しているだけのときに右クリックからライブラリを
  消せるのは、「編集モード中だけ棚をいじれる」という規則から外れる。
- **環境設定「一般」の「最近開いたファイルを表示」は、帯の「履歴から開く」ボタンの出し分けに読み替えた。**
  一覧の列が無くなったこの設定を、意味を失わせずに残すため。

---

## 段階 5. コレクションの中・メタデータ編集シート・カバー画像

### 5.1 `CollectionDetailView.swift`

- 上段: 戻る(`chevron.backward`、`openedCollectionID = nil`)+ コレクション名(編集モード中は `TextField`。Return で `rename`、空・重複なら元に戻してメッセージをトースト)。
- 右上: `+`(NSOpenPanel → `add`)/ 編集 / 並び替え / カバーのスライダー。
- `LazyVGrid(.adaptive(minimum: coverSize))` に `CollectionCoverThumbnail`。名前は出さない(`.help(item.title)`)。
- 左クリック → `openItem(item)`: `resolvedExistingURL` → `appState.open(url:)`。無ければアラート「Book Not Found」(`missingFavorite` と同じ形。
  「Remove from Collection」ボタン付き。`AppState.missingCollectionItem: CollectionItem?`)。
- 右クリック(常時): `BookOpenContextMenuItems(onOpen:, onOpenIn:)`(Open / New Normal Window / New Private Window / New Tab。
  `BookWindowOpener.open(BookOpenRequest(url), to:, from: appState, ...)`)。編集モード中はさらに `Divider` + 「Edit Metadata…」+ 「Remove from Collection」。
- ドロップ → 追加(4.3)。
- 存在確認: `CollectionStore.scheduleExistenceRefresh()` をアクティブ化・マウント/アンマウントで(`FavoritesStore` と同じ購読)。

### 5.2 カバー上書きの共通部品化: `ViewModels/CoverOverrideController.swift`(新規)

`BookExportViewModel` の 482–620(`resolvedCoverNames` / `coverDisplayName` / `refreshCoverName` / `resolveDefaultCoverName` /
`loadBookForCoverPicker` / `setCover` / `setExternalCover` / `resetCover`)をそのまま移す。`BookExportViewModel` は
`let coverController: CoverOverrideController` を持ち、`resolveCoverOverride` だけ残す。`ExportCoverCell` / `ExportCoverPickerContent` は
`@ObservedObject var controller: CoverOverrideController` を受ける形に変える(`ExportWindowContent` の呼び出しを更新)。

`LayoutStore` に `bookID` + `sourceURL` 版の overload を足す(`existingOrNewSettings(forBookID:sourceURL:)`):
`setCoverPageKey(forBookID:sourceURL:pageKey:displayName:)` / `setExternalCover(forBookID:sourceURL:fileURL:)` /
`setCoverCropAnchor(forBookID:sourceURL:anchor:)`。既存の `MangaBook` 版はこれを呼ぶ。
`CoverOverrideController` にも `cropAnchor(forBookID:) -> CoverCropAnchor?` と `setCropAnchor(forBookID:_:)` を持たせる。

### 5.3 `Views/Welcome/BookMetadataSheet.swift`

- 入力: `bookID`、`sourceURL`(コレクションのブックマークから解決。開けなければシート自体を出さずアラート)。
- 上: 著者 / タイトル / シリーズ / 巻数の4欄。初期値は `MetadataEditorViewModel.makeInitialDraft` を `static func initialDraft(forBookID:baseName:metadataStore:formatStore:)`
  に切り出して共用(登録済みなら DB、未登録なら `BookMetadataDeriver.derive`)。
- 下: カバー画像(`CollectionCoverThumbnail` と同じ画像、幅 150pt。`ExportWindowContent.cover` と同じ寸法感)。
  - 画像ファイルのドロップ(自前の `.onDrop`、`.image` のみ)→ `layoutStore.setExternalCover(forBookID:sourceURL:fileURL:)`。
  - 右クリック: 「Choose Page in This Book…」(`ExportCoverPickerContent` を `.popover` で。中の「Choose File…」「Reset to Default」もそのまま使えるので
    メニューは実質この1項目でもよいが、要望どおり「Choose File…」「Reset to Default (First Page)」も並べる)。
  - 右クリックの続き(`Divider` の後): サブメニュー「Landscape Cover Shows」に「Automatic(読み方向に従う)/ Left Edge / Center / Right Edge」を
    チェックマーク付きで並べ、`layoutStore.setCoverCropAnchor(forBookID:sourceURL:anchor:)` を書く(要望追加 2026-09-09)。
    横長でないカバー(`item.coverCropSide == .none` かつ `coverStatus == ready`)のときはサブメニューを `disabled`(効かない指定を選ばせない)。
  - 変更後の再抽出は `CollectionCoverExtractor` が `layoutDataDidChange` で拾う。シートの表示は `collectionsDidChange(bookID)` で更新。
- 下部ボタン: Cancel / Register(同幅)。Register = `metadataStore.upsert(... sourceURL: sourceURL)`(このシートは本の URL を持てているので、
  ウインドウ版と違ってブックマークと inode も入る)。4欄すべて空で Register → `upsert` が行を消す(既存仕様)ので、ボタン名は変えない。
- カバーの操作はメタデータの Register とは独立に即時保存(書き出しウインドウと同じ挙動)。Cancel はメタデータ4欄だけ戻す旨をコメントに。

### 5.4 「メタデータの編集」ウインドウにカバー列

- `MetadataEditorWindow.bookTable` に `TableColumn("Cover") { row in ExportCoverCell(bookID: row.bookID, controller: viewModel.coverController) }`
  (巻数の後、登録ボタンの前)。`MetadataColumnWidths` に `cover`(実測: 表示名の幅、`ExportWindowContent.coverMin` = 90 と同じ下限・上限 150)。
- `ExportCoverPickerContent` の下段(「Choose File…」の後)に同じ「Landscape Cover Shows」の4択を足す(`CoverOverrideController.setCropAnchor`)。
  書き出しウインドウにも同じポップオーバーが出るが、そこでは書き出しに効かない指定なので、書き出しウインドウ側は
  `ExportCoverPickerContent(showsCropAnchor: false)` で出さない(メタデータの編集ウインドウとシートだけ true)。
- `MetadataEditorViewModel` に `let coverController: CoverOverrideController`(URL の解決は `BookExportViewModel.resolveURL` と同じ列:
  bookmark → layout → metadata → collection。`CoverOverrideController` が `resolveURL` を閉包で受ける)。
- EPUB/CBZ 書き出しウインドウは `BookLayoutSettings` を読むだけなので変更不要(反映を実機で確認)。

### 5.5 テスト・確認

- `MetadataEditorTests`: `initialDraft` の切り出し後も既存テストが通る。`LayoutStore` の bookID 版 overload(`BookLayoutEditorTests` に追加)。
- `BookExportViewModelTests`: `coverController` 経由でも `resolveCoverOverride` の結果が同じ。
- 実機: コレクションの中でメタデータ登録 → 「メタデータの編集」ウインドウでロック(登録済み)表示。カバーを変える → コレクションのタイル・
  EPUB 書き出しウインドウのカバー列・実際の EPUB(Kindle Previewer で開く)の3か所が一致。実体の無い本が暗い。右クリックの4通りの開き方。

### 5.6 実装時に計画から変えたところ(2026-09-09)

- **`BookExportViewModel.coverController` は `let` ではなく `lazy var`。** URL の解決手段
  (`resolveURL(forBookID:)`)がその ViewModel 自身の持ち物で、格納プロパティの初期化中には
  まだ `self` を閉包へ渡せないため。`MetadataEditorViewModel` 側も同じ形。
- **`LayoutStore` の `MangaBook` 版は bookID 版を呼ばない。** 呼ばせると、行を新しく作るときの
  差し替え検知の指紋(`recordedPageCount` ほか)を記録する機会まで失う ―― 本を開いている
  呼び出し元からそれを奪わないよう、**書き込みの本体だけ**を private な
  `applyCoverPageKey` / `applyExternalCover` へ寄せ、行の用意の仕方だけが違う2つの入り口にした。
- **`CoverOverrideController.setExternalCover` は `MangaBook` を取らない。** 受け取っていたのは
  `LayoutStore` へ渡すためだけで、bookID + sourceURL 版ができたので要らなくなった
  (メタデータ編集シートが本を読まずに画像を落とせるのはこのため)。
- **横長カバーの見せ方の描き方は場所で変えた。** カバーピッカー(ポップオーバーの下段)は
  `Picker(.menu)` ―― チェックマークを自前で描かずに済む。メタデータ編集シートの右クリックは
  コンテキストメニューで `Picker` が使えないので、選択中の項目に `Label(systemImage:
  "checkmark")` を自分で添える。
- **「効かない指定を選ばせない」は `isCropAnchorEnabled` として呼び出し側から渡す。**
  横長かどうかは `CollectionItem.coverCrop` から分かるが、それを持っているのはコレクション側
  だけ ―― 「メタデータの編集」ウインドウは行に `CollectionItem` を持たないので常に有効にする。
- **シートへの画像のドロップは自前の `.onDrop` ではなく `fileURLDropTarget`。** 計画では
  自前で書くとしていたが、受け口を1か所にまとめる規則(`BookFileDropTarget`)は
  「本を開かないドロップ」にも当てはまる。落ちてきた URL から画像だけを拾う。
- **`MetadataEditorViewModel` に `preferences` を追加**(`CoverOverrideController` が要る)。
  併せて、ウェルカム画面のウインドウ内容に `metadataFormatStore` を足した(メタデータ編集
  シートがファイル名からの推測に使う)。
- **`CollectionDetailView` のメタデータ編集シートは `grid` 側に付けた。** 同じビューに
  `.sheet` を2つ重ねると片方しか出ないことがあるため(リネームのシートは外側の `VStack`)。
- **テストの置き場所。** `LayoutStore` の bookID 版は `BookLayoutEditorTests` ではなく
  `LayoutStoreTests`(カバーの上書きは本を開かない経路で、あちらは1冊を開いて編集する画面の
  ロジック)。`CoverOverrideController` 経由の確認は、既にカバーの上書きを見ている
  `ExportFormatViewModelTests` に足した。
- **テストから `resetCover` は呼ばない。** あれは表示名を作り直すために
  `BookPageListCache.shared` を読み、必要なら本を読み込んでそこへ書き戻す(テストは共有の
  キャッシュに触れない)。書き出しに効くのは DB 側なので `clearCoverOverride` で確かめる。

---

## 段階 6. 仕上げ

- `docs/14-library-collections.md`(新規): モデル・ストア・カバーの決定事項・ドロップの振り分け・ウェルカム画面の構成。`docs/README.md` から辿る。
  `docs/06` 一覧表(3モデル + カバーファイル)、`docs/09` 画面構成図とウェルカム画面の節、`docs/08` JSON v4、`docs/10`(コレクションのブックマーク)、
  `docs/13`(お気に入り無効化の経緯、`WelcomeQuickOpen*` の削除)。
- 用語表(私のメモ側)に「ライブラリ / コレクション / 本を追加 / コレクションから削除 / 履歴から開く」を足す。
- `Localizable.xcstrings`: 新しいキーの日本語訳を一括で入れる(ビルド由来の差分はそのままコミット)。
- `scripts/ci/check-all.sh` を通す。`QOO_CI_WARNINGS_AS_ERRORS=YES` で Debug/Release ビルド。`xcodebuild test`(署名あり)。
- README/MANUAL/CHANGELOG は指示があったときだけ。

---

## 見積り

| 段階 | 新規 | 変更 | 目安 |
|---|---|---|---|
| 1 | 1 ファイル | 12 ファイル(分岐のみ) | 半日 |
| 2 | ― | 7 ファイル | 半日 |
| 3 | 8 ファイル(モデル3・ストア1・サービス4)+ テスト5 | 10 ファイル | 2〜3 日 |
| 4 | 10 ファイル(`Views/Welcome/`)+ 状態1 | 4 ファイル | 3〜4 日 |
| 5 | 3 ファイル(詳細・シート・controller) | 6 ファイル | 2〜3 日 |
| 6 | docs 1 | docs 6・xcstrings | 1 日 |

## 段階をまたぐ約束(実装中に確認すること)

1. すりガラス面(`PanelSurface.welcome`)に足した部品ごとに輪郭の扱いを決める(検討メモ §2.10 の表)。
2. 新しい永続化経路は `isPrivateWindow` のコメントに列挙し、同じガードを入れる(`grep -rn "skipsPersistence\|isPrivateWindow"`)。
3. `save()` はまとめる(一括追加は保存と通知を1回)。
4. `#Predicate` を使わない。`@Attribute(.unique)` を付けない。属性の後追加は宣言時デフォルト必須。
5. GUI の挙動は推測で2回外したらログを仕込んで実測する。ファイル選択ダイアログは自動操作しない。検証後はウインドウ位置・面の設定を戻す。
