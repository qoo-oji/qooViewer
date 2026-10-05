import Foundation
import Combine
import CoreGraphics

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
/// ただし**最上位の書庫の一覧だけは裏で取る**(`make(book:)`)。ネットワークボリューム上の書庫では、一覧 1 回が
/// 「エントリ数 × 往復」になりうるため(2026-09-24)。readerは一覧を取った裏の処理が手放してからメインへ渡す。
/// **一覧(`entries`)も裏で作る**(2026-09-27、表示の切り替えの監査の 11。`reload` のコメント)。
/// **書庫・入れ子の書庫・PDF/EPUB を開くこと、入れ子の書庫を一時ファイルへ書き出すことも裏で**(2026-10-05 の監査の範囲外の指摘。以前は
/// メインのまま同期に行い、入れ子の書庫の取り出し ―― 数百 MB の書き出しもありうる ―― の間、ネットワークボリュームの上の本では往復の
/// 間ずっと、アプリごと止まった)。reader はスレッド安全ではないので、**reader を使う仕事は一度に 1 つ**(`readerWorkTask`)で、走って
/// いる間はメインは reader に触らない ―― 入口(`navigate`・`resolveImageClick`・`revealCurrentPage`)は一覧を作っている最中と同じく
/// 断る・待たせる(`isListingPending`)。受け渡しは `ReaderHandoff`(`PreparedRootHandoff` と同じ約束)。解決役(`resolver`)も同じ
/// 理由で、走っている間に `releaseResources` が来たら、手放すのは仕事が終わってから(`isReleased`)。
@MainActor
final class BookContentsBrowserState: ObservableObject {
    @Published private(set) var entries: [BookInternalBrowsing.Entry] = []
    /// 今の階層の一覧が作れなかったときの文(一覧の代わりに出す)。
    @Published private(set) var navigationErrorMessage: String?
    /// 踏み込み(`navigate`)に失敗したときの一時的な知らせ(2026-10-04 の監査 SP-6)。一覧はそのまま残し、パネルが下に短く出す。
    /// 以前は踏み込みの失敗も `navigationErrorMessage` に入れていたので、階層は動いていないのに一覧がエラー文に置き換わったまま
    /// 戻る手段が無かった(ルートでは「戻る」が淡色、深い階層では 1 つ余分に戻る。ページ送りでも消えない)。
    @Published private(set) var stepInFailure: ViewerNotice?
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

    /// 「新しい本として開く」ためだけに書き出した一時ファイルのうち、**まだ開く側へ渡していないもの**。解決役が持つものとは別
    /// (NestedArchiveResolver.materializeToIndependentFileのコメント参照)。
    ///
    /// 渡したら(`handOffTemporaryFile`)寿命は開いた側 ―― その本を表示しているウインドウの `AppState`(`AppState.ownedTemporaryCopies`)――
    /// へ移る(2026-10-04 の監査 SP-4、実測)。以前は渡した後もここで持ち、本が替わった直後にこの状態(古い本のもの)が解放されて消して
    /// いたので、開いたばかりの一時コピーの本のページが真っ黒になった(新しい本の読み手が書庫を開くのと削除が競争した)。
    private var temporaryFileURLs: [URL] = []
    /// 渡した一時コピーの持ち主の数(アプリで 1 つ。テストは自前のものを入れる)。
    var temporaryCopies: TemporaryCopyRegistry = .shared

    /// 本のページの鍵(読み込んだときの全ページ。除外したページも入る)。今のページの並び(`bookPages`)に無くここにある画像の行は、
    /// **除外したページ**(`resolveImageClick` の `.excludedPage`)。
    private let bookPageKeys: Set<String>

    /// 一覧を作っている最中の仕事(`reload`)。
    private var listingTask: Task<Void, Never>?
    /// reader を使う仕事(書庫・PDF/EPUB を開く・入れ子の書庫を書き出す)が裏で走っている間(型コメント)。
    private var readerWorkTask: Task<Void, Never>?
    /// `releaseResources` が呼ばれた。裏で reader を使う仕事が走っていれば、その結果は捨て、解決役はそれが終わってから手放す。
    private var isReleased = false
    /// 戻る・進むの回数。裏で踏み込んでいる間に利用者が戻る・進むを押したら、踏み込んだ結果は当てない(`finishNavigate`)。
    private var historyMoveSerial = 0
    /// 今のページを含む階層を裏で探している最中の仕事(`revealCurrentPage`)。
    private var revealTask: Task<Void, Never>?
    private var revealToken: UUID?
    /// 一覧の世代。階層・並び順が変わるたび(`reload`)、探した階層へ切り替えたときに進める。古い世代の結果は捨てる。
    private var listingGeneration = 0
    /// 一覧・階層探しを待っている間に届いた「今のページを見せる」(最後の 1 回だけ。済んだら当て直す)。
    private var pendingRevealSortKeys: [String]?

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
        case .documentPages(let fileName, _):
            return fileName
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
    convenience init?(book: MangaBook) {
        // 直接渡された画像ファイルの本(ユーザー要望)。sourceURLは先頭1ページの画像でしかなく
        // フォルダでも書庫でもないため、以下のsourceURLを見る判定には掛けられない。
        // 辿るべき中身の階層が無いので、渡された画像そのものを平坦な1階層として見せる。
        if book.origin == .imageFiles {
            self.init(book: book, root: .imageFiles(book.pages.compactMap { page in
                guard case .file(let url) = page.source else { return nil }
                return url
            }))
            return
        }
        guard let root = Self.prepareRoot(of: book) else { return nil }
        self.init(book: book, root: root)
    }

    /// 本の最上位の階層を、**メインスレッドを塞がずに**用意してから作る(ContentView はこちらを使う)。
    ///
    /// 書庫の本では最上位を作るのに書庫の一覧が要る。ZIPFoundation の一覧はエントリごとにローカルヘッダーを読むので、
    /// ネットワークボリューム上の本では「エントリ数 × 往復」になり、メインスレッドで取ると数秒 UI が固まった
    /// (2026-09-24 の実測: 1 往復 5ms の模擬で 200 ページの cbz が 2.7 秒。ビューアの初期化もその間待たされ、最初のページが
    /// 遅れた。docs/plans/network-volume-study.md §2.1)。一覧までを裏で済ませ、状態オブジェクトはメインで組み立てる。
    /// 階層を 1 段ずつ辿る以後の操作は、型コメントのとおりメインのまま(最上位の一覧に比べて軽い)。
    static func make(book: MangaBook) async -> BookContentsBrowserState? {
        if book.origin == .imageFiles { return BookContentsBrowserState(book: book) }
        // FileIO で(DirectoryBrowser.listingAsync のコメント。書庫を開いて一覧を取るのはブロッキングする I/O)。
        let prepared = await FileIO.perform {
            prepareRoot(of: book).map(PreparedRootHandoff.init)
        }
        guard let prepared else { return nil }
        return BookContentsBrowserState(book: book, root: prepared.root)
    }

    /// 本の最上位の階層(フォルダ・書庫)。書庫なら開いて一覧まで取る。どちらでもなければ nil。
    private nonisolated static func prepareRoot(of book: MangaBook) -> PreparedRoot? {
        let url = book.sourceURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return .folder(url) }
        guard isArchiveFile(url.lastPathComponent),
              let archive = try? NestedArchiveResolver.openRootArchive(at: url),
              let allPaths = try? archive.reader.listFilePaths()
        else { return nil }
        return .archive(url, archive, allPaths)
    }

    private init(book: MangaBook, root: PreparedRoot) {
        bookPageKeys = Set(book.pages.map(\.sortKey))
        switch root {
        case .imageFiles(let urls):
            currentLevel = .imageFileList(urls)
            currentLocator = nil
        case .folder(let url):
            currentLevel = .folder(url)
            currentLocator = nil
        case .archive(let url, let archive, let allPaths):
            // matchKeyPrefix: nil ― 本自身のルート書庫そのものなので、BookLoader.loadArchiveの
            // sortKeyPrefix: nilと同じ(sortKey/matchKeyはエントリのパスそのもの)。
            currentLevel = .archive(archive: archive, allPaths: allPaths, prefix: "", matchKeyPrefix: nil)
            currentLocator = ArchiveLocator(rootURL: url)
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
        // 裏の一覧・階層探しの結果は、戻ってきても当てない。
        listingGeneration &+= 1
        listingTask?.cancel()
        listingTask = nil
        revealTask?.cancel()
        revealTask = nil
        revealToken = nil
        pendingRevealSortKeys = nil
        isReleased = true
        // 裏で reader を使う仕事が走っていれば、解決役はそれが終わってから手放す(`finishReaderWork`。型コメント)。
        if readerWorkTask == nil { resolver.purgeAll() }
        removeIndependentTemporaryFiles()
    }

    /// 裏で reader を使う仕事が終わった(`readerWorkTask` の後始末)。`releaseResources` が待つ間に呼ばれていたら、解決役を手放して
    /// true(呼ぶ側は結果を捨てる)。
    private func finishReaderWork() -> Bool {
        readerWorkTask = nil
        guard isReleased else { return false }
        resolver.purgeAll()
        return true
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

    /// `matchKey` の画像が `bookPages`(AppState.currentBookPages)の何ページ目か。本のページでなければ nil。
    ///
    /// 並び順の表(`pageOrder`。同じ currentBookPages から作る)で引き、表が一覧と揃っていない瞬間(ページ一覧が変わった直後、
    /// 表が流し込まれる前の 1 回の描画)だけ線形に探す(2026-09-25 の監査。行の右クリックメニューは行の body の一部として毎回
    /// 作られるので、以前は描き直しのたびに「見えている行の数 × ページ数」の比較をしていた ―― ページ送りのたびにも)。
    func pageIndex(ofMatchKey matchKey: String, in bookPages: [PageRef]) -> Int? {
        if let index = pageOrder[matchKey], bookPages.indices.contains(index), bookPages[index].sortKey == matchKey {
            return index
        }
        // 表と一覧の数が揃っていて表に無いなら、本のページではない(除外したページ・入れ子の書庫の中だけの画像)。
        if pageOrder.count == bookPages.count, pageOrder[matchKey] == nil { return nil }
        return bookPages.firstIndex(where: { $0.sortKey == matchKey })
    }

    /// 今の階層の一覧を作り直す。**一覧はメインの外で作り、同じ回の中で続けて頼まれたぶんは 1 回にまとめる**
    /// (2026-09-27、表示の切り替えの監査の 11)。
    ///
    /// 以前はここで同期に `contentsOfDirectory` と子ごとの属性の問い合わせ(フォルダの本)、全エントリの切り出しと並べ替え
    /// (書庫の本)をメインで行っていた。本を替えるたびに「作った直後(init)・並び順の流し込み(`pageOrder`)・今のページの
    /// 表示(`revealCurrentPage`)」で最大 3 回走り、ネットワークボリューム上の本では 1 回ごとに往復を待った。
    /// いまは頼まれた回を覚えるだけで、実際に作るのは次の回に 1 度だけ(その時点の階層と並び順で)。結果はまだその世代の
    /// ときだけ当てる(待つ間に踏み込んだ・戻った・本を閉じた、なら捨てる)。
    func reload() {
        listingGeneration &+= 1
        let generation = listingGeneration
        listingTask?.cancel()
        listingTask = Task { [weak self] in
            // 同じ回のうちに続けて頼まれていれば、最後の 1 回だけが取りに行く。
            guard let input = self?.listingInput(for: generation) else { return }
            let result: Result<[BookInternalBrowsing.Entry], Error> = await FileIO.perform {
                Result { try BookInternalBrowsing.entries(from: input.source, pageOrder: input.pageOrder) }
            }
            self?.finishListing(result, generation: generation)
        }
    }

    /// 一覧の材料(まだその世代なら)。reader は渡さない(`BookInternalBrowsing.ListingSource`)。
    private func listingInput(
        for generation: Int
    ) -> (source: BookInternalBrowsing.ListingSource, pageOrder: [String: Int])? {
        guard listingGeneration == generation else { return nil }
        return (BookInternalBrowsing.listingSource(for: currentLevel), pageOrder)
    }

    private func finishListing(_ result: Result<[BookInternalBrowsing.Entry], Error>, generation: Int) {
        guard listingGeneration == generation else { return }
        listingTask = nil
        switch result {
        case .success(let list):
            entries = list
            navigationErrorMessage = nil
        case .failure(let error):
            entries = []
            navigationErrorMessage = localizedErrorMessage(for: error, fallback: "This folder could not be read.")
        }
        applyPendingReveal()
    }

    /// 一覧を作っている・階層を探している・裏で reader を使っている最中か(出ている `entries` が今の階層のものとは限らない。
    /// reader を使う仕事は一度に 1 つ ―― 型コメント)。
    private var isListingPending: Bool { listingTask != nil || revealTask != nil || readerWorkTask != nil }

    /// 一覧・階層探し・reader を使う仕事が済むまで待つ(テストが、踏み込んだ・戻った後の一覧を確かめるため)。
    func waitUntilListed() async {
        while let task = listingTask ?? revealTask ?? readerWorkTask {
            await task.value
        }
    }

    /// フォルダ/ネストしたアーカイブファイルへ踏み込む(entry.navigateTarget == nilの
    /// 画像ファイルには何もしない。画像のクリックはresolveImageClickを使う)。
    func navigate(_ entry: BookInternalBrowsing.Entry) {
        guard let target = entry.navigateTarget else { return }
        // 一覧を作っている最中は、出ている行は前の階層のもの(一覧は裏で作る。reload のコメント)。その行の行き先を今の階層から
        // 開くと食い違うので、押しても何もしない(ローカルの本ならほんの一瞬)。
        guard !isListingPending else { return }
        // 開くのは裏で(型コメント)。reader は箱で渡し、終わるまでメインは触らない。
        let input = ReaderHandoff(value: (target: target, level: currentLevel, locator: currentLocator, resolver: resolver))
        let serial = historyMoveSerial
        readerWorkTask = Task { [weak self] in
            let output = await FileIO.perform {
                ReaderHandoff(value: Result {
                    try Self.openContainer(
                        input.value.target, from: input.value.level, locator: input.value.locator, resolver: input.value.resolver
                    )
                })
            }
            self?.finishNavigate(output.value, historyMoveSerial: serial)
        }
    }

    private func finishNavigate(_ result: Result<(BookEntryLevel, ArchiveLocator?)?, Error>, historyMoveSerial serial: Int) {
        guard !finishReaderWork() else { return }
        // 待つ間に戻る・進むで階層を離れていたら、離れた階層の子へは入らない(踏み込みを取りやめたのと同じ)。
        guard serial == historyMoveSerial else {
            applyPendingReveal()
            return
        }
        switch result {
        case .success(let next?):
            backStack.append((currentLevel, currentLocator))
            forwardStack.removeAll()
            currentLevel = next.0
            currentLocator = next.1
            reload()
            return
        case .success(nil):
            break
        case .failure(let error):
            // 階層は動いていないので、一覧(と navigationErrorMessage)には触らない(SP-6。stepInFailure のコメント)。
            stepInFailure = ViewerNotice(
                message: localizedErrorMessage(for: error, fallback: "This item could not be opened.")
            )
        }
        // 待つ間に頼まれた「今のページを見せる」(一覧を作り直さなかったので、ここで当てる)。
        applyPendingReveal()
    }

    /// navigateTargetを、levelを起点として開く。navigate(_:)とresolveLevel(forMatchKey:)
    /// (revealCurrentPage用)の両方が使う共通ロジック。levelが対象のnavigateTargetと
    /// 噛み合わない場合(.archiveVirtualFolder/.nestedArchiveEntryはlevelが.archiveで
    /// あることが前提)はnilを返す(navigate(_:)側は元々この場合何もしなかったので、
    /// その挙動を保つ)。
    /// **裏で呼ぶ**(reader を使う。型コメント)ので nonisolated。解決役は呼ぶ側の 1 つを渡す。
    private nonisolated static func openContainer(
        _ target: BookInternalBrowsing.NavigateTarget, from level: BookEntryLevel, locator: ArchiveLocator?,
        resolver: NestedArchiveResolver
    ) throws -> (BookEntryLevel, ArchiveLocator?)? {
        // .imageFileListの階層はコンテナを1件も含まない(navigateTargetが常にnil)ため、
        // ここへ辿り着くことはない。
        switch target {
        case .realFolder(let url):
            return (.folder(url), nil)
        case .documentFileOnDisk(let url):
            // フォルダの本の中のPDF/EPUB。matchKeyPrefixは、BookLoader.collectPages(inFolder:)が
            // そのファイルへ渡すsortKeyPrefix(= fileURL.path)と全く同じ。
            // locatorは「新しい本として開く」の対象(resolveImageClick参照)。そのファイル自身。
            return (
                try documentLevel(fileName: url.lastPathComponent, matchKeyPrefix: url.path) {
                    // ディスク上に実在するので取り出しは要らない(フォルダの中の書庫と同じ)。
                    if isPDFFile(url.lastPathComponent) {
                        return .pdf(openPDFDocument(at: url), .file(url))
                    }
                    return .epub(try EpubStructureResolver.resolve(reader: try makeArchiveReader(for: url)))
                },
                ArchiveLocator(rootURL: url)
            )
        case .documentEntry(let entryPath):
            guard case .archive(let parentArchive, _, _, let parentMatchKeyPrefix) = level,
                  let locator
            else { return nil }
            // 書庫の中のPDF/EPUB。matchKeyPrefixの組み立てはネストした書庫と同じ式
            // (BookLoader.collectPages(at:...)のsortKeyPrefixと揃える)。
            let name = (entryPath as NSString).lastPathComponent
            let matchKeyPrefix = parentMatchKeyPrefix.map { "\($0)/\(entryPath)" } ?? entryPath
            let nested = locator.appending(entryPath)
            return (
                try documentLevel(fileName: name, matchKeyPrefix: matchKeyPrefix) {
                    if isPDFFile(name) {
                        return .pdf(
                            BookLoader.pdfDocument(atEntry: entryPath, in: parentArchive.reader),
                            .entry(locator: locator, entryPath: entryPath)
                        )
                    }
                    // EPUBはzipコンテナなので、ネストした書庫と全く同じ取り出し方で開ける。
                    let child = try resolver.openTransient(nested, parentReader: parentArchive.reader)
                    return .epub(try EpubStructureResolver.resolve(reader: child.reader))
                },
                nested
            )
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
                parentMatchKeyPrefix: parentMatchKeyPrefix, resolver: resolver
            )
        }
    }

    /// PDF/EPUBの中身の階層を組み立てる。行の名前とmatchKeyは、BookLoaderがページを
    /// 作るときと**同じ式**で組み立てる(BookLoader.documentPageSortKey / PDFContainer.
    /// pageDisplayName)。ここが食い違うと、ダブルクリックしても本のページとして認識されない。
    private nonisolated static func documentLevel(
        fileName: String, matchKeyPrefix: String, resolve: () throws -> ResolvedDocument
    ) rethrows -> BookEntryLevel {
        let pages: [BookDocumentPage]
        switch try resolve() {
        case .pdf(let document, let container):
            pages = (0..<(document?.numberOfPages ?? 0)).map { index in
                BookDocumentPage(
                    displayName: container.pageDisplayName(pageIndex: index),
                    matchKey: BookLoader.documentPageSortKey(index: index, prefix: matchKeyPrefix)
                )
            }
        case .epub(let structure):
            pages = structure.pages.enumerated().map { index, page in
                BookDocumentPage(
                    displayName: (page.entryPath as NSString).lastPathComponent,
                    matchKey: BookLoader.documentPageSortKey(index: index, prefix: matchKeyPrefix)
                )
            }
        }
        return .documentPages(fileName: fileName, pages: pages)
    }

    /// documentLevelが受け取る、解決済みのPDF/EPUB。
    private nonisolated enum ResolvedDocument {
        case pdf(CGPDFDocument?, PDFContainer)
        case epub(EpubStructure)
    }

    func goBack() {
        guard let (level, locator) = backStack.popLast() else { return }
        historyMoveSerial &+= 1
        forwardStack.append((currentLevel, currentLocator))
        currentLevel = level
        currentLocator = locator
        reload()
    }

    func goForward() {
        guard let (level, locator) = forwardStack.popLast() else { return }
        historyMoveSerial &+= 1
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
    ///
    /// **階層探しと一覧はメインの外で**(2026-09-27、表示の切り替えの監査の 11)。以前は一覧の作り直し(`reload`)と、ルートから
    /// たどり直すときの各階層の一覧(`resolveLevel`)をメインで取っていた。いまは:
    /// - 一覧を作っている・階層を探している最中なら、今の `entries` は古いので、済んでから当てる(`pendingRevealSortKeys`)。
    /// - たどり直しは、reader の要らない容器(実在するフォルダ・書庫の中の仮想フォルダ)の分を `FileIO` の上で辿り
    ///   (`BookInternalBrowsing.walk`)、最後の段の一覧もそこで作ったものを使う(一覧を取り直さない)。書庫・PDF・EPUB を開く
    ///   必要が出たら、そこから先だけ従来どおりメインで辿る(reader はメインだけが触る。型コメント)。
    func revealCurrentPage(sortKeys: [String]) {
        guard !sortKeys.isEmpty else { return }
        if isListingPending {
            pendingRevealSortKeys = sortKeys
            return
        }
        if entries.contains(where: { sortKeys.contains($0.matchKey) }) {
            highlightedMatchKeys = Set(sortKeys)
            return
        }
        let generation = listingGeneration
        let token = UUID()
        revealToken = token
        let start = BookInternalBrowsing.listingSource(for: rootLevel)
        let order = pageOrder
        let matchKey = sortKeys[0]
        revealTask = Task { [weak self] in
            let walk = await FileIO.perform {
                BookInternalBrowsing.walk(
                    from: start, toward: matchKey, pageOrder: order, maxDepth: BookContentsBrowserState.maxResolutionDepth
                )
            }
            self?.finishReveal(walk, sortKeys: sortKeys, generation: generation, token: token)
        }
    }

    /// 裏で辿った結果を当てる(`revealCurrentPage`)。待つ間に利用者が踏み込んだ・戻った・並び順が変わった(世代が進んだ)なら
    /// 何もしない ―― 以前も、ページ送りのとき以外に今の階層を動かすことは無かった。
    private func finishReveal(
        _ walk: BookInternalBrowsing.RevealWalk, sortKeys: [String], generation: Int, token: UUID
    ) {
        guard revealToken == token else { return }
        revealTask = nil
        revealToken = nil
        defer { applyPendingReveal() }
        guard listingGeneration == generation else { return }
        // 辿った段を階層へ戻す。裏で辿るのは実在するフォルダと、出発点の書庫の中の仮想フォルダだけなので、書庫の段は
        // 出発点(本のルート)の書庫・座標をそのまま使う。
        let levels: [(BookEntryLevel, ArchiveLocator?)] = walk.steps.enumerated().map { index, source in
            if index == 0 { return (rootLevel, rootLocator) }
            switch source {
            case .folder(let url):
                return (.folder(url), nil)
            case .archive(let allPaths, let prefix, let matchKeyPrefix):
                guard case .archive(let archive, _, _, _) = rootLevel else { return (rootLevel, rootLocator) }
                return (.archive(archive: archive, allPaths: allPaths, prefix: prefix, matchKeyPrefix: matchKeyPrefix), rootLocator)
            case .documentPages, .imageFileList:
                // 裏では踏み込まない(`walk` の switch)。出発点だけがこれになりうる。
                return (rootLevel, rootLocator)
            }
        }
        guard let last = levels.last else { return }
        switch walk.outcome {
        case .found:
            applyResolvedLevel(path: Array(levels.dropLast()), final: last, entries: walk.entries, sortKeys: sortKeys)
        case .needsContainer(let target):
            // ここから先は reader が要る(書庫・PDF・EPUB を開く)。それも裏で辿る(型コメント)。待つ間に階層が動いたら(世代が
            // 進んだら)当てない。
            let input = ReaderHandoff(value: (
                target: target, last: last, levels: levels, resolver: resolver, pageOrder: pageOrder, matchKey: sortKeys[0]
            ))
            readerWorkTask = Task { [weak self] in
                let output = await FileIO.perform {
                    let value = input.value
                    let next = try? Self.openContainer(
                        value.target, from: value.last.0, locator: value.last.1, resolver: value.resolver
                    )
                    return ReaderHandoff(value: next.flatMap {
                        Self.resolveLevel(
                            forMatchKey: value.matchKey, from: $0, path: value.levels,
                            pageOrder: value.pageOrder, resolver: value.resolver
                        )
                    })
                }
                self?.finishContainerReveal(output.value, sortKeys: sortKeys, generation: generation)
            }
        case .notFound:
            return
        }
    }

    /// 裏で書庫・PDF・EPUB を開いて辿った結果を当てる(`finishReveal` の `.needsContainer`)。
    private func finishContainerReveal(
        _ resolved: (
            path: [(BookEntryLevel, ArchiveLocator?)], final: (BookEntryLevel, ArchiveLocator?),
            entries: [BookInternalBrowsing.Entry]
        )?,
        sortKeys: [String], generation: Int
    ) {
        guard !finishReaderWork() else { return }
        defer { applyPendingReveal() }
        guard listingGeneration == generation, let resolved else { return }
        applyResolvedLevel(path: resolved.path, final: resolved.final, entries: resolved.entries, sortKeys: sortKeys)
    }

    /// 探し当てた階層へ切り替える。一覧は探すときに作ったものを使う(同じ並び順で作ってあるので、取り直さない)。
    private func applyResolvedLevel(
        path: [(BookEntryLevel, ArchiveLocator?)], final: (BookEntryLevel, ArchiveLocator?),
        entries newEntries: [BookInternalBrowsing.Entry], sortKeys: [String]
    ) {
        backStack = path
        forwardStack.removeAll()
        currentLevel = final.0
        currentLocator = final.1
        // 前の階層の一覧を作っている仕事があっても、その結果は当てない。
        listingGeneration &+= 1
        listingTask?.cancel()
        listingTask = nil
        entries = newEntries
        navigationErrorMessage = nil
        highlightedMatchKeys = Set(sortKeys)
    }

    /// 待たせていた「今のページを見せる」を当て直す。
    private func applyPendingReveal() {
        guard let sortKeys = pendingRevealSortKeys else { return }
        pendingRevealSortKeys = nil
        revealCurrentPage(sortKeys: sortKeys)
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
    ///
    /// 2026-09-27 から、ルートからの前半(reader の要らない容器)は `BookInternalBrowsing.walk` が裏で辿り、ここは書庫・PDF・EPUB を
    /// 開いた先(`start`。`path` はそこまでの段)から続きを辿る。最後の段の一覧も返す(切り替えるときに取り直さない)。
    /// 容器の中に入っているかの判定は `BookInternalBrowsing.matchKey(_:isContainedIn:)`(裏の `walk` と共用)。
    /// **裏で呼ぶ**(reader を使う)ので nonisolated。並び順と解決役は呼ぶ側のものを渡す。
    private nonisolated static func resolveLevel(
        forMatchKey matchKey: String, from start: (BookEntryLevel, ArchiveLocator?),
        path initialPath: [(BookEntryLevel, ArchiveLocator?)], pageOrder: [String: Int], resolver: NestedArchiveResolver
    ) -> (
        path: [(BookEntryLevel, ArchiveLocator?)], final: (BookEntryLevel, ArchiveLocator?),
        entries: [BookInternalBrowsing.Entry]
    )? {
        var level = start.0
        var locator = start.1
        var path = initialPath
        for _ in 0..<Self.maxResolutionDepth {
            guard let levelEntries = try? BookInternalBrowsing.entries(
                at: level, pageOrder: pageOrder
            ) else { return nil }
            if levelEntries.contains(where: { $0.matchKey == matchKey }) {
                return (path, (level, locator), levelEntries)
            }
            guard let container = levelEntries.first(where: {
                $0.isContainer && BookInternalBrowsing.matchKey(matchKey, isContainedIn: $0.matchKey)
            }), let target = container.navigateTarget,
                let next = try? openContainer(target, from: level, locator: locator, resolver: resolver) else { return nil }
            path.append((level, locator))
            level = next.0
            locator = next.1
        }
        return nil
    }

    /// 裏の `walk` へも渡すので nonisolated(ただの定数)。
    nonisolated static let maxResolutionDepth = 32

    enum ImageClickResult: Equatable {
        case jumpToPage(Int)
        case openAsNewBook(URL)
        /// 入れ子の書庫を一時ファイルへ書き出してから新しい本として開く。書き出しは裏で行い、済んだら `whenMaterialized` を呼ぶ
        /// (書き出せなければ呼ばない)。呼ぶ側は待つ間に別の本が頼まれていないか確かめてから開く。
        case materializingNewBook
        /// レイアウトで除外したページ。行き先が無い(呼び出し側は鳴らす)。
        case excludedPage
        case unavailable
    }

    /// 画像の行が、この本の**除外したページ**か(読み込んだときのページにあって、今の並び `bookPages` に無い)。一覧の行を淡く描く。
    func isExcludedPage(_ entry: BookInternalBrowsing.Entry, bookPages: [PageRef]) -> Bool {
        entry.isImage && bookPageKeys.contains(entry.matchKey) && pageIndex(ofMatchKey: entry.matchKey, in: bookPages) == nil
    }

    /// entryのクリック(画像のみ意味を持つ)を解決する。bookPages(呼び出し元が
    /// AppState.currentBookPagesを渡す)のsortKeyと一致すれば、そのページへのジャンプを返す。
    ///
    /// **除外したページなら、どの階層でも `.excludedPage`**(2026-10-04 の監査 SP-4)。以前は同じ「除外ページの行のクリック」が、フォルダの本では
    /// 何もせず、本そのものの書庫では本を開き直し、入れ子の書庫ではその書庫を一時コピーにして新しい本として開く、と 3 通りに分かれていた。
    ///
    /// 本のページでもなければ(入れ子の書庫の中で、入れ子の深さ・大きさの上限で BookLoader が読み込まなかった画像など)、現在の階層の元に
    /// なったアーカイブ/フォルダ自体を新しい本として開く指示を返す(入れ子なら一時ファイルへ書き出す ―― 渡す側は `handOffTemporaryFile`)。
    /// クリックした画像そのものへ厳密にジャンプすることまではスコープに含めない(AppState.openにページ指定を通す仕組みが無く、影響範囲が
    /// 大きくなるための意図的な割り切り)。
    ///
    /// 入れ子の書庫の書き出しは**裏で**(型コメント。以前はメインで同期に書き出し、数百 MB の書庫ではその間アプリごと止まった)。
    /// 書き出せたら `whenMaterialized` を呼ぶ(書き出した一時ファイルは渡すまでこの状態が持つ ―― 呼ぶ側が開くなら `handOffTemporaryFile`)。
    func resolveImageClick(
        on entry: BookInternalBrowsing.Entry, bookPages: [PageRef],
        whenMaterialized: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> ImageClickResult {
        guard entry.isImage else { return .unavailable }
        if let index = pageIndex(ofMatchKey: entry.matchKey, in: bookPages) {
            return .jumpToPage(index)
        }
        if bookPageKeys.contains(entry.matchKey) { return .excludedPage }
        // 一覧を作っている最中は、行と今の階層(currentLocator)が食い違う(navigate のコメント)。reader を使う仕事が走っている
        // 間も、書き出し(親の reader を使う)を始めない。
        guard !isListingPending, let locator = currentLocator else { return .unavailable }
        guard locator.isNested else { return .openAsNewBook(locator.rootURL) }
        let input = ReaderHandoff(value: (locator: locator, resolver: resolver))
        readerWorkTask = Task { [weak self] in
            let output = await FileIO.perform {
                ReaderHandoff(value: try? input.value.resolver.materializeToIndependentFile(input.value.locator))
            }
            guard let url = output.value else {
                self?.finishMaterializing(nil)
                return
            }
            guard let self else {
                // 窓(この状態)がもう無い。書き出したものを残さない。
                try? FileManager.default.removeItem(at: url)
                return
            }
            if self.finishMaterializing(url) { whenMaterialized(url) }
        }
        return .materializingNewBook
    }

    /// 裏の書き出しが終わった(`resolveImageClick`)。書き出したものはこの状態が持ち、使ってよければ true。`releaseResources` が待つ間に
    /// 呼ばれていたら、書き出したものも消して false。
    @discardableResult
    private func finishMaterializing(_ url: URL?) -> Bool {
        let released = finishReaderWork()
        guard let url else { return false }
        if released {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
            return false
        }
        temporaryFileURLs.append(url)
        return true
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
    private nonisolated static func openNestedArchive(
        entryPath: String, parentArchive: OpenArchive, parentLocator: ArchiveLocator,
        parentMatchKeyPrefix: String?, resolver: NestedArchiveResolver
    ) throws -> (BookEntryLevel, ArchiveLocator?) {
        let locator = parentLocator.appending(entryPath)
        let archive = try resolver.openTransient(locator, parentReader: parentArchive.reader)
        let allPaths = try archive.reader.listFilePaths()
        let matchKeyPrefix = parentMatchKeyPrefix.map { "\($0)/\(entryPath)" } ?? entryPath
        return (.archive(archive: archive, allPaths: allPaths, prefix: "", matchKeyPrefix: matchKeyPrefix), locator)
    }

    /// 「新しい本として開く」で書き出した一時ファイルを、開く側へ渡す(以後ここでは消さない)。開く側の `AppState` が引き受ける
    /// (`AppState.ownedTemporaryCopies`。`temporaryFileURLs` のコメント)。書き出したものでなければ何もしない。
    func handOffTemporaryFile(_ url: URL) {
        guard temporaryFileURLs.contains(url) else { return }
        temporaryFileURLs.removeAll { $0 == url }
        // 渡したものだけが、窓が引き受けて消してよい一時コピーになる(TemporaryCopyRegistry。2026-10-05 の監査 A7-2)。
        temporaryCopies.handOff(url)
    }

    private func localizedErrorMessage(for error: Error, fallback: String.LocalizationValue) -> String {
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        return (error as? LocalizedError)?.errorDescription ?? String(localized: fallback, language: locale)
    }
}

/// 本の中身ブラウザの最上位の階層の下ごしらえ(`BookContentsBrowserState.prepareRoot`)。
private nonisolated enum PreparedRoot {
    case imageFiles([URL])
    case folder(URL)
    /// 本そのものの書庫(開いた状態)と、その一覧。
    case archive(URL, OpenArchive, [String])
}

/// reader を使う仕事の材料と結果を、メインと裏の間で受け渡す箱(`BookContentsBrowserState` の型コメント)。`PreparedRootHandoff` と同じ
/// 約束 ―― 渡した側は、受け取った側が返すまでその reader(と解決役)に触らない(`readerWorkTask` が走っている間は入口が断る)。
private nonisolated struct ReaderHandoff<Value>: @unchecked Sendable {
    let value: Value
}

/// 裏で用意した最上位の階層を、メインへ渡すための箱(`BookContentsBrowserState.make(book:)`)。
///
/// 中の`OpenArchive`(の reader)はスレッド安全ではないが、用意した裏の処理はこの箱を返した時点で手放し、以後はメインだけが
/// 触る(同時に 2 つのスレッドから使われることは無い)。そのための`@unchecked`。
private nonisolated struct PreparedRootHandoff: @unchecked Sendable {
    let root: PreparedRoot
}
