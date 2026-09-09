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

### 5.7 実機で見て直したところ(2026-09-09)

段階4・5で足した UI を、実機(アクセシビリティ操作 + `screencapture`)と `ImageRenderer` で
描き出して確かめた。推測ではなく実測で分かったことと、その結果入れた修正。

- **`.frame(width:)` をボタンに掛けても、描かれるベゼルは揃わない。** 与えた幅はレイアウト上の
  枠にしか効かず、ベゼルは文字列の長さのまま枠の中央に置かれる(`ImageRenderer` で
  「枠あり/枠なし/ラベル側に幅」の3通りを並べて確認)。`WelcomeTopBar` のコメントに書いてあった
  とおりで、**幅はラベルに、`chrome: 0` で**与える。段階4・5で足した3つ
  (`CollectionNameSheet` / `BookMetadataSheet` / `AddBooksPanel`)をこの形に直した。
  この方式ではない既存のダイアログ(`MetadataFormatDialogs` のフッター等)も同じ状態だが、
  今回の範囲外として触っていない。
- **すりガラス面を文字色で塗ると、帯の2つのボタンと区切り線が跡形もなく消える。**
  「標準のボタンは自前の不透明な地を持つから輪郭は要らない」という前提が誤りだった ――
  この面の背後はウインドウ外を透かす `BehindWindowVisualEffectView` で、その上の AppKit の
  ボタンのベゼルは下地に合わせて描かれる(ダーク+白100%で実測)。ボタンには
  `.panelControlWell()`(形)と `.panelOutlinedContent()`(文字)、区切り線には
  `.panelOutlinedContent()` を入れた。作り直す前のウェルカム画面の「開く…」も同じ状態だった。
- **並べ替えメニューの輪郭が抜けていた。** `SidePanelSortMenu` で実測済みの
  「`.borderlessButton` の Menu はラベル側の輪郭が効かないので Menu 自体へ掛ける」「`fixedSize()`
  で幅を固定する」の2点が `WelcomeSortMenu` に反映されていなかった。同じ形に揃えた。
- **カバー列を足したら「メタデータの編集」ウインドウが横スクロールになった。** 1300pt 幅の実機で
  右端の登録/削除ボタンが隠れかける(`MetadataColumnWidths` の冒頭が警告していた状態)。
  開いた直後の幅を 150 → 100 に下げて解消。表示名は本を読んでから非同期に決まるので、
  この列だけ実測(`autoSizeColumnsIfNeeded`)はしない。
- **メタデータ編集シートに、どの本かが出ていなかった。** コレクションの一覧はカバーだけを並べて
  名前を出さないので、右クリックで開いた先にも名前が無いと対象を取り違える。見出しの下に
  本の名前を足し、カバー(左)と4欄(右)の2段組みにして高さを揃えた(460×334)。
- 履歴のポップオーバーは、履歴が空のときだけ幅が中身なりに細くなっていた(360pt へ固定)。
- 「本を追加」パネルの冊数は、下の裸の数字ではなくコレクション名の隣へ移した。
- 編集モードのトグルの説明を状態で入れ替えた(編集中はチェックマーク = 抜ける操作なので「完了」)。

**既定のライブラリ名が英語のまま(`Library`)の環境がある** ―― `ensureDefaultLibrary` は
`String(localized:language:)` で作るが、**名前は作った時点の文字列が DB に残る**ので、日本語訳を
入れる前のビルドで一度起動していると英語のままになる。当初は「右クリックの『名前を変更…』で直す」と
していたが、ユーザー報告を受けて 5.9 で構造ごと直した(既定のライブラリは名前を持たない)。

### 5.8 実機検証の続き ―― コレクションの中身(2026-09-09)

段階4・5の実機確認は、5.7 の時点では**コレクションに本が1冊も入っていない状態**までしか進んでいなかった
(本の追加は「本を追加…」の `NSOpenPanel` かドロップしかなく、ファイル選択ダイアログは自動操作しない約束のため)。
今回は Finder からの**実ドラッグ**(`cliclick` の `dd`/`dm`/`du`)で本を落として、中身のある状態を一通り見た。
検証用の本(縦長6ページ / 横長4:3カバー / cbz / pdf / 途中で消すフォルダ)は自分で作ったものを使い、
終了後に UserDefaults・SwiftData ストア・カバー画像・作った本をすべて元へ戻してある。

**確かめて問題が無かったもの**

- 編集モードでの複数ドロップ → 名前入力(空欄・重複の検証、`キャンセル`/`作成` の幅が揃う)→ 本が入った状態で
  「本を追加」パネル → 完了、まで一続きに動く。冊数はコレクション名の隣に出る。形式バッジ(フォルダ/CBZ/PDF)も出る。
- カバーの抽出とタイルの 3×2 + 冊数バッジ。**カバーの差し替え(この本のページから選ぶ)は、押した瞬間に
  シート・タイル・DB の3つへ同時に反映される**(`登録` を押す前でも DB に入る = 設計どおり)。
- 横長カバーの切り取り: 既定(自動)は右開きなので**左側**、`右端` を選ぶと**右側**へ即座に切り替わる。
- 縦長カバーの本では「横長カバーの見せ方」が無効(ポップオーバーの `Picker` は淡色。ただし下記の既知の見た目参照)。
- コレクションからのメタデータ登録が、ビューアのタイトル(`[Tester] A-portrait-folder`)と
  「メタデータの編集」ウインドウのカバー列(`page03.png`)へ反映される。カバー列を足しても 1300pt 幅で横スクロールにならない。
- 実体を消した本は、**アプリをアクティブにし直した時点で**淡色になる(存在確認は起動時・アクティブ化・ボリューム着脱のときだけ ―― お気に入りと同じ作り)。
  開こうとすると「本が見つかりません」のアラートが出る。
- 右クリックの4通りの開き方(同じウインドウ・新規ノーマル・新規シークレット・新規タブ)がすべて動く。
  非編集モードでは「メタデータの編集…」「コレクションから削除」が出ない。
- ツールバーの「ウェルカム画面へ戻る」で**コレクションの中へ戻り**、編集モードは解除されている。
- シークレットウインドウのウェルカム画面では「履歴から開く」「+」「編集」が無効。
- ライブラリを5つに増やしても帯は崩れず、横スクロールしても「本を開く…」「履歴から開く」と右端の `+` は残る。
  別ウインドウを開くと同じライブラリが選ばれている(以後の切り替えはウインドウごと)。
- **輪郭の2条件**(ダーク+白100%塗り / ライト+黒100%塗り)で、帯の2ボタン・区切り線・ライブラリ名・右上の操作列・
  タイルの名前・コレクションの中の見出しと戻る矢印がすべて読める。
- コレクションを作り替えてもメニューバーは作り直されない ―― `CollectionStore.objectWillChange` は
  `AppStores.allObjectWillChangePublishers` に入っていない(コード側で確認。ログを取るまでもない)。

**見つけて直した不具合**

- **「お気に入りの編集」ウインドウが「ウインドウ」メニューから開けた。** `Window` シーンは宣言するだけで
  「ウインドウ」メニューに項目が並ぶため、段階1で入り口を全部塞いだつもりが、ユーザーの登録内容
  (44件+11件)ごと編集できる状態で開けてしまっていた。`.commandsRemoved()` で自動のメニュー項目を落とした。
  **フラグで `Scene` の宣言ごと囲むことはできない**: `SceneBuilder` が受け付ける条件分岐は `if #available` だけで
  (`buildOptional` は `_LimitedAvailabilitySceneMarker` 版しか使えない)、普通の `if` を書くと
  `error: failed to produce diagnostic for expression` でビルドが通らない(実測)。
- **「メタデータの編集」ウインドウが、外で登録された内容を反映しなかった。** ウェルカム画面のメタデータ編集シートで
  著者名を登録しても、開いたままのウインドウの行は**著者名が空のまま**(ファイル名からの推測値)で、しかも
  行は「登録済み」の見た目になる ―― そのまま `登録` を押せば空の値で DB を上書きできてしまう。
  原因は `reload()` が編集中の値(`drafts`)を意図的に残す作りで、`bookMetadataDidChange` を受けても
  行の値を作り直していなかったこと。通知の `userInfo["bookID"]`(無ければ全件変更)という既存の約束どおりに
  作り直すようにした。**`object:` でこのウインドウのストアに絞ってある** ―― 全件変更で `drafts` を捨てるため、
  絞らないと1プロセスで複数のストアを動かすテストが互いの入力を消してしまう。回帰テストを2本追加(830件)。

**残っている既知の見た目**(今回は直していない)

- コンテキストメニューの「横長カバーの見せ方」は、効かない本でも**親項目だけは淡色にならない**(開くと中の4択は淡色)。
  `.disabled` を掛けた `Menu` を `.contextMenu` の中に置いたときの SwiftUI の描き方で、選べないこと自体は守られている。
- 「本が見つかりません」のアラートに `OK` と `キャンセル` が並ぶ。`role: .cancel` を付けていない `OK` に
  破棄ボタンが加わると、SwiftUI がキャンセルを自分で足すため。**お気に入り側(`ContentView`)も同じ形**なので、
  片方だけ変えるとちぐはぐになる。直すなら2か所同時に。
- すりガラス面を 100% で塗ると、タイルの角丸の板が面に溶けて**タイルの境界が消える**(カバーと名前は読める)。
- 新しいウインドウを開いたとき、選択中のライブラリが帯のスクロール範囲の外にあると、**どれも選ばれていないように見える**
  (帯は先頭から表示される)。開いたときだけ選択中まで送る手はある。
- 既定のライブラリ名が英語のまま(5.7 の既知)。


---

## 段階 5.9(要望追加 2026-09-09). 編集モードでの複数選択と一括削除

編集モード中に、コレクションのタイル・コレクションの中のカバーを**選んで、まとめて削除する**。
それまで削除は右クリックの1件ずつしか無く、棚を整理するのに数だけ手順が要った。

### 決定事項

- **クリックの意味をモードで切り替える。** 閲覧中は従来どおり「開く」、編集モード中は
  「選ぶ/選び直す」。ドロップの意味(開く/登録する)を編集モードで切り替えているのと同じ規則で、
  覚えることを1つ(編集モードかどうか)に保つ。
- **編集モード中でも開けるように、右クリックへ「開く」を足す**(コレクションのタイル。本の側は
  `BookOpenContextMenuItems` が最初から4通りの開き方を持っている)。これが無いと、編集モード中に
  コレクションの中へ入るのにいちいちモードを抜ける必要が出る。
- **選択の印は左上**(`SelectionCheckmarkBadge`)。選んでいなければ空の丸、選んでいれば
  アクセント地のチェックマーク。印だけでは小さいときに分かりにくいので、**札/カバーの縁に
  アクセント色の枠**も出す。
- **ゴミ箱は「＋」の左**、編集モードのときだけ出す。操作列は右端に揃えてあるので、左へ伸びる
  ぶんには既にあるボタンの位置が変わらない(`LibraryPaneControls` の「位置が変わらない」方針)。
  選択が空のときは淡色。
- **選択は画面が変わったら必ず捨てる**(`WelcomeLibraryState` の `isEditing` /
  `openedCollectionID` の didSet に集約)。見えていない選択をゴミ箱が消す事故を、画面側の
  書き忘れで起こさないため。
- **削除は必ず確認する。** 1件と複数で鍵を分ける(英語で「1 collections」にしないため)。
  コレクションの中の右クリック「コレクションから削除」も同じ確認へ通した ―― 取り消せない
  書き込みで、入り口によって確認の有無が変わるのはちぐはぐなため。
- **まとめて消す経路はストアに足す**(`CollectionStore.delete(_ collections:)` /
  `remove(_ items:)`)。1件ずつ既存の API を呼ぶと保存と通知がその回数だけ走る
  (`removeItems(forBookID:)` と同じ理由)。本をまとめて外すときの `.collectionsDidChange` には
  `bookID` を**付けない**(複数の本にまたがるため)。
- 輪郭(すりガラス面の決まりごと): 選択の印は**自前の不透明な地**を持つので何も掛けない
  (冊数バッジと同じ側)。選択の枠は色だけが頼りなので `.panelOutlinedAccent(in:)`。

### 変更したファイル

`ViewModels/WelcomeLibraryState.swift`(選択の集合と捨てる契機)/ `ViewModels/CollectionStore.swift`
(一括削除2つ)/ `Views/Welcome/SelectionCheckmarkBadge.swift`(新規)/ `CollectionTile.swift` /
`CollectionGridView.swift` / `CollectionDetailView.swift` / `CollectionCoverThumbnail.swift`
(角丸を選択の枠と共有)/ `WelcomeLibraryPane.swift`(ゴミ箱)。

テストは `CollectionStoreTests`(一括削除2本)と `WelcomeLibraryStateTests`(新規3本 ――
選択の入り/外れ、編集モードを抜けたとき、コレクションの中へ入った/出たとき)。

### 既定のライブラリは名前を持たない(同日のユーザー報告)

帯のライブラリ名が「Library」と英語のままになる(5.7 の既知の問題)。**名前は作った時点の
文字列が DB に残る**ため、日本語訳を入れる前のビルドで一度起動していると直らない。

「初期状態ではライブラリ無しにする」案も検討したが採らなかった ―― ペインは `library != nil` の
ときしか描かれず、編集モードのトグルはそのペインの中、帯の「＋」は編集モード中しか押せないため、
**ライブラリ 0 個は行き止まり**になる(0 個を許すなら空状態の導線から作り直しが要る)。
初回起動が空白になるのも避けたい。

採った案: **既定のライブラリは名前を持たず、表示のたびに表示言語で組み立てる。**

- `BookLibrary.usesDefaultName`(新規属性・宣言時デフォルト `false`)と
  `displayName(language:)` / `defaultName(language:)` / `allDefaultNames` / `occupiedNames`。
- `ensureDefaultLibrary` は `usesDefaultName: true` で作る(`name` にもそのときの既定名を
  入れておく ―― 列を空にしないため。表示には使わない)。
- `CollectionStore.adoptDefaultLibraryName()` を `reload()` の最後に通し、**属性を足す前から
  ある行**のうち「どれかの言語の既定名そのまま」のものを既定扱いへ拾い直す。
  ユーザーが自分で既定名を付けた場合も既定扱いに戻る(保存された文字列からは区別できない。
  表示は同じ文字列のままで、変わるのは表示言語に追従するかどうかだけ)。
- `rename(_ library:to:)` は `usesDefaultName = false`。名前を付けた時点で言語に追従しなくなる。
- 重複判定(`hasLibraryNamed`)は `occupiedNames` を見る ―― 既定のライブラリは**全言語の既定名を
  塞ぐ**。日本語表示で「ライブラリ」を別に作れると、英語へ切り替えた瞬間に同じ名前が2つ並ぶため。
- 帯・リネームシートの初期値は `displayName(language: locale)`(`@Environment(\.locale)`)。
  書き出し JSON は `AppLanguage.currentLocale` の見出しで書き、取り込みの合流も `occupiedNames`
  で見る(英語環境で書き出した `Library` が日本語環境の既定のライブラリへ入る)。
- 属性の後追加は SwiftData の軽量マイグレーション。実際に保存されているストアの**複製**を今の
  スキーマで開いて、通ること・既定のライブラリが拾い直されることを使い捨てのテストで確認した
  (確認後に削除)。テストは `CollectionStoreTests` に4本。

---

## 段階 5.10(要望追加 2026-09-09). カバーの縦横比をライブラリ単位で選ぶ(2:3 / 1:1 / 3:2)

カバーは 2:3 固定で、横長の画像は抽出の時点で 2:3 へ切って保存していた。商業コミックならそれで
よいが、**同人 CG 集のように横長画像だけで構成された本**では、横幅の半分以上を捨てた札が並ぶ。
さらに、このアプリを**漫画ビューアではなく画像ビューアとして使う**人にとっては、写真や壁紙が
縦長に切られること自体が不便(同日のユーザー指摘)。そこで縦横比を **2:3 / 1:1 / 3:2** から
選べるようにし、比が合わないときにどこを切るかも選べるようにした。

### 決定事項

- **粒度はライブラリ単位**(`BookLibrary.coverAspectRatioRaw` / `coverCropAnchorRaw`、どちらも
  非 Optional + 宣言時デフォルト = 軽量マイグレーション)。1 つのグリッドに比の違う札が混ざらない
  ようにするため ―― 「同じ大きさの札が整然と並ぶ」ことが、一覧の目的(どの本かを見分ける)に効く。
- **札の割り付けは比から決まる。** 2:3 は 3 列 2 行(最大 6 冊)、1:1 は 2 列 2 行(最大 4 冊)、
  3:2 は 2 列 3 行(最大 6 冊。2:3 の裏返し)。いずれも札全体がほぼ正方形に落ち着く組み合わせで、
  縦横比を別に指定しなくてよい(`CoverAspectRatio.tileColumns` のコメントに計算。縦長・横長は
  間隔 1 本ぶんだけずれる)。
- **切り出しを「保存時」から「表示時」へ移した。** これが今回いちばん大きな変更。
  比を選べるようにした以上、抽出時に切る方式だと**トグル 1 つでそのライブラリの全冊を読み直す**
  ことになる ―― 書庫を展開し直すので冊数ぶんの時間がかかり、外付けボリュームが未接続なら抽出に
  失敗してカバーが灰色(`.failed`)へ落ちる。**表示の設定を変えただけでカバーが消える**のは
  受け入れ難い。保存するのは切っていない画像 1 枚だけにして、比も位置も表示時に効かせれば、
  切り替えは即時かつ無損失になる(`CGImage.cropping(to:)` は元画像を参照する部分画像を作るだけ)。
- **「自動(読み方向から決める)」は廃止**(段階 5.7 で入れたばかりの挙動を同日に覆した)。
  上下方向の切り出しには読み方向が何も言えないうえ、読み方向を変えるとカバーの見た目まで変わるのは
  予想しにくい。`CoverCropAnchor` は軸に依存しない `start` / `center` / `end` の 3 値になり、
  切る軸(左右か上下か)は画像と枠の比から決まる。ラベルだけは「上／左」「下／右」と両軸を併記する。
- **本ごとの上書きの意味が変わった。** `BookLayoutSettings.coverCropAnchorRaw` の `nil` は、
  「自動」ではなく**「そのライブラリの設定に従う」**。旧値 `"left"` / `"right"` は
  `CoverCropAnchor.stored(_:)` が `start` / `end` として読み替える。
- **保存するカバーの長辺を 512px → 768px** へ(`CollectionCoverStore.maxPixelSize`)。切らずに
  保存するようになったため、横長画像から 1:1 を切り出すと長辺の一部しか残らない。コレクションの中の
  セルは最大 300pt = Retina で 600px 要る。
- **世代番号で一度だけ作り直す。** 既に保存済みのカバーは 2:3 に切られた状態なので、そのままだと
  1:1 で「二重に切る」ことになる。`CollectionCoverExtractor.coverStorageGeneration` を
  `UserDefaults`(`qooViewer.pref.` で始まらないキー)と突き合わせ、上がっていたら起動時に 1 回だけ
  全件を `.pending` へ戻す。
- 歯車は**スライダーの右**、コレクションの一覧とコレクションの中の**両方**に出る
  (`LibraryPaneControls` が共通なので自動的にそうなる)。**編集モードは条件にしない** ―― 棚の中身を
  変える操作ではなく見え方の設定なので、閲覧しているだけのときにも触れてよい。書き込みではあるので
  シークレットウインドウでだけ塞ぐ。
- **設定パネルに説明文は置かない**(同日のユーザー指示)。ラジオが並ぶだけの小さな面で、
  文章を 1 つ足すと面の半分が字で埋まる。見出しは Picker のラベルではなく**上に自前で置く**
  ―― `Picker("見出し", …)` のままだと 2 つの設定で見出しの長さが違うぶんラジオの左端が揃わず、
  右側に使い道の無い余白が残る(実測)。「本ごとに上書きできる」といった説明は MANUAL.md 側へ。
- 輪郭(すりガラス面の決まりごと): 歯車は `SidePanelNavButton` = `.panelIconButtonLabel()` が
  内側で輪郭を掛けている。ポップオーバーの中身は macOS が不透明に描くので何も要らない。

### 減った仕掛け

カバーの画素が読み方向にも位置指定にも依存しなくなったので、再抽出の契機がまとめて消えた:
`CollectionCoverExtractor.handleDefaultReadingDirectionChange()` と
`preferences.$defaultReadingDirection` の購読(= 抽出役から `AppPreferences` 依存そのもの)、
`CoverSignature` の `readingDirection` / `cropAnchor`、`CollectionStore.itemsWithCroppedCover()`、
`CollectionItem.coverCropSide` と `CoverCropSide`、`OverrideSnapshot.readingDirection`。
`CollectionItem` には代わりに `coverAspect`(保存したカバーの 幅 ÷ 高さ)が入る ―― メタデータ編集で
「位置の指定が効くか」を画像を復号せずに判定するため。

### 変更したファイル

`Services/CoverImageResolver.swift`(`CoverAspectRatio` 新規 / `CoverCropAnchor` を 3 値へ /
`croppedForGrid` → `cropped(_:to:anchor:)` + `cropsAnyEdge`)、`Models/BookLibrary.swift`、
`Models/CollectionItem.swift`、`Models/BookLayoutSettings.swift`(意味の書き替え)、
`Services/CollectionCoverStore.swift`、`Services/CollectionCoverExtractor.swift`、
`Services/LibraryJSONSchema.swift` / `LibraryImportExportService.swift`(`ExportedLibrary` に
Optional 2 つ。`formatVersion` は 4 のまま)、`ViewModels/CollectionStore.swift`
(`setCoverAppearance`)、`ViewModels/LayoutStore.swift`、`ViewModels/CoverOverrideController.swift`、
`App/AppStores.swift`、`Views/Welcome/LibrarySettingsPopover.swift`(新規)、
`WelcomeLibraryPane.swift` / `CollectionCoverThumbnail.swift` / `CollectionTile.swift` /
`CollectionGridView.swift` / `CollectionDetailView.swift` / `BookMetadataSheet.swift` /
`AddBooksPanel.swift`、`Views/Export/ExportWindowContent.swift`、`Views/MetadataEditorWindow.swift`。

テストは `CoverImageResolverTests`(切り方を左右・上下の両方で。**`CGImage.cropping(to:)` の原点は
左上**なので `.start` が上端 ―― 取り違えを検出するために、上下で色を変えた画像で固定した)、
`CollectionStoreTests`(既定値 / ライブラリごとに独立 / 比を変えても再抽出にならない /
どの比でも札がほぼ正方形になる割り付けか)、
`LayoutStoreTests`(新しい enum)、`LibraryImportTests`(JSON の往復と、フィールドが無い古い JSON)。

なお `#expect(!f(...))` はマクロ展開の都合で判定を取り違えることがある(実際に踏んだ)。
否定は一度ローカルへ受けてから `== false` で比べる。

札の割り付けは、使い捨てのテストで `CollectionTile` を `ImageRenderer` に描かせて目で確かめた
(3×2 と 2×2 がどちらもほぼ正方形に収まること。確認後に削除)。`.task` は `ImageRenderer` では
走らないので、この方法で見えるのは**割り付けだけ**で、実際のカバー画像は出ない ―― 切り方の正しさは
`CoverImageResolverTests` の画素の判定側で押さえている。

---

## 段階 5.11(指摘 2026-09-09). 「足す」操作を編集モードから外す

ライブラリのリネーム・削除・追加を、ペイン(コレクション一覧)の編集モードと同じ鍵で開けていた
(段階 4)。**帯とペインは区切り線で分かれた別の領域に見えるのに、区切り線の下のボタンを押さないと
区切り線の上の名前を変えられない**のは筋が通らない、という指摘。しかも編集モード外の右クリックは
メニューすら出ない(「項目が空の contextMenu は付けない」方針)ので、**手がかりがゼロ**だった
―― 実際、右クリックが効かないという形で報告が来た。

ペインに編集モードがあるのは、クリックの意味が変わる(開く/選ぶ)ことと、まとめて削除するための
選択が要るからで、**帯にはどちらの事情も無い**。チップのクリックは常にライブラリの切り替えだけ、
リネームと削除は右クリックからしか辿れず、削除は確認のアラートも出す。そこで
`WelcomeTopBar.canEditLibraries` を `allowsEditing && state.isEditing` から `allowsEditing` へ ――
塞ぐのはシークレットウインドウ(保存データを書かない)だけにした。

これで帯の「＋」(新しいライブラリ)も常に押せ、チップの右クリックは常にメニューを出す。

### ペインの「＋」も同じ(続いての指摘)

`LibraryPaneControls` の「＋」(一覧では新しいコレクション、コレクションの中では本の追加)も
編集モード中しか押せなかった。同じ理屈で外す ―― `isDisabled: !allowsEditing || !isEditing` を
`!allowsEditing` へ。**棚を作る・本を入れるのはこの画面で最初にやること**なのに、それがモードの
奥に隠れていた。`isEditing` に残る役目は**ゴミ箱を出すかどうかだけ**になった。

ドロップの意味(閲覧中は開く / 編集モード中は登録する)は**そのまま**にしてある。あちらは同じ操作の
結果が二通りに分岐するので、モードで決める必要が実際にある(ボタンのように、押せる・押せないの
違いに落とせない)。

---

## 段階 5.12(指摘 2026-09-09). 名前入力シートの幅と間隔

`CollectionNameSheet`(ライブラリ/コレクションの作成・リネームの4通りすべて)が、欄の右にだけ
説明のつかない余白を持っていた。実測すると**面が470pt**で、いちばん広い部品は320ptの欄
―― 何がその幅を出しているのかは特定できていない(有力なのは `SelectAllTextField`
= NSViewRepresentable が親へ返す寸法だが、確かめていないので断定しない)。

- 面の幅を **360pt に決め打ち**し、欄は `maxWidth: .infinity` で面いっぱいに伸ばす。
- 欄と検証メッセージを**1つの塊**にした(内側 spacing 2 / 外側 12)。以前は見出し・欄・メッセージ・
  ボタンを同じ間隔で並べていたので、**見えていないメッセージのぶんだけ欄とボタンが離れて見えた**。
  メッセージの高さを予約する方針(面の高さが跳ねないように)はそのまま。

結果は 470×145 → **360×141**。
---

## 段階 5.13(要望追加 2026-09-09). 帯のライブラリ ―― 幅を揃える / 掴んで並べ替える

### 幅

チップの幅が名前の長さで変わるのが落ち着かない、という指摘。左の2つのボタン(「本を開く…」
「履歴から開く」)と**同じ見積もり**から求めた固定幅にした(`WelcomeTopBar.chipLabelWidth`)。
収まらない名前は中略(`.truncationMode(.middle)`)で出し、全体はツールチップで読める。

「履歴から開く」を出さない設定でも**両方の文字列を測る**。あちらのラベル幅は実際に並んでいる
ボタンだけで決めているが(段階 4)、そこまで連動させると、履歴の設定を切り替えただけで
ライブラリの幅まで変わってしまう。

### 並べ替え

`BookLibrary.sortOrder` は最初からこのために持っていた列。ストア側は
`CollectionStore.reorderLibraries(_ orderedIDs:)` ―― **どこへ落としたかの解釈は画面の都合**なので、
ストアは渡された順に番号を振り直すだけにする。渡された配列が今あるライブラリと1対1で対応しない
ときは何もしない(別のウインドウが同時に増減させていた場合、取りこぼした行の `sortOrder` が 0 の
まま残って並びが壊れるより、その一回を捨てるほうがよい)。

画面側(`LibraryChipReorder`)で実測して決めたこと:

- **`.draggable` ではなく `.onDrag(_:preview:)`。** 掴んだ瞬間が分かる口が要る(掴んでいるチップを
  淡く描くため)。`.draggable` にはその契機が無い。
- **`ViewModifier` に切り出す。** シークレットウインドウでは並べ替えさせないが、`if` で
  修飾を付け外しすると SwiftUI から見て別のビューになり、チップが作り直される。中で分岐すれば
  同じビューのまま効き目だけ切り替わる。
- **落とし先の印はチップを丸ごと縁取る。** 最初は左端に細い挿入線を出していたが、ドラッグ中は
  指の下にドラッグの絵が乗るので**線が完全に隠れて何も見えなかった**(実測)。縁なら絵の外側に残る。
- **ドラッグの絵に自前の地を持たせる。** 文字だけにすると、下を通るチップの文字と重なって
  両方読めなくなる(実測)。
- 運ぶのは `BookLibrary.id` の文字列。`Transferable` の専用型は作らない ―― アプリの外へ落としても
  何も起きないほうがよく、文字列なら受け取り側が無視するだけで済む。

実機で確認した(合成したマウスイベントでドラッグし、掴む→乗る→落とすの3点を撮った)。
テストは `CollectionStoreTests` に2本(渡した順に付け替わること / 数が合わない並びは捨てること)。

**検証中に踏んだこと**: 開いたままのシートに気づかず、以降のクリックとドラッグがすべて
モーダルに吸われていた。「操作が効かない」ときは、まず `sheets of window 1` を見る。
---

## 段階 5.14(指摘 2026-09-09). 案内の文言と、履歴パネルの高さ

### 空のときの案内は、ドロップの意味に合わせる

コレクションが1つも無い画面で編集モードに入っても「ここにドラッグ&ドロップしても開けます」の
ままだった。ドロップの意味は編集モードで変わる(閲覧中は開く / 編集モード中は登録する。
`WelcomeView.handleDrop`)のに、案内だけが片方を指していた。

- `CollectionGridView` … 編集モード中は「本やフォルダをここに落とすとコレクションを作れます」
- `CollectionDetailView` … 逆向きの同じ間違いがあった。「本をここに落とすと追加できます」は
  **編集モード中だけ**正しく、モード外で落とした本はコレクションに入らず開く。こちらも切り替える。

判定はどちらも `allowsEditing && state.isEditing`(シークレットウインドウは編集モードに入れない)。

### 履歴パネルの高さは実測する

7件しか無いのにスクロールバーが出ていた。高さを「1行 24pt × 件数 + 12」と**掛け算で見積もって
いた**のが原因で、実際の行はもう少し高い ―― 行の中身(文字の行送り、形式バッジ)が変われば
正しい値も変わるので、掛け算では追い切れない。

`onGeometryChange` で中身の高さを実測してそのまま面の高さに使い、上限だけ 420 → 560 に。
このために `LazyVStack` を `VStack` へ戻している ―― 実測するには画面外の行まで含めた本当の高さが
要るのに、Lazy だと見えているぶんしか作られず、実測値が最初の数行で止まる。履歴は保存件数
(既定20・上限100)までの短い一覧なので、全部作って差し支えない。
---

## 段階 5.15(指摘 2026-09-09). 即時反映と、編集モードを持ち越さないこと

### 切り出し位置の変更が、次のクリックまで絵に出ない

メタデータ編集で位置を変えても札が変わらず、画面のどこかをクリックすると変わっていた。

原因は **LayoutStore が `objectWillChange` を出していない**こと。あのストアの published は
`layoutBookIDs`(レイアウト情報を持つ本の集合)1つだけで、しかも集合の出入りが起きたときしか
更新しない ―― レイアウトの読み取りが頻繁なので意図的に絞ってある(`refreshLayoutBookID`)。
切り出し位置は `isBookLevelSettingEmpty` に数えない属性なので、変えても集合は動かず、
DB から読んでいる表示は何も知らないままだった。

LayoutStore 側を published にする案は採らなかった。アプリ全体で 1 つのストアなので、
そこから publish するとメニューバーまで作り直しにかかる(私のメモ「メニュー再構築の現行犯逮捕手順」)。
代わりに、**DB から読んで描いている側が `.layoutDataDidChange` を拾って body を組み直す**
(`CollectionGridView` / `CollectionDetailView` の `layoutRevision`、`BookMetadataSheet` の
`coverRevision`)。数を増やすだけで値は読まない ―― @State が変われば body は組み直される。

シートの側は自分の操作でも数を進める。`coverController` を `@State` で持っていて購読していないため、
自分で押した変更すら契機が無い(通知でも拾えるが、同じウインドウ内は待たずに反映したい)。

> **`BookMetadataSheet` の `coverRevision` は段階 5.20 で撤回した**(`@State` の数え上げでは
> `.contextMenu` が組み直されないことがある)。`CollectionGridView` / `CollectionDetailView` の
> `layoutRevision` はメニューを持たないのでそのまま。

### 画面が移ったら編集モードから出る

ライブラリを移っても、コレクションの中へ入っても、編集モードが残ったままだった。編集モードは
**いま見えているものに手を入れるための状態**なので、別のものを見始めた時点で持ち越す理由が無い
―― 持ち越すと、入った先でクリックの意味が変わったままなのに、なぜそうなっているのかが画面から
読めない。`WelcomeLibraryState` の `selectedLibraryID` / `openedCollectionID` の didSet で
`isEditing = false`(選択は `isEditing` の didSet が捨てる)。

同じ値の再代入では何も起きない、は従来どおり。テストは `WelcomeLibraryStateTests` に
既存1本の書き替えと新規1本。
---

## 段階 5.16(指摘 2026-09-09). メタデータ編集の入り口・ページを選ぶ面・札の隙間

### 「メタデータの編集」は編集モードを条件にしない

棚から本を出し入れする操作ではなく、その1冊の中身を整える操作なので、モードの奥に置く理由が無い
(帯のリネームと同じ判断)。**「コレクションから削除」は編集モードのまま**にしてある ―― あちらは
取り消せない削除で、ゴミ箱と同じ扱いにしておきたい。

### ページを選ぶ面は2段構えにする

行を押した瞬間にカバーが決まる作りだったが、**押しても画面が何も変わらず、面も閉じない**ので、
決まったのかどうかも、どうやって閉じるのかも分からなかった。

- 行を押すのは「選ぶ」まで(チェックマークとアクセント地で印を付ける)
- 下に「キャンセル」/「選択」。開いた時点で、既に指定されているページに印が付く
  (`CoverOverrideController.coverPageKey(forBookID:)`を追加)
- 「既定に戻す」「ファイルを選ぶ…」は**その場で効かせて、そのまま閉じる** ―― それ自体が
  終わりの操作なので、「キャンセルで戻るのはどれか」を面の上に残さない
- 切り出し位置だけは即時のまま(元から即時保存の側。`BookMetadataSheet`の型コメント)

この面は書き出しウインドウとメタデータ編集ウインドウでも同じものを使うので、3か所すべてが
同じ操作感になる。

### 札の中の隙間

3pt では詰まりすぎて、6冊が1枚の大きな絵のように見えていた。間隔 3 → 6pt、内側の余白 6 → 8pt
(余白が間隔より狭いと外周だけ窮屈に見える)。札が正方形からずれる量は間隔と同じなので、
180pt の札で 6pt = 3% 程度。並べたときに気づく差にはならない。
---

## 段階 5.17(要望追加 2026-09-09). 棚の間で動かす

編集モード中の右クリックに「移動」を足す。行き先は**サブメニュー**で出す(ユーザー指示)。

### コレクション → 別のライブラリ

`CollectionStore.move(_ collection:to:)`。移す先に**同じ名前のコレクションがあるときは動かさない**
―― 同じライブラリの中で名前が重複しないという決まり(`hasCollectionNamed`)を、移動だけ例外には
できない。UI は `canMove(_:to:)` で先に見て、その行を**選べないようにし、理由を名前に添える**
(「マンガ(同名のコレクションがあります)」)。押しても何も起きない項目にするより、なぜ選べないかが
その場で分かるほうがよい。ライブラリが1つしか無いときは項目ごと出さない。

### 本 → 別のコレクション

`CollectionStore.move(_ item:to:)`。**行そのものを付け替える**(消して作り直さない)のが要点で、
カバー画像のファイル名は行の id なので、付け替えなら抽出済みのカバーがそのまま生きる。

移す先に同じ本が既に入っている場合は、**移す側の行を消すだけ**にする ―― 同じコレクションに同じ本を
2つ置かない(`insertItems`)という決まりに合わせつつ、「移動したのに元にも残っている」を避ける。
消える行のカバー画像も一緒に消す。

メニューの形は行き先の数で変える。ライブラリが1つなら、そのライブラリのコレクションを**直に**
並べる(行き先が1つの入れ子を毎回開かせない)。2つ以上ならライブラリごとの入れ子にする ――
コレクション名はライブラリをまたぐと重複しうるので、どの棚のものか分かる必要がある。

どちらも移動のあとに `state.clearSelection()` を通す。移した先は今見えていないので、
**見えていないものをゴミ箱が消さない**という既存の決まりを守るため。

テストは `CollectionStoreTests` に3本(コレクションの移動と同名の拒否 / 本の移動でカバーが残ること /
移す先に同じ本が居るときは元を消すだけ)。

> **このうち「本 → 別のコレクション」は段階 5.19 で撤回した**(自動登録フォルダと噛み合わない)。
> コレクション → 別のライブラリはそのまま残っている。
---

## 段階 5.18(要望追加 2026-09-09). コレクションの札の背景色

ライブラリの設定に背景色を足す。`BookLibrary.coverBackgroundColorRaw`(`RGBColorValue.hexString`)。

- **nil = 既定**(`Color.primary.opacity(0.07)`)。色を決め打ちで保存すると**外観の切り替えに
  追従できなくなる**ので、「未指定」の状態を残してある。色を決めてあるときだけ「初期化」を出す。
- 色を選ぶのは既存の `CustomColorPickerSheet`(パレット + RGB)。SwiftUI標準の `ColorPicker` は
  このアプリでは使わない決まり(`SettingsColorRow` のコメント ―― macOSのカラーパネルは1枚しか無く、
  返る `Color` を sRGB 8bit へ落とすときの解釈がOS任せになる)。
- **ダイアログはポップオーバーではなく `LibraryPaneControls` が出す。** ポップオーバーの中から
  シートを出すと、親のポップオーバーが閉じた時点でシートごと消える。ポップオーバーは
  「開いてほしい」をクロージャで伝えるだけにして、閉じたあと1回遅らせてからシートを出す
  (`WelcomeView.presentAddBooks` と同じ理由)。
- 並びは**カバーの形 → 残す位置 → 背景色**(ユーザー指示)。形と切り方は同じ「カバーをどう出すか」の
  話なので隣り合わせにする。
- 文言は**「背景色」**。最初は「札の地の色」としたが意味が読めないという指摘。既存の
  `Background Color` の鍵がそのまま「背景色」なので、それを使い回す。

`RGBColorValue` を `nonisolated` にした。SwiftData のモデルのアクセサから読み書きするため
(あちらはメインアクター分離ではない文脈で評価されうる)。中身は数値3つの値型で共有状態を
持たないので、分離する意味が元から無い。

テストは `CollectionStoreTests` に1本(既定は未指定 / 保存形式が `#RRGGBB` / 既定へ戻せる /
ライブラリごとに独立)。
---

## 段階 5.19(要望追加 2026-09-09). コレクションの自動登録フォルダ

コレクションに**自動登録フォルダ**を1つ持たせる。そのフォルダに本が増えると、ウェルカム画面を
見にきたタイミングでそのコレクションへ自動的に足される。

### FSEvents で監視しない

自動登録の結果が意味を持つのは「ウェルカム画面のコレクションを見たとき」だけで、裏で本が増えた
瞬間に知らせる相手がいない。**見る直前に走査する**だけで見え方は同じになる。常時監視を入れると、
(1) コピーの途中のファイルがその瞬間に登録され、カバーの抽出が `.failed` のまま固定される、
(2) 許可済みフォルダのぶんだけストリームを張り、閉じ忘れの面倒を新しく作る、の2つを引き受ける
ことになる。契機を人の操作へ寄せておけば、どちらも起きない。

> **これは段階 5.21 で撤回した。** ユーザーの要望は「コピーした瞬間に増えてほしい」だった ――
> 「知らせる相手がいない」という前提が間違っていた(画面を見ながらコピーする)。

走査の契機は `CollectionStore.scheduleExistenceRefresh` と同じ考え方で5つ ―― アプリがアクティブに
なったとき、ボリュームがマウントされたとき、ウェルカム画面が現れたとき、コレクションを開いたとき、
自動登録フォルダを設定した直後。多重起動は畳む(`CollectionAutoFolderScanner`)。

### 拾う範囲は棚の直下だけ ―― 判定を増やさない

「そのフォルダに並んでいる本」は `ShelfFolderResolver.role(of:order:)` の `.shelf(books:)` そのもの。
**直下だけ**で、ファイルの本と画像を直接持つフォルダが並び順どおりに入る。編集モード中にその
フォルダをドロップしたときに入る本と1冊のずれもなく一致する(`CollectionDropClassifier` も同じ判定を
通っている)。フォルダが棚でない(それ自体が1冊・空・中間フォルダだけ)ときは何も拾わないが、
**指定そのものは弾かない** ―― いまは本が無くても、後からそこへ書庫が置かれれば棚になる。

`CollectionAutoFolderScan.settlingInterval`(10秒)より後に更新されたものは、その回は見送る。
大きな書庫をコピーしている最中に走査が当たると、書き終わっていないファイルが登録され、カバーの
抽出が失敗して `.failed` のまま固定される(抽出をやり直す契機はカバーの上書きが変わったときだけ)。
コピー中のファイルは更新時刻が動き続けるので、「最後の更新から少し経っている」を条件にすれば
次の走査まで待たされるだけで済む。更新時刻が読めないもの・未来の時刻のものは通す(通さないと
永久に登録されない)。

> **一律10秒の待ちも段階 5.21 で撤回した**(即時反映を求められている以上、小さな本まで待たせる
> 理由が無い)。「書き込みが止まったか」を見る形へ差し替えた。

### 権限は `FolderAccessStore` に一本化する ―― 持つのはパスだけ

`BookCollection.autoFolderPath`(`String?`)。**セキュリティスコープ付きブックマークは持たない。**
このアプリでフォルダを列挙する権限は `FolderAccessStore` が一手に持っており(許可済みフォルダの
配下すべてを起動中ずっと開いたままにする)、ここに別のブックマークを持たせると同じフォルダの権限を
2箇所が別々に開閉することになる ―― 過去に漏れを出したのと同じ形。走査する側は `isPathCovered` に
「いま列挙してよいか」を訊き、覆われていなければ**黙って見送る**。代償として、フォルダを移動・
リネームすると自動登録は静かに止まる(設定の面に常にパスが出ているので選び直せば直る)。

初期値の入り方は3通り。**フォルダをドロップ**したらそのフォルダ(権限も付いてくる)、
**ファイルをドロップ**したらそれらが入っていたフォルダ(全部が同じフォルダのときだけ。
**権限は付いてこない**)、**「＋」から**なら空欄。ファイル由来のときは設定の面に
「アクセスを許可」が出て、`AppState.ensureAccess(toFolder:message:)` と同じ形の `NSOpenPanel` で
許可を求める。許可されるまで自動登録は静かに何もしない。

### 除外リストは作らない

自動登録フォルダの中の本をコレクションから外しても、次の走査でまた入る。ユーザーの判断
(「それを嫌な人は自動登録フォルダを利用すべきではない」)。手で外した本を覚えておく列も、
自動で入ったか手で入れたかの印も持たない。

**「本 → 別のコレクション」(段階 5.17)はこれに伴って削除した。** 移しても次の走査で戻ってくる
ので、成立したりしなかったりする操作になる ―― 右クリックの一項目としては読めない。
`CollectionStore.move(_ item:to:)` と右クリックの「別のコレクションへ移動」、対応するテスト2本、
文言 `Move to Collection` を落とした。コレクション → 別のライブラリは残っている。

### 歯車はコレクションの設定になる

コレクションを開いている間、右上の歯車は**そのコレクションの設定**(`CollectionSettingsPopover`)を
出す。以前はどちらの画面でもライブラリの設定を出していたが、棚を開いているのにその外側の設定が
出るのは筋が通らない、というユーザーの判断。そのぶん、カバーの見せ方(ライブラリ単位)を変えるには
一覧へ戻ることになる ―― 一覧とコレクションの中の両方に出すことも検討したが、**歯車1つに設定を
2種類**入れるほうが読めない、と判断した。

フォルダを選ぶ行(`CollectionAutoFolderRow`)は、名前入力シートと設定のポップオーバーで**同じ部品**を
使う。選び方・アクセス権の求め方が入り口によって違うと、同じ設定に見えなくなるため。

**パスは直接打てる**(ユーザー要望 2026-09-09。当初は「打ったパスには権限が伴わないので、打てば
動くように見えて動かない欄になる」として読み取り専用にしていたが、同日に撤回した)。権限が無い状態は
元から起こりうる(落とされたファイルの親フォルダ)ので、そのための「アクセスを許可」は既にこの行に
ある ―― 打った場合も同じ道を通るだけで、新しい行き止まりは生まれない。欄を空にすれば自動登録なしへ
戻るので、**「クリア」のボタンは置かない**。`~` は展開しない(サンドボックスの中では `~` が
コンテナを指すので、展開すると打った人の意図と違う場所になる)。

打てるようにしたことで出てきた3つは、実装側で潰してある。
- **1文字ごとにDBへ書かない。** 設定のポップオーバーは下書き(`@State`)を持ち、Returnと面が
  閉じたときにだけ書く。そうしないと打つたびに `save()` と `.collectionsDidChange` と `reload()` が
  走り、後ろの一覧が描き直される。
- **打っている最中の文字列を横から書き換えない。** 素朴に「`folder` のパスと欄の文字列が違えば
  揃える」と書くと、`URL(fileURLWithPath:)` が末尾の `/` を落とすせいで「/Users/」まで打った瞬間に
  打った `/` が消える。欄の文字列を同じ経路に通した結果と比べる。
- **注意書きの高さを常に予約する**(名前欄の検証メッセージと同じ扱い)。打っている最中は
  「見つかりません」が出たり消えたりするので、跳ねると読めない。注意書きは2種類 ――
  そこにフォルダが無い(`そのフォルダが見つかりません。`)と、あるが権限が無い(`アクセスを許可`
  付き)。無い場所への許可を求めるパネルは開いても意味が無いので、ボタンは後者でだけ押せる。

「＋」から作って自動登録フォルダだけを選んだ場合は、そのフォルダの本で棚を作る。そうしないと
「空の棚は作らない」方針(`createCollection`)に阻まれて、行が作られないまま「本を追加」パネルだけが
開く。1冊も無いフォルダだったときは、選ばれたフォルダを `AddBooksTarget.autoFolder` で運び、
1冊目が入って行ができた時点で書き込む。

### JSON

`ExportedCollection.autoFolderPath`(Optional。`formatVersion` は据え置き)。**パスだけ**を書き出し、
取り込み側では**その場所に実際にフォルダがあるときだけ**設定する。既にあるコレクションへ混ぜる
ときは、**まだ設定されていないときだけ**入れる ―― JSON を追加で取り込んだだけで手元の設定が
差し替わるのは筋が通らない。

### テスト

`CollectionAutoFolderScanTests`(新規4本: 直下だけ・並び順・ドロップと一致 / 棚でないフォルダは空 /
書き終わったばかりは見送る / 未来の時刻は通す)、`CollectionStoreTests` に2本(設定とクリア、
クリアしても本は残る / 既に入っている本が走査の入力から落ちる)、`LibraryImportTests` に
往復1本と「実在しないパスは設定しない」1本。走査の中核は `nonisolated` な純粋関数として
切り出してあるので、ストアを組まずに直接叩ける。
---

## 段階 5.20(不具合 2026-09-09). カバーの切り取り位置がシートに反映されない

ユーザー報告: 登録直後のコレクションの本を「メタデータの編集」で開き、カバーを右クリックして
「切り取るときに残す位置」を変えても、カバーもメニューのチェックマークも変わらない。閉じてその本を
クリックし直すと反映済み。

### 実測でモデルは無罪と分かった

推測を重ねずに、コンテナへ追記するログを仕込んでユーザー自身に操作してもらった
(統合ログには出てこなかったので `~/Library/Containers/…/Data/tmp/` へ直接書いた)。

```
MENU.tap   want=.start controller=true
STORE.set  hadRow=false current=nil want=.start
STORE.set  done readback=.start        ← DB は正しい
SHEET.body rev=2 anchor=.start          ← body も正しい値を読んでいる
MENU.build current=.start checked=true  ← メニューも正しく組まれている
```

書き込みも読み戻しも毎回成功しており、**古いのは画面だけ**。しかも**計測を入れると再現しなくなる**
(タイミング依存)。この時点で自前のコードの筋ではなく SwiftUI 側を疑い、CLAUDE.md の決まりどおり
先に検索した ―― macOS の SwiftUI ではメニュー系(MenuBarExtra・ToolbarItem・contextMenu)が
`@State` の変化に追随しない事例が複数報告されており、案内されている回避策も
「`@State` ではなく観測対象(ObservableObject)から描く」ことだった。

### 直し方

`CoverOverrideController` は `ObservableObject` なのに、シートが `@State` で持っていた
(**`@State` に入れた `ObservableObject` は購読されない**)。そのため段階 5 では `coverRevision` を
手で回して描き直しを促していたが、`.contextMenu` の組み直しはそこまで面倒を見てくれない。

- コントローラに `@Published private(set) var revision` を足し、カバーの指定を書くすべての口
  (ページ指定・外部ファイル・既定に戻す・切り取り位置)で `noteCoverDidChange()` を通す。
  `.layoutDataDidChange`(別ウインドウからの変更)もここへ流し込み、契機を1本にする。
- カバーの絵と右クリックメニューを `CoverArea` へ切り出し、`@ObservedObject` で購読する。
  `coverRevision` は削除。
- `.contextMenu` が確実に組み直されるよう `.id(controller.revision)` を掛ける。**掛けるのは
  カバーとメニューだけ**で、ページを選ぶ画面を出しているかどうかの `@State` は外側の `CoverArea`
  が持つ ―― 内側を作り直してもその画面が閉じないようにするため。作り直しが確実、というのは
  画面外セルが解放されない件で `.id(epoch)` だけが効いたのと同じ判断。

**再現しなくなった状態でしか確認できていない**(計測を外した修正版でユーザーが確認)。

## 段階 5.21(要望 2026-09-09). 自動登録をその場で反映する

ユーザー要望: 「10秒経たないと反映されないのではなく、リアルタイムに反映してほしい」。
段階 5.19 の2つの判断(FSEvents を入れない / 一律10秒待つ)をどちらも撤回する。

### 監視する

`FolderChangeWatcher`(新規)= FSEvents の薄い包み。`FileEvents`(フォルダ単位ではなくファイル単位)
+ `NoDefer`(最初のイベントを待たせない)+ `WatchRoot` + `FullHistory`、まとめる時間は 0.3 秒。
**イベントの中身は捨てて「何か変わった」とだけ伝える** ―― どの本が増えたかは走査側がフォルダを
一覧して決める(判定を2箇所に分けない)。監視するのは `FolderAccessStore.isPathCovered` を
通ったパスだけ。

**作りは qooLibrary の実測に合わせた**(ユーザーの指摘 2026-09-09。
`qoo-oji/qooLibrary` の `Sources/QooInfrastructure/Watch/FileSystemEventStream.swift` に、
サンドボックス下で計測した結果が表でまとまっている)。最初に書いたものは3つ穴があった:

1. **`FSEventStreamCreate` はブロックしうる**(到達できない共有上のパスを含めると30秒返らない)。
   メインアクターから同期で呼んでいたので、共有が落ちた瞬間にアプリが固まる作りだった。
   `watch(_:)` を `async` にし、生成はメインアクターの外へ出した。破棄も待たずに投げる。
2. **`context.info` に `self` を `retain`/`release` 無しで渡していた。** 専用の箱を渡して
   retain/release を CF に任せる形へ直した(`self` だと self → stream → self の循環になり
   `deinit` が呼ばれない。箱は `passUnretained` で渡す ―― `retain` 指定の context は CF が
   自分で +1 するため、`passRetained` にすると作り直すたびに漏れる)。
3. **パスを差し替えるたびに `sinceWhen` を「今から」にしていた**ので、止めてから始めるまでの
   変更を取りこぼした。`FSEventStreamGetLatestEventId` を引き継ぐ。生成を待っている間に
   顔ぶれが変わったら作ったものを捨てる世代番号も足した(空集合でも世代は進める)。

C へ渡すコールバックと箱は**ファイル直下**に置く。`@MainActor` の型の内側に書くとメインアクター
隔離とみなされ、FSEvents 自身のキューから呼ばれた時点で `SIGTRAP` で落ちる(qooLibrary の実測)。
`IgnoreSelf` は付けない ―― このアプリ自身が自動登録フォルダへ本を書き出すことがあるため。

**人の操作を契機にする経路は残す。** FSEvents はネットワークボリューム(SMB/AFP)では飛ばず、
アプリが止められている間の変更も取りこぼしうる。監視は「見ている間の即時反映」、従来の契機
(アクティブ化・ボリュームのマウント・画面の表示・コレクションを開く)は「取りこぼしの回収」。

### 一律の待ちをやめ、「書き込みが止まったか」を見る

`CollectionAutoFolderScan.isSettled`:
- 更新時刻が `quietInterval`(2秒)より古ければその場で通す。**同じボリューム内の移動・リネームは
  元の更新時刻を引き継ぐので、ここで即座に入る。**
- そうでなければ、`recheckDelay`(0.5秒)以上空けた前回の観測と**大きさも更新時刻も同じ**ときだけ通す。
- どちらでもないものはその回は見送り、0.5秒後にもう一度見る(`scheduleRecheck`)。

これで、別ボリュームからの大きなコピーは「終わった直後」に入り、小さなファイルは1回の見直しで入る。
未来の時刻・読めないものを通す扱いは据え置き(通さないと永久に登録されない)。

判定は純粋関数(`Observation` を突き合わせるだけ)にしてあるので、実時間を待たずにテストできる
―― 境界を7本(古い更新は即通す / 1回目は通さない / 間隔を空けた同一は通す / 増えている間は通さない /
近すぎる2回は通さない / 未来は通す / 実ファイルから読める)。

## 段階 5.22(要望 2026-09-09). コレクションの中で、カバーの下に情報を出す

コレクションを開いた画面(`CollectionDetailView`)で、本のカバーの下に文字を添えられるようにする。
選べるのは3つ ―― **表示しない(既定)/ ファイル名 / タイトル**(`CollectionCoverCaptionStyle`)。

### コレクションごとの設定にはしない

最初はコレクションの設定(歯車 → `CollectionSettingsPopover`)へ置く案だったが、あの面は
**コレクション1つだけに効く**ので、棚ごとに下の文字が変わることになる ―― 一覧としての見え方が
揃わないうえ、棚を作るたびに設定し直すことになる(ユーザーの判断)。

置き場所は**環境設定「外観」→「ウェルカム画面」**(`PanelSurfaceSettingsView.welcomeSection`)。
ページ一覧の「サムネイルの下の表示」がまったく同じ形でそこにあるので、それに合わせた。
「1つのパネルの見た目を決める設定は必ず同じページに揃える」という「外観」の方針
(`AppearanceSettingsView` 冒頭)にも沿う ―― ウェルカム画面はすりガラス面の1つ
(`PanelSurface.welcome`)で、自分のページを既に持っている。

`AppPreferences.collectionCoverCaptionStyle`(UserDefaults)。**既定は「表示しない」** ――
従来の見え方を1ピクセルも変えない側に倒す(面ごとの既定値と同じ考え方)。
「初期設定に戻す」の担当も「外観」(`keys(for:)` / `apply(_:for:)` の両方へ足すこと)。

**「文字の大きさ」も同じセクションに置く**(ユーザー要望 2026-09-09)。
`collectionCoverCaptionFontSize`(既定 10pt = `.caption` の実寸そのもの。範囲 8〜20pt は
ページ一覧・フィルムストリップと同じ)。**「表示しない」のときは灰色にする** ―― 効かない設定を
触れるままにしておくと壊れているように見えるため(ページ一覧の同じ行と同じ扱い)。

**一覧(札)のコレクション名の大きさ**も同じページに置く(ユーザー要望 2026-09-09)。
`collectionTileNameFontSize`(既定 13pt = 設定にする前の `Text` の既定 = macOS の `.body`)。
`CollectionTile` は環境を読まない部品なので、値は `CollectionGridView` が引数で渡す。
帳簿の下限セル数の札の高さ(定数 24 だった)も、この値から出す
(`(大きさ × 1.3).rounded(.up) + 6`。6pt は絵と名前の間隔)。

### セクションは画面の階層に合わせて2つに分ける

一度は「コレクション」1つのセクションに3行(名前の大きさ / カバーの下の表示 / 文字の大きさ)を
まとめたが、**一覧側の設定と中身側の設定が混ざって読めなかった**(ユーザー指示 2026-09-09:
「コレクションとひとまとめにされると分かりづらい」)。

- **ライブラリ**(`librarySection`) … コレクションの一覧(札)の見え方。並んでいるのは
  コレクションなので「コレクション名の大きさ」。
- **コレクション**(`collectionSection`) … コレクションを開いた中の見え方。
  「カバーの下の表示」と、その「文字の大きさ」。

この順に並ぶのは、画面としても一覧を見てから中へ入るため。なお**カバーの縦横比・切り取る位置・
札の地の色はライブラリごとの設定**なので、ここではなくウェルカム画面の歯車
(`LibrarySettingsPopover`)のまま ―― あちらはライブラリを選んでから決めるもので、アプリ全体の
外観ではない。

### 「タイトル」は「メタデータの編集」と同じものを出す

`MetadataEditorViewModel.initialDraft(forBookID:baseName:metadataStore:formatStore:)` をそのまま
通す ―― **登録済みならDBの値、未登録ならファイル名からの推測値**(除外文字列 → ファイル名
フォーマット → 巻数フォーマット。`BookMetadataDeriver`)。同じ関数を通しているので、右クリックの
「メタデータの編集」を開いて確かめた文字列と、カバーの下の表示が食い違うことはない。

どちらも空のとき(タイトルだけ空にして登録した本・推測が何も拾えなかった本)は、拡張子を除いた
ファイル名へ落とす。空文字のまま出すと、その1冊だけ下の行が潰れて高さが揃わない。

推測は**毎回その場で行い、結果は覚えておかない**。1冊ぶんならメインアクター上でも一瞬で終わり、
`LazyVGrid` が組み立てるのは見えているセルだけなので、数千行をまとめて処理する
`MetadataEditorViewModel`(`derivedCache`)とは事情が違う。覚えると、メタデータの登録・フォーマットの
変更のたびに捨てる契機を自分で持つことになる(ストアはどちらも `@EnvironmentObject` なので、
変わればそのまま描き直される)。

### 見た目

カバーとの間は4pt、1行、中略は真ん中。すりガラス面に直接置く文字なので
`.panelOutlinedContent()`(CLAUDE.md の表)。**選択中の枠と印はカバーにだけ掛ける** ――
下の文字まで枠で囲むと、選んだ範囲がカバー1枚に見えなくなる。帳簿の下限セル数
(`minimumCellCount`)の高さにも、文字のぶん(`(文字の大きさ × 1.3).rounded(.up) + 4`。
`ThumbnailGridView` がキャプションのぶんを見込むのとまったく同じ式)を足す。

テストは `AppPreferencesTests` の総なめ(既定値・保存・「外観」の担当)に載る。表示そのものは
画面を動かして確かめる。

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
