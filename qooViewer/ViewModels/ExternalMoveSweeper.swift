import Foundation
import SwiftData

/// アプリの外(Finder など)で名前を変えた・移した本の保存データを、起動後に新しいパスへ付け替える(2026-09-22、利用者の指示)。
///
/// 付け替えないと、その本を開くまで(読書位置とメタデータは開いても)古いパスのまま残り、次のことが起きていた:
/// 読書位置が消えて 1 ページ目から始まる、直したメタデータとロックが新しい名前の本に付いてこない(解析した本はすべて登録する
/// ので、新しいパスに読みだけの行が先にできる)、ライブラリのキャプション・タイトル・並べ替え・検索が古いまま、ブックマーク・
/// レイアウトの編集や掃除のウインドウに古い名前で並ぶ、自動で追加するフォルダの走査が毎回その本を足そうとする。
///
/// - 手がかりは各ストアの行が持つセキュリティスコープ付きブックマーク(`BookExistenceProbe.locateAtRecordedPath` の `movedTo`)。
///   ブックマークを持たない記録(読書位置だけの本)は追えない。
/// - コレクションの本は、ライブラリ機能が ON ならコレクションの実在確認(`CollectionStore.onBooksFoundAtNewPaths`)が同じことを
///   するので、ここでは見ない(全冊のブックマークを 2 度解決しない)。
/// - 繋がっていないボリュームの本は見ない(ブックマークの解決が秒単位で止まる)。
/// - 付け替えはアプリの中での移動・改名と同じ `BookRecordRelocator`。
@MainActor
enum ExternalMoveSweeper {
    /// 別の場所に見つかった本(古いパス → 新しいパス)。付け替えは呼び出し側。
    static func movedBooks(
        favoritesStore: FavoritesStore, collectionStore: CollectionStore, bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore, metadataStore: BookMetadataStore, folderAccess: FolderAccessStore,
        modelContext: ModelContext, skipsCollectionBooks: Bool
    ) async -> [FileSystemChange.Relocation] {
        var known = KnownBooks.collect(from: KnownBooks.Sources(
            metadataStore: metadataStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
            favoritesStore: favoritesStore, collectionStore: collectionStore, modelContext: modelContext))
        if skipsCollectionBooks { known.subtract(collectionStore.allRegisteredBookIDs()) }
        let probes = known.filter(isOnMountedVolume).sorted().map { bookID in
            BookExistenceProbe.make(
                bookID: bookID, metadataStore: metadataStore, layoutStore: layoutStore, bookmarkStore: bookmarkStore,
                favoritesStore: favoritesStore, collectionStore: collectionStore, folderAccess: folderAccess)
        }.filter { !$0.bookmarkCandidates.isEmpty }
        guard !probes.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            probes.compactMap { probe -> FileSystemChange.Relocation? in
                guard let movedTo = probe.locateAtRecordedPath().movedTo else { return nil }
                return .init(from: URL(fileURLWithPath: probe.bookID), to: URL(fileURLWithPath: movedTo))
            }
        }.value
    }

    /// `/Volumes/<名前>/…` の本は、そのボリュームが今あるときだけ(起動ディスクの本は常に)。
    nonisolated static func isOnMountedVolume(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + components[2])
    }
}
