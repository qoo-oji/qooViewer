import Foundation
import CoreGraphics

/// 指定された1つのフォルダ、またはアーカイブファイルから、1冊の本(MangaBook)を読み込む。
///
/// フォルダの再帰スキャンやアーカイブの展開はファイルの数によっては時間がかかることがある。
/// 以前はAppState(MainActor)から同期的に直接呼んでいたため、その間メインスレッドが
/// 完全にブロックされ、操作不能な状態(レインボーカーソル)になってしまっていた。
/// そのため実際の読み込み処理はTask.detachedでメインスレッド外に逃がし、`load`自体は
/// async化して呼び出し側(AppState)がawaitで待てるようにしている。
/// nonisolated: Xcode 26既定のMainActor自動分離の対象外にして、どのコンテキストからでも
/// 呼べるようにしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated enum BookLoader {
    static func load(from url: URL) async throws -> MangaBook {
        let task = Task.detached(priority: .userInitiated) { () throws -> MangaBook in
            try loadSync(from: url)
        }
        return try await task.value
    }

    private static func loadSync(from url: URL) throws -> MangaBook {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BookLoaderError.notFound
        }
        if isDirectory.boolValue {
            return try loadFolder(url)
        }
        if isPDFFile(url.lastPathComponent) {
            return try loadPDF(url)
        }
        if isEpubFile(url.lastPathComponent) {
            return try loadEpub(url)
        }
        return try loadArchive(url)
    }

    /// フォルダの場合は、直下だけでなくサブフォルダ(章分けなど)の画像も
    /// 再帰的にすべて集めて1冊のページ一覧にする。
    private static func loadFolder(_ url: URL) throws -> MangaBook {
        var imageURLs: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDir, isImageFile(fileURL.lastPathComponent) {
                    imageURLs.append(fileURL)
                }
            }
        }
        guard !imageURLs.isEmpty else { throw BookLoaderError.noPages }

        let pages = imageURLs
            .sorted { $0.path.compare($1.path, options: .numeric) == .orderedAscending }
            .map { pageURL in
                PageRef(id: pageURL.path, sortKey: pageURL.path, source: .file(pageURL))
            }
        return MangaBook(id: url.path, title: url.lastPathComponent, sourceURL: url, pages: pages)
    }

    private static func loadArchive(_ url: URL) throws -> MangaBook {
        let reader = try makeArchiveReader(for: url)
        let paths = try reader.listFilePaths()
            .filter { isImageFile($0) }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        guard !paths.isEmpty else { throw BookLoaderError.noPages }

        let pages = paths.map { path in
            PageRef(
                id: "\(url.path)#\(path)",
                sortKey: path,
                source: pageSource(for: url, entryPath: path)
            )
        }
        return MangaBook(
            id: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            pages: pages
        )
    }

    /// PDFファイルを1冊の本として読み込む。zip/7z/rarのような「中身を展開するアーカイブ」とは
    /// 違い、PDFは1ファイルの中に複数ページを直接持つ形式のため、専用の読み込み経路になる。
    /// ページ数の取得だけを行い(軽量)、実際に各ページを画像として描画する処理は
    /// PageLoader.renderPDFPageで、表示に必要になったタイミングで都度行う。
    private static func loadPDF(_ url: URL) throws -> MangaBook {
        guard let document = CGPDFDocument(url as CFURL) else { throw BookLoaderError.notFound }
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw BookLoaderError.noPages }

        let pages = (0..<pageCount).map { index in
            PageRef(
                id: "\(url.path)#pdf#\(index)",
                sortKey: String(format: "%06d", index),
                source: .pdf(pdfURL: url, pageIndex: index)
            )
        }
        return MangaBook(
            id: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            pages: pages
        )
    }

    /// EPUBファイルを1冊の本として読み込む。EPUB自体はzipコンテナのため、内部の読み出しは
    /// ZipArchiveReaderをそのまま使う。ただしcbz(loadArchive)のように「zip内の画像を名前順に
    /// 並べる」のではなく、container.xml/package documentが定義する正しい読み順(spine)を
    /// 解決してからページを組み立てる必要があるため、専用の読み込み経路にしている
    /// (詳細はEpubStructureResolver.swift参照)。
    ///
    /// 対象は「固定レイアウトの画像ベースのコミックEPUB」のみで、文章主体のリフロー型EPUBの
    /// 本文レンダリングやDRM付きEPUBには対応していない。spineのどの項目からも画像を
    /// 1枚も特定できなかった場合は、通常のnoPagesとは区別してepubNotPictureBookを返し、
    /// ユーザーに理由が伝わるようにする。
    private static func loadEpub(_ url: URL) throws -> MangaBook {
        let reader = try ZipArchiveReader(url: url)
        let structure: EpubStructure
        do {
            structure = try EpubStructureResolver.resolve(reader: reader)
        } catch {
            throw BookLoaderError.epubNotPictureBook
        }
        guard !structure.pages.isEmpty else { throw BookLoaderError.epubNotPictureBook }

        let pages = structure.pages.enumerated().map { index, page in
            PageRef(
                id: "\(url.path)#\(page.entryPath)",
                sortKey: String(format: "%06d", index),
                source: .zip(archiveURL: url, entryPath: page.entryPath),
                epubSpreadPosition: page.spreadPosition
            )
        }
        return MangaBook(
            id: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            pages: pages,
            epubLayoutHint: EpubLayoutHint(
                pageProgressionDirection: structure.pageProgressionDirection,
                forcedDisplayMode: structure.forcedDisplayMode
            )
        )
    }
}

enum BookLoaderError: LocalizedError {
    case notFound
    case noPages
    /// EPUBとしては開けたが、画像ベースの固定レイアウトコミックとしてページを1枚も
    /// 特定できなかった場合(リフロー型の小説EPUB、DRM付きEPUBなど)。
    case epubNotPictureBook

    // Note: ここでは preferences.effectiveLocale(アプリ内の表示言語設定)ではなく
    // デフォルトのLocale解決(システムのロケールに従う)を使っている。BookLoaderは
    // AppPreferencesを持たないstatic enumのため、呼び出し元(AppState)まで
    // Localeを引き回す必要があり、エラーメッセージという頻度の低い経路のために
    // そこまでの変更は見送った。システム言語とアプリ内の表示言語設定を別々にしている
    // 場合、エラーメッセージだけシステム言語で表示されることがある。
    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "The file or folder could not be found.")
        case .noPages:
            return String(
                localized: "No supported images were found. (Supports image folders, zip/cbz, rar/cbr, 7z/cb7, PDF, and EPUB.)"
            )
        case .epubNotPictureBook:
            return String(
                localized: "This EPUB doesn't appear to be an image-based comic (fixed-layout) book, so it couldn't be opened. Text-based reflowable EPUBs and DRM-protected EPUBs are not supported."
            )
        }
    }
}
