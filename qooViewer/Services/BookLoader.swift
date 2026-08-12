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
    ///
    /// ユーザー要望: フォルダの中(サブフォルダを含むどの階層でも)に、画像ファイルだけでなく
    /// zip/cbz・rar/cbr・7z/cb7形式の書庫ファイルが直接置かれているケース(章ごとに書庫化されて
    /// いる、書庫の中に書庫が入っているなど)も、1冊の本として画像と同じページ一覧に統合して
    /// 開けるようにする。実際の統合処理はcollectPages(fromArchiveURL:...)に委譲する
    /// (書庫の中の書庫、そのまた中の書庫…という再帰にも対応する。maxNestedArchiveDepth参照)。
    private static func loadFolder(_ url: URL) throws -> MangaBook {
        var temporaryFileURLs: [URL] = []
        let pages = collectPages(inFolder: url, temporaryFileURLs: &temporaryFileURLs)
        guard !pages.isEmpty else { throw BookLoaderError.noPages }

        let sortedPages = pages.sorted { $0.sortKey.compare($1.sortKey, options: .numeric) == .orderedAscending }
        return MangaBook(
            id: url.path,
            title: url.lastPathComponent,
            sourceURL: url,
            pages: sortedPages,
            temporaryResources: BookTemporaryResources(fileURLs: temporaryFileURLs)
        )
    }

    /// loadFolderの実処理。フォルダを再帰的に辿り、画像ファイルはそのままページ化し、
    /// 書庫ファイルが見つかった場合はcollectPages(fromArchiveURL:...)でその中身も統合する。
    /// ディスク上に実在する書庫ファイルを開くだけなので、一時ファイルへの書き出しはまだ不要
    /// (その書庫自身がさらにネストした書庫を含む場合にだけ、collectPages内で発生する)。
    private static func collectPages(inFolder url: URL, temporaryFileURLs: inout [URL]) -> [PageRef] {
        var pages: [PageRef] = []
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return pages }

        for case let fileURL as URL in enumerator {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else { continue }
            let name = fileURL.lastPathComponent
            if isImageFile(name) {
                pages.append(PageRef(id: fileURL.path, sortKey: fileURL.path, source: .file(fileURL)))
            } else if isArchiveFile(name) {
                let nestedPages = (try? collectPages(
                    fromArchiveURL: fileURL,
                    idPrefix: fileURL.path,
                    sortKeyPrefix: fileURL.path,
                    temporaryFileURLs: &temporaryFileURLs,
                    depth: 0
                )) ?? []
                pages.append(contentsOf: nestedPages)
            }
        }
        return pages
    }

    /// ユーザー要望: アーカイブの直下(またはその中でさらに見つかった、入れ子になった
    /// アーカイブの中)に画像が無く、書庫ファイルしか無いケースでも開けるようにする。
    /// 書庫の直下に見つかった書庫ファイルは、その中身(画像・さらに入れ子の書庫)も
    /// 再帰的に統合して1冊の本のページ一覧に含める。
    private static func loadArchive(_ url: URL) throws -> MangaBook {
        var temporaryFileURLs: [URL] = []
        let pages = try collectPages(
            fromArchiveURL: url, idPrefix: url.path, sortKeyPrefix: nil,
            temporaryFileURLs: &temporaryFileURLs, depth: 0
        )
        guard !pages.isEmpty else { throw BookLoaderError.noPages }

        let sortedPages = pages.sorted { $0.sortKey.compare($1.sortKey, options: .numeric) == .orderedAscending }
        return MangaBook(
            id: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            pages: sortedPages,
            temporaryResources: BookTemporaryResources(fileURLs: temporaryFileURLs)
        )
    }

    /// 書庫の中に書庫が何重に入れ子になっていても壊れたアーカイブなどで無限に再帰しないための
    /// 安全装置(通常のマンガでこの深さに達することは無い)。
    private static let maxNestedArchiveDepth = 8

    /// archiveURL(実際にディスク上に存在する書庫ファイル)の中身を列挙し、画像はそのまま
    /// ページ化、さらに入れ子になった書庫が見つかった場合は再帰的に統合する。
    ///
    /// 入れ子の書庫は、reader.data(at:)で取り出したバイト列を一時ファイルへ書き出してから
    /// 開き直す(rar/7zのライブラリがメモリ上のDataからは開けずファイルパスを要求するため。
    /// zipもここでは一時ファイル化する — SidePanelの本の中身ブラウザ(BookContentsBrowserState)
    /// と異なり、ここで作るPageRef.sourceのarchiveURLはPageLoaderが本を閲覧している間ずっと
    /// 繰り返し参照する必要があり、都度メモリ上のDataを持ち回るより実ファイルとして
    /// 存在させておくほうが単純で安全なため)。書き出した一時ファイルはこの本を表す
    /// MangaBook.temporaryResourcesが保持し、本を閉じてこの本のすべてのコピーが解放された
    /// タイミングでARCにより自動的に削除される(BookTemporaryResources参照)。
    ///
    /// idPrefix/sortKeyPrefixは、この階層のPageRef.id/sortKeyを組み立てるための接頭辞。
    /// sortKeyPrefixがnilの場合は最上位(本そのものの書庫)を表し、既存の挙動(sortKey =
    /// エントリのパスそのもの)をそのまま維持する。非nilの場合は入れ子の書庫を表し、
    /// "\(prefix)/\(path)"の形にすることで、その書庫ファイル自身が兄弟ファイルと並んでいた
    /// 位置に、中身がそのまま展開されたかのように自然順ソートされる。
    private static func collectPages(
        fromArchiveURL archiveURL: URL,
        idPrefix: String,
        sortKeyPrefix: String?,
        temporaryFileURLs: inout [URL],
        depth: Int
    ) throws -> [PageRef] {
        guard depth <= maxNestedArchiveDepth else { return [] }
        let reader = try makeArchiveReader(for: archiveURL)
        let allPaths = try reader.listFilePaths()

        var pages: [PageRef] = []
        for path in allPaths {
            if isImageFile(path) {
                pages.append(PageRef(
                    id: "\(idPrefix)#\(path)",
                    sortKey: sortKeyPrefix.map { "\($0)/\(path)" } ?? path,
                    source: pageSource(for: archiveURL, entryPath: path)
                ))
            } else if isArchiveFile(path), depth < maxNestedArchiveDepth {
                guard let data = try? reader.data(at: path) else { continue }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension((path as NSString).pathExtension)
                guard (try? data.write(to: tempURL)) != nil else { continue }
                temporaryFileURLs.append(tempURL)

                let nestedIdPrefix = "\(idPrefix)#\(path)"
                let nestedSortKeyPrefix = sortKeyPrefix.map { "\($0)/\(path)" } ?? path
                let nestedPages = (try? collectPages(
                    fromArchiveURL: tempURL,
                    idPrefix: nestedIdPrefix,
                    sortKeyPrefix: nestedSortKeyPrefix,
                    temporaryFileURLs: &temporaryFileURLs,
                    depth: depth + 1
                )) ?? []
                pages.append(contentsOf: nestedPages)
            }
        }
        return pages
    }

    /// PDFファイルを1冊の本として読み込む。zip/7z/rarのような「中身を展開するアーカイブ」とは
    /// 違い、PDFは1ファイルの中に複数ページを直接持つ形式のため、専用の読み込み経路になる。
    /// ページ数の取得だけを行い(軽量)、実際に各ページを画像として描画する処理は
    /// PageLoader.renderPDFPageで、表示に必要になったタイミングで都度行う。
    ///
    /// 併せて、Document Catalogから読み方向/見開き強制のヒント(EPUBのpage-progression-direction/
    /// rendition:spreadに相当)を読み取り、sourceLayoutHintとして持たせる(詳細は
    /// PDFStructureResolver.resolveLayoutHintのコメント参照)。目次(アウトライン)の読み取りは
    /// ここでは行わない。EPUBの目次と同じく、ブックマークが1件も無い場合にのみ意味を持つ処理の
    /// ため、本を開くたびに毎回コストをかける必要が無く、ViewerViewModelが必要になったタイミングで
    /// 都度読み込む(autoImportPDFOutlineAsBookmarksIfNeeded参照)。
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
            pages: pages,
            sourceLayoutHint: PDFStructureResolver.resolveLayoutHint(document: document)
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
            sourceLayoutHint: SourceLayoutHint(
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
