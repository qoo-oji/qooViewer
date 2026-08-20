import Foundation

/// 本(フォルダ / zip・cbz / rar・cbr / 7z・cb7)の中から`ComicInfo.xml`を探して解析する。
/// EpubStructureResolver.resolveMetadata / PDFStructureResolver.resolveMetadataのCBZ版。
///
/// 用途は2つある:
/// - 本を初めて開いたときに、書誌メタデータ・読み方向・ブックマークをDBの初期値として取り込む
///   (ViewerViewModel / BookLoader)。
/// - CBZ書き出しのとき、元ファイルに既に入っていたComicInfo.xmlの内容を引き継ぐ
///   (CbzExporter。qooViewerが管理しない項目 — 出版社・あらすじ・発行年など — を
///   書き出しのたびに失わないようにするため)。
///
/// nonisolated: BookLoader(Task.detached)・CbzExporterから呼ばれるため
/// (詳細はServices/ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum ComicInfoResolver {
    /// フォルダでもアーカイブでも、この1つで扱えるようにした入口。
    /// PDF・EPUBはComicInfo.xmlを持たない形式のため常にnilを返す。
    static func resolve(bookAt url: URL) -> ComicInfo? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return resolveInFolder(url)
        }
        guard isArchiveFile(url.lastPathComponent) else { return nil }
        guard let reader = try? makeArchiveReader(for: url) else { return nil }
        return resolve(reader: reader)
    }

    /// 既に開いてあるアーカイブから読む版(BookLoaderのように、ページ列挙のために
    /// 同じReaderを既に持っている呼び出し元向け)。
    static func resolve(reader: ArchiveReading) -> ComicInfo? {
        guard let paths = try? reader.listFilePaths(),
              let path = comicInfoPath(in: paths),
              let data = try? reader.data(at: path)
        else { return nil }
        return ComicInfoXML.parse(data)
    }

    private static func resolveInFolder(_ url: URL) -> ComicInfo? {
        let fileURL = url.appendingPathComponent(ComicInfoXML.fileName)
        // 大文字小文字を区別しないファイルシステム(macOSの既定)ではこれで"comicinfo.xml"も
        // 拾えるが、区別する設定のボリュームもあるため、見つからなければ直下を走査する。
        if let data = try? Data(contentsOf: fileURL) {
            return ComicInfoXML.parse(data)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              let match = names.first(where: { $0.caseInsensitiveCompare(ComicInfoXML.fileName) == .orderedSame }),
              let data = try? Data(contentsOf: url.appendingPathComponent(match))
        else { return nil }
        return ComicInfoXML.parse(data)
    }

    /// アーカイブ内のエントリ一覧からComicInfo.xmlを選ぶ。
    ///
    /// Komga・Kavitaはどちらも「ルート直下」しか見ないため、まずルート直下を探す。それでも
    /// 見つからない場合に限りサブフォルダ内のものを拾う — 書庫全体をもう1階層フォルダで
    /// 包んでしまっている本(この種のファイルは実際によくある)からも、読み取りのときだけは
    /// 情報を拾えるようにするため(書き出すときは必ずルート直下に置く)。
    private static func comicInfoPath(in paths: [String]) -> String? {
        if let root = paths.first(where: { $0.caseInsensitiveCompare(ComicInfoXML.fileName) == .orderedSame }) {
            return root
        }
        return paths.first {
            ($0 as NSString).lastPathComponent.caseInsensitiveCompare(ComicInfoXML.fileName) == .orderedSame
        }
    }
}

extension ComicInfo {
    /// このComicInfoから読み取れる書誌メタデータ(タイトル・著者・シリーズ・巻数)。
    /// EPUB/PDFと同じ経路でDBへ取り込むため、共通のSourceBookMetadataへ変換する。
    ///
    /// 著者は「作画者(Penciller)よりも原作者(Writer)を優先し、どちらも無ければ表紙・その他の
    /// クレジットへ降りる」という順で1つだけ選ぶ。BookMetadata.authorが単一の文字列で、
    /// 役割の区別を持たないため(カンマ区切りで複数人が書かれている場合はその文字列のまま
    /// 入れる — 分割して1人目だけを採るより、書かれている情報を落とさないほうがよい)。
    var sourceBookMetadata: SourceBookMetadata {
        var metadata = SourceBookMetadata()
        metadata.title = title
        metadata.author = [writer, penciller, coverArtist, editor].first { !$0.isEmpty } ?? ""
        metadata.series = series
        // 巻数はNumberを優先する。Numberが空でVolumeだけが書かれているファイル(Kavita向けに
        // 作られたもの)もあるため、その場合はVolumeから拾う。
        if !number.isEmpty {
            metadata.seriesIndex = number
        } else if let volume {
            metadata.seriesIndex = String(volume)
        }
        return metadata
    }

    /// このComicInfoが確定させている読み方向。
    ///
    /// `YesAndRightToLeft`のときだけ右開きを確定させる。`Yes`は「漫画である」ことしか
    /// 表しておらず方向は未指定のため、左開きと解釈してはいけない(ComicInfoMangaの
    /// コメント参照)。`No`は西洋コミック向けの明示なので左開きとして扱う。
    var readingDirection: ReadingDirection? {
        switch manga {
        case .yesAndRightToLeft: return .rightToLeft
        case .no: return .leftToRight
        case .yes, .unknown, nil: return nil
        }
    }

    /// `<Pages>`のBookmark属性に書かれている、しおりの一覧。
    /// 返すのは(0始まりのページ番号, 名前)の組で、ページ番号順に並んでいる。
    var bookmarks: [(pageIndex: Int, name: String)] {
        pages
            .compactMap { page -> (pageIndex: Int, name: String)? in
                guard let bookmark = page.bookmark?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !bookmark.isEmpty
                else { return nil }
                return (page.image, bookmark)
            }
            .sorted { $0.pageIndex < $1.pageIndex }
    }
}
