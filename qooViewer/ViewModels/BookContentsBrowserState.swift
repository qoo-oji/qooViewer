import Foundation
import Combine

/// サイドパネル下段(本の中身ブラウザ)の閲覧状態。本ごとに作り直す(ContentViewが
/// `appState.currentBook?.id`の変化を見て新しいインスタンスに差し替える)。
///
/// 常に「今より1段深い場所」へしか移動しない(navigate内でのみ深さが増える)、純粋な
/// 階層構造のスタックとして実装している。上段のSidePanelBrowserStateと違い、ボリューム
/// 一覧のような「兄弟へのジャンプ」は存在しない。
///
/// 実際のFileManager/アーカイブI/Oは、この階層を1段ずつ辿るだけの軽い処理(BookLoaderの
/// ような再帰的な全件スキャンではない)であるため、上段のSidePanelBrowserStateと異なり
/// Task.detachedへのオフロードは行わずMainActor上で同期的に行っている
/// (ArchiveReadingの各実装はSendableではないため、MainActorとTask.detachedをまたいで
/// 同じreaderインスタンスを受け渡すのはSwift 6の厳格な並行性チェック上安全ではない、
/// という理由もある)。
@MainActor
final class BookContentsBrowserState: ObservableObject {
    @Published private(set) var entries: [BookInternalBrowsing.Entry] = []
    @Published private(set) var navigationErrorMessage: String?

    weak var preferences: AppPreferences?

    private var currentLevel: BookEntryLevel
    private var currentOrigin: ArchiveOrigin?
    private var backStack: [(BookEntryLevel, ArchiveOrigin?)] = []
    private var forwardStack: [(BookEntryLevel, ArchiveOrigin?)] = []
    /// ネストしたアーカイブへ踏み込むたびに作った一時ファイル(rar/7z、および「新しい本として
    /// 開く」ためにやむを得ず書き出したzip)。戻る/進むで再度同じ階層へ戻ったときに
    /// 再展開しなくて済むよう、都度削除せずセッション中(=この状態オブジェクトの生存期間中)
    /// 保持しておき、破棄されるときにまとめて削除する。
    private var temporaryFileURLs: [URL] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    /// 上記の理由により「1階層上へ」は常に「戻る」と一致する。
    var canGoUp: Bool { canGoBack }

    /// 本がフォルダ、または対応アーカイブ形式(zip/cbz/rar/cbr/7z/cb7)でなければnilを返す
    /// (呼び出し元はnilならこの状態オブジェクト自体を保持せず、下段セクションを表示しない)。
    /// PDF/EPUBはページがファイル単位で存在しない、またはzipコンテナの生の中身を見せても
    /// かえって分かりづらいため非対応(SidePanelViewのコメントも参照)。
    init?(book: MangaBook) {
        let url = book.sourceURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        if isDirectory.boolValue {
            currentLevel = .folder(url)
            currentOrigin = nil
        } else if isArchiveFile(url.lastPathComponent) {
            guard let reader = try? makeArchiveReader(for: url),
                  let allPaths = try? reader.listFilePaths() else { return nil }
            // matchKeyPrefix: nil ― 本自身のルート書庫そのものなので、BookLoader.loadArchiveの
            // sortKeyPrefix: nilと同じ(sortKey/matchKeyはエントリのパスそのもの)。
            currentLevel = .archive(reader: reader, allPaths: allPaths, prefix: "", matchKeyPrefix: nil)
            currentOrigin = ArchiveOrigin(backing: .onDisk(url))
        } else {
            return nil
        }
        reload()
    }

    deinit {
        let urls = temporaryFileURLs
        Task.detached(priority: .utility) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func reload() {
        do {
            entries = try BookInternalBrowsing.entries(at: currentLevel)
            navigationErrorMessage = nil
        } catch {
            entries = []
            navigationErrorMessage = localizedErrorMessage(for: error, fallback: "This folder could not be read.")
        }
    }

    /// フォルダ/ネストしたアーカイブファイルへ踏み込む(entry.navigateTarget == nilの
    /// 画像ファイルには何もしない。ダブルクリックはresolveDoubleClickを使う)。
    func navigate(_ entry: BookInternalBrowsing.Entry) {
        guard let target = entry.navigateTarget else { return }
        do {
            let next: (BookEntryLevel, ArchiveOrigin?)
            switch target {
            case .realFolder(let url):
                next = (.folder(url), nil)
            case .archiveVirtualFolder(let prefix):
                // 同じreaderのまま仮想パスを深くするだけ(I/O無し)なので、matchKeyPrefixは
                // 変わらない(BookInternalBrowsing.archiveEntriesのコメント参照 ―
                // matchKeyは仮想フォルダの深さに関係なく常にreader内の完全なパスから
                // 組み立てるため)。
                guard case .archive(let reader, let allPaths, _, let matchKeyPrefix) = currentLevel else { return }
                next = (
                    .archive(reader: reader, allPaths: allPaths, prefix: prefix, matchKeyPrefix: matchKeyPrefix),
                    currentOrigin
                )
            case .archiveFileOnDisk(let url):
                let reader = try makeArchiveReader(for: url)
                let allPaths = try reader.listFilePaths()
                // matchKeyPrefix: url.path ― BookLoader.collectPages(inFolder:...)が、フォルダの
                // 中で見つけた書庫ファイルへcollectPages(fromArchiveURL:...)を呼ぶ際に渡す
                // sortKeyPrefix(= fileURL.path)と全く同じ。
                next = (
                    .archive(reader: reader, allPaths: allPaths, prefix: "", matchKeyPrefix: url.path),
                    ArchiveOrigin(backing: .onDisk(url))
                )
            case .nestedArchiveEntry(let entryPath):
                guard case .archive(let reader, _, _, let parentMatchKeyPrefix) = currentLevel else { return }
                next = try openNestedArchive(
                    entryPath: entryPath, from: reader, parentMatchKeyPrefix: parentMatchKeyPrefix
                )
            }
            backStack.append((currentLevel, currentOrigin))
            forwardStack.removeAll()
            currentLevel = next.0
            currentOrigin = next.1
            reload()
        } catch {
            navigationErrorMessage = localizedErrorMessage(for: error, fallback: "This item could not be opened.")
        }
    }

    func goBack() {
        guard let (level, origin) = backStack.popLast() else { return }
        forwardStack.append((currentLevel, currentOrigin))
        currentLevel = level
        currentOrigin = origin
        reload()
    }

    func goForward() {
        guard let (level, origin) = forwardStack.popLast() else { return }
        backStack.append((currentLevel, currentOrigin))
        currentLevel = level
        currentOrigin = origin
        reload()
    }

    func goUp() { goBack() }

    enum DoubleClickResult {
        case jumpToPage(Int)
        case openAsNewBook(URL)
        case unavailable
    }

    /// entryのダブルクリック(画像のみ意味を持つ)を解決する。bookPages(呼び出し元が
    /// AppState.currentBookPagesを渡す)のsortKeyと一致すれば、そのページへのジャンプを
    /// 返す。一致しなければ(ネストしたアーカイブの中まで踏み込んで初めて見つかった、
    /// BookLoaderが元々読み込んでいない画像 — BookLoaderはネストしたアーカイブを一切
    /// 読み込まないため)、現在の階層の元になったアーカイブ/フォルダ自体を新しい本として
    /// 開く指示を返す。クリックした画像そのものへ厳密にジャンプすることまではスコープに
    /// 含めない(AppState.openにページ指定を通す仕組みが無く、影響範囲が大きくなるための
    /// 意図的な割り切り)。
    func resolveDoubleClick(on entry: BookInternalBrowsing.Entry, bookPages: [PageRef]) -> DoubleClickResult {
        guard entry.isImage else { return .unavailable }
        if let index = bookPages.firstIndex(where: { $0.sortKey == entry.matchKey }) {
            return .jumpToPage(index)
        }
        guard let origin = currentOrigin, let url = materializedURL(for: origin) else {
            return .unavailable
        }
        return .openAsNewBook(url)
    }

    /// ネストしたアーカイブエントリへ踏み込む。zip/cbzはメモリ上のまま新しいreaderを開き、
    /// rar/cbr/7z/cb7は一時ファイルへ書き出してから開く(ZipArchiveReader.init(data:)の
    /// コメント、ArchiveReading.swiftのライブラリ制約の調査結果を参照)。
    ///
    /// parentMatchKeyPrefixは踏み込む前の階層のmatchKeyPrefix。BookLoaderの
    /// nestedSortKeyPrefix(= sortKeyPrefix.map { "\($0)/\(path)" } ?? path)と全く同じ式で、
    /// この新しい階層のmatchKeyPrefixを組み立てる。
    private func openNestedArchive(
        entryPath: String, from reader: ArchiveReading, parentMatchKeyPrefix: String?
    ) throws -> (BookEntryLevel, ArchiveOrigin?) {
        let data = try reader.data(at: entryPath)
        let ext = (entryPath as NSString).pathExtension.lowercased()
        let newReader: ArchiveReading
        let origin: ArchiveOrigin
        if ext == "zip" || ext == "cbz" {
            newReader = try ZipArchiveReader(data: data)
            origin = ArchiveOrigin(backing: .inMemory(data: data, preferredExtension: ext))
        } else {
            let tempURL = Self.makeTemporaryFileURL(extension: ext)
            try data.write(to: tempURL)
            temporaryFileURLs.append(tempURL)
            newReader = try makeArchiveReader(for: tempURL)
            origin = ArchiveOrigin(backing: .onDisk(tempURL))
        }
        let allPaths = try newReader.listFilePaths()
        let matchKeyPrefix = parentMatchKeyPrefix.map { "\($0)/\(entryPath)" } ?? entryPath
        return (.archive(reader: newReader, allPaths: allPaths, prefix: "", matchKeyPrefix: matchKeyPrefix), origin)
    }

    /// 「新しい本として開く」ためにだけ、メモリ上のzip/cbzデータを例外的に一時ファイルへ
    /// 書き出す(AppState.open(url:)が実ファイルのURLを必要とするため)。
    private func materializedURL(for origin: ArchiveOrigin) -> URL? {
        switch origin.backing {
        case .onDisk(let url):
            return url
        case .inMemory(let data, let ext):
            let tempURL = Self.makeTemporaryFileURL(extension: ext)
            do {
                try data.write(to: tempURL)
            } catch {
                return nil
            }
            temporaryFileURLs.append(tempURL)
            return tempURL
        }
    }

    private static func makeTemporaryFileURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    private func localizedErrorMessage(for error: Error, fallback: String.LocalizationValue) -> String {
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        return (error as? LocalizedError)?.errorDescription ?? String(localized: fallback, locale: locale)
    }
}

/// BookContentsBrowserStateが「今の階層の元になったアーカイブ/フォルダ」を、必要になった
/// タイミングで実ファイルのURLへ変換できるようにするための内部状態。
private struct ArchiveOrigin {
    enum Backing {
        /// 既に実ファイルとして存在する(ネストしたアーカイブがディスク上のフォルダの中に
        /// 直接あった場合、または一時ファイルへ書き出し済みの場合)。
        case onDisk(URL)
        /// メモリ上のデータのみで、実ファイルはまだ存在しない(ネストしたzip/cbzをまだ
        /// ディスクへ書き出していない状態)。
        case inMemory(data: Data, preferredExtension: String)
    }
    let backing: Backing
}
