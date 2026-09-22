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
///   (本かどうか分からない)。繋がっていないボリュームとネットワークのボリュームのフォルダは調べもしない
///   (`ExternalMoveSweeper.isLocallyReachable`。ブックマークの解決が止まる・ディスクイメージを勝手にマウントしうる。2026-09-22 の監査)。
///   外付けのフォルダは、記録したボリュームの UUID が今のボリュームと一致するものだけ(UUID を記録していない記録は消さない)。
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
        let bookIDs = candidates(in: known)
        let probes = bookIDs.map { bookID in
            BookExistenceProbe.make(
                bookID: bookID, metadataStore: metadataStore, layoutStore: layoutStore, bookmarkStore: bookmarkStore,
                favoritesStore: favoritesStore, collectionStore: collectionStore, folderAccess: folderAccess)
        }
        guard !probes.isEmpty else { return 0 }
        // 外付けの本は、記録したボリュームの UUID と今そこにあるボリュームの UUID が同じときだけ消す(2026-09-22 の監査。
        // `/Volumes/<名前>` の名前は別のディスクでも同じになりうるので、同じ名前の別のディスクのフォルダを見て消しかねない)。
        var recordedVolumes: [String: Set<String>] = [:]
        for bookID in bookIDs where MountTable.volumeRoot(of: bookID) != nil {
            let identifiers = [metadataStore.metadata(forBookID: bookID)?.fileNodeIdentifier,
                               layoutStore.bookLayoutSettings(forBookID: bookID)?.fileNodeIdentifier]
                + collectionStore.items(forBookID: bookID).map(\.fileNodeIdentifier)
                + favoritesStore.existingFavorites(forBookID: bookID).map(\.fileNodeIdentifier)
            recordedVolumes[bookID] = Set(identifiers.compactMap { $0?.volumeUUID })
        }
        // ファイルに触る(ブックマークの解決は繋がっていないボリュームで秒単位止まる)ので、メインの外で。
        let targets = await Task.detached(priority: .utility) {
            let mounts = MountTable.current()
            var currentVolumes: [String: String?] = [:]
            return probes.filter { probe in
                guard ExternalMoveSweeper.isLocallyReachable(probe.bookID, mounts: mounts) else { return false }
                if let root = MountTable.volumeRoot(of: probe.bookID) {
                    if currentVolumes[root] == nil {
                        currentVolumes[root] = .some(mounts.volumeIdentifier(URL(fileURLWithPath: root, isDirectory: true)))
                    }
                    guard let current = currentVolumes[root] ?? nil,
                          recordedVolumes[probe.bookID]?.contains(current) == true else { return false }
                }
                return probe.isNonBookFolderAtRecordedPath()
            }.map(\.bookID)
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
