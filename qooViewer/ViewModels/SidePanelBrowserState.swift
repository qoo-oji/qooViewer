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
    /// 表示枠内へスクロール+ハイライトする対象。handlePanelRevealed/goUpが設定する。
    @Published private(set) var highlightedURL: URL?

    weak var folderAccess: FolderAccessStore?
    weak var preferences: AppPreferences?

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

    /// (1)パネルがホバーで表示されるたびに(hideSidePanel == trueのときのContentViewの
    /// ホバー検知から)、および(2)開いている本が切り替わるたびに(ContentViewの
    /// .onChange(of: appState.currentBook?.id)から。サイドパネルが常時表示のときは
    /// ホバーでの「表示される」タイミング自体が発生しないため、本の切り替わりを直接検知する
    /// 必要がある)呼ぶ。本を開いていれば必ずその親フォルダへ再アンカーし、本自身を
    /// ハイライト+スクロール対象にする(ユーザー要望: 毎回必ずフォーカスされた状態で
    /// 見えるようにしたい)。本を開いていない場合は何もしない(初回はinitで設定済みの
    /// ボリューム一覧のまま、既にどこかを手動で閲覧中ならその位置を維持する — ウェルカム画面
    /// での閲覧中に毎回ボリューム一覧へ戻されるのを防ぐ)。
    func handlePanelRevealed(currentBook: MangaBook?) {
        guard let currentBook else { return }
        let folder = currentBook.sourceURL.deletingLastPathComponent()
        if folder != currentDirectory {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
            currentDirectory = folder
        }
        highlightedURL = currentBook.sourceURL
        reload()
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
                if let directory {
                    result = try await DirectoryBrowser.entriesAsync(in: directory, sort: sort)
                } else {
                    result = await DirectoryBrowser.mountedVolumeEntriesAsync(sort: sort)
                }
                guard !Task.isCancelled else { return }
                self.entries = result
                self.appliedSort = sort
                self.needsFolderAccessGrant = false
                // 読み込んでいる間に並べ替え設定が変わっていた場合の取りこぼしを拾う
                // (変わっていなければ何もしない)。
                self.applySortSettings()
            } catch {
                guard !Task.isCancelled else { return }
                self.entries = []
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
        panel.prompt = String(localized: "Grant Access", locale: locale)
        panel.message = String(
            localized: "To show files in this folder, please select and grant access to it.",
            locale: locale
        )
        guard panel.runModal() == .OK, let grantedURL = panel.url else { return }

        // AppState.open(url:)と同じ防御的な呼び出し(パネルで選んだURLはこのセッション中は
        // 既にアクセス可能なはずだが、念のため)。
        _ = grantedURL.startAccessingSecurityScopedResource()
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
