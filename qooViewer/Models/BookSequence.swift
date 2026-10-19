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
/// Finder・Dock で複数を選んで開いた本・ウインドウへ複数を落とした本・StackNest でいっしょに渡された本も、選んだ順の並びを持つ
/// (`Title.openedTogether`)。**画面に出ている本が並びを持つ間、サイドパネルのフォルダブラウザは本の置き場所のフォルダの代わりに
/// この並びを仮想のフォルダとして出す**(2026-10-19、利用者の指示。`AppState.shownBookSequence` → `SidePanelBrowserState.showSequence`。
/// 見出しは `Title`)。
///
/// nonisolated: `BookOpenRequest`(`WindowGroup(for:)` の値)に載るため。
nonisolated struct BookSequence: Codable, Hashable, Sendable {
    enum Entry: Codable, Hashable, Sendable {
        /// パスで開く本(スマートライブラリ。権限は対象フォルダの許可 ―― FolderAccessStore)。
        case file(path: String)
        /// コレクションの本(開くときは項目のブックマークから解決する ―― `CollectionStore.existingURL(fromBookmark:)`、FileIO の上)。
        /// `path` は項目が見つからなくなったとき(コレクションから外した)の予備。
        case collectionItem(id: UUID, path: String)

        var path: String {
            switch self {
            case .file(let path), .collectionItem(_, let path): path
            }
        }
    }

    /// 並びの出どころ(サイドパネルのフォルダブラウザが、並びを仮想のフォルダとして出すときの見出し ―― 2026-10-19、
    /// 利用者の指示)。作る側が決めて付ける。
    ///
    /// **文字列ではなく出どころで持ち、見出しの文は出すときに組む**(`displayName(locale:)`)。表示言語の設定はその場で切り替わる
    /// ので、作った時点の言語の文を持つと、切り替えた後も前の言語のまま残る。`BookOpenRequest` に載る(WindowGroup の値)ので、
    /// 同じ選択からは同じ値になるものだけを入れる(コレクション・スマートコレクション・束の名前。UUID や時刻は入れない ――
    /// BookOpenRequest の型コメント)。
    enum Title: Codable, Hashable, Sendable {
        /// Finder・Dock で複数を選んで開いた・ウインドウへ複数を落とした・StackNest でいっしょに渡された本。
        case openedTogether
        /// ライブラリのコレクション(その名前)。
        case collection(name: String)
        /// スマートライブラリ。`name` は開いていた束(著者名・シリーズ名)か、選んでいたスマートコレクションの名前。どちらも
        /// 無ければ nil(見出しは「スマートライブラリ」)。
        case smartLibrary(name: String?)

        /// 見出しに出す文。
        func displayName(locale: Locale) -> String {
            switch self {
            case .openedTogether:
                String(localized: "Books Opened Together", language: locale)
            case .collection(let name):
                name
            case .smartLibrary(let name):
                name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Smart Library", language: locale)
            }
        }
    }

    let entries: [Entry]
    /// いま開いている(これから開く)本の位置。
    let position: Int
    /// 並びの出どころ(`Title`)。nil は付けていない並び(見出しは「まとめて開いた本」と同じに扱う ―― `displayName(locale:)`)。
    let title: Title?

    /// `position` が範囲の外なら nil(空の並びも)。
    init?(entries: [Entry], position: Int, title: Title? = nil) {
        guard entries.indices.contains(position) else { return nil }
        self.entries = entries
        self.position = position
        self.title = title
    }

    /// 同じ並びで位置だけ変えたもの(出どころも同じ)。
    func moved(to position: Int) -> BookSequence? {
        BookSequence(entries: entries, position: position, title: title)
    }

    /// サイドパネルの見出しに出す、並びの名前(`Title.displayName(locale:)`)。
    func displayName(locale: Locale) -> String {
        (title ?? .openedTogether).displayName(locale: locale)
    }

    /// 並びの 1 冊を一覧の行に出すときの名前(サイドパネルの仮想フォルダ)。**記録してあるパスの最後の成分**で、ファイルシステムには
    /// 触らない。StackNest の参照ファイル(`.stacknestbook`)は拡張子を外す(参照ファイルの名前は本の題 + この拡張子)。
    static func displayName(of entry: Entry) -> String {
        let name = (entry.path as NSString).lastPathComponent
        guard isStackNestReferenceFile(name) else { return name.isEmpty ? entry.path : name }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
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
        // 見出しはそのコレクションの名前(押した時点のもの。後で名前を変えても、開いている並びの見出しは変わらない ―― 並びと同じく写し)。
        let title = (item.collection?.name).map { Title.collection(name: $0) }
        return BookSequence(
            entries: items.map { .collectionItem(id: $0.id, path: $0.bookID) }, position: index, title: title)
    }
}
