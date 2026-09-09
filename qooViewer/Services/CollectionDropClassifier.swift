import Foundation

/// ウェルカム画面へドロップされたURLを、「1冊の本」「棚(本が並んだフォルダ)」「対象外」の
/// 3つへ振り分ける(改善要望5)。
///
/// 編集モード中のウェルカム画面では、ドロップは「開く」ではなく「コレクションを作る/本を
/// 追加する」になる。そのとき、
///   ・書庫/PDF/EPUBのファイル、画像を直接持つフォルダ、画像フォルダだけが並ぶフォルダ
///     → **本**。まとめて1つのコレクションの中身になる。
///   ・本のファイルが直下に並んでいるフォルダ → **棚**。フォルダ名を既定の名前にした
///     コレクション1つになる(中の本が中身)。
///   ・それ以外(空フォルダ、画像1枚、中間フォルダだけのフォルダ、対応していないファイル)
///     → **対象外**。
///
/// 「本かどうか」の判定はShelfFolderResolverと1つに揃えてある ―― ドロップで「棚」と
/// 見なされたフォルダを、同じアプリの別の経路(ダブルクリックで開く)が「1冊」と見なす、
/// といった食い違いを作らないため。
///
/// nonisolated: 判定はフォルダの列挙を伴うのでメインスレッド外で走らせる
/// (ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum CollectionDropClassifier {
    enum Item: Sendable, Equatable {
        /// 1冊の本(ファイル、または1冊にあたるフォルダ)。
        case book(URL)
        /// 棚。`folder`はそのフォルダ自身、`books`は直下の本。
        ///
        /// フォルダ名(コレクション名の既定値)だけでなく**フォルダのURLそのもの**を持つのは、
        /// ここから作るコレクションの自動登録フォルダの初期値にするため
        /// (BookCollection.autoFolderPath参照)。
        case shelf(folder: URL, books: [URL])
        /// コレクションには入れられないもの。
        case ignored(URL)
    }

    /// - Parameter order: 棚の中の本を並べる順(サイドパネルのフォルダブラウザと同じもの)。
    ///   コレクションへ入る順が、フォルダを開いたときに見える並びと一致するようにするため。
    static func classify(_ urls: [URL], order: SiblingBookOrder) -> [Item] {
        urls.map { classifyOne($0, order: order) }
    }

    /// `classify(_:order:)`をメインスレッド外で行う版(ドロップの受け口が使う)。
    static func classifyAsync(_ urls: [URL], order: SiblingBookOrder) async -> [Item] {
        await Task.detached(priority: .userInitiated) {
            classify(urls, order: order)
        }.value
    }

    /// **既にある**コレクションへ本を追加する場面で拾うURL。本はそのまま、棚はその中の本を
    /// 展開して並べ、それ以外は捨てる。
    ///
    /// コレクションを**作る**場面(編集モード中のウェルカム画面へのドロップ)では、棚は
    /// 「フォルダ名を既定の名前にしたコレクション1つ」という別の意味を持つため、そちらは
    /// `classify(_:order:)`の結果をそのまま見る。追加の場面にはその曖昧さが無い ――
    /// 開いているコレクションへ本の並んだフォルダを落として何も起きないのは、黙って失敗した
    /// ようにしか見えない。
    static func booksToAdd(from items: [Item]) -> [URL] {
        items.flatMap { item -> [URL] in
            switch item {
            case .book(let url): return [url]
            case .shelf(_, let books): return books
            case .ignored: return []
            }
        }
    }

    private static func classifyOne(_ url: URL, order: SiblingBookOrder) -> Item {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .ignored(url)
        }
        guard isDirectory.boolValue else {
            // ファイル。開ける形式(DirectoryBrowserが一覧に残すのと同じ3種)だけを本として扱う。
            // 画像ファイル1枚は本にしない ―― ビューアは「その場限りの本」として開けるが、
            // それは開いている間だけのもので、登録して開き直せる対象ではない
            // (MangaBook.isTransient / AppState.skipsPersistenceの扱いと揃える)。
            let name = url.lastPathComponent
            return isArchiveFile(name) || isPDFFile(name) || isEpubFile(name)
                ? .book(url) : .ignored(url)
        }
        switch ShelfFolderResolver.role(of: url, order: order) {
        case .book:
            return .book(url)
        case .shelf(let books):
            // 本が1冊も無い棚は作らせない(空のコレクションは作らないという方針)。
            return books.isEmpty ? .ignored(url) : .shelf(folder: url, books: books)
        case .neither:
            return .ignored(url)
        }
    }
}
