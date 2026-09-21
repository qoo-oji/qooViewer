import Foundation
import SwiftData

/// 本の実体があるかを確かめる材料と、その判定(「本ごとの保存データを削除」ウインドウとメタデータの編集ウインドウが使う)。
///
/// 元は LibraryCleanupViewModel の中にあった(2026-09-21、メタデータの編集ウインドウの「実体の無い本の削除」で同じ判定が
/// 要るので切り出した)。判定の順序と理由は `evaluate` のコメント。メインアクターの外で判定するので、材料は Sendable な値で持つ。
nonisolated struct BookExistenceProbe: Sendable {
    enum Result: Sendable, Equatable {
        case exists
        case missing
        /// アクセス権が無く判定できない(外付けボリュームが未接続の場合などもここに入る)。
        case unknown
    }

    let bookID: String
    /// この本を指すセキュリティスコープ付きブックマークの候補(各ストアから集めた順)。
    let bookmarkCandidates: [Data]
    /// 環境設定「フォルダのアクセス権」で許可済みのフォルダ配下かどうか。
    let isPathCovered: Bool

    /// メインアクターで、ストアから材料を集める。
    @MainActor
    static func make(
        bookID: String, metadataStore: BookMetadataStore, layoutStore: LayoutStore, bookmarkStore: BookmarkStore,
        favoritesStore: FavoritesStore, collectionStore: CollectionStore, folderAccess: FolderAccessStore
    ) -> BookExistenceProbe {
        BookExistenceProbe(
            bookID: bookID,
            bookmarkCandidates: [
                metadataStore.metadata(forBookID: bookID)?.bookmarkData,
                layoutStore.bookLayoutSettings(forBookID: bookID)?.bookmarkData,
                bookmarkStore.anyBookmarkData(forBookID: bookID),
                favoritesStore.anyBookmarkData(forBookID: bookID),
                collectionStore.anyBookmarkData(forBookID: bookID),
            ].compactMap { $0 },
            isPathCovered: folderAccess.isPathCovered(URL(fileURLWithPath: bookID))
        )
    }

    /// 元のファイル/フォルダが今も存在するかどうかを判定する。**ブロッキングする**(ブックマークの解決は、未接続の
    /// 外付け/ネットワークボリュームを指していると秒単位で止まる)ので、メインアクターの外で呼ぶ。
    ///
    /// 判定の順序:
    /// 1. いずれかのストアが持つセキュリティスコープ付きブックマークからURLを解決できるなら、
    ///    それを開いて確認する(最も確実。環境設定「フォルダのアクセス権」でフォルダを許可していなくても判定できる)。
    /// 2. 解決できない場合でも、環境設定「フォルダのアクセス権」で許可済みのフォルダ配下のパスなら、
    ///    素のパスに対する存在確認の結果をそのまま信用してよい。
    /// 3. どちらでもない場合、存在確認が成功すれば存在する(見えている以上は確実)。
    ///    失敗した場合は「無い」のか「アクセス権が無くて見えない」のか区別できないため、
    ///    `.unknown` として扱う(誤って「消えた」と表示して削除を促さないため)。
    func evaluate() -> Result {
        for data in bookmarkCandidates {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            return FileManager.default.fileExists(atPath: url.path) ? .exists : .missing
        }
        if FileManager.default.fileExists(atPath: bookID) { return .exists }
        return isPathCovered ? .missing : .unknown
    }
}

/// 本に関する保存データを、種類を問わずすべて削除する(お気に入り・コレクション・ブックマーク・レイアウト・メタデータ・
/// 読書履歴)。「本ごとの保存データを削除」ウインドウとメタデータの編集ウインドウの右クリックが使う。
///
/// 読書履歴(BookReadingState)まで消すのは、これを残すと「メタデータの編集」ウインドウにも掃除のウインドウにも、
/// その本の行が出続けてしまうため(LibraryCleanupViewModel.deleteAllData のコメント)。
@MainActor
struct BookSavedDataEraser {
    let favoritesStore: FavoritesStore
    let collectionStore: CollectionStore
    let bookmarkStore: BookmarkStore
    let layoutStore: LayoutStore
    let metadataStore: BookMetadataStore
    let modelContext: ModelContext

    func deleteAllData(forBookIDs bookIDs: [String]) {
        for bookID in bookIDs {
            favoritesStore.removeFavorites(forBookID: bookID)
            collectionStore.removeItems(forBookID: bookID)
            bookmarkStore.deleteAllBookmarks(forBookID: bookID)
            layoutStore.discardLayoutData(forBookID: bookID)
            metadataStore.delete(forBookID: bookID)
        }
        // 読書履歴だけは、本ごとではなく最後にまとめて消す(deleteReadingStates 参照)。
        deleteReadingStates(forBookIDs: Set(bookIDs))
    }

    /// 読書履歴の削除。BookReadingStateは専用のストアクラスを持たず(ViewerViewModelが直接
    /// ModelContextを操作している)、ここでも同じくModelContext経由で削除する。
    ///
    /// #Predicateによる絞り込みフェッチは使わず、全件フェッチしてSwift側で選別する
    /// (LayoutStore.bookLayoutSettings(forBookID:)のコメントと同じ理由: 絞り込みフェッチが
    /// 誤って0件を返す事象を踏んでいるため、このプロジェクトでは一貫して避けている)。
    ///
    /// 全件フェッチが必要という制約があるからこそ、本1冊ごとではなく**まとめて**受け取る
    /// (1冊ごとに呼ぶと、N冊消すと全件フェッチとsave()がN回ずつ走る)。
    private func deleteReadingStates(forBookIDs bookIDs: Set<String>) {
        guard !bookIDs.isEmpty else { return }
        let states = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        let matched = states.filter { bookIDs.contains($0.bookID) }
        guard !matched.isEmpty else { return }
        for state in matched {
            modelContext.delete(state)
        }
        try? modelContext.save()
        // 消した本を今開いているウインドウがあれば、そのViewerViewModelは削除済みの行を
        // 握ったまま(同じModelContextなので同じオブジェクト)。以後そこへ書かせない
        // (Notification.Name.bookReadingStatesDidDeleteのコメント参照。監査で指摘)。
        NotificationCenter.default.post(
            name: .bookReadingStatesDidDelete, object: nil,
            userInfo: [BookReadingStateDeletionNotification.bookIDsUserInfoKey: Set(matched.map(\.bookID))]
        )
    }
}
