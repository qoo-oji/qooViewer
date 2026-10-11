import Foundation

/// 本ごとのディスクキャッシュ(ページ一覧 `BookPageListCache` とページのサムネイル `ThumbnailDiskCache`)の組。
///
/// ■ なぜ組にして持ち回すのか(2026-10-11 の「GUI 無しで確かめる口」の点検)
/// 以前は読み込み・表示の各所が `BookPageListCache.shared` / `ThumbnailDiskCache.shared` を直に読み、テストは
/// `cachesPageList: false` / `usesThumbnailDiskCache: false` / `usesDiskCaches: false` の旗でキャッシュの経路ごと止めていた
/// (テストが利用者のキャッシュへ書かないため)。その結果、構造キャッシュからの組み立て直し・サムネイルのディスク読み書き・
/// ページ寸法の持ち越し・「ファイルに何も無かった」記録(`sourceProbe`)の経路は、テストで一度も走っていなかった。
/// 置き場所を差し替えられるようにすれば、テストは一時フォルダのキャッシュでその経路をそのまま通せる。
///
/// **旗は残してある。** `cachesPageList: false` などは「この本はキャッシュを読み書きしない」(シークレットウインドウ・
/// シークレットフォルダの本)という約束そのもので、置き場所の選択とは別の話だから。旗が false なら、ここで何を渡しても
/// キャッシュには触らない。
nonisolated struct BookDiskCaches: Sendable {
    let pageLists: BookPageListCache
    let thumbnails: ThumbnailDiskCache

    /// アプリ本体が使う既定の組(利用者のキャッシュディレクトリ)。
    static let shared = BookDiskCaches(pageLists: .shared, thumbnails: .shared)

    init(pageLists: BookPageListCache, thumbnails: ThumbnailDiskCache) {
        self.pageLists = pageLists
        self.thumbnails = thumbnails
    }

    /// `directory` の下に 2 つのキャッシュを作る(テストの口)。サムネイルのキャッシュは既定で無効なので、
    /// 使う側が `configure(isEnabled: true, …)` を押し込むこと(`ThumbnailDiskCache.Configuration` 参照)。
    init(directory: URL) {
        let pageLists = directory.appendingPathComponent("BookPageLists", isDirectory: true)
        let thumbnails = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        // ページ一覧の保管庫は自分ではフォルダを作らない(既定の置き場所は `shared` を作るときに作られる)。
        for folder in [pageLists, thumbnails] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        self.init(
            pageLists: BookPageListCache(directory: pageLists),
            thumbnails: ThumbnailDiskCache(directory: thumbnails)
        )
    }
}
