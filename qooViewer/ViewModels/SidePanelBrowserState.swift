import Foundation
import AppKit
import Combine

/// サイドパネル上段(フォルダブラウザ)の閲覧状態。ContentViewが1つだけ`@StateObject`として
/// 保持し、本の切替やウェルカム画面への出入りをまたいで使い回す(本ごとに作り直される
/// ViewerViewとは異なるライフサイクル)。
///
/// ■ 一覧を読み直す契機(2026-09-19 の監査。docs/plans/fs-ui-consistency-audit.md の H3)
/// 以前は移動・本の切り替わり・アクセス権の付与のときしか読まなかったので、表示中のフォルダに本を足しても消しても、
/// アプリを離れて戻っても一覧は変わらなかった。いまは (1) アプリ自身がファイルを動かした知らせ(`FileSystemChange`。
/// ファイルブラウザの操作・自動リネーム)で、表示中のフォルダに関わるときだけ、(2) アプリがアクティブになったとき・
/// ボリュームの着脱(外での変更。棚・履歴と同じ契機)に読み直す。FSEvents では見張らない(パネルは隠れていることが多い)。
/// 表示中のフォルダが消えていたら、残っているいちばん近い祖先へ移る(ファイルブラウザと同じ。以前は読み込みの失敗を
/// 全部「アクセス権が無い」として「アクセスを許可…」を出していた)。
///
/// ■ 見えていない間は読み直さない(2026-09-25 の監査)
/// (1)(2)と本の切り替わりの読み直しは、この節が画面に出ていないとき(パネルを隠している・別のモード・機能が OFF・ホーム)は
/// 「出たら読み直す」印を付けるだけにする(`isVisible`。ContentView が知らせる)。一覧の読み込みは直下のフォルダごとに中を
/// 覗く(DirectoryBrowser.makeEntry)ので、本の並ぶ棚では 1 回が数百回の readdir になる。以前はそれを、見えていないのに
/// アクティブ化のたび・本を開くたびに、開いているウインドウ・タブの数だけ繰り返していた(共有の上ならネットワーク越しに)。
/// 移動・付け替え(`currentDirectory` などパスで覚えているもの)は今までどおりその場で行う。
@MainActor
final class SidePanelBrowserState: ObservableObject {
    /// 現在表示中のフォルダ。nilのときは最上位(ボリューム一覧)を表す。
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var entries: [DirectoryBrowser.Entry] = []
    /// entries(in:)が権限エラーを投げた場合にtrue。空フォルダと区別し、パネル側で
    /// その場からアクセスを許可するボタンを出す判定に使う。
    @Published private(set) var needsFolderAccessGrant = false
    /// 権限以外の理由で一覧を読めなかったときの文(`FileBrowserLoadError.other`。パネルは一覧の代わりにこれを出す)。
    /// 2026-10-04 の監査 SP-8: 以前は権限以外の失敗も `needsFolderAccessGrant` に落とし、許可しても直らない「アクセスを許可…」を
    /// 出していた(右のファイルブラウザは `.other` の文をそのまま出す ―― FileBrowserPane.loadErrorMessage)。
    @Published private(set) var listingErrorMessage: String?
    /// 今表示中のフォルダの直下に画像ファイルがあるかどうか。
    ///
    /// この一覧は画像ファイルを行として出さない(DirectoryBrowser.makeEntry。一覧の目的は
    /// 「本を探すこと」で、画像を並べるとノイズになる)。そのため、**画像だけが入っている
    /// フォルダへ移動すると一覧が空になり、行き止まりに見える**。画像とサブフォルダが同居して
    /// いるフォルダでも、そのフォルダ自体の画像を開く手立てが一覧に現れない
    /// (ユーザー指摘: 画像のあるフォルダに、さらに画像のあるフォルダが入っている場合)。
    ///
    /// ユーザー報告: 画像を直接開いた状態で、その画像が入っているフォルダをクリックすると、
    /// フォルダ移動はするが何も起きない。上段は画像の本のとき1階層上を表示する仕様
    /// (browserAnchor参照)なので、いちばん押したくなる行がまさにこれにあたる。
    ///
    /// 今は移動した時点でそのフォルダの画像を表示する(SidePanelView.moveAndShowImages)ので、「このフォルダの画像を開く」導線は
    /// 出さない。パネル側はこの値を、一覧が空である理由(画像だけのフォルダ)を伝える文を出すのに使う(SidePanelView の
    /// 「This folder's images are open.」「This folder holds images.」)。以前の「導線を出す(一覧が空なら中央に、サブフォルダが
    /// 並んでいるならその先頭の行として)」という説明は 2026-10-04 の監査 §5 で今の動きに直した。
    @Published private(set) var currentDirectoryHasImages = false
    /// 表示枠内へスクロール+ハイライトする対象。handlePanelRevealed/goUpが設定する。
    /// 「上へ」で出てきたフォルダの強調はこれ。今の本の行の強調は下の currentBookRowURL で別に持つ(2026-10-04 の監査 SP-13・決定 12)。
    @Published private(set) var highlightedURL: URL?
    /// 今の本の行(本の親フォルダの一覧での本自身。画像を直接開いた本は画像の入ったフォルダ ―― browserAnchor の highlighted)。
    /// **どこへ移動しても**、その行が一覧にあれば今の本として強調する(SP-13・決定 12)。以前は強調が highlightedURL 1 つだけで、
    /// 戻る/進むで本のフォルダへ戻っても今の本の行が強調されず、「上へ」で出てきたフォルダと同じ見た目だった。
    @Published private(set) var currentBookRowURL: URL?
    /// 規則 2(直下に画像が無く、章ごとの画像フォルダに分けた本)と分かったフォルダの行のパス(2026-10-04 の監査 SP-3・決定 14)。
    /// サイドパネルは今のまま規則 1 だけで「本」を数える(「開く」系は直下に画像がある行だけ。MANUAL)が、規則 2 の行の
    /// 「スマートライブラリの対象に追加」は押しても断られる(本のフォルダは対象にしない)ので、淡色にするためにこれを見る。
    /// 一覧を読んだ後に、直下に画像が無くサブフォルダがある行だけを FileIO の上で調べる(probeChapterBooks)。分かるまでは空 ――
    /// その間は押せて、押せば従来どおり断って知らせる。
    @Published private(set) var chapterBookFolderPaths: Set<String> = []
    private var chapterProbeTask: Task<Void, Never>?

    weak var folderAccess: FolderAccessStore?
    weak var preferences: AppPreferences?

    /// 次の`handlePanelRevealed`での再アンカーを1回だけ見送るための目印。**どの本のための見送りか**(開こうとしたフォルダ)を持つ。
    ///
    /// フォルダ行のクリックは「そのフォルダへ入る」と「そのフォルダの画像を開く」を同時に行う
    /// (SidePanelView.navigateAndOpenIfImages)。本が切り替わればContentViewが
    /// `handlePanelRevealed`を呼ぶが、そこでいつもどおり本の親フォルダへ再アンカーすると、
    /// **せっかく入ったフォルダから親へ弾き返されて**しまい、中のサブフォルダへ進めなくなる。
    ///
    /// 相手を持つのは 2026-10-04 の監査 SP-1。以前は真偽だけで、開こうとした本がこの窓に出なかった(シークレットウインドウへ
    /// 回した・読み込みに失敗した・中止した)と印が残り、次に別の経路で開いた本でフォルダブラウザが追従しなかった。今は次の本の
    /// 切り替わりで必ず下ろし、見送るのはその本が印の相手のときだけ。
    private var skipsNextAnchorFor: URL?

    private var backStack: [URL?] = []
    private var forwardStack: [URL?] = []
    /// 一覧の読み込み。`private(set)`なのは**テストが待ち合わせるため**で、アプリ側は
    /// 触らない(AppState.openTaskと同じ口)。**時間で待つ形は書かないこと。**
    private(set) var reloadTask: Task<Void, Never>?
    /// 今のentriesを並べ替えるのに使った設定。applySortSettings()が「設定が変わっていなければ
    /// 何もしない」と判断するために覚えておく。
    private var appliedSort: FolderBrowserSort?
    private var changeObservation: AnyCancellable?
    private var systemObservations: [AnyCancellable] = []
    /// この節が画面に出ているか(型コメント「見えていない間は読み直さない」)。ContentView が `setVisible` で知らせる。
    /// 既定は true(知らせる者のいないテストでは今までどおりその場で読み直す)。
    private(set) var isVisible = true
    /// 見えていない間に読み直しを見送った。見えたら読み直す。
    private var needsReloadWhenVisible = false

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentDirectory != nil }

    /// - Parameter changeCenter: nil なら既定(アプリでは全体で 1 つ、テストの中ではこの状態だけのもの)。
    /// - Parameter observesSystem: アクティブ化・ボリュームの着脱で読み直すか。**テストは false**(放送の通知なので、並んで走る
    ///   ほかのテストの契機で読み直される)。
    init(changeCenter: FileSystemChangeCenter? = nil, observesSystem: Bool = !RuntimeEnvironment.isRunningTests) {
        reload()
        changeObservation = (changeCenter ?? .defaultForState()).changes.sink { [weak self] change in
            MainActor.assumeIsolated { self?.handleFileSystemChange(change) }
        }
        guard observesSystem else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        systemObservations = [
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.reloadWhenVisible() } },
            Publishers.Merge(
                workspace.publisher(for: NSWorkspace.didMountNotification),
                workspace.publisher(for: NSWorkspace.didUnmountNotification)
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reloadWhenVisible() } },
        ]
    }

    /// この節が画面に出た・隠れた(ContentView。型コメント「見えていない間は読み直さない」)。出たとき、見送った読み直しがあれば
    /// 読み直す(それまでは前の一覧が出ている ―― ファイルブラウザの 2 回目以降の表示と同じ)。
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        guard visible, needsReloadWhenVisible else { return }
        needsReloadWhenVisible = false
        reload()
    }

    /// 見えていれば読み直し、見えていなければ見えたときまで先送りする。
    /// - Parameter directoryChanged: 表示するフォルダが変わった(移った)。見えていない間なら、前のフォルダの行(古いパス)は
    ///   すぐに捨てる ―― 見えた瞬間に押せる行が、別のフォルダ・もう無いパスを指さないように。
    private func reloadWhenVisible(directoryChanged: Bool = false) {
        guard isVisible else {
            needsReloadWhenVisible = true
            // 読み込み中の一覧は前の状態のものなので捨てる(見えたときに読み直す)。
            reloadTask?.cancel()
            reloadTask = nil
            if directoryChanged {
                if !entries.isEmpty { entries = [] }
                if currentDirectoryHasImages { currentDirectoryHasImages = false }
            }
            return
        }
        reload()
    }

    /// アプリ自身がファイルを動かした(型コメント)。パスで覚えているもの(表示中のフォルダ・履歴・強調する行)を付け替え、
    /// 表示中のフォルダに関わるなら読み直す。
    func handleFileSystemChange(_ change: FileSystemChange) {
        func relocated(_ url: URL?) -> URL? {
            guard let url, let path = change.relocatedPath(for: url.path) else { return url }
            return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
        }
        backStack = backStack.map(relocated)
        forwardStack = forwardStack.map(relocated)
        if let highlightedURL, let moved = relocated(highlightedURL), moved != highlightedURL { self.highlightedURL = moved }
        guard let directory = currentDirectory else { return }
        if let moved = relocated(directory), moved != directory {
            currentDirectory = moved
            reloadWhenVisible(directoryChanged: true)
        } else if change.requiresReload(ofFolderAt: directory.path) {
            reloadWhenVisible()
        }
    }

    /// 開いている本が切り替わるたびに呼ぶ(ContentViewの.onChange(of: appState.currentBook?.id))。
    /// 本を開いていれば必ずその親フォルダへ再アンカーし、本自身をハイライト+スクロール対象に
    /// する(ユーザー要望: 開いた本が必ずフォーカスされた状態で見えるようにしたい)。
    /// 本を開いていない場合は何もしない(初回はinitで設定済みのボリューム一覧のまま、既に
    /// どこかを手動で閲覧中ならその位置を維持する — ウェルカム画面での閲覧中に毎回
    /// ボリューム一覧へ戻されるのを防ぐ)。
    ///
    /// 名前が「Revealed」なのは、かつてパネルを隠す設定でホバー表示されるたびにも呼んでいた
    /// 名残。その呼び出しは、フォルダブラウザで移動した場所がパネルが隠れるたびに失われて
    /// 常時表示と挙動が食い違うため、やめた(ユーザーの指示)。今は本の切り替わりだけが契機。
    func handlePanelRevealed(currentBook: MangaBook?) {
        guard let currentBook else {
            currentBookRowURL = nil
            return
        }
        // 入れ子の書庫を書き出した一時コピーの本(本の中身ブラウザの「新しい本として開く」)では、今いる場所を保つ(2026-10-04 の監査 SP-4)。
        // 親はアプリの一時フォルダで、そこへ移ると利用者の知らないフォルダ(空、または UUID 名の書庫)が並んだ。
        // 一時フォルダの中なので、どの行も今の本として強調しない。
        if currentBook.isTemporaryCopy {
            currentBookRowURL = nil
            skipsNextAnchorFor = nil
            return
        }
        let anchor = Self.browserAnchor(for: currentBook)
        currentBookRowURL = anchor.highlighted
        // このパネルの中のクリックで開いた本なら、今いる場所をそのまま保つ
        // (skipsNextAnchorForのコメント参照)。一覧はnavigate側で読み込み済み。印は相手に関わらずここで下ろす(SP-1)。
        let skipTarget = skipsNextAnchorFor
        skipsNextAnchorFor = nil
        if let skipTarget, MountTable.normalized(skipTarget.path) == MountTable.normalized(currentBook.sourceURL.path) {
            return
        }
        let directoryChanged = anchor.directory != currentDirectory
        if directoryChanged {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
            currentDirectory = anchor.directory
        }
        highlightedURL = anchor.highlighted
        reloadWhenVisible(directoryChanged: directoryChanged)
    }

    /// 本を開いたときに、フォルダブラウザのどこを表示してどれをハイライトするか。
    ///
    /// 通常の本(フォルダ・書庫・PDF・EPUB)は、その本の親フォルダを表示して本自身をハイライトする。
    ///
    /// 直接渡された画像ファイルの本(MangaBook.BookOrigin.imageFiles)だけは**もう1階層上**を表示し、
    /// 画像が入っているフォルダのほうをハイライトする(ユーザー要望)。画像が入っているフォルダを
    /// そのまま表示しても、フォルダブラウザは画像ファイルを一覧に出さない仕様
    /// (DirectoryBrowser.makeEntry。一覧の目的は「本を探すこと」で、画像を並べるとノイズになる)
    /// のため、中身が1件も無い空のフォルダに見えてしまい役に立たないため。
    /// 1階層上なら、その画像フォルダ自体が「1冊の本」として行に並ぶ — つまりクリックすれば
    /// フォルダ全体を本として開ける状態になり、Fileメニューの「このフォルダの画像をすべて開く」と
    /// 同じ着地点への導線になる。
    ///
    /// 複数枚が複数フォルダにまたがって選択されている場合は、sourceURL(=先頭ページの画像)が
    /// 入っているフォルダが対象になる。
    private static func browserAnchor(for book: MangaBook) -> (directory: URL, highlighted: URL) {
        let parent = book.sourceURL.deletingLastPathComponent()
        guard book.origin == .imageFiles else { return (parent, book.sourceURL) }
        return (parent.deletingLastPathComponent(), parent)
    }

    /// 上記を1回だけ見送らせる。フォルダ行のクリックで本を開く直前に、開こうとする本(フォルダ)を渡して呼ぶ。
    /// 次に切り替わった本がそれでなければ見送らない(SP-1)。
    func skipNextAnchorOnce(for book: URL) {
        skipsNextAnchorFor = book
    }

    /// フォルダ行のシングルクリック。
    func navigate(into folder: URL) {
        backStack.append(currentDirectory)
        forwardStack.removeAll()
        currentDirectory = folder
        highlightedURL = nil
        reload()
    }

    /// 1階層上へ。ボリュームのルート(またはファイルシステムのルート)にいた場合は、
    /// ボリューム一覧(currentDirectory = nil)へ戻る。どちらの場合も、それまでいた場所を
    /// highlightedURLにしてから読み込み直す(ユーザー要望: 上へ移動したら元いたフォルダが
    /// フォーカスされる)。
    func goUp() {
        guard let leaving = currentDirectory else { return }
        backStack.append(currentDirectory)
        forwardStack.removeAll()
        if DirectoryBrowser.isVolumeRoot(leaving) {
            currentDirectory = nil
        } else {
            currentDirectory = leaving.deletingLastPathComponent()
        }
        highlightedURL = leaving
        reload()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentDirectory)
        currentDirectory = previous
        highlightedURL = nil
        reload()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentDirectory)
        currentDirectory = next
        highlightedURL = nil
        reload()
    }

    /// 読み込みが(消えたフォルダからの退避による読み直しを含めて)片付くまで待つ。**テストのための口。**
    func settle() async {
        while let task = reloadTask {
            await task.value
            if reloadTask == task { break }
        }
        // 規則 2 の下調べ(probeChapterBooks)も待つ。
        while let task = chapterProbeTask {
            await task.value
            if chapterProbeTask == task { return }
        }
    }

    func reload() {
        reloadTask?.cancel()
        let directory = currentDirectory
        let sort = preferences?.folderBrowserSort ?? .default
        reloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: [DirectoryBrowser.Entry]
                var hasImages = false
                if let directory {
                    // 一覧と一緒に「直下に画像があるか」も受け取る(同じ列挙で調べるのでI/Oは
                    // 増えない。currentDirectoryHasImages参照)。
                    let listing = try await DirectoryBrowser.listingAsync(in: directory, sort: sort)
                    result = listing.entries
                    hasImages = listing.containsImageFile
                } else {
                    result = await DirectoryBrowser.mountedVolumeEntriesAsync(sort: sort)
                }
                guard !Task.isCancelled else { return }
                self.entries = result
                self.currentDirectoryHasImages = hasImages
                self.appliedSort = sort
                self.needsFolderAccessGrant = false
                self.listingErrorMessage = nil
                if let directory { self.probeChapterBooks(in: result, directory: directory) } else { self.clearChapterBooks() }
                // 読み込んでいる間に並べ替え設定が変わっていた場合の取りこぼしを拾う
                // (変わっていなければ何もしない)。
                self.applySortSettings()
            } catch {
                guard !Task.isCancelled else { return }
                // 表示していたフォルダが消えた(移動・削除・ボリュームを外した)なら、残っている祖先へ移る(型コメント)。
                // 「アクセスを許可…」を出すのは、読む権限が無いときだけ。それ以外の失敗は文を出す(SP-8。listingErrorMessage)。
                var otherFailure: String?
                if let directory {
                    switch FileBrowserLoadError.classify(error, folder: directory) {
                    case .notFound, .volumeUnavailable:
                        // ブロッキングする探索は FileIO の上で(ファイルブラウザの同じ探索と同じ。2026-10-04 の監査 §2-4 ――
                        // 以前は Task.detached で、応答しない共有で協調スレッドを塞いだ)。
                        let ancestor = await FileIO.perform(qos: .utility) {
                            FileBrowserListing.nearestExistingAncestor(of: directory)
                        }
                        guard !Task.isCancelled, self.currentDirectory == directory else { return }
                        self.currentDirectory = ancestor
                        self.highlightedURL = nil
                        self.reload()
                        return
                    case .needsAccess:
                        break
                    case .other(let message):
                        otherFailure = message
                    }
                }
                self.entries = []
                self.currentDirectoryHasImages = false
                self.clearChapterBooks()
                self.appliedSort = sort
                self.needsFolderAccessGrant = otherFailure == nil
                self.listingErrorMessage = otherFailure
            }
        }
    }

    /// 一覧のうち、直下に画像が無くサブフォルダがある行が規則 2 の本か(ShelfFolderResolver.isSingleBookFolder)を調べ、
    /// chapterBookFolderPaths に入れる(SP-3・決定 14)。子フォルダの中を読むので一覧より I/O が増える ―― 調べるのはその形の行だけ、
    /// FileIO の上で 1 行ずつ(応答しない共有で協調スレッドを止めない。CLAUDE.md)。ネットワークのボリュームでは調べない(行ごとに
    /// 往復が増える。淡色にならないだけで、押せば従来どおり断る)。TCC の保護下の場所は、表示中のフォルダと同じ保護下でなければ
    /// 読まない(DirectoryProbe.mayReadChild。読むこと自体が許可のダイアログを出す)。
    private func probeChapterBooks(in entries: [DirectoryBrowser.Entry], directory: URL) {
        clearChapterBooks()
        let candidates = entries
            .filter { $0.isDirectory && !$0.containsImageFile && $0.containsSubdirectory }
            .map(\.url)
            .filter { DirectoryProbe.mayReadChild($0, of: directory) }
        guard !candidates.isEmpty, !MountTable.current().isRemote(directory) else { return }
        chapterProbeTask = Task { [weak self] in
            var found: Set<String> = []
            for url in candidates {
                guard !Task.isCancelled else { return }
                if await FileIO.perform({ ShelfFolderResolver.isSingleBookFolder(url) }) { found.insert(url.path) }
            }
            guard !Task.isCancelled, let self, self.currentDirectory == directory else { return }
            self.chapterBookFolderPaths = found
        }
    }

    private func clearChapterBooks() {
        chapterProbeTask?.cancel()
        chapterProbeTask = nil
        if !chapterBookFolderPaths.isEmpty { chapterBookFolderPaths = [] }
    }

    /// 並べ替え設定(パネル上部の並べ替えメニュー、および環境設定「一般」タブのグループ分け)が
    /// 変わったときに、今の一覧をその場で並べ替え直す。ディスクは一切読み直さない
    /// (DirectoryBrowser.Entryが並べ替えに必要な値をすべて持っているため。
    /// DirectoryBrowser.sortedEntries(_:sort:)参照)。
    ///
    /// 設定が変わっていなければ何もしないので、呼び出し側は「変わったかもしれない」タイミング
    /// (メニュー操作の直後、パネルが再び現れたとき)で気軽に呼んでよい。
    ///
    /// 並べ替えはメインアクター上で同期的に行う。数千件でも数ミリ秒で、ユーザーが自分で
    /// メニューを操作した直後という文脈でもあるため、非同期にして一覧が一瞬古い並びのまま
    /// 見えるほうが不自然だと判断した。
    func applySortSettings() {
        let sort = preferences?.folderBrowserSort ?? .default
        guard sort != appliedSort else { return }
        appliedSort = sort
        guard !entries.isEmpty else { return }
        entries = DirectoryBrowser.sortedEntries(entries, sort: sort)
    }

    /// AppState.grantAccessToCurrentFolder()と同じ形のNSOpenPanel。対象が「現在の本の親」
    /// 固定のあちらと異なり、こちらはパネルで今見ようとしている任意の場所が対象のため、
    /// 共通化はせず別実装にしている。
    func requestFolderAccess() {
        guard let directory = currentDirectory else { return }
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = String(localized: "Grant Access", language: locale)
        panel.message = String(
            localized: "To show files in this folder, please select and grant access to it.",
            language: locale
        )
        // 操作されたウインドウ(キー)のシート(2026-09-27。WindowSheet)。
        WindowSheet.begin(panel) { [weak self] response in
            guard response == .OK, let grantedURL = panel.url else { return }
            // アクセスの開閉はFolderAccessStoreが一手に管理する(以前はここでも
            // startAccessingSecurityScopedResource()を呼んでいたが、対になるstopが無く
            // 漏れていた。FolderAccessStore.accessedURLsByPathのコメント参照)。
            self?.folderAccess?.add(url: grantedURL)
            self?.reload()
        }
    }

    /// 今表示中のフォルダをFinderで開く(ユーザー要望)。AppState.revealCurrentBookInFinder()の
    /// フォルダ側の分岐(NSWorkspace.shared.open(url))と同じ考え方だが、こちらは常にフォルダ
    /// そのものが対象(選択状態にする対象のファイルが無い)なので単純にopen(url:)でよい。
    /// ボリューム一覧(currentDirectory == nil)のときは対象が無いため何もしない。
    func openInFinder() {
        guard let directory = currentDirectory else { return }
        NSWorkspace.shared.open(directory)
    }
}
