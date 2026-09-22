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
/// - 繋がっていないボリュームとネットワークのボリュームの本は見ない(ブックマークの解決が秒単位で止まる)。判定は `MountTable`
///   だけで、ファイルシステムには触らない(`isLocallyReachable`)。以前は `/Volumes/<名前>` の `fileExists` をメインで本ごとに
///   呼んでいて、切れたネットワークの共有があると起動が固まりえた(2026-09-22 の監査)。
/// - ゴミ箱の中へ移った本は付け替えない(`locateAtRecordedPath` が「無い」にする)。
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
        let probes = known.sorted().map { bookID in
            BookExistenceProbe.make(
                bookID: bookID, metadataStore: metadataStore, layoutStore: layoutStore, bookmarkStore: bookmarkStore,
                favoritesStore: favoritesStore, collectionStore: collectionStore, folderAccess: folderAccess)
        }.filter { !$0.bookmarkCandidates.isEmpty }
        guard !probes.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let mounts = MountTable.current()
            return probes.compactMap { probe -> FileSystemChange.Relocation? in
                guard isLocallyReachable(probe.bookID, mounts: mounts),
                      let movedTo = probe.locateAtRecordedPath().movedTo else { return nil }
                return .init(from: URL(fileURLWithPath: probe.bookID), to: URL(fileURLWithPath: movedTo))
            }
        }.value
    }

    /// ビューアで開いている本(とその中・その上のフォルダ)に当たる付け替えを外す(2026-09-22 の監査)。
    ///
    /// ビューアは「開いている間は `bookID` が変わらない」前提で、レイアウト・ブックマークを `bookID` で読み直し・書き込む。
    /// アプリの中の操作は開いている本を動かすこと自体を断る(`FileBrowserOperations.refusesBecauseOpenInViewer`)が、アプリの外での
    /// 移動は止められないので、付け替えのほうを見送る。開いたまま付け替えると、読んでいる途中でレイアウトとブックマークが外れ、
    /// その後の書き込みが古いパスに行を作って保存データが 2 か所に割れた。見送った本は、閉じた後の実在確認・次の起動・次に
    /// 開いたときの追従(`reconcileBookIDIfMoved`)で付け替わる。
    nonisolated static func excludingOpenBooks(
        _ relocations: [FileSystemChange.Relocation], openBookIDs: Set<String>
    ) -> [FileSystemChange.Relocation] {
        guard !openBookIDs.isEmpty else { return relocations }
        let openPaths = openBookIDs.map { URL(fileURLWithPath: $0) }
        return relocations.filter { relocation in
            FileBrowserOperations.openBookConflict(among: [relocation.from, relocation.to], openBookPaths: openPaths.map(\.path)) == nil
        }
    }

    /// いま繋がっていて、ネットワーク越しでないボリュームの上の本か。マウントの表(`MountTable`)だけで決め、パスには触らない
    /// (`URL.standardizedFileURL` もパスの実在を見るので使わない)。
    nonisolated static func isLocallyReachable(_ path: String, mounts: MountTable) -> Bool {
        let url = URL(fileURLWithPath: path)
        return !mounts.isOnAnUnmountedVolume(url) && !mounts.isRemote(url)
    }
}
