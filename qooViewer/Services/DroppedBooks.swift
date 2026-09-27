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

extension BookOpenRequest {
    /// 複数の本(全部が画像のときを除く)を渡されたとき、先頭の本を開き残りを「次の本・前の本」でたどる要求
    /// (DroppedBooks.multiple。Dock・Finder から渡されたとき、「新規ウインドウで開く…」で複数を選んだとき)。1 件だけ・全部が画像・
    /// 本が 1 冊も無いときは nil(呼び出し側は従来どおり `init(openingCandidates:)` の要求を使う)。
    static func sequenced(from candidates: [URL], order: SiblingBookOrder) async -> BookOpenRequest? {
        guard Set(candidates.map(\.path)).count > 1,
              !candidates.allSatisfy({ isImageFile($0.lastPathComponent) })
        else { return nil }
        let found = await Task.detached(priority: .userInitiated) { DroppedBooks.multiple(candidates, order: order) }.value
        guard let first = found.books.first else { return nil }
        let sequence = found.books.count > 1
            ? BookSequence(entries: found.books.map { .file(path: $0.path) }, position: 0) : nil
        return BookOpenRequest(first, sequence: sequence)
    }
}
