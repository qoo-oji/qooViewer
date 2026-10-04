import Foundation

/// ウインドウへ落とされた・パネルで選ばれたものを「開く」ときの下調べ(2026-09-27、ホームの操作の統一。
/// docs/plans/home-interaction-design.md §2.4)。
///
/// 以前は `BookOpenRequest(openingCandidates:)` が先頭の 1 件だけを開き、残りを黙って捨てていた。また、開けないもの
/// (空のフォルダ・対応しないファイル)もそのまま読み込みへ回し、エラーになって**表示中の本まで閉じていた**。ここで
/// 読み込みの前に振り分ける:
///
/// - 1 件: 開いて意味があるか(`single`)。開けないと分かったら開かずに知らせる(表示中の本はそのまま)。
///   読めないフォルダ(許可が無い)は「分からない」として従来どおり開きに行く ―― アクセスを求める導線がその先にある
///   (ShelfFolderResolver.resolvedBookURL のコメント)。
/// - 複数(全部が画像のときを除く。そちらは従来どおり 1 冊にまとめる): 本だけを自然順に並べ、棚のフォルダは中の本に
///   展開して(スマートライブラリで束を展開して並びにするのと同じ)、先頭を開き、残りを「次の本・前の本」でたどれるようにする
///   (`BookSequence`。コレクション・スマートライブラリから開いたときと同じ)。本でないものは並びに入れず、数を返す。
///
/// どちらもフォルダを読むので、メインアクターの外で呼ぶこと。
nonisolated enum DroppedBooks {
    enum Single: Equatable, Sendable {
        /// 開く(本、または開いてみないと分からないもの)。
        case open
        /// 本が無い(空のフォルダ・本を含まないフォルダ・対応しないファイル)。
        case nothing
    }

    static func single(_ url: URL, order: SiblingBookOrder) -> Single {
        var isDirectory: ObjCBool = false
        // 見つからないものは従来どおり開きに行く(読み込みが「見つかりません」を出す)。
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .open }
        guard isDirectory.boolValue else {
            let name = url.lastPathComponent
            return isArchiveFile(name) || isPDFFile(name) || isEpubFile(name) || isImageFile(name) ? .open : .nothing
        }
        // 読めないフォルダは「分からない」(アクセスを求める導線へ)。
        guard (try? DirectoryBrowser.listing(in: url, sort: order.sort)) != nil else { return .open }
        if case .book = ShelfFolderResolver.role(of: url, order: order) { return .open }
        return ShelfFolderResolver.resolvedBookURL(for: url, order: order) == url ? .nothing : .open
    }

    struct Multiple: Equatable, Sendable {
        /// 開く順の本。
        var books: [URL]
        /// 本でないので並びに入れなかった数。
        var skipped: Int
    }

    static func multiple(_ urls: [URL], order: SiblingBookOrder) -> Multiple {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.path).inserted }
        var books: [URL] = []
        var skipped = 0
        for url in naturalOrderSortedByPath(unique) {
            let found = booksIn(url, order: order)
            if found.isEmpty { skipped += 1 } else { books.append(contentsOf: found) }
        }
        return Multiple(books: books, skipped: skipped)
    }

    /// 1 つのものから並びに入れる本。画像ファイル 1 枚は入れない(その場限りの本で、並びの 1 冊として開き直せない ――
    /// CollectionDropClassifier と同じ扱い)。
    private static func booksIn(_ url: URL, order: SiblingBookOrder) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else {
            let name = url.lastPathComponent
            return isArchiveFile(name) || isPDFFile(name) || isEpubFile(name) ? [url] : []
        }
        // 読めないフォルダはそのまま入れる(開いたときにアクセスを求める)。
        guard (try? DirectoryBrowser.listing(in: url, sort: order.sort)) != nil else { return [url] }
        switch ShelfFolderResolver.role(of: url, order: order) {
        case .book:
            return [url]
        case .shelf(let books) where !books.isEmpty:
            return books
        default:
            // 中間フォルダは開くときと同じく奥の最初の本(ShelfFolderResolver.resolvedBookURL)。
            let resolved = ShelfFolderResolver.resolvedBookURL(for: url, order: order)
            return resolved == url ? [] : [resolved]
        }
    }
}

/// Dock・Finder から渡されたものの下調べ(AppDelegate.application(_:open:)。2026-09-27)。ウインドウへのドロップと同じ規則
/// (DroppedBooks)で、開く要求と、本でないので開かなかった数を返す。全部が画像なら従来どおり 1 冊にまとめる。
/// 「新規ウインドウで開く…」もこれを通す(2026-10-04 の監査 O-6。以前は `BookOpenRequest.sequenced` という複数のときだけの
/// 下調べで、本が 1 冊も無いと下調べ前の要求のまま窓を作ってエラーを出していた ―― それで使われなくなったので外した)。
nonisolated enum ExternalOpenPreparation {
    struct Prepared: Sendable {
        /// 開く要求。本が 1 つも無ければ nil。
        var request: BookOpenRequest?
        var skipped: Int
    }

    /// - Parameter routed: 先の回でシークレットウインドウへ回した本のパス(2026-10-04 の監査 O-9)。まとめ直しの回はこれを
    ///   入れない ―― 入れると、まとめ直した並びの先頭がまた回され、一緒に渡されたノーマルの本がどこにも開かれず並びにも残らなかった
    ///   (実測)。回した本はシークレットウインドウに出ている。全部が回した本なら、要求も数えた件数も無い(知らせも出さない)。
    static func prepare(_ urls: [URL], order: SiblingBookOrder, excluding routed: Set<String> = []) -> Prepared {
        var seen = Set<String>()
        let unique = urls.filter { !routed.contains($0.path) && seen.insert($0.path).inserted }
        guard let first = unique.first else { return Prepared(request: nil, skipped: 0) }
        if unique.allSatisfy({ isImageFile($0.lastPathComponent) }) {
            return Prepared(request: BookOpenRequest(openingCandidates: unique), skipped: 0)
        }
        if unique.count == 1 {
            return DroppedBooks.single(first, order: order) == .open
                ? Prepared(request: BookOpenRequest(first), skipped: 0)
                : Prepared(request: nil, skipped: 1)
        }
        let found = DroppedBooks.multiple(unique, order: order)
        // 棚を中の本に展開した結果にも、回した本は入れない(上の routed)。
        let books = found.books.filter { !routed.contains($0.path) }
        guard let book = books.first else { return Prepared(request: nil, skipped: found.skipped) }
        let sequence = books.count > 1
            ? BookSequence(entries: books.map { .file(path: $0.path) }, position: 0) : nil
        return Prepared(request: BookOpenRequest(book, sequence: sequence), skipped: found.skipped)
    }

    /// シークレットウインドウへ回した要求が連れていった本のパス(`prepare` の `routed` へ足すもの)。要求の本だけでなく、**一緒に
    /// 回した並びの本すべて** ―― 回した先の窓が「次の本」でたどる(2026-10-04 のレビューの R6-3。以前は要求の本だけを控えたので、
    /// Finder でシークレットフォルダの本 2 冊とふつうの本を一緒に開くと、種類ごとに分かれて届いたまとめ直しの回で並びの 2 冊目が
    /// また回され、ふつうの本がノーマルの窓で開かれなかった)。
    static func routedPaths(of request: BookOpenRequest) -> Set<String> {
        Set(request.urls.map(\.path)).union(request.sequence?.entries.map(\.path) ?? [])
    }
}
