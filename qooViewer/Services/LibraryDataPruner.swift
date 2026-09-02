import Foundation
import SwiftData

/// 本ごとの読書状態(BookReadingState。最後に読んだページ・表示モード・読み方向など)が、
/// 時間の経過とともに際限なく増え続けないようにする。
///
/// qooViewerは開いたことのある本ごとに1件のBookReadingStateをSwiftDataに保存し続けるため、
/// 長期間使い続けて多数の異なる本(フォルダ/アーカイブファイル)を開くと、二度と開かれない
/// 古い本のデータがデータベースに残り続けてしまう。これを避けるため、BookReadingStateの
/// 総数が環境設定の上限を超えたら、最後に読んだ時刻(updatedAt)が最も古いものから順に削除する。
///
/// 以前はここでBookReadingStateに紐づくBookmarkもあわせて削除していたが、「手間をかけて
/// 作ったブックマーク・レイアウト設定が、単に読書履歴が古くなったというだけでアプリの都合により
/// 勝手に消えることを避けたい」という方針(設計コンセプト10.3節)により、この連動削除は廃止した。
/// Bookmark/BookLayoutSettings/PageLayoutOverrideはこのプルーナーの対象外とし、無制限に保持する。
/// 不要になったブックマーク・レイアウト設定は、「ブックマーク・レイアウトの編集」ウインドウから
/// 手動で削除する(一括削除ボタンも含む)。
enum LibraryDataPruner {
    /// 新しい本を開いた(BookReadingStateを新規作成した)直後に呼ぶ。
    /// maxTrackedBooks以下のときは何もしない。
    ///
    /// - Parameter excludedBookIDs: 削除の対象から外す本(今どこかのウインドウ/タブで開いて
    ///   いる本。ViewerViewModel.openBookIDs参照)。開いている本のViewerViewModelは自分の
    ///   BookReadingStateの行を握ったままページ送りのたびに書き込むため、ここで消してしまうと
    ///   削除済みのオブジェクトへの書き込みになる(SwiftDataでは未定義。監査で指摘)。
    ///   長時間放置しているウインドウの本は`updatedAt`が古く、別のウインドウで次々に
    ///   本を開くと削除の候補に上がりうるので、件数ではなく本で除外する。除外したぶんは
    ///   その次に古い本を削るので、総数の上限は変わらず守られる。
    static func pruneIfNeeded(modelContext: ModelContext, maxTrackedBooks: Int, excludedBookIDs: Set<String>) {
        guard maxTrackedBooks > 0 else { return }

        let countDescriptor = FetchDescriptor<BookReadingState>()
        guard let totalCount = try? modelContext.fetchCount(countDescriptor), totalCount > maxTrackedBooks else {
            return
        }
        let excessCount = totalCount - maxTrackedBooks

        // 最後に読んだ時刻(updatedAt)が古い順に取得し、開いている本を飛ばしながら
        // 超過した件数分だけ削除する。除外の有無で取得件数が変わるため、fetchLimitは付けず
        // 古い順に必要なぶんだけ辿る(ここへ来るのは上限を超えた一瞬だけで、件数も
        // 環境設定の上限(最大2000)止まり)。
        let staleDescriptor = FetchDescriptor<BookReadingState>(
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        guard let candidates = try? modelContext.fetch(staleDescriptor), !candidates.isEmpty else { return }

        var deletedCount = 0
        for state in candidates where deletedCount < excessCount {
            guard !excludedBookIDs.contains(state.bookID) else { continue }
            modelContext.delete(state)
            deletedCount += 1
        }
        guard deletedCount > 0 else { return }

        try? modelContext.save()
    }
}
