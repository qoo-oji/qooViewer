import Foundation
import AppKit
import Combine

/// サイドパネル上段(フォルダブラウザ)の閲覧状態。ContentViewが1つだけ`@StateObject`として
/// 保持し、本の切替やウェルカム画面への出入りをまたいで使い回す(本ごとに作り直される
/// ViewerViewとは異なるライフサイクル)。
@MainActor
final class SidePanelBrowserState: ObservableObject {
    /// 現在表示中のフォルダ。nilのときは最上位(ボリューム一覧)を表す。
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var entries: [DirectoryBrowser.Entry] = []
    /// entries(in:)が権限エラーを投げた場合にtrue。空フォルダと区別し、パネル側で
    /// その場からアクセスを許可するボタンを出す判定に使う。
    @Published private(set) var needsFolderAccessGrant = false
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
    /// パネル側はこの値を見て「このフォルダの画像を開く」導線を出す(一覧が空なら中央に、
    /// サブフォルダが並んでいるならその先頭の行として)。
    @Published private(set) var currentDirectoryHasImages = false
    /// 表示枠内へスクロール+ハイライトする対象。handlePanelRevealed/goUpが設定する。
    @Published private(set) var highlightedURL: URL?

    weak var folderAccess: FolderAccessStore?
    weak var preferences: AppPreferences?

    /// 次の`handlePanelRevealed`での再アンカーを1回だけ見送るための目印。
    ///
    /// フォルダ行のクリックは「そのフォルダへ入る」と「そのフォルダの画像を開く」を同時に行う
    /// (SidePanelView.navigateAndOpenIfImages)。本が切り替わればContentViewが
    /// `handlePanelRevealed`を呼ぶが、そこでいつもどおり本の親フォルダへ再アンカーすると、
    /// **せっかく入ったフォルダから親へ弾き返されて**しまい、中のサブフォルダへ進めなくなる。
    private var skipsNextAnchor = false

    private var backStack: [URL?] = []
    private var forwardStack: [URL?] = []
    private var reloadTask: Task<Void, Never>?
    /// 今のentriesを並べ替えるのに使った設定。applySortSettings()が「設定が変わっていなければ
    /// 何もしない」と判断するために覚えておく。
    private var appliedSort: FolderBrowserSort?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentDirectory != nil }

    init() {
        reload()
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
        guard let currentBook else { return }
        // このパネルの中のクリックで開いた本なら、今いる場所をそのまま保つ
        // (skipsNextAnchorのコメント参照)。一覧はnavigate側で読み込み済み。
        if skipsNextAnchor {
            skipsNextAnchor = false
            return
        }
        let anchor = Self.browserAnchor(for: currentBook)
        if anchor.directory != currentDirectory {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
            currentDirectory = anchor.directory
        }
        highlightedURL = anchor.highlighted
        reload()
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

    /// 上記を1回だけ見送らせる。フォルダ行のクリックで本を開く直前に呼ぶ。
    func skipNextAnchorOnce() {
        skipsNextAnchor = true
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
                // 読み込んでいる間に並べ替え設定が変わっていた場合の取りこぼしを拾う
                // (変わっていなければ何もしない)。
                self.applySortSettings()
            } catch {
                guard !Task.isCancelled else { return }
                self.entries = []
                self.currentDirectoryHasImages = false
                self.appliedSort = sort
                self.needsFolderAccessGrant = true
            }
        }
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
        guard panel.runModal() == .OK, let grantedURL = panel.url else { return }

        // アクセスの開閉はFolderAccessStoreが一手に管理する(以前はここでも
        // startAccessingSecurityScopedResource()を呼んでいたが、対になるstopが無く
        // 漏れていた。FolderAccessStore.accessedURLsByPathのコメント参照)。
        folderAccess?.add(url: grantedURL)
        reload()
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
