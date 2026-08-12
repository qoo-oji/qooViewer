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
    /// 今ビューアに表示されているページのmatchKey(revealCurrentPage参照)。一覧の該当行の
    /// ハイライト、および自動スクロールに使う。
    @Published private(set) var highlightedMatchKeys: Set<String> = []

    weak var preferences: AppPreferences?

    private var currentLevel: BookEntryLevel
    private var currentOrigin: ArchiveOrigin?
    private var backStack: [(BookEntryLevel, ArchiveOrigin?)] = []
    private var forwardStack: [(BookEntryLevel, ArchiveOrigin?)] = []
    /// 本自身のルート階層(init時点のcurrentLevel/currentOriginと同じ値。以後変更しない)。
    /// revealCurrentPage(sortKeys:)が、現在どこにいるかに関わらず常に本の最初から
    /// たどり直せるようにするために保持する。
    private let rootLevel: BookEntryLevel
    private let rootOrigin: ArchiveOrigin?
    /// ネストしたアーカイブへ踏み込むたびに作った一時ファイル(rar/7z、および「新しい本として
    /// 開く」ためにやむを得ず書き出したzip)。戻る/進むで再度同じ階層へ戻ったときに
    /// 再展開しなくて済むよう、都度削除せずセッション中(=この状態オブジェクトの生存期間中)
    /// 保持しておき、破棄されるときにまとめて削除する。
    private var temporaryFileURLs: [URL] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    /// 上記の理由により「1階層上へ」は常に「戻る」と一致する。
    var canGoUp: Bool { canGoBack }
    /// 今、本自身のルート階層(本のファイル/フォルダそのもの)を見ているかどうか。
    /// backStackが空 = ここまで一度もnavigate/revealCurrentPageで深さが増えていないか、
    /// goBackで完全に戻り切った状態、のいずれか。
    private var isAtRootLevel: Bool { backStack.isEmpty }

    /// 今のフォルダ/ネストした書庫の名前。ルート階層にいるときはnil(SidePanelViewはこれが
    /// nilならボタン下の名前表示を省略する)。ユーザー要望: 本の中の階層を移動しているときは、
    /// 今どこにいるか分かるようボタンの下にファイル名を表示したい。
    var currentLocationName: String? {
        guard !isAtRootLevel else { return nil }
        return Self.displayName(for: currentLevel)
    }

    private static func displayName(for level: BookEntryLevel) -> String? {
        switch level {
        case .folder(let url):
            return DirectoryBrowser.displayName(for: url)
        case .archive(_, _, let prefix, let matchKeyPrefix):
            if !prefix.isEmpty {
                // 仮想フォルダの中 ― prefixは"chapter1/nested/"のように末尾"/"付きなので、
                // 末尾のスラッシュを除いた最後の要素がそのままフォルダ名。
                let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
                if let slash = trimmed.range(of: "/", options: .backwards) {
                    return String(trimmed[trimmed.index(after: slash.lowerBound)...])
                }
                return trimmed
            }
            // prefixが空 ― ネストした書庫そのものの直下。ファイル名はmatchKeyPrefix
            // (踏み込んだ書庫エントリのパスの積み重ね)の末尾の要素から取る。
            guard let matchKeyPrefix else { return nil }
            if let slash = matchKeyPrefix.range(of: "/", options: .backwards) {
                return String(matchKeyPrefix[matchKeyPrefix.index(after: slash.lowerBound)...])
            }
            return matchKeyPrefix
        }
    }

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
        rootLevel = currentLevel
        rootOrigin = currentOrigin
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
            guard let next = try openContainer(target, from: currentLevel, origin: currentOrigin) else { return }
            backStack.append((currentLevel, currentOrigin))
            forwardStack.removeAll()
            currentLevel = next.0
            currentOrigin = next.1
            reload()
        } catch {
            navigationErrorMessage = localizedErrorMessage(for: error, fallback: "This item could not be opened.")
        }
    }

    /// navigateTargetを、levelを起点として開く。navigate(_:)とresolveLevel(forMatchKey:)
    /// (revealCurrentPage用)の両方が使う共通ロジック。levelが対象のnavigateTargetと
    /// 噛み合わない場合(.archiveVirtualFolder/.nestedArchiveEntryはlevelが.archiveで
    /// あることが前提)はnilを返す(navigate(_:)側は元々この場合何もしなかったので、
    /// その挙動を保つ)。
    private func openContainer(
        _ target: BookInternalBrowsing.NavigateTarget, from level: BookEntryLevel, origin: ArchiveOrigin?
    ) throws -> (BookEntryLevel, ArchiveOrigin?)? {
        switch target {
        case .realFolder(let url):
            return (.folder(url), nil)
        case .archiveVirtualFolder(let prefix):
            // 同じreaderのまま仮想パスを深くするだけ(I/O無し)なので、matchKeyPrefixは
            // 変わらない(BookInternalBrowsing.archiveEntriesのコメント参照 ―
            // matchKeyは仮想フォルダの深さに関係なく常にreader内の完全なパスから
            // 組み立てるため)。
            guard case .archive(let reader, let allPaths, _, let matchKeyPrefix) = level else { return nil }
            return (.archive(reader: reader, allPaths: allPaths, prefix: prefix, matchKeyPrefix: matchKeyPrefix), origin)
        case .archiveFileOnDisk(let url):
            let reader = try makeArchiveReader(for: url)
            let allPaths = try reader.listFilePaths()
            // matchKeyPrefix: url.path ― BookLoader.collectPages(inFolder:...)が、フォルダの
            // 中で見つけた書庫ファイルへcollectPages(fromArchiveURL:...)を呼ぶ際に渡す
            // sortKeyPrefix(= fileURL.path)と全く同じ。
            return (.archive(reader: reader, allPaths: allPaths, prefix: "", matchKeyPrefix: url.path), ArchiveOrigin(backing: .onDisk(url)))
        case .nestedArchiveEntry(let entryPath):
            guard case .archive(let reader, _, _, let parentMatchKeyPrefix) = level else { return nil }
            return try openNestedArchive(entryPath: entryPath, from: reader, parentMatchKeyPrefix: parentMatchKeyPrefix)
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

    /// ビューアに今実際に表示されているページ(sortKeys。単ページなら1件、見開きで2ページとも
    /// 表示中なら2件)を、常に一覧内でハイライト+スクロール表示できる状態に保つ。
    /// ContentView経由でページ送りのたびに呼ばれる(AppState.currentVisiblePageSortKeys、
    /// ContentView.swiftの.onChange参照)。
    ///
    /// 今の階層(entries)の中に対象が見つかればハイライト対象を差し替えるだけ。見つからない
    /// 場合(ページ送りでフォルダ/ネストした書庫の境界をまたいだ場合)は、本のルートから
    /// たどり直して対象を含む階層を探し、そこへ切り替える(resolveLevel参照)。
    ///
    /// resolveLevelが返すpathは、ルートから対象の直前の階層まで「navigate(_:)を1回ずつ
    /// 手動で辿った場合と全く同じ」経路になるようbackStackを丸ごと置き換える(単に直前の
    /// currentLevelを1件pushするだけだと、goUp()がその直前の階層 ― ページ送りで通り過ぎた
    /// 別の書庫など、対象の実際の親ではない場所 ― に戻ってしまう不具合になっていた。
    /// ユーザー報告: ページ送りで書庫ファイルを移動した後「1階層上へ」を押すと、1つ前の
    /// 書庫ファイルに戻ってしまう)。
    func revealCurrentPage(sortKeys: [String]) {
        guard !sortKeys.isEmpty else { return }
        if entries.contains(where: { sortKeys.contains($0.matchKey) }) {
            highlightedMatchKeys = Set(sortKeys)
            return
        }
        guard let resolved = resolveLevel(forMatchKey: sortKeys[0]) else { return }
        backStack = resolved.path
        forwardStack.removeAll()
        currentLevel = resolved.final.0
        currentOrigin = resolved.final.1
        reload()
        highlightedMatchKeys = Set(sortKeys)
    }

    /// revealCurrentPage用: 本のルート(rootLevel)から出発し、entries(at:)とnavigateTargetを
    /// 使って、与えられたmatchKey(=PageRef.sortKey)を含む階層まで実際に1階層ずつ辿る
    /// (navigate(_:)を手動で繰り返した場合と全く同じ経路になる ― 「今の階層のentries一覧の
    /// 中に、対象を配下に含むコンテナ(フォルダ/ネストした書庫)を探し、そこへ踏み込む」を
    /// 繰り返すだけなので、BookLoaderのsortKey組み立て方やアーカイブ形式ごとの違いを
    /// このメソッド自身が知る必要が無い)。見つからなければnil(matchKeyは必ずこの本の
    /// 実在するページのsortKeyのはずなので通常は起きないが、途中でI/Oエラーが起きた場合
    /// などの防御)。pathは[root, ..., 対象の直前の階層]の順(backStackへそのまま代入できる
    /// 並び)。
    private func resolveLevel(
        forMatchKey matchKey: String
    ) -> (path: [(BookEntryLevel, ArchiveOrigin?)], final: (BookEntryLevel, ArchiveOrigin?))? {
        var level = rootLevel
        var origin = rootOrigin
        var path: [(BookEntryLevel, ArchiveOrigin?)] = []
        for _ in 0..<Self.maxResolutionDepth {
            guard let levelEntries = try? BookInternalBrowsing.entries(at: level) else { return nil }
            if levelEntries.contains(where: { $0.matchKey == matchKey }) {
                return (path, (level, origin))
            }
            guard let container = levelEntries.first(where: {
                $0.isContainer && Self.matchKey(matchKey, isContainedIn: $0.matchKey)
            }), let target = container.navigateTarget,
                let next = try? openContainer(target, from: level, origin: origin) else { return nil }
            path.append((level, origin))
            level = next.0
            origin = next.1
        }
        return nil
    }

    /// containerMatchKeyが表すフォルダ/ネストした書庫の配下にmatchKeyがあるかどうか。
    /// 仮想フォルダのmatchKeyは末尾"/"付き(BookInternalBrowsing.archiveEntries参照)、
    /// 実フォルダ/書庫ファイルのmatchKeyは付いていないため、後者は"/"を補ってから比較する
    /// (補わずに単純な前方一致だけで判定すると、"chapter1"と"chapter10"のように片方が
    /// 他方の文字列prefixになっている兄弟同士を誤って混同してしまう)。
    private static func matchKey(_ matchKey: String, isContainedIn containerMatchKey: String) -> Bool {
        containerMatchKey.hasSuffix("/")
            ? matchKey.hasPrefix(containerMatchKey)
            : matchKey.hasPrefix(containerMatchKey + "/")
    }

    private static let maxResolutionDepth = 32

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
