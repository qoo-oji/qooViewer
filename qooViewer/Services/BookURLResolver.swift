import Foundation

/// bookID(ファイル/フォルダのパス)から、実際に開けるURLを解決する処理を、メインアクターの
/// 外でも実行できる形に切り出したもの。
///
/// EPUB出力・PDF出力ウインドウは、一覧を組み立てる時点で「登録済みの本のうち、元のファイルが
/// 今も存在するもの」だけに絞り込む。この判定はセキュリティスコープ付きブックマークの解決を
/// 伴い、対象が未接続の外付け/ネットワークボリュームを指していると1件あたり秒単位ブロックし
/// うる。登録済みの本の数だけ繰り返されるため、以前はウインドウを開くだけでメインスレッドが
/// その間ずっと止まっていた。
///
/// SwiftDataから各ストアのブックマークデータを集める部分だけを呼び出し側(メインアクター)が
/// 行い、ここへはSendableな値だけを渡す。
///
/// `nonisolated`: このプロジェクトの既定のアクター隔離はMainActorのため、明示しないと
/// メインアクター限定になってしまう(Services/ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum BookURLResolver {
    /// 1冊分の解決材料。優先順位は、従来の
    /// `bookmarkStore.resolvedURLFromBookmarkData ?? layoutStore.resolvedURL ?? metadataStore.resolvedURL`
    /// という呼び出しの連鎖をそのまま写したもの(挙動を変えないため、素のパスへのフォールバックが
    /// どの段階で効くかも含めて同じ順序で評価する)。
    struct Candidates: Sendable {
        let bookID: String
        /// ブックマーク側の候補(複数)。こちらは素のパスへフォールバックしない。
        let bookmarkStoreBookmarks: [Data]
        /// レイアウト設定側の候補。解決できなければ素のパスへフォールバックする。
        let layoutBookmark: Data?
        /// メタデータ側の候補。解決できなければ素のパスへフォールバックする。
        let metadataBookmark: Data?
    }

    static func resolvedURL(_ candidates: Candidates) -> URL? {
        // 1. BookmarkStore相当(フォールバック無し)
        for data in candidates.bookmarkStoreBookmarks {
            if let url = resolvedExistingURL(fromBookmark: data) { return url }
        }
        // 2. LayoutStore相当(ブックマーク → 素のパス)
        if let url = resolvedURL(fromBookmark: candidates.layoutBookmark, bookID: candidates.bookID) {
            return url
        }
        // 3. BookMetadataStore相当(ブックマーク → 素のパス)
        return resolvedURL(fromBookmark: candidates.metadataBookmark, bookID: candidates.bookID)
    }

    private static func resolvedExistingURL(fromBookmark data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func resolvedURL(fromBookmark data: Data?, bookID: String) -> URL? {
        if let data, let url = resolvedExistingURL(fromBookmark: data) { return url }
        let fallbackURL = URL(fileURLWithPath: bookID)
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }
        return fallbackURL
    }
}
