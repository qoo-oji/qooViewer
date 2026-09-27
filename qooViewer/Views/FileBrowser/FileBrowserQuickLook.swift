import AppKit
import Combine
import Quartz

/// ファイルブラウザのスペースキーのクイックルック(2026-09-27、監査 27。Finder の基本操作)。
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
@MainActor
final class FileBrowserQuickLook: NSObject {
    /// 選択の持ち主(一覧の `editResponder` と同じもの)。
    weak var actions: FileBrowserActions?
    /// パネルが受けたキーを回す先(この一覧)。
    weak var keyTarget: NSView?

    private var urls: [URL] = []
    private var selectionObserver: AnyCancellable?

    /// スペースキー: 出ていれば閉じ、出ていなければ出す(何も選んでいなければ何もしない)。
    func toggle() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !selectedURLs().isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// 一覧の `acceptsPreviewPanelControl(_:)` の答え。選んでいるものがあるときだけ引き受ける。
    var acceptsControl: Bool { !selectedURLs().isEmpty }

    func beginControl(_ panel: QLPreviewPanel) {
        urls = selectedURLs()
        panel.dataSource = self
        panel.delegate = self
        // `@Published` は値が入る前に知らせるので、読み直しは次の回へ回す。
        selectionObserver = actions?.state?.$selection.dropFirst().sink { [weak self, weak panel] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let panel, panel.dataSource === self else { return }
                    let current = self.selectedURLs()
                    guard current != self.urls, !current.isEmpty else { return }
                    self.urls = current
                    panel.reloadData()
                }
            }
        }
    }

    func endControl(_ panel: QLPreviewPanel) {
        selectionObserver = nil
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        urls = []
    }

    private func selectedURLs() -> [URL] {
        actions?.state?.selectedEntries.map(\.url) ?? []
    }
}

extension FileBrowserQuickLook: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let keyTarget else { return false }
        keyTarget.keyDown(with: event)
        return true
    }
}

extension FileBrowserQuickLook {
    /// スペースキー(修飾キー無し)か。
    static func isToggleKey(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
    }
}
