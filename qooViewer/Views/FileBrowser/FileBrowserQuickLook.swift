import AppKit
import Combine
import Quartz

/// ファイルブラウザのスペースキーのクイックルック(2026-09-27、監査 27。Finder の基本操作)。右クリックメニューの
/// 「クイックルック」・メニューバーの ⌘Y(2026-10-01)も同じパネルを出す(`show(toggles:)`)。
///
/// ■ 仕組み
/// `QLPreviewPanel` はアプリで 1 枚の共有のパネルで、誰が中身を渡すかは responder chain で決まる: パネルを出す・キーウインドウが
/// 変わるたびに、ファーストレスポンダから順に `acceptsPreviewPanelControl(_:)` を尋ね、true を返したものに
/// `beginPreviewPanelControl(_:)` / `endPreviewPanelControl(_:)` を送る。一覧(リスト・アイコン)の NSView がそれに答え、
/// 中身の受け渡しはこの型が受け持つ(一覧ごとに 1 つ)。
///
/// - 見せるのは**いまの選択**(`FileBrowserState.selection`)。パネルを出している間に選択が変われば取り直す(矢印キーで次の項目へ)。
/// - パネルが受けたキーは一覧へ回す(`previewPanel(_:handle:)`)。矢印で選択が動き、スペースでパネルが閉じる。Esc はパネル自身が閉じる。
/// - 書庫の本・PDF・フォルダの見え方は macOS のクイックルックに任せる(zip は中身の一覧など。2026-09-27、利用者の判断)。
/// - 読み取り専用モードでも使える(何も書き換えない)。
/// - **記号リンク・エイリアスは先を見せる**(2026-09-29 実測: `QLPreviewPanel` にリンクの URL をそのまま渡すと、Finder と違って
///   リンクのファイル自体 ―― 「エイリアス、14 バイト」 ―― が出た。Finder は先をプレビューし、題を「名前 (エイリアス)」にする)。
///   先はアイコンと同じ規則(`FileBrowserLinkResolver.backgroundTarget`: 触ってよい場所だけ)で FileIO の上で解き、解けたら差し替えて
///   `reloadData`。断られた先(共有・未接続・保護下)はリンク自身のまま。
@MainActor
final class FileBrowserQuickLook: NSObject {
    /// 選択の持ち主(一覧の `editResponder` と同じもの)。
    weak var actions: FileBrowserActions?
    /// パネルが受けたキーを回す先(この一覧)。
    weak var keyTarget: NSView?

    /// パネルに渡す項目(選択の順)。
    private var items: [Item] = []
    private var selectionObserver: AnyCancellable?
    /// 先を解いている最中の選択(解き終わったときに選択が同じなら差し替える)。
    private var resolvingSelection: [URL] = []

    /// パネルに渡す 1 項目。記号リンク・エイリアスは先の URL と「名前 (エイリアス)」の題(Finder と同じ)。
    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL!
        let previewItemTitle: String!

        init(url: URL, title: String) {
            previewItemURL = url
            previewItemTitle = title
        }
    }

    /// 選択の項目からパネルの項目を作る。記号リンク・エイリアスは先を解く(`FileBrowserLinkResolver.backgroundTarget`。解けなければ
    /// リンク自身)。**FileIO の上で呼ぶ**(先を解くのはリンクと先の各段の lstat)。
    nonisolated static func previewItems(
        for entries: [FileBrowserEntry], currentFolder: URL?, mountTable: MountTable,
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) -> [(url: URL, title: String)] {
        entries.map { entry in
            guard entry.isLink,
                  let target = FileBrowserLinkResolver.backgroundTarget(
                    of: entry.url, currentFolder: currentFolder, mountTable: mountTable,
                    protectedPrefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
                  )
            else { return (entry.url, entry.displayName) }
            // 種類の説明は Finder の「エイリアス」(OS の言語)。無ければ名前だけ。
            let title = entry.typeDescription.map { "\(entry.displayName) (\($0))" } ?? entry.displayName
            return (target, title)
        }
    }

    /// スペースキー: 出ていれば閉じ、出ていなければ出す(何も選んでいなければ何もしない)。
    func toggle() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !selectedURLs().isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// 右クリックメニュー・メニューバーの「クイックルック」(`FileBrowserState.requestQuickLook`)。出ていなければ出し、出ていれば
    /// 右クリックはこの一覧の選択へ差し替え(閉じない)、メニューバーの ⌘Y(`toggles`)は Finder と同じく閉じる。
    /// 選択は呼ぶ側が先に右クリックした項目へ揃えておく(FileBrowserActions.quickLook)。
    ///
    /// パネルの受け手はキーウインドウのファーストレスポンダから探される(型コメント)。右クリックのメニューは後ろのウインドウ・
    /// 前面でないアプリでも開き、⌘Y はツリーに焦点があっても届くので、この一覧のウインドウをキーにし、一覧を焦点にしてから出す。
    /// 出ているパネルは `updateController()` で受け手を探し直させる(別のウインドウの一覧が受け手のままにならないように)。
    func show(toggles: Bool) {
        if toggles, QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard let view = keyTarget, let window = view.window, !selectedURLs().isEmpty, let panel = QLPreviewPanel.shared()
        else { return }
        if !NSApp.isActive { NSApp.activate() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        if panel.isVisible { panel.updateController() }
        panel.makeKeyAndOrderFront(nil)
    }

    /// 一覧の `acceptsPreviewPanelControl(_:)` の答え。選んでいるものがあるときだけ引き受ける。
    var acceptsControl: Bool { !selectedURLs().isEmpty }

    func beginControl(_ panel: QLPreviewPanel) {
        showSelection(in: panel)
        panel.dataSource = self
        panel.delegate = self
        // `@Published` は値が入る前に知らせるので、読み直しは次の回へ回す。
        selectionObserver = actions?.state?.$selection.dropFirst().sink { [weak self, weak panel] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let panel, panel.dataSource === self else { return }
                    let current = self.selectedURLs()
                    guard current != self.items.map(\.previewItemURL), current != self.resolvingSelection, !current.isEmpty
                    else { return }
                    self.showSelection(in: panel)
                    panel.reloadData()
                }
            }
        }
    }

    func endControl(_ panel: QLPreviewPanel) {
        selectionObserver = nil
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        items = []
        resolvingSelection = []
    }

    private func selectedURLs() -> [URL] {
        actions?.state?.selectedEntries.map(\.url) ?? []
    }

    /// いまの選択をまず項目そのもので見せ、記号リンク・エイリアスがあれば先を FileIO で解いて差し替える(型コメント)。
    private func showSelection(in panel: QLPreviewPanel) {
        let entries = actions?.state?.selectedEntries ?? []
        items = entries.map { Item(url: $0.url, title: $0.displayName) }
        let selection = entries.map(\.url)
        resolvingSelection = selection
        guard entries.contains(where: \.isLink) else { return }
        let currentFolder = actions?.state?.currentFolder
        let mountTable = MountTable.current()
        Task { [weak self, weak panel] in
            let resolved = await FileIO.perform {
                Self.previewItems(for: entries, currentFolder: currentFolder, mountTable: mountTable)
            }
            guard let self, let panel, panel.dataSource === self, self.resolvingSelection == selection,
                  self.selectedURLs() == selection
            else { return }
            self.items = resolved.map { Item(url: $0.url, title: $0.title) }
            panel.reloadData()
        }
    }
}

extension FileBrowserQuickLook: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let keyTarget else { return false }
        keyTarget.keyDown(with: event)
        return true
    }
}

extension FileBrowserQuickLook {
    /// 一覧のビューを捨てるとき(`dismantleNSView`)に呼ぶ。パネルがこのビューから中身を受け取っていれば閉じる。
    ///
    /// パネルは今の受け手(`currentController`)を**保持し続ける**(単体の AppKit で実測、2026-09-27)。受け手が変わるのはキー
    /// ウインドウが変わったときだけなので、パネルを出したまま本を開く(パネルの Return は一覧へ回る)・表示を切り替えると、外れた
    /// 一覧がパネルに残り、パネルで押したキー(⌘⌫ など)が見えない一覧の選択へ届いた。閉じれば受け手を手放す。
    static func closePanel(ifControlledBy view: NSView) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.currentController as AnyObject? === view
        else { return }
        panel.orderOut(nil)
    }

    /// スペースキー(修飾キー無し)か、⌘Y か。
    ///
    /// ⌘Y はメニューバーの「クイックルック」のキー(2026-10-01)で、ふつうはメニューが先に受ける。メニューの項目が受けなかった
    /// とき(パネルがキーウインドウでメニューバーがこのウインドウの選択を読めないなど)は、キーがパネルから一覧へ回ってくる
    /// (`previewPanel(_:handle:)`)ので、ここでも開け閉めする(Finder と同じく ⌘Y で閉じる)。
    static func isToggleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 49 && flags.isEmpty { return true }
        return flags == .command && event.charactersIgnoringModifiers?.lowercased() == "y"
    }
}
