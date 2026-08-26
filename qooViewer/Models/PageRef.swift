import Foundation

/// 1ページ分の画像データがどこから取得できるかを表す
///
/// nonisolated: Xcode 26 (Swift 6.2)からの新規プロジェクトは既定で「Default Actor Isolation =
/// MainActor」になっており、注釈のない型は暗黙的にMainActor専用になる。PageSource/PageRefは
/// BookLoader(Task.detached)が組み立て、PageLoader(actor)が読み出す — つまりメインアクターの
/// 外で使われる値型のため、明示的にnonisolatedを付ける(ArchiveReading.swift冒頭のコメント参照)。
///
/// 付けていなかったため、PageLoaderからのpage.source.isFile / page.displayNameの参照が
/// 「main actor-isolated property cannot be accessed from outside of the actor;
/// this is an error in the Swift 6 language mode」という警告になっていた(実際にはメイン
/// アクター外から同期的に読まれており、Swift 6言語モードへ切り替えた時点でエラーになる状態
/// だった)。どちらもimmutableな値から計算するだけで、共有された可変状態には一切触れない。
nonisolated enum PageSource {
    /// フォルダ内の画像ファイル
    case file(URL)
    /// 書庫(zip/cbz・rar/cbr・7z/cb7、およびEPUBのzipコンテナ)内のエントリ。
    ///
    /// 以前は形式ごとに`.zip`/`.sevenZip`/`.rar`の3ケースに分かれ、それぞれが
    /// **ディスク上に実在する書庫ファイルのURL**を持っていた。入れ子になった書庫を
    /// 遅延展開する(=開く時点では展開しない)ようにしたことで「どの書庫か」を実ファイルの
    /// URLでは表せなくなったため、`ArchiveLocator`1つへ畳んである(詳細は
    /// ArchiveLocatorの型コメント参照)。形式の判定も`locator.archiveFileName`の拡張子を
    /// 見る1箇所へ集約でき、対応形式を増やすときに触る場所が減った。
    case archive(locator: ArchiveLocator, entryPath: String)
    /// PDFファイル内の1ページ(0始まりのページ番号)
    case pdf(pdfURL: URL, pageIndex: Int)

    /// フォルダ内の独立した画像ファイルかどうか(書庫内エントリ・PDFのページではない)。
    /// この場合だけ、ファイルを丸ごと読まずにヘッダーだけを読むURLベースの経路が使える
    /// (PageLoader.pageSize/pageImageInfo、ImageDecoder.headerInfo(ofFileAt:)参照)。
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

/// EPUBのpackage document内で、そのページに明示的に指定された見開き内の配置。
/// EPUB Publications仕様の`page-spread-left`/`page-spread-right`(spine itemrefのproperties)、
/// および`rendition:page-spread-center`に対応する。
///
/// - left: 見開きの左側に配置する(通常は次のページと組んで、自身が起点になる)
/// - right: 見開きの右側に配置する(常に直前のページと組む。自身が見開きの起点にはならない)
/// - center: 見開き表示中でも単独の1ページとして中央に表示する(前後のページとは組まない)
///
/// EPUB以外のPageSource(フォルダ・cbz/cbr/cb7・PDF)では常にnil。
enum PageSpreadPosition: String, Codable, Hashable {
    case left
    case right
    case center
}

/// 本の中の1ページを表す(nonisolatedの理由はPageSourceのコメント参照)
nonisolated struct PageRef: Identifiable, Hashable {
    /// 一意なキー(画像キャッシュや SwiftUI の List/ForEach 用)
    let id: String
    /// 自然順ソート用のキー(ファイル名やアーカイブ内パス)
    let sortKey: String
    let source: PageSource
    /// EPUBがこのページの見開き内配置を明示している場合のみ値を持つ。詳細はPageSpreadPosition参照。
    /// EPUB以外のソースでは常にnil(デフォルト値のため、他のPageRef生成箇所は変更不要)。
    var epubSpreadPosition: PageSpreadPosition? = nil

    static func == (lhs: PageRef, rhs: PageRef) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// ファイル名だけの短い表示名。書庫の中のフォルダ・入れ子の書庫のどこにある画像なのかまで
    /// 示したい表示箇所では、これではなく`location(inBookAt:)`を使う(PageLocation参照)。
    var displayName: String {
        switch source {
        case .file(let url):
            return url.lastPathComponent
        case .archive(_, let entryPath):
            return (entryPath as NSString).lastPathComponent
        case .pdf(let pdfURL, let pageIndex):
            // PDFのページ自体には(アーカイブ内エントリのような)個別のファイル名がないため、
            // 元のPDFファイル名とページ番号(1始まりで表示)を組み合わせて表示する。
            return "\(pdfURL.deletingPathExtension().lastPathComponent) (\(pageIndex + 1))"
        }
    }
}

/// 「そのページの画像は、本の中のどこにあるのか」を表示用に畳んだもの
/// (`PageRef.location(inBookAt:)`が組み立てる)。
///
/// ファイル名だけでは足りないのは、書庫の中のフォルダ・書庫の中の書庫(章ごとに書庫化された
/// ものが1冊にまとまっている本)を開いたときで、章ごとに`001.jpg`から番号が振り直されている
/// 本では一覧に同じ名前がいくつも並ぶ ―― どの章のページなのか区別がつかなくなる
/// (ユーザー要望)。そこで画像のファイル名を出す画面では、ファイル名と一緒にこの
/// `folderPath`を添える。
///
/// **EPUBだけは例外で、常に`folderPath`がnilになる。** EPUBの画像は`OEBPS/Images/`のような
/// 決まった場所にまとめて置かれているのが普通で、どのページにも同じ1行が付くだけで
/// 「どこの画像か」の区別には何の役にも立たない(ユーザー指示)。EPUBのページが書庫の中の
/// 別々の場所から来ることは仕組み上ありえない ―― `archiveExtensions`に`epub`は含まれないため、
/// EPUBは常に本そのものであり、入れ子の書庫として開かれることも、中の書庫へ潜ることも無い
/// (ArchiveReading.swiftのisEpubFileのコメント参照)。
nonisolated struct PageLocation: Hashable {
    /// 画像のファイル名(`PageRef.displayName`と同じ)。
    let fileName: String
    /// この画像が入っているフォルダ/書庫の、**本の直下から見た**相対パス。
    /// 例: `"vol1.cbz/ch03"`。本の直下に置かれた画像ならnil(この場合は従来どおり
    /// ファイル名だけを表示すればよい)。
    let folderPath: String?

    /// 本の直下から見た相対パス全体。例: `"vol1.cbz/ch03/003.jpg"`。
    /// 1行に収める必要がある場所(ツールチップなど)で使う。
    var fullPath: String {
        guard let folderPath else { return fileName }
        return "\(folderPath)/\(fileName)"
    }
}

nonisolated extension PageRef {
    /// このページが本の中のどこにあるかを求める(詳細は`PageLocation`参照)。
    ///
    /// `bookRootURL`には、そのページが属する本の`MangaBook.sourceURL`を渡す。nil、または
    /// 本の直下に置かれた画像では`folderPath`がnilになり、表示は従来のファイル名だけに戻る。
    ///
    /// 相対パスの起点を`sourceURL`に取っているため、本が書庫1つならその書庫の中でのパス、
    /// 本がフォルダならフォルダの中でのパス(中に書庫があればその書庫名も1階層として現れる)に
    /// なり、どちらも「ユーザーが開いたものから見た道順」で揃う。
    func location(inBookAt bookRootURL: URL?) -> PageLocation {
        let root = bookRootURL.map { Self.normalizedPath($0.path) }
        switch source {
        case .file(let url):
            return PageLocation(
                fileName: url.lastPathComponent,
                folderPath: Self.relativePath(of: url.deletingLastPathComponent().path, under: root)
            )
        case .archive(let locator, let entryPath):
            // EPUBは中のフォルダを出さない(理由はPageLocationの型コメント参照)。
            guard !isEpubFile(locator.rootURL.lastPathComponent) else {
                return PageLocation(
                    fileName: (entryPath as NSString).lastPathComponent, folderPath: nil
                )
            }
            var components: [String] = []
            // 本そのものが書庫ならここは空になる。フォルダの本では、その中の書庫ファイルが
            // フォルダの中のどこにあるか(例: `chapters/vol1.cbz`)がそのまま入る。
            if let archivePath = Self.relativePath(of: locator.rootURL.path, under: root) {
                components.append(archivePath)
            }
            // 入れ子の書庫を潜った道順。各要素は親の中での完全なエントリパスのため、
            // `chapters/ch03.cbz`のようにフォルダを含みうる(ArchiveLocator参照)。
            components.append(contentsOf: locator.nestedPath)
            // 書庫の中でのフォルダ。書庫の直下にある画像なら空文字列になる。
            let entryFolder = (entryPath as NSString).deletingLastPathComponent
            if !entryFolder.isEmpty { components.append(entryFolder) }
            return PageLocation(
                fileName: (entryPath as NSString).lastPathComponent,
                folderPath: components.isEmpty ? nil : components.joined(separator: "/")
            )
        case .pdf(let pdfURL, _):
            // PDFのページは独立したファイルではないため、名前はdisplayNameの組み立て
            // (ファイル名+ページ番号)に任せる。本そのものがそのPDFなので、通常フォルダは付かない。
            return PageLocation(
                fileName: displayName,
                folderPath: Self.relativePath(of: pdfURL.deletingLastPathComponent().path, under: root)
            )
        }
    }

    /// 末尾の`/`を落としたパス(ルート`/`だけは残す)。`URL.path`は通常末尾に`/`を付けないが、
    /// 前方一致で相対パスを切り出す都合上、ここで揃えておく。
    private static func normalizedPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// `root`の中から見た`path`の相対パス。`root`自身・`root`の外・rootがnilのときはnil。
    private static func relativePath(of path: String, under root: String?) -> String? {
        guard let root else { return nil }
        let path = normalizedPath(path)
        guard path != root else { return nil }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }
}
