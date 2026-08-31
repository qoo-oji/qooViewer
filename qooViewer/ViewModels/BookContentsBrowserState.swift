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
    private var currentLocator: ArchiveLocator?
    private var backStack: [(BookEntryLevel, ArchiveLocator?)] = []
    private var forwardStack: [(BookEntryLevel, ArchiveLocator?)] = []
    /// 本自身のルート階層(init時点のcurrentLevel/currentLocatorと同じ値。以後変更しない)。
    /// revealCurrentPage(sortKeys:)が、現在どこにいるかに関わらず常に本の最初から
    /// たどり直せるようにするために保持する。
    /// varなのは、releaseResources()でここが握っている書庫のファイルハンドルも
    /// その場で手放すため(以後この状態オブジェクトは使われない)。
    private var rootLevel: BookEntryLevel
    private let rootLocator: ArchiveLocator?
    /// 入れ子の書庫を開く係。**この状態オブジェクト専用のインスタンス**で、ビューア側
    /// (PageLoader)のものとは共有しない(NestedArchiveResolverの型コメント参照 ――
    /// スレッド安全性を持たせない代わりに、所有者ごとに1つ持つ約束にしてある)。
    ///
    /// lazyなのは、`preferences`がinitの**後**に代入されるため(ContentViewが本の切り替えで
    /// この状態オブジェクトを作り直し、直後にpreferencesを差す)。最初に使われるのは
    /// ユーザーが入れ子の書庫へ踏み込んだときなので、その時点では必ず入っている。
    private lazy var resolver = NestedArchiveResolver(
        limits: .standard(
            inMemoryBytes: preferences?.nestedArchiveMemoryLimitBytes
                ?? AppPreferences.defaultNestedArchiveMemoryLimitBytes
        )
    )

    /// 「新しい本として開く」ためだけに書き出した一時ファイル。解決役が持つものとは別で、
    /// 渡した先(新しく開かれた本)がいつまで使うか分からないため、こちらで寿命を持つ
    /// (NestedArchiveResolver.materializeToIndependentFileのコメント参照)。
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
        case .imageFileList:
            // 常にルート階層のみ(踏み込めない)ため、そもそもここへ来ない。
            return nil
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

    /// 本がフォルダ、対応アーカイブ形式(zip/cbz/rar/cbr/7z/cb7)、または直接渡された画像ファイル
    /// のいずれでもなければnilを返す(呼び出し元はnilならこの状態オブジェクト自体を保持せず、
    /// 下段セクションを表示しない)。
    /// PDF/EPUBはページがファイル単位で存在しない、またはzipコンテナの生の中身を見せても
    /// かえって分かりづらいため非対応(SidePanelViewのコメントも参照)。
    init?(book: MangaBook) {
        // 直接渡された画像ファイルの本(ユーザー要望)。sourceURLは先頭1ページの画像でしかなく
        // フォルダでも書庫でもないため、以下のsourceURLを見る判定には掛けられない。
        // 辿るべき中身の階層が無いので、渡された画像そのものを平坦な1階層として見せる。
        if book.origin == .imageFiles {
            currentLevel = .imageFileList(book.pages.compactMap { page in
                guard case .file(let url) = page.source else { return nil }
                return url
            })
            currentLocator = nil
            rootLevel = currentLevel
            rootLocator = nil
            reload()
            return
        }

        let url = book.sourceURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        if isDirectory.boolValue {
            currentLevel = .folder(url)
            currentLocator = nil
        } else if isArchiveFile(url.lastPathComponent) {
            guard let archive = try? NestedArchiveResolver.openRootArchive(at: url),
                  let allPaths = try? archive.reader.listFilePaths() else { return nil }
            // matchKeyPrefix: nil ― 本自身のルート書庫そのものなので、BookLoader.loadArchiveの
            // sortKeyPrefix: nilと同じ(sortKey/matchKeyはエントリのパスそのもの)。
            currentLevel = .archive(archive: archive, allPaths: allPaths, prefix: "", matchKeyPrefix: nil)
            currentLocator = ArchiveLocator(rootURL: url)
        } else {
            return nil
        }
        rootLevel = currentLevel
        rootLocator = currentLocator
        reload()
    }

    /// この本の中身ブラウザが用済みになったとき(本を閉じた・別の本へ移った)に呼ぶ。
    ///
    /// ARCのdeinit任せにしないのは、SwiftUIが旧世代のビューを抱えているあいだ解放が遅れ、
    /// その間ずっと入れ子の書庫の一時ファイルとファイルハンドルが残るため
    /// (PageLoader.releaseAllResources / ViewerViewModel.releaseResourcesと同じ理由)。
    func releaseResources() {
        // 階層のスタックが握っているOpenArchiveも手放す(これが最後の持ち主なら、
        // その場で一時ファイルが消える)。
        backStack.removeAll()
        forwardStack.removeAll()
        currentLevel = .imageFileList([])
        rootLevel = .imageFileList([])
        currentLocator = nil
        entries = []
        resolver.purgeAll()
        removeIndependentTemporaryFiles()
    }

    deinit {
        // releaseResources()が呼ばれていれば空。取りこぼしの保険として残す。
        // deinitはnonisolatedな文脈なのでMainActorのメソッドは呼べず、ここだけ手で書く
        // (ファイルI/Oをdeinitのスレッドで行わない点は従来どおり)。
        let urls = temporaryFileURLs
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func removeIndependentTemporaryFiles() {
        let urls = temporaryFileURLs
        temporaryFileURLs.removeAll()
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// 今開いている本の実際のページ順(sortKey → 読書順の位置)。一覧の並びはこれに従う
    /// (BookInternalBrowsing.sortedEntries参照)。ContentViewがAppState.currentBookPages
    /// (ViewerViewModelが同期している実効順)から流し込み、環境設定の並び順・ユーザーの
    /// 並べ替え・除外が変わればそのたびに更新される。空のままでも動く(その場合は名前順)。
    var pageOrder: [String: Int] = [:] {
        didSet { if pageOrder != oldValue { reload() } }
    }

    func reload() {
        do {
            entries = try BookInternalBrowsing.entries(
                at: currentLevel, sortOrder: preferences?.sidePanelSortOrder ?? .foldersFirst,
                pageOrder: pageOrder
            )
            navigationErrorMessage = nil
        } catch {
            entries = []
            navigationErrorMessage = localizedErrorMessage(for: error, fallback: "This folder could not be read.")
        }
    }

    /// フォルダ/ネストしたアーカイブファイルへ踏み込む(entry.navigateTarget == nilの
    /// 画像ファイルには何もしない。画像のクリックはresolveImageClickを使う)。
    func navigate(_ entry: BookInternalBrowsing.Entry) {
        guard let target = entry.navigateTarget else { return }
        do {
            guard let next = try openContainer(target, from: currentLevel, locator: currentLocator) else { return }
            backStack.append((currentLevel, currentLocator))
            forwardStack.removeAll()
            currentLevel = next.0
            currentLocator = next.1
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
        _ target: BookInternalBrowsing.NavigateTarget, from level: BookEntryLevel, locator: ArchiveLocator?
    ) throws -> (BookEntryLevel, ArchiveLocator?)? {
        // .imageFileListの階層はコンテナを1件も含まない(navigateTargetが常にnil)ため、
        // ここへ辿り着くことはない。
        switch target {
        case .realFolder(let url):
            return (.folder(url), nil)
        case .archiveVirtualFolder(let prefix):
            // 同じreaderのまま仮想パスを深くするだけ(I/O無し)なので、matchKeyPrefixは
            // 変わらない(BookInternalBrowsing.archiveEntriesのコメント参照 ―
            // matchKeyは仮想フォルダの深さに関係なく常にreader内の完全なパスから
            // 組み立てるため)。
            guard case .archive(let archive, let allPaths, _, let matchKeyPrefix) = level else { return nil }
            return (.archive(archive: archive, allPaths: allPaths, prefix: prefix, matchKeyPrefix: matchKeyPrefix), locator)
        case .archiveFileOnDisk(let url):
            let archive = try NestedArchiveResolver.openRootArchive(at: url)
            let allPaths = try archive.reader.listFilePaths()
            // matchKeyPrefix: url.path ― BookLoader.collectPages(inFolder:...)が、フォルダの
            // 中で見つけた書庫ファイルへcollectPages(at:...)を呼ぶ際に渡す
            // sortKeyPrefix(= fileURL.path)と全く同じ。
            return (.archive(archive: archive, allPaths: allPaths, prefix: "", matchKeyPrefix: url.path), ArchiveLocator(rootURL: url))
        case .nestedArchiveEntry(let entryPath):
            guard case .archive(let parentArchive, _, _, let parentMatchKeyPrefix) = level,
                  let locator
            else { return nil }
            return try openNestedArchive(
                entryPath: entryPath, parentArchive: parentArchive, parentLocator: locator,
                parentMatchKeyPrefix: parentMatchKeyPrefix
            )
        }
    }

    func goBack() {
        guard let (level, locator) = backStack.popLast() else { return }
        forwardStack.append((currentLevel, currentLocator))
        currentLevel = level
        currentLocator = locator
        reload()
    }

    func goForward() {
        guard let (level, locator) = forwardStack.popLast() else { return }
        backStack.append((currentLevel, currentLocator))
        currentLevel = level
        currentLocator = locator
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
        currentLocator = resolved.final.1
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
    ) -> (path: [(BookEntryLevel, ArchiveLocator?)], final: (BookEntryLevel, ArchiveLocator?))? {
        var level = rootLevel
        var locator = rootLocator
        var path: [(BookEntryLevel, ArchiveLocator?)] = []
        for _ in 0..<Self.maxResolutionDepth {
            guard let levelEntries = try? BookInternalBrowsing.entries(
                at: level, sortOrder: preferences?.sidePanelSortOrder ?? .foldersFirst,
                pageOrder: pageOrder
            ) else { return nil }
            if levelEntries.contains(where: { $0.matchKey == matchKey }) {
                return (path, (level, locator))
            }
            guard let container = levelEntries.first(where: {
                $0.isContainer && Self.matchKey(matchKey, isContainedIn: $0.matchKey)
            }), let target = container.navigateTarget,
                let next = try? openContainer(target, from: level, locator: locator) else { return nil }
            path.append((level, locator))
            level = next.0
            locator = next.1
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

    enum ImageClickResult {
        case jumpToPage(Int)
        case openAsNewBook(URL)
        case unavailable
    }

    /// entryのクリック(画像のみ意味を持つ)を解決する。bookPages(呼び出し元が
    /// AppState.currentBookPagesを渡す)のsortKeyと一致すれば、そのページへのジャンプを
    /// 返す。一致しなければ(ネストしたアーカイブの中まで踏み込んで初めて見つかった、
    /// BookLoaderが元々読み込んでいない画像 — BookLoaderはネストしたアーカイブを一切
    /// 読み込まないため)、現在の階層の元になったアーカイブ/フォルダ自体を新しい本として
    /// 開く指示を返す。クリックした画像そのものへ厳密にジャンプすることまではスコープに
    /// 含めない(AppState.openにページ指定を通す仕組みが無く、影響範囲が大きくなるための
    /// 意図的な割り切り)。
    func resolveImageClick(on entry: BookInternalBrowsing.Entry, bookPages: [PageRef]) -> ImageClickResult {
        guard entry.isImage else { return .unavailable }
        if let index = bookPages.firstIndex(where: { $0.sortKey == entry.matchKey }) {
            return .jumpToPage(index)
        }
        guard let locator = currentLocator, let url = materializedURL(for: locator) else {
            return .unavailable
        }
        return .openAsNewBook(url)
    }

    /// ネストしたアーカイブエントリへ踏み込む。
    ///
    /// zip/cbzはメモリ上のまま、rar/cbr/7z/cb7は一時ファイルへ書き出してから開く ―― という
    /// 使い分けは解決役(NestedArchiveResolver)がまとめて面倒を見るので、ここは座標を1段
    /// 深くして渡すだけでよい。以前はこのメソッドが自前で書き出しと後始末をしており、
    /// BookLoader側と同じ処理が2つ存在していた。
    ///
    /// **解決役のLRUには載せない(openTransient)。** 開いた書庫の寿命は、この下段ブラウザの
    /// 移動履歴(currentLevel / backStack / forwardStack)がそのまま持つ ―― そしてその履歴は
    /// 「今いる枝」しか保持しない(深さは最大でも入れ子の上限)。LRUにも載せると、
    /// 履歴が持っているぶんとは別に予算いっぱいまで溜まり、ビューア側のぶんと二重に
    /// ディスクを使うことになる。戻る/進むで同じ階層へ戻ったときは履歴が持っている
    /// OpenArchiveをそのまま使い回すので、取り出し直しも起きない。
    ///
    /// parentMatchKeyPrefixは踏み込む前の階層のmatchKeyPrefix。BookLoaderの
    /// nestedSortKeyPrefix(= sortKeyPrefix.map { "\($0)/\(path)" } ?? path)と全く同じ式で、
    /// この新しい階層のmatchKeyPrefixを組み立てる。
    private func openNestedArchive(
        entryPath: String, parentArchive: OpenArchive, parentLocator: ArchiveLocator,
        parentMatchKeyPrefix: String?
    ) throws -> (BookEntryLevel, ArchiveLocator?) {
        let locator = parentLocator.appending(entryPath)
        let archive = try resolver.openTransient(locator, parentReader: parentArchive.reader)
        let allPaths = try archive.reader.listFilePaths()
        let matchKeyPrefix = parentMatchKeyPrefix.map { "\($0)/\(entryPath)" } ?? entryPath
        return (.archive(archive: archive, allPaths: allPaths, prefix: "", matchKeyPrefix: matchKeyPrefix), locator)
    }

    /// 「新しい本として開く」ために、今いる階層の書庫を実ファイルとして用意する
    /// (AppState.open(url:)が実ファイルのURLを必要とするため)。
    ///
    /// 入れ子でなければ元のファイルをそのまま返す。入れ子の場合は、解決役が持っている
    /// 一時ファイルを流用せず**独立したコピー**を書き出す ―― 向こうの寿命はLRUの追い出しに
    /// 握られており、受け取った側(新しく開かれた本)がいつまで使うか分からないため。
    /// こちらで書き出したぶんの削除はこの状態オブジェクトが持つ(temporaryFileURLs)。
    private func materializedURL(for locator: ArchiveLocator) -> URL? {
        guard locator.isNested else { return locator.rootURL }
        guard let url = try? resolver.materializeToIndependentFile(locator) else { return nil }
        temporaryFileURLs.append(url)
        return url
    }

    private func localizedErrorMessage(for error: Error, fallback: String.LocalizationValue) -> String {
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        return (error as? LocalizedError)?.errorDescription ?? String(localized: fallback, locale: locale)
    }
}
