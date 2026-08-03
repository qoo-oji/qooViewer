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
    static func pruneIfNeeded(modelContext: ModelContext, maxTrackedBooks: Int) {
        guard maxTrackedBooks > 0 else { return }

        let countDescriptor = FetchDescriptor<BookReadingState>()
        guard let totalCount = try? modelContext.fetchCount(countDescriptor), totalCount > maxTrackedBooks else {
            return
        }

        // 最後に読んだ時刻(updatedAt)が古い順に、超過した件数分だけ取得する。
        var staleDescriptor = FetchDescriptor<BookReadingState>(
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        staleDescriptor.fetchLimit = totalCount - maxTrackedBooks
        guard let staleStates = try? modelContext.fetch(staleDescriptor), !staleStates.isEmpty else { return }

        for state in staleStates {
            modelContext.delete(state)
        }

        try? modelContext.save()
    }
}
