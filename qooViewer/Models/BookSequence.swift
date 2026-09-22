import Foundation

/// 本を開いた**一覧の並び**(2026-09-22、利用者の指示)。ライブラリのコレクション・スマートライブラリから本を開いたとき、
/// 「次の本へ」「前の本へ」(キー・メニュー・最後/最初のページでの移動)は、同じフォルダの本ではなく**開いた一覧に
/// 見えていた並び**(検索・絞り込み・並べ替えの後)をたどる。
///
/// `BookOpenRequest.sequence` に載って運ばれ(新しいタブ/ウインドウで開いても一緒に渡る)、`AppState.bookSequence` に
/// 置かれる。**一覧の外から本を開く(履歴・ファイルブラウザ・ドロップなど)と消え**、同じフォルダの本をたどる従来の動きに
/// 戻る。一覧をたどって開いた本では、並びを持ったまま `position` だけが進む。
///
/// 並びは開いた時点の写し。一覧の側で後から絞り込みを変えても、開いている本の並びは変わらない(ブラウザの「戻る」と同じ
/// 考え方 ―― 読んでいる最中に行き先が入れ替わらない)。
///
/// nonisolated: `BookOpenRequest`(`WindowGroup(for:)` の値)に載るため。
nonisolated struct BookSequence: Codable, Hashable, Sendable {
    enum Entry: Codable, Hashable, Sendable {
        /// パスで開く本(スマートライブラリ。権限は対象フォルダの許可 ―― FolderAccessStore)。
        case file(path: String)
        /// コレクションの本(開くときは項目のブックマークから解決する ―― `CollectionStore.resolvedExistingURL`)。
        /// `path` は項目が見つからなくなったとき(コレクションから外した)の予備。
        case collectionItem(id: UUID, path: String)

        var path: String {
            switch self {
            case .file(let path), .collectionItem(_, let path): path
            }
        }
    }

    let entries: [Entry]
    /// いま開いている(これから開く)本の位置。
    let position: Int

    /// `position` が範囲の外なら nil(空の並びも)。
    init?(entries: [Entry], position: Int) {
        guard entries.indices.contains(position) else { return nil }
        self.entries = entries
        self.position = position
    }

    /// 同じ並びで位置だけ変えたもの。
    func moved(to position: Int) -> BookSequence? {
        BookSequence(entries: entries, position: position)
    }

    /// 次(`forward`)/前へたどるときに試す順の位置(近い順)。見つからない本は飛ばして次を試すため、全部を返す。
    /// 端では空(並びの外へは出ない ―― 同じフォルダの本へは戻らない)。
    func candidatePositions(forward: Bool) -> [Int] {
        forward ? Array(entries.indices.suffix(from: position + 1)) : Array(entries.indices.prefix(upTo: position).reversed())
    }
}

extension BookSequence {
    /// 並びの 1 冊を開けるかを確かめる材料。メインで集め(コレクションの項目は SwiftData の行)、**確かめ(`resolve`)は
    /// `FileIO` の上で**行う(`AppState.openInSequence`)。
    nonisolated struct Probe: Sendable {
        /// 記録してあるパス(スマートライブラリの本、項目が見つからなくなったコレクションの本はこれで確かめる)。
        let path: String
        /// コレクションの項目のブックマーク(開く権限でもある)。nil ならパスで確かめる。
        let bookmark: Data?

        /// 開く URL。見つからなければ nil。ボリュームへ問い合わせるので、メインから呼ばない。
        func resolve() -> URL? {
            // コレクションの本は項目のブックマークから(一覧から開くときの CollectionDetailView.open と同じ)。
            // パスだけで在るかを確かめると、許可の無い場所の本はサンドボックスで「無い」になるので、先には見ない。
            if let bookmark { return CollectionStore.existingURL(fromBookmark: bookmark) }
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
    }
}

extension BookSequence {
    /// コレクションの本の並び(`opening` の位置つき)。見えている並び(検索・並べ替えの後)を渡すこと。
    @MainActor
    static func collection(_ items: [CollectionItem], opening item: CollectionItem) -> BookSequence? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        return BookSequence(entries: items.map { .collectionItem(id: $0.id, path: $0.bookID) }, position: index)
    }
}
