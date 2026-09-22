import Foundation
import SwiftData

/// 本ではないフォルダ(棚・中間のフォルダ・空のフォルダ)の保存データを、起動時に消す(2026-09-22、利用者の指示)。
///
/// 棚(本が並んでいるだけのフォルダ)を開くと、今は中の先頭の本を開く(`ShelfFolderResolver`、2026-09-06 から)。それより前は
/// 棚をまるごと 1 冊として開いていたので、そのときの読書位置などがフォルダのパスで残っている。それを「このアプリが知っている本」
/// (`KnownBooks`)として、メタデータの編集ウインドウが並べ・登録し直し、削除しても戻ってきた。
///
/// - 対象は、書庫・PDF・EPUB の名前ではない `bookID` のうち、**その場所にあって中を読めて、本ではないと確かめられたフォルダ**
///   だけ(`BookExistenceProbe.isNonBookFolderAtRecordedPath`)。無い・読めない・繋がっていないボリュームのものは消さない
///   (本かどうか分からない)。
/// - 消すのは保存データ一式(`BookSavedDataEraser.deleteAllData`: お気に入り・コレクションの項目・ブックマーク・レイアウト・
///   メタデータ・読書位置)。本ではないので、どれも意味を持たない。
/// - ライブラリ機能が OFF でも走る(保存データを正しく保つ仕事。`AppStores.applyLibraryFeature` の型コメントの決まり)。
@MainActor
enum NonBookFolderSweeper {
    /// 消した本の数。
    @discardableResult
    static func sweep(
        favoritesStore: FavoritesStore, collectionStore: CollectionStore, bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore, metadataStore: BookMetadataStore, folderAccess: FolderAccessStore,
        modelContext: ModelContext
    ) async -> Int {
        let known = KnownBooks.collect(from: KnownBooks.Sources(
            metadataStore: metadataStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
            favoritesStore: favoritesStore, collectionStore: collectionStore, modelContext: modelContext))
        let probes = candidates(in: known).map { bookID in
            BookExistenceProbe.make(
                bookID: bookID, metadataStore: metadataStore, layoutStore: layoutStore, bookmarkStore: bookmarkStore,
                favoritesStore: favoritesStore, collectionStore: collectionStore, folderAccess: folderAccess)
        }
        guard !probes.isEmpty else { return 0 }
        // ファイルに触る(ブックマークの解決は繋がっていないボリュームで秒単位止まる)ので、メインの外で。
        let targets = await Task.detached(priority: .utility) {
            probes.filter { $0.isNonBookFolderAtRecordedPath() }.map(\.bookID)
        }.value
        guard !targets.isEmpty else { return 0 }
        BookSavedDataEraser(
            favoritesStore: favoritesStore, collectionStore: collectionStore, bookmarkStore: bookmarkStore,
            layoutStore: layoutStore, metadataStore: metadataStore, modelContext: modelContext
        ).deleteAllData(forBookIDs: targets.sorted())
        return targets.count
    }

    /// フォルダでありうる `bookID`(書庫・PDF・EPUB の名前のものは除く。数千冊のファイルの本に触らないため)。
    nonisolated static func candidates(in bookIDs: Set<String>) -> [String] {
        bookIDs.filter { !isArchiveFile($0) && !isPDFFile($0) && !isEpubFile($0) }.sorted()
    }
}
