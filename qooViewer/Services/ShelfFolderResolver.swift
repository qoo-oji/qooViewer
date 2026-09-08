import Foundation

/// 「本が並んでいるだけのフォルダ」(以下、棚)を開こうとしたときに、**実際に開く1冊**を決める。
///
/// ユーザー報告 2026-09-06: 書庫・PDF・EPUBが並んだフォルダをドロップすると、中の全ファイルを
/// 走査して1冊にまとめるため、表示までに時間がかかり、履歴にもフォルダのほうが残ってしまう。
/// 期待は「そのフォルダの先頭の本を、直接ドロップしたときとまったく同じように開く」こと
/// (フォルダブラウザにはその本が入っているフォルダが現れ、次の本/前の本でその隣へ進める)。
///
/// ■ 棚と「1冊の本」の境界(ユーザーの指示)
/// 1. **直下に画像があるフォルダは、それ自体が1冊**(従来どおり。サブフォルダの画像も再帰的に
///    集める)。`A/001.jpg, ch1/002.jpg` → A全体で1冊。
/// 2. **直下に本のファイル(書庫/PDF/EPUB)が無く、画像フォルダだけが並んでいるフォルダも1冊**。
///    `A/ch1/001.jpg, ch2/001.jpg` は「章ごとに画像を分けた1冊」であって棚ではない。
/// 3. **書庫/PDF/EPUB のファイルが直下にあるフォルダは棚**。その中では**画像フォルダも1冊の本**
///    として、ファイルと同列に並び順で競う(ユーザーの指示)。`A/ch1/001.jpg, 01.cbz` なら、
///    名前順で先に来るほうが開く。ここでの「本」の定義は、アプリの他の場所(サイドパネル上段の
///    フォルダブラウザ、「次の本へ」のSiblingFinder)とまったく同じ。
///
/// 上のどれでもないフォルダ(本を直接持たない中間フォルダだけが並ぶ)は、その中をさらに同じ規則で
/// 見る。`A/作者名/01.cbz` → 1段降りて`01.cbz`が開く。
///
/// 判定に要るのは「そのフォルダの一覧」だけで、中の書庫やPDFは一切開かない。サブフォルダが
/// 画像を持つかどうかは、一覧を作る時点で`DirectoryBrowser`が既に調べている
/// (`Entry.containsImageFile`)ため、そのための追加のディスク読み込みも起きない。
///
/// ■ 並び順はフォルダブラウザ・次の本/前の本と同じもの
/// 「先頭の本」は、サイドパネル上段に見えているのと同じ並びの先頭にする(SiblingBookOrder)。
/// そうすることで、棚を開く → 「次の本へ」で2冊目、という並びが一覧の見た目と一致する。
///
/// nonisolated: メインスレッド外(AppState.openの読み込みTask)から呼ぶため
/// (詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated enum ShelfFolderResolver {
    /// 棚を辿る深さの上限。これを超えたら諦めて呼び出し側のフォルダをそのまま開く
    /// (循環リンクや、本の入っていない深い階層で延々と列挙し続けないための安全弁)。
    private static let maxDepth = 8

    /// `url`が棚なら、その中の先頭の本のURL。棚でなければ`url`自身(=これまでどおり開く)。
    ///
    /// 読めないフォルダ(アクセス権が無い等)や、本が1冊も入っていない棚は`url`のまま返す。
    /// 前者はアクセス権を求める従来の導線へ、後者は「ページが見つかりません」へ落とす ――
    /// どちらもフォルダをそのまま開こうとしたときの結果と同じで、この解決役が新しい失敗を
    /// 持ち込まないようにするため。
    static func resolvedBookURL(for url: URL, order: SiblingBookOrder) -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return url }
        return firstBook(in: url, order: order, depth: 0) ?? url
    }

    /// `resolvedBookURL(for:order:)`をメインスレッド外で行う版(本を開く経路が使う)。
    static func resolvedBookURLAsync(for url: URL, order: SiblingBookOrder) async -> URL {
        await Task.detached(priority: .userInitiated) {
            resolvedBookURL(for: url, order: order)
        }.value
    }

    /// このフォルダが**それ自体で1冊**かどうか(型コメントの規則1・2)。
    /// `firstBook`と`role(of:order:)`が同じ判定を使うために切り出してある。
    private static func isSingleBook(_ listing: DirectoryBrowser.Listing) -> Bool {
        // 1. 画像が直下にある = このフォルダ自体が1冊。
        if listing.containsImageFile { return true }
        // 2. 本のファイルが1つも無く、画像フォルダが並んでいる = 章ごとに画像を分けた1冊。
        //    (書庫等のファイルが1つでも混ざっていれば棚。型コメントの場合分け参照)
        let holdsBookFiles = listing.entries.contains { !$0.isDirectory }
        return !holdsBookFiles
            && listing.entries.contains { $0.isDirectory && $0.containsImageFile }
    }

    /// フォルダの立ち位置(型コメントの場合分けをそのまま値にしたもの)。
    /// コレクションへのドロップの振り分け(CollectionDropClassifier)が使う。
    enum FolderRole: Sendable, Equatable {
        /// それ自体が1冊(規則1・2)。
        case book
        /// 棚(規則3)。`books`は**直下にある本だけ**を並び順どおりに並べたもの
        /// (ファイルの本と、画像を直接持つフォルダの本。中間フォルダの中までは降りない ――
        /// `firstBook`が「開く1冊」を探すために降りるのとはここが違う。コレクションへ入れる
        /// のは「見えている棚に並んでいる本」であって、奥から拾ってきた1冊ではない)。
        case shelf(books: [URL])
        /// どちらでもない(空フォルダ、中間フォルダだけが並ぶフォルダ、読めないフォルダ)。
        case neither
    }

    /// `url`が本なのか棚なのかを判定する。フォルダでないURLには`.neither`を返す
    /// (ファイルの本かどうかの判定は呼び出し側の仕事)。
    static func role(of url: URL, order: SiblingBookOrder) -> FolderRole {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let listing = try? DirectoryBrowser.listing(in: url, sort: order.sort)
        else { return .neither }
        if isSingleBook(listing) { return .book }
        // 規則3: 直下に本のファイルがあるフォルダが棚。
        guard listing.entries.contains(where: { !$0.isDirectory }) else { return .neither }
        let books = listing.entries
            .filter { !$0.isDirectory || $0.containsImageFile }
            .map(\.url)
        return .shelf(books: books)
    }

    /// `folder`が棚なら、その直下に並んでいる本。棚でなければnil。
    static func directBooks(in folder: URL, order: SiblingBookOrder) -> [URL]? {
        guard case .shelf(let books) = role(of: folder, order: order) else { return nil }
        return books
    }

    /// `folder`を開いたときに実際に開くべき本。`folder`自身が1冊ならそれを返し、棚なら中を
    /// 順に見て最初に見つかった本を返す。本が1冊も無ければnil(呼び出し側は次の項目へ進むか、
    /// 元のフォルダをそのまま開く)。
    private static func firstBook(in folder: URL, order: SiblingBookOrder, depth: Int) -> URL? {
        guard depth <= maxDepth,
              let listing = try? DirectoryBrowser.listing(in: folder, sort: order.sort)
        else { return nil }
        if isSingleBook(listing) { return folder }
        // 3. ここからは棚。並びの先頭から順に、最初に本として開けるものを探す。
        for entry in listing.entries {
            // 開ける形式のファイル(DirectoryBrowserが一覧に残すのはこれだけ)。
            guard entry.isDirectory else { return entry.url }
            // 画像を直接持つフォルダは1冊。一覧を作った時点で分かっている値なので、
            // ここで判断すればそのフォルダをもう一度列挙せずに済む(下の再帰でも同じ結論になる)。
            if entry.containsImageFile { return entry.url }
            // どちらでもないフォルダは中間フォルダ。中をさらに同じ規則で見る
            // (本を1冊も含まなければ、次の項目へ進む)。
            if let found = firstBook(in: entry.url, order: order, depth: depth + 1) { return found }
        }
        return nil
    }
}
