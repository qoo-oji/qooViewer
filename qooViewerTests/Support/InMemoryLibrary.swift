import Foundation
import SwiftData

@testable import qooViewer

/// 保存データ(お気に入り・ブックマーク・レイアウト設定・書誌メタデータ)を持つ、
/// **テスト 1 つぶんのライブラリ**。
///
/// `ModelConfiguration(isStoredInMemoryOnly: true)` の `ModelContainer` をテストが自前で作り、
/// その `mainContext` の上にアプリと同じ 4 つのストアを載せる。**実物のアプリの
/// `QooViewerApp.modelContainer.mainContext` には触れない** ―― テストは TEST_HOST =
/// 実物のアプリの中で走るので、あちらへ書くと利用者の保存データが増減してしまう。
///
/// スキーマはアプリのものをそのまま使う(`QooViewerApp.modelSchema`)。モデル型の一覧を
/// ここへ書き写すと、アプリにモデルを足したときにテストだけ古いスキーマで走り続けてしまう。
///
/// 1 つの `ModelContext` を 4 つのストアで共有するのもアプリと同じ(CLAUDE.md /
/// docs/06。コンテキストを分けると片方の変更がもう片方に見えない)。
///
/// ■ このライブラリを作ると、走っているアプリ側に少しだけ触れる
/// - `FavoritesStore` / `BookmarkStore` は固定のキーで `MenuBarMenuGate.shared` へ
///   「メニューを閉じたら一覧を作り直す」処理を登録する(アプリ全体で 1 つという前提)。
///   同じキーなので、テストのストアの登録がアプリのストアの登録を**置き換える**。置き換えた
///   処理はテストのストアが消えた時点で何もしなくなるが、影響はテストホストのメニューの
///   更新だけで、保存されるものは何も無い。
/// - ブックマークの書き込みは `NotificationCenter.default` へ `.bookmarksDidChange` を投げる。
///   アプリ側のストアはこれを受けて**自分の**保存先を読み直すだけ(読み取りのみ)。
@MainActor
final class InMemoryLibrary {
    let container: ModelContainer
    let context: ModelContext
    let favorites: FavoritesStore
    let bookmarks: BookmarkStore
    let layouts: LayoutStore
    let metadata: BookMetadataStore
    /// メタデータ推測のルールだけは SwiftData ではなく `UserDefaults` に載っているため、
    /// このライブラリ専用の領域(suite)を渡す。`UserDefaults.standard` に書くと利用者の
    /// ルールを書き換えてしまう。
    let metadataFormats: MetadataFormatStore
    private let metadataFormatsSuiteName: String

    init(label: String = "library") throws {
        let configuration = ModelConfiguration(
            schema: QooViewerApp.modelSchema, isStoredInMemoryOnly: true
        )
        container = try ModelContainer(for: QooViewerApp.modelSchema, configurations: [configuration])
        context = container.mainContext
        favorites = FavoritesStore(modelContext: context)
        bookmarks = BookmarkStore(modelContext: context)
        layouts = LayoutStore(modelContext: context)
        metadata = BookMetadataStore(modelContext: context)
        metadataFormatsSuiteName = "qooViewerTests.\(label).\(UUID().uuidString)"
        metadataFormats = MetadataFormatStore(
            defaults: UserDefaults(suiteName: metadataFormatsSuiteName) ?? .standard
        )
    }

    deinit {
        // `TemporaryDirectory` と同じ後始末。メモリ内のコンテナはここで手放されて消えるが、
        // `UserDefaults` の領域はファイルとして残るので明示的に消す。
        UserDefaults().removePersistentDomain(forName: metadataFormatsSuiteName)
    }

    // MARK: - 取り込み / 書き出し

    /// `LibraryImportExportService.apply` を、このライブラリの 5 つのストアへ通す。
    /// `cachesPageList: false` は固定 ―― 取り込みは本を読み直すので、既定のままだと
    /// 実物のアプリのページ一覧キャッシュ(`BookPageListCache`)へテスト用の本が残る。
    @discardableResult
    func apply(
        _ file: QooLibraryExportFile, policies: LibraryImportExportService.ImportPolicies
    ) async -> LibraryImportExportService.ImportSummary {
        await LibraryImportExportService.apply(
            file, policies: policies,
            favoritesStore: favorites, bookmarkStore: bookmarks, layoutStore: layouts,
            metadataStore: metadata, metadataFormatStore: metadataFormats,
            cachesPageList: false
        )
    }

    /// `LibraryImportExportService.buildExportFile` を、このライブラリの 5 つのストアから。
    /// `cachesPageList: false` の理由は `apply` と同じ。
    ///
    /// 既定値(`= .everything`)は付けられない ―― **既定引数の式はメインアクターの外として
    /// 検査される**ので、メインアクターに分離された型の静的プロパティは書けない
    /// (`ExportHarness` に同じ落とし穴の記録がある)。
    func buildExportFile(
        _ selection: LibraryImportExportService.ExportSelection
    ) async -> (QooLibraryExportFile, LibraryImportExportService.ExportResult) {
        await LibraryImportExportService.buildExportFile(
            selection: selection,
            favoritesStore: favorites, bookmarkStore: bookmarks, layoutStore: layouts,
            metadataStore: metadata, metadataFormatStore: metadataFormats,
            cachesPageList: false
        )
    }

    // MARK: - 中身を読む(期待値の組み立て用)

    /// フォルダ階層を `親/子/本` のパスの列にしたもの(並びは `FavoritesStore` の一覧順)。
    /// お気に入りの木を 1 つの値として比べられるようにするためのもの。
    func favoriteBookPaths() -> [String] {
        var result: [String] = []
        func walk(_ folder: FavoriteFolder?, prefix: String) {
            for book in favorites.books(in: folder) {
                result.append(prefix + book.title)
            }
            for subfolder in favorites.subfolders(of: folder) {
                walk(subfolder, prefix: prefix + subfolder.name + "/")
            }
        }
        walk(nil, prefix: "")
        return result
    }

    /// この本のブックマークを (ページ番号, 鍵, 名前) の列で。ページ番号順。
    func bookmarkRows(forBookID bookID: String) -> [(pageIndex: Int, pageKey: String?, name: String)] {
        bookmarks.bookmarks(forBookID: bookID)
            .sorted { $0.pageIndex < $1.pageIndex }
            .map { (pageIndex: $0.pageIndex, pageKey: $0.pageKey, name: $0.name) }
    }

    /// この本のページ単位設定を 鍵 → 状態 の辞書で。
    func pageStates(forBookID bookID: String) -> [String: PageLayoutState] {
        Dictionary(
            layouts.pageOverrides(forBookID: bookID).map { ($0.pageKey, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

extension LibraryImportExportService.ExportSelection {
    /// 5 カテゴリすべてを書き出す選択。
    static let everything = Self(
        includeFavorites: true, includeBookmarks: true, includeLayouts: true,
        includeMetadata: true, includeMetadataFormats: true
    )
}

extension LibraryImportExportService.ImportPolicies {
    /// 5 カテゴリすべてを同じ方針で取り込む(フォーマット定義は overwrite / ignore の 2 択なので、
    /// merge を渡した場合はそのまま渡す ―― `applyMetadataFormats` は方針の値を見ずに
    /// 丸ごと差し替えるため、ignore 以外は同じ意味になる)。
    static func all(_ policy: LibraryImportExportService.ImportPolicy) -> Self {
        Self(
            favorites: policy, bookmarks: policy, layouts: policy, metadata: policy,
            metadataFormats: policy
        )
    }
}
