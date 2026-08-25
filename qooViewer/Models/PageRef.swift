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

    /// プログレスバーのフィルムストリップなどに表示する、ファイル名だけの短い表示名。
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
