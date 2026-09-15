import AppKit
import SwiftUI

/// ファイルブラウザのアイコン表示(改善要望7 段階3、2026-09-13。**2026-09-15 に SwiftUI の `LazyVGrid` から `NSCollectionView` へ置き換えた**)。
///
/// ■ なぜ AppKit にしたか(ユーザー判断 2026-09-15)
/// リスト(`NSTableView`)・ツリー(`NSOutlineView`)と別の仕組みで同じ機能を作り直していたので、挙動がずれていた:
/// - ドロップ: SwiftUI の `DropInfo` にはドラッグ元が許す操作が無く、他のアプリからの移動を「Finder のときだけ」と推し量っていた
/// - 右クリック: SwiftUI の `.contextMenu` と AppKit の `NSMenu` の 2 系統(淡色のサブメニューを押せないボタンで描く回避策も SwiftUI だけ)
/// - 選択・帯で選ぶ・矢印キー・type-select・名前の編集が自前、`LazyVGrid` が画面外のセルの絵を手放さないので帳簿で数えて作り直していた
/// いまは**受け口・出し口・メニュー・名前の欄・キーの割り当てをリストと同じ口で**持つ(`FileBrowserActions.dropDecision(for:into:)`、
/// `FileBrowserMenuBuilder`、`FileBrowserNameField`、`FileBrowserEditCommand.forKey`)。セルは使い回されるので、絵は見えているセルのぶんだけ残る。
///
/// ■ クリック(Finder と同じ)
/// 選択・⌘ で反転・⇧ で範囲・余白からの帯・余白のクリックで外す・矢印キーは `NSCollectionView` の標準。ダブルクリックと Return / ⌘↓ で開く、
/// ⌘↑ で上へ、⌘⌫ / ⌥⌘V / ⌘[ / ⌘] はリストと同じ(`FileBrowserCollectionView.keyDown`)。文字のキーは `FileBrowserState.typeSelect`
/// (`NSCollectionView` には type-select が無い)。
///
/// ■ 名前の変更
/// **選ばれている 1 件の名前の文字の上をもう一度クリックすると、ダブルクリックの間隔を待って編集が始まる**(Finder と同じ。アイコンの部分・
/// 名前の横の余白では始めない。途中でもう一度クリック・キーを押せば取りやめ)。新規フォルダの直後・右クリックの「名前を変更」は
/// `FileBrowserState.renameRequest`。欄はセルの名前の `FileBrowserNameField` をそのまま編集できる形に切り替え、打った文字に合わせて下へ伸ばす。
/// Return で確定、Esc で取りやめ、焦点が外れても確定、編集中のセルが画面から外れて使い回されるときも確定。**編集中は一覧を取り込まない**
/// (リストと同じ理由 ―― 取り込むと添字がずれて別の項目の名前を変えうる。監査の 5)。
///
/// ■ ドラッグ&ドロップ
/// 出し口は `NSCollectionView` の標準(`pasteboardWriterForItemAt`)。受け口は**自前で持つ**(`FileBrowserCollectionView` の
/// `draggingEntered` など)。フォルダのセルの上ならそのフォルダ、それ以外(ファイルのセル・余白)なら表示中のフォルダ。
/// 標準の受け口は「セルの間へ差し込む」表示を前提にしていて、表示中のフォルダ全体を受け口にする形が無いため。
/// **`draggingEnded` / `concludeDragOperation` は上書きしない**(FileBrowserOutlineView のコメント: ドラッグ元の終わりの通知が止まる)。
///
/// ■ 絵
/// セル(`FileBrowserIconItem`)が `FileBrowserThumbnailProvider` に頼む。持っている絵は新しい絵が届くまで手放さない(大きさを変えるたびに
/// 種類のアイコンへ戻って点滅しないように)。小さくする方向では読み直さない。使い回されるときに頼みを取り消して絵を捨てる。
///
/// ■ 輪郭(すりガラス面の決まりごと)。描くのは `FileBrowserIconCellView`
/// - 名前 → 未選択は文字の輪郭(セルが本文と同じ矩形で反対色の文字を敷く)、選択中はアクセント地 + 反対色の縁
/// - アイコン・本の絵 → 掛けない。選択中の薄い地は反対色の縁で囲む(`.panelOutlinedFrame(in:)` 相当)
/// - ドロップの受け口になっているフォルダの地(アクセント色)→ 反対色の縁(`.panelOutlinedAccent(in:)` 相当)
/// - 編集中の欄 → 不透明な地なので掛けない
///
/// ■ リーク
/// 閉包・delegate・メニューの対象は `dismantleNSView` で切る(CLAUDE.md)。`NSTrackingArea` は使わない。
struct FileBrowserIconView: NSViewRepresentable {
    @ObservedObject var state: FileBrowserState
    let actions: FileBrowserActions
    let thumbnails: FileBrowserThumbnailProvider
    /// 提供役の `revision` / `includesVideo` の写し。**値で受け取らないと、変わっても `updateNSView` が呼ばれない**。
    let thumbnailRevision: UInt64
    let includesVideo: Bool
    let outlineWidth: CGFloat
    let locale: Locale
    /// 一覧全体(表示中のフォルダ)がドロップの受け口になった・外れた(ペインがリストと同じ枠を出す)。
    let onWholeViewDropTargetChange: (Bool) -> Void

    static let spacing: CGFloat = 12
    static let padding: CGFloat = 16
    static let nameFont = NSFont.systemFont(ofSize: 12)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let layout = FileBrowserIconLayout()
        layout.spacing = Self.spacing
        layout.inset = Self.padding

        let collection = FileBrowserCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(FileBrowserIconItem.self, forItemWithIdentifier: FileBrowserIconItem.identifier)
        collection.dataSource = coordinator
        collection.delegate = coordinator
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collection.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        collection.handler = coordinator
        let menu = NSMenu()
        menu.delegate = coordinator
        collection.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder

        coordinator.collection = collection
        coordinator.layout = layout
        coordinator.update(from: self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        // 捨てる直前に一覧を取り込み直さない(取り込むと、捨てるビューが絵を頼み直す)。
        coordinator.finishEditing(commit: true, syncsAfterward: false)
        if let collection = coordinator.collection {
            // **見えているセルの絵の依頼を取り消す**(2026-09-15 の 3 回目の監査)。表示の切り替え・ウインドウを閉じるときのアイテムは
            // `prepareForReuse` を通らずに捨てられ、Task は取り消されないので、提供役に待ちが残って本の展開・QuickLook を走らせ続けた。
            for case let item as FileBrowserIconItem in collection.visibleItems() { item.cancelThumbnailRequest() }
            collection.dataSource = nil
            collection.delegate = nil
            collection.handler = nil
            collection.unregisterDraggedTypes()
            collection.menu?.delegate = nil
            collection.menu = nil
        }
        // 閉包を先に切る(SwiftUI の更新の最中に @State を書かない)。
        coordinator.onWholeViewDropTargetChange = nil
        coordinator.collection = nil
        coordinator.state = nil
        coordinator.actions = nil
        coordinator.thumbnails = nil
    }

    // MARK: - 寸法

    /// セルの幅。アイコンの大きさに、名前の 2 行ぶんの横の余裕を足す。
    static func cellWidth(iconSize: CGFloat) -> CGFloat {
        max(iconSize + 24, 84)
    }

    /// 名前の 1 行の高さ。
    static var nameLineHeight: CGFloat {
        ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
    }

    /// 名前の上端(アイコンの枠 + 余白 4 + 間隔 4)。
    static func nameTop(iconSize: CGFloat) -> CGFloat {
        iconSize + 8 + 4
    }

    static func cellSize(iconSize: CGFloat) -> NSSize {
        NSSize(width: cellWidth(iconSize: iconSize), height: nameTop(iconSize: iconSize) + nameLineHeight * 2 + 6)
    }

    /// 名前の文字が描かれている矩形(セルの座標。上が 0)。**文字の上のクリックだけを「名前のクリック」とみなす**(Finder と同じ。
    /// 2026-09-14。以前は「アイコンの枠より下」全部で、名前の横の余白をクリックしても編集が始まった ―― 計画 §4.10)。
    /// 描く条件(12pt・2 行まで・左右の余白 4)で測り、つまむ余裕として周りに 2pt 足す。
    static func nameRect(of name: String, cellWidth: CGFloat, top: CGFloat) -> CGRect {
        let available = cellWidth - 8
        let bounds = (name as NSString).boundingRect(
            with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: nameAttributes(color: .labelColor)
        )
        let width = min(available, ceil(bounds.width)) + 8
        let height = min(ceil(bounds.height), nameLineHeight * 2) + 2
        return CGRect(x: (cellWidth - width) / 2, y: top, width: width, height: height).insetBy(dx: -2, dy: -2)
    }

    /// 2 行に収まるよう、長い名前の**中ほどを「…」で詰めた**文字(Finder と同じく両端を残す)。収まればそのまま。
    ///
    /// **残す文字を長い方から 1 文字ずつ減らして試す**(二分探索にしない)。折り返しは単語単位なので、残す文字を増やすと収まる・減らすと
    /// はみ出す、が常には成り立たず、二分探索では「Sample Bo…k」のように短く詰めすぎた(2026-09-15 の実機検証)。
    /// 結果は名前と幅ごとに覚える(セルを使い回すたびに測り直さない)。
    ///
    /// 測り方は**セルが名前を描く方法と同じ**(`nameAttributes` で `NSString` の描画。`FileBrowserIconCellView.drawName`)。最初は名前を
    /// `NSTextField` に描かせていて、欄の折り返しと測った結果が食い違い、収まるはずの文字が 3 行になって下が欠けた(2026-09-15 の実機検証)。
    static func twoLineName(_ name: String, width: CGFloat) -> String {
        let key = "\(width)|\(name)"
        if let cached = twoLineNameCache[key] { return cached }
        let limit = nameLineHeight * 2 + 0.5
        func fits(_ text: String) -> Bool {
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: nameAttributes(color: .labelColor)
            ).height <= limit
        }
        var result = name
        if !fits(name) {
            let characters = Array(name)
            // **明らかに入らない長さは測らない**(2026-09-15 の 3 回目の監査。以前は全部を `boundingRect` で測り、120 字で約 100 回・8ms、
            // 長い名前が並ぶフォルダを開くたび・ピンチのたびに見えているセルの数だけメインを止めた)。2 行に入るなら、残す文字の幅の合計は
            // 2 行ぶんの幅を超えない(行末で折り返した空白の分と字詰めの差だけ余裕を見る)。字の幅は 1 字ずつ覚える。
            // 残す文字を長い方から 1 文字ずつ試す規則(上のコメント)は変えない ―― 飛ばすのは、この条件で入り得ない長さだけ。
            var prefixWidths = [CGFloat](repeating: 0, count: characters.count + 1)
            for (index, character) in characters.enumerated() {
                prefixWidths[index + 1] = prefixWidths[index] + characterWidth(character)
            }
            let budget = width * 2 * 1.05 + characterWidth(" ") * 2 + 4
            let ellipsis = characterWidth("…")
            result = "…"
            for count in stride(from: characters.count - 1, through: 1, by: -1) {
                let head = (count + 1) / 2
                let tail = count - head
                let estimated = prefixWidths[head] + ellipsis + (prefixWidths[characters.count] - prefixWidths[characters.count - tail])
                guard estimated <= budget else { continue }
                let candidate = String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
                if fits(candidate) {
                    result = candidate
                    break
                }
            }
        }
        if twoLineNameCache.count >= 4000 { twoLineNameCache.removeAll() }
        twoLineNameCache[key] = result
        return result
    }

    private static var twoLineNameCache: [String: String] = [:]

    /// 1 字を 1 行で描いたときの幅(`twoLineName` の見積り)。字の種類は限られるので覚えておく。
    private static func characterWidth(_ character: Character) -> CGFloat {
        if let known = characterWidthCache[character] { return known }
        let measured = (String(character) as NSString).size(withAttributes: [.font: nameFont]).width
        if characterWidthCache.count >= 20000 { characterWidthCache.removeAll() }
        characterWidthCache[character] = measured
        return measured
    }

    private static var characterWidthCache: [Character: CGFloat] = [:]

    /// 名前を描く・測るときの属性(中央揃え・単語で折り返す)。
    static func nameAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: nameFont, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate,
        NSTextFieldDelegate, FileBrowserCollectionViewHandling {
        weak var collection: FileBrowserCollectionView?
        weak var layout: FileBrowserIconLayout?
        var state: FileBrowserState?
        var actions: FileBrowserActions?
        var thumbnails: FileBrowserThumbnailProvider?
        var onWholeViewDropTargetChange: ((Bool) -> Void)?

        private var entries: [FileBrowserEntry] = []
        private var revision = -1
        private var appliedCutPaths: Set<String> = []
        private var appliedScroll: FileBrowserState.ScrollRequest?
        private var appliedRename: FileBrowserState.ScrollRequest?
        private var iconSize: CGFloat = 0
        private var outlineWidth: CGFloat = -1
        private var thumbnailRevision: UInt64 = 0
        private var includesVideo = true
        private var locale = Locale.current
        /// 絵の出せる種類かの判定に使うマウント表(読み直しのたびに写す。ファイルシステムには触れない)。
        private var mountTable = MountTable.current()
        private var isApplyingSelection = false
        private let menuBuilder = FileBrowserMenuBuilder()
        /// 名前を編集している項目とそのセル。
        /// 編集中の項目(始めた時点の姿)と、そのセル。
        private var editing: (entry: FileBrowserEntry, cell: FileBrowserIconCellView)?
        /// いま画面に出している一覧のフォルダ(最後に一覧を取り込んだ時点の `state.currentFolder`)。**余白へのドロップ・背景のメニューはこれを使う**
        /// (2026-09-15 の 3 回目の監査。名前の編集中は取り込みを止めるので、`state.currentFolder` は画面と違うフォルダを指しうる)。
        private var displayedFolder: URL?
        /// 名前の編集中に取り込みを待たせた(終わったら取り込む)。
        private var needsSyncAfterEditing = false
        /// クリック・キーのたびに進む番号(名前のクリックから編集を始めるまでに次の操作があれば取りやめる)。
        private var interactionSerial = 0
        /// ドロップの受け口として強調しているフォルダのセル。
        private var dropTargetID: String?
        private var isWholeViewDropTarget = false {
            didSet {
                guard isWholeViewDropTarget != oldValue else { return }
                onWholeViewDropTargetChange?(isWholeViewDropTarget)
            }
        }

        func update(from view: FileBrowserIconView) {
            guard let collection, let layout else { return }
            state = view.state
            actions = view.actions
            thumbnails = view.thumbnails
            onWholeViewDropTargetChange = view.onWholeViewDropTargetChange
            collection.editResponder = view.actions
            locale = view.locale
            var needsReconfigure = false
            if view.state.iconSize != iconSize {
                iconSize = view.state.iconSize
                layout.itemSize = FileBrowserIconView.cellSize(iconSize: iconSize)
                needsReconfigure = true
            }
            if view.outlineWidth != outlineWidth || view.thumbnailRevision != thumbnailRevision || view.includesVideo != includesVideo {
                outlineWidth = view.outlineWidth
                thumbnailRevision = view.thumbnailRevision
                includesVideo = view.includesVideo
                needsReconfigure = true
            }
            // **名前の編集中は一覧を取り込まない**(型コメント)。
            if let editing {
                let folderChanged = view.state.currentFolder != displayedFolder
                if needsReconfigure || folderChanged || view.state.entriesRevision != revision || view.state.cutPaths != appliedCutPaths {
                    needsSyncAfterEditing = true
                }
                // 編集中に表示するフォルダが変わった(⌘[・戻るボタンは編集欄に焦点があっても効く)なら、打った名前で確定して取り込む
                // (2026-09-15 の 3 回目の監査。画面を古いフォルダのままにしない)。確定は状態を変えるので、SwiftUI の更新の外で。
                if folderChanged {
                    let cell = editing.cell
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.editing?.cell === cell else { return }
                        self.finishEditing(commit: true)
                    }
                }
                return
            }
            syncWithState(view.state, reconfiguringVisibleItems: needsReconfigure)
        }

        private func syncWithState(_ state: FileBrowserState, reconfiguringVisibleItems: Bool) {
            guard let collection else { return }
            var needsReload = false
            if state.entriesRevision != revision || state.currentFolder != displayedFolder {
                revision = state.entriesRevision
                entries = state.entries
                displayedFolder = state.currentFolder
                mountTable = .current()
                needsReload = true
            }
            if state.cutPaths != appliedCutPaths {
                appliedCutPaths = state.cutPaths
                if !needsReload { reconfigureVisibleItems() }
            }
            if needsReload {
                dropTargetID = nil
                isApplyingSelection = true
                collection.reloadData()
                isApplyingSelection = false
            } else if reconfiguringVisibleItems {
                reconfigureVisibleItems()
            }
            applySelection(from: state)
            if let request = state.scrollRequest, request != appliedScroll {
                appliedScroll = request
                if let index = entries.firstIndex(where: { $0.id == request.id }) { scrollToItem(index) }
            }
            if let request = state.renameRequest, request != appliedRename,
               let index = entries.firstIndex(where: { $0.id == request.id }) {
                appliedRename = request
                state.finishRenameRequest(request)
                scrollToItem(index)
                beginEditing(index: index)
            }
        }

        private func applySelection(from state: FileBrowserState) {
            guard let collection else { return }
            let wanted = Set(entries.indices.filter { state.selection.contains(entries[$0].id) }.map { IndexPath(item: $0, section: 0) })
            guard wanted != collection.selectionIndexPaths else { return }
            isApplyingSelection = true
            collection.selectionIndexPaths = wanted
            isApplyingSelection = false
        }

        private func scrollToItem(_ index: Int) {
            guard let collection else { return }
            collection.layoutSubtreeIfNeeded()
            guard let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
            collection.scrollToVisible(frame.insetBy(dx: 0, dy: -FileBrowserIconView.spacing))
        }

        private func reconfigureVisibleItems() {
            guard let collection else { return }
            for indexPath in collection.indexPathsForVisibleItems() {
                guard let item = collection.item(at: indexPath) as? FileBrowserIconItem else { continue }
                configure(item, at: indexPath.item)
            }
        }

        // MARK: データ

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            entries.count
        }

        func collectionView(
            _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileBrowserIconItem.identifier, for: indexPath)
            if let item = item as? FileBrowserIconItem { configure(item, at: indexPath.item) }
            return item
        }

        private func configure(_ item: FileBrowserIconItem, at index: Int) {
            guard entries.indices.contains(index), let state else { return }
            let entry = entries[index]
            let kind = FileBrowserThumbnailProvider.kind(
                for: entry, currentFolder: displayedFolder, mountTable: mountTable, includesVideo: includesVideo
            )
            item.cell.configure(
                entry: entry, kind: kind, iconSize: iconSize, outlineWidth: outlineWidth,
                isCut: state.isCut(entry), isDropTarget: dropTargetID == entry.id
            )
            if let thumbnails {
                item.requestThumbnail(
                    entry: entry, kind: kind, iconSize: iconSize, revision: thumbnailRevision,
                    provider: thumbnails, savesToDisk: !state.isPrivate
                )
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            // **既に別の位置で使い回されているアイテムの依頼は取り消さない**(2026-09-15 の 4 回目の監査。`reloadData` の最中は
            // 「新しい位置で configure」の後にこの通知が来うるので、無条件に取り消すと新しい位置の絵の依頼を消していた)。
            if let iconItem = item as? FileBrowserIconItem {
                let currentPath = collectionView.indexPath(for: iconItem)
                if currentPath == nil || currentPath == indexPath { iconItem.cancelThumbnailRequest() }
            }
            // 編集中のセルが画面から外れて使い回されるなら、打った名前で確定する(型コメント)。**この呼び出しの外で**(2026-09-15 の
            // 3 回目の監査。確定は待たせていた `reloadData` を走らせることがあり、NSCollectionView の更新の最中にやり直すと、戻った後に
            // 古い件数のまま範囲外の位置を頼んできた ―― 合成の一覧で実測)。
            if let editing, (item as? FileBrowserIconItem)?.cell === editing.cell {
                let cell = editing.cell
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.editing?.cell === cell else { return }
                    self.finishEditing(commit: true)
                }
            }
        }

        // MARK: 選択

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            // クリックで選んだ項目を矢印キー・type-select の起点にする。
            if indexPaths.count == 1, let index = indexPaths.first?.item, entries.indices.contains(index) {
                state?.setSelectionAnchor(entries[index].id)
            }
            writeSelection()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            writeSelection()
        }

        private func writeSelection() {
            guard !isApplyingSelection, let collection, let state else { return }
            let ids = Set(collection.selectionIndexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item].id : nil })
            if ids != state.selection { state.selection = ids }
        }

        // MARK: 出し口

        func collectionView(
            _ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent
        ) -> Bool {
            editing == nil
        }

        func collectionView(
            _ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            guard entries.indices.contains(indexPath.item) else { return nil }
            return FileBrowserActions.pasteboardWriter(for: entries[indexPath.item])
        }

        func collectionView(
            _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        ) {
            self.collection?.didBeginDragInCurrentClick = true
            // 名前のクリックから編集を始める待ちを取りやめる。
            noteInteraction()
            // `NSCollectionView` はドラッグしているセルを隠すが、Finder・リストと同じく元の場所に残す(2026-09-15 の実機検証。隠すと
            // 並べ替えのドラッグのように空きができた)。隠すのはドラッグが始まった直後なので、次のランループで戻す。
            DispatchQueue.main.async { [weak self] in
                guard let collection = self?.collection else { return }
                for indexPath in indexPaths { collection.item(at: indexPath)?.view.isHidden = false }
            }
            FileBrowserDragTracker.begin(indexPaths.sorted().compactMap { indexPath in
                entries.indices.contains(indexPath.item) && !entries[indexPath.item].isVolume ? entries[indexPath.item].url : nil
            })
        }

        func collectionView(
            _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
            dragOperation operation: NSDragOperation
        ) {
            FileBrowserDragTracker.end()
        }

        // MARK: 受け口(FileBrowserCollectionViewHandling)

        func dragOperation(for info: NSDraggingInfo, at point: NSPoint) -> NSDragOperation {
            guard let actions else { return [] }
            let folderIndex = folderIndex(at: point)
            let destination = folderIndex.map { entries[$0].url } ?? displayedFolder
            let (decision, _) = actions.dropDecision(for: info, into: destination)
            let operation = decision.dragOperation(sourceMask: info.draggingSourceOperationMask)
            setDropTarget(id: operation.isEmpty ? nil : folderIndex.map { entries[$0].id })
            isWholeViewDropTarget = folderIndex == nil && !operation.isEmpty
            return operation
        }

        func performDrop(_ info: NSDraggingInfo, at point: NSPoint) -> Bool {
            let folderIndex = folderIndex(at: point)
            clearDropTarget()
            guard let actions else { return false }
            let destination = folderIndex.map { entries[$0].url } ?? displayedFolder
            let (decision, urls) = actions.dropDecision(for: info, into: destination)
            actions.performDrop(decision, urls: urls)
            return decision.isAccepted
        }

        func clearDropTarget() {
            setDropTarget(id: nil)
            isWholeViewDropTarget = false
        }

        /// `point`(一覧の座標)の下のセルがフォルダ(パッケージでない)なら、その添字。
        private func folderIndex(at point: NSPoint) -> Int? {
            guard let index = collection?.indexPathForItem(at: point)?.item, entries.indices.contains(index),
                  entries[index].isNavigableFolder
            else { return nil }
            return index
        }

        private func setDropTarget(id: String?) {
            guard dropTargetID != id, let collection else { return }
            let previous = dropTargetID
            dropTargetID = id
            for changed in [previous, id].compactMap(\.self) {
                guard let index = entries.firstIndex(where: { $0.id == changed }),
                      let item = collection.item(at: IndexPath(item: index, section: 0)) as? FileBrowserIconItem
                else { continue }
                item.cell.isDropTarget = changed == id
            }
        }

        // MARK: クリックとキー(FileBrowserCollectionViewHandling)

        func noteInteraction() {
            interactionSerial += 1
        }

        func openItem(at index: Int) {
            guard let actions, let state, entries.indices.contains(index) else { return }
            let entry = entries[index]
            actions.open(state.selection.contains(entry.id) ? state.selectedEntries : [entry])
        }

        func openSelection() {
            guard let actions, let state else { return }
            let targets = state.selectedEntries
            guard !targets.isEmpty else { return }
            actions.open(targets)
        }

        func typeSelect(_ characters: String) {
            state?.typeSelect(characters)
        }

        func moveSelection(_ direction: GridKeyboardNavigation.Direction) {
            state?.moveSelection(direction, columns: layout?.columnCount ?? 1)
        }

        func magnify(by magnification: CGFloat) {
            guard let state else { return }
            let range = FileBrowserState.iconSizeRange
            let next = min(range.upperBound, max(range.lowerBound, state.iconSize * (1 + magnification)))
            if next != state.iconSize { state.iconSize = next }
        }

        func isNameHit(at point: NSPoint, index: Int) -> Bool {
            guard let collection, entries.indices.contains(index),
                  let item = collection.item(at: IndexPath(item: index, section: 0)) as? FileBrowserIconItem
            else { return false }
            return item.cell.isNameHit(item.cell.convert(point, from: collection))
        }

        /// 選ばれている 1 件の名前をクリックした(型コメント)。ダブルクリックの間隔を待ち、その間に次の操作が無く、まだその 1 件だけを
        /// 選んでいれば編集を始める。
        func nameClicked(at index: Int) {
            guard entries.indices.contains(index) else { return }
            let id = entries[index].id
            let serial = interactionSerial
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard let self, self.interactionSerial == serial, self.editing == nil, self.state?.selection == [id],
                      let current = self.entries.firstIndex(where: { $0.id == id })
                else { return }
                self.beginEditing(index: current)
            }
        }

        // MARK: 名前の変更

        private func beginEditing(index: Int) {
            guard let collection, let actions, entries.indices.contains(index), editing == nil else { return }
            let entry = entries[index]
            // 読み取り専用モードの間は、名前のクリックからも始めない(段階 8.5)。
            guard !entry.isVolume, actions.allowsFileChanges else { return }
            let indexPath = IndexPath(item: index, section: 0)
            collection.layoutSubtreeIfNeeded()
            guard let item = collection.item(at: indexPath) as? FileBrowserIconItem else {
                // 画面の外から頼まれた(新規フォルダが下の方にできた)。スクロールした後のセルができてから 1 回だけ試し直す。
                let id = entry.id
                DispatchQueue.main.async { [weak self] in
                    guard let self, let current = self.entries.firstIndex(where: { $0.id == id }),
                          self.collection?.item(at: IndexPath(item: current, section: 0)) != nil
                    else { return }
                    self.beginEditing(index: current)
                }
                return
            }
            interactionSerial += 1
            editing = (entry, item.cell)
            if let state {
                state.selection = [entry.id]
                applySelection(from: state)
            }
            collection.editingField = item.cell.nameField
            // 始められなかった(ウインドウが無い・焦点を移せない)なら、編集中の印を残さない(残ると一覧の取り込みが止まったままになる)。
            guard item.cell.beginEditing(name: entry.url.lastPathComponent, selectsWholeName: entry.isNavigableFolder, delegate: self) else {
                editing = nil
                collection.editingField = nil
                item.cell.endEditing()
                return
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            editing?.cell.fitEditingHeight()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finishEditing(commit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finishEditing(commit: false)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finishEditing(commit: true)
        }

        /// 編集を終える(確定なら打った名前で変える)。2 回目以降は何もしない(焦点を戻すと「編集が終わった」がもう一度届く)。
        /// - Parameter syncsAfterward: false なら、待たせていた一覧の取り込みをしない(呼び出し側がすぐ取り込む・ビューを捨てる)。
        func finishEditing(commit: Bool, syncsAfterward: Bool = true) {
            guard let current = editing else { return }
            editing = nil
            let name = current.cell.nameField.currentEditor()?.string ?? current.cell.nameField.stringValue
            current.cell.endEditing()
            collection?.editingField = nil
            if let collection, collection.window?.firstResponder !== collection {
                collection.window?.makeFirstResponder(collection)
            }
            // 今の一覧に無ければ(表示するフォルダが変わった)、始めた時点の姿で変える(黙って捨てない)。
            let entry = state?.entry(withID: current.entry.id) ?? current.entry
            if commit, let state, name != entry.url.lastPathComponent {
                state.operations.rename(entry, to: name)
            }
            if syncsAfterward, needsSyncAfterEditing, let state {
                needsSyncAfterEditing = false
                syncWithState(state, reconfiguringVisibleItems: true)
            }
        }

        // MARK: 右クリック

        /// 右クリック: 選択に含まれるセルならその全部、外ならその 1 件だけ(選択は変えない。Finder・リストと同じ)。
        /// セルの外(余白)ならペースト・新規フォルダ・表示・表示順序。
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let collection else { return }
            let folder = displayedFolder
            guard let clicked = collection.clickedIndexPath?.item, entries.indices.contains(clicked) else {
                menuBuilder.rebuild(
                    menu, for: FileBrowserMenuContext(kind: .background, entries: [], folder: folder),
                    actions: actions, locale: locale
                )
                return
            }
            let selected = collection.selectionIndexPaths.map(\.item).sorted()
            let targets = selected.contains(clicked)
                ? selected.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
                : [entries[clicked]]
            menuBuilder.rebuild(
                menu, for: FileBrowserMenuContext(kind: .of(entries[clicked]), entries: targets, folder: folder),
                actions: actions, locale: locale
            )
        }
    }
}

// MARK: - 一覧

/// 一覧が受け口・クリック・キーを渡す相手(Coordinator)。
@MainActor
protocol FileBrowserCollectionViewHandling: AnyObject {
    func dragOperation(for info: NSDraggingInfo, at point: NSPoint) -> NSDragOperation
    func performDrop(_ info: NSDraggingInfo, at point: NSPoint) -> Bool
    func clearDropTarget()
    func noteInteraction()
    func openItem(at index: Int)
    func openSelection()
    func typeSelect(_ characters: String)
    func moveSelection(_ direction: GridKeyboardNavigation.Direction)
    func magnify(by magnification: CGFloat)
    func isNameHit(at point: NSPoint, index: Int) -> Bool
    func nameClicked(at index: Int)
}

/// アイコン表示の `NSCollectionView`。キー・クリック・受け口・ピンチを `handler` へ渡す(リストの `FileBrowserTableView` に当たる)。
final class FileBrowserCollectionView: NSCollectionView, NSMenuItemValidation {
    weak var handler: (any FileBrowserCollectionViewHandling)?
    weak var editResponder: (any FileBrowserEditResponding)?
    /// 名前を編集している欄。
    weak var editingField: NSTextField?
    /// 右クリックしたセル(`menu(for:)` で控え、メニューを組むときに読む)。
    private(set) var clickedIndexPath: IndexPath?
    /// いまのクリックからドラッグが始まった(名前のクリックとみなさない)。
    var didBeginDragInCurrentClick = false

    // MARK: クリック

    override func mouseDown(with event: NSEvent) {
        handler?.noteInteraction()
        let point = convert(event.locationInWindow, from: nil)
        let index = indexPathForItem(at: point)
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let wasOnlySelection = index.map { selectionIndexPaths == [$0] } ?? false
        let onName = index.map { handler?.isNameHit(at: point, index: $0.item) ?? false } ?? false
        didBeginDragInCurrentClick = false
        super.mouseDown(with: event)
        guard let index else { return }
        if event.clickCount == 2 {
            handler?.openItem(at: index.item)
        } else if event.clickCount == 1, flags.isEmpty, wasOnlySelection, onName, !didBeginDragInCurrentClick {
            handler?.nameClicked(at: index.item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        handler?.noteInteraction()
        clickedIndexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return super.menu(for: event)
    }

    override func magnify(with event: NSEvent) {
        handler?.magnify(by: event.magnification)
    }

    // MARK: キー

    override func keyDown(with event: NSEvent) {
        handler?.noteInteraction()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Return / Enter、⌘↓(Finder の「開く」)。
        if (event.keyCode == 36 || event.keyCode == 76) && flags.subtracting([.numericPad, .function]).isEmpty
            || (event.keyCode == 125 && flags.contains(.command)) {
            handler?.openSelection()
            return
        }
        if let command = FileBrowserEditCommand.forKey(event), let editResponder {
            if editResponder.canPerform(command) { editResponder.perform(command) }
            return
        }
        // 矢印キーは自分で動かす(FileBrowserState.moveSelection のコメント。⌘↑ / ⌘↓ は上で受けてある)。
        if flags.isDisjoint(with: [.command, .option, .control]) {
            let direction: GridKeyboardNavigation.Direction? = switch event.keyCode {
            case 123: .left
            case 124: .right
            case 125: .down
            case 126: .up
            default: nil
            }
            if let direction {
                handler?.moveSelection(direction)
                return
            }
        }
        if let characters = Self.typeSelectCharacters(of: event) {
            handler?.typeSelect(characters)
            return
        }
        super.keyDown(with: event)
    }

    /// type-select に使う文字。⌘・⌃・⌥ 付き、制御文字(Return / Tab / Esc / Delete)、矢印などの機能キー(U+F700〜U+F8FF)は受けない。
    static func typeSelectCharacters(of event: NSEvent) -> String? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
                      && scalar.value != 0x7F
              })
        else { return nil }
        return characters
    }

    @objc func copy(_ sender: Any?) { editResponder?.perform(.copy) }
    @objc func cut(_ sender: Any?) { editResponder?.perform(.cut) }
    @objc func paste(_ sender: Any?) { editResponder?.perform(.paste) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): editResponder?.canPerform(.copy) ?? false
        case #selector(cut(_:)): editResponder?.canPerform(.cut) ?? false
        case #selector(paste(_:)): editResponder?.canPerform(.paste) ?? false
        case #selector(selectAll(_:)): numberOfItems(inSection: 0) > 0
        default: true
        }
    }

    // MARK: 出し口

    override func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        fileBrowserDragSourceMask(allowsFileChanges: editResponder?.allowsFileChanges ?? false)
    }

    // MARK: 受け口(型コメント「ドラッグ&ドロップ」。標準の受け口は呼ばない)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        autoscrollDuringDrag(to: convert(sender.draggingLocation, from: nil))
        return updateDrop(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        handler?.clearDropTarget()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handler?.performDrop(sender, at: convert(sender.draggingLocation, from: nil)) ?? false
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        handler?.dragOperation(for: sender, at: convert(sender.draggingLocation, from: nil)) ?? []
    }

    /// ドラッグを端へ寄せたらスクロールする(標準の受け口を呼ばないので、自分で行う)。
    private func autoscrollDuringDrag(to point: NSPoint) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = visibleRect
        let margin: CGFloat = 24
        var origin = clip.bounds.origin
        if point.y < visible.minY + margin {
            origin.y -= 12
        } else if point.y > visible.maxY - margin {
            origin.y += 12
        } else {
            return
        }
        origin.y = min(max(0, origin.y), max(0, frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

/// 同じ大きさのセルを、間隔を固定して左上から詰めて並べる(本棚の `WelcomeGridColumns` と同じ見え方。標準の `NSCollectionViewFlowLayout` は
/// 余った幅をセルの間へ配る)。
///
/// **位置は最初からここで決める**(2026-09-15 の実機検証)。最初は流し込みの結果の x だけを書き換えていたが、`NSCollectionView` の
/// `indexPathForItem(at:)` は書き換える前の位置で引くので、見えているセルをクリックしても「セルの外」になり、選択もダブルクリックも効かなかった。
final class FileBrowserIconLayout: NSCollectionViewLayout {
    var itemSize = NSSize(width: 120, height: 150) {
        didSet { if itemSize != oldValue { invalidateLayout() } }
    }
    var spacing: CGFloat = 12
    var inset: CGFloat = 16

    private var itemCount = 0
    /// 1 行の列の数(矢印キーの移動に使う)。
    private(set) var columnCount = 1
    private var preparedWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        itemCount = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        preparedWidth = collectionView.bounds.width
        let usable = preparedWidth - inset * 2
        columnCount = max(1, Int(((usable + spacing) / (itemSize.width + spacing)).rounded(.down)))
    }

    private var rowCount: Int {
        itemCount == 0 ? 0 : (itemCount + columnCount - 1) / columnCount
    }

    private func frame(forItem index: Int) -> NSRect {
        let column = index % columnCount
        let row = index / columnCount
        return NSRect(
            x: inset + CGFloat(column) * (itemSize.width + spacing),
            y: inset + CGFloat(row) * (itemSize.height + spacing),
            width: itemSize.width, height: itemSize.height
        )
    }

    /// 中身が少なくても**見えている範囲いっぱいまで一覧にする**(余白のどこからでも帯で選べ、ドロップ・右クリックが一覧に届くように。
    /// 一覧の外へ落ちると、ペインの SwiftUI の受け口が拾ってしまう)。
    override var collectionViewContentSize: NSSize {
        let rows = CGFloat(rowCount)
        let height = rows == 0 ? 0 : inset * 2 + rows * itemSize.height + (rows - 1) * spacing
        let visible = collectionView?.enclosingScrollView?.contentView.bounds.height ?? 0
        return NSSize(width: preparedWidth, height: max(height, visible))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard itemCount > 0 else { return [] }
        let rowHeight = itemSize.height + spacing
        let firstRow = max(0, Int(((rect.minY - inset) / rowHeight).rounded(.down)))
        let lastRow = min(rowCount - 1, Int(((rect.maxY - inset) / rowHeight).rounded(.down)))
        guard firstRow <= lastRow else { return [] }
        var result: [NSCollectionViewLayoutAttributes] = []
        for row in firstRow...lastRow {
            for column in 0..<columnCount {
                let index = row * columnCount + column
                guard index < itemCount else { break }
                let itemFrame = frame(forItem: index)
                guard itemFrame.intersects(rect) else { continue }
                let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
                attributes.frame = itemFrame
                result.append(attributes)
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < itemCount else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame(forItem: indexPath.item)
        return attributes
    }

    /// 幅が変わったら並べ直す(スクロールでは並べ直さない)。
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != preparedWidth
    }
}

// MARK: - セル

/// アイコン表示の 1 件。絵を頼み、使い回されるときに頼みを取り消す(型コメント「絵」)。
final class FileBrowserIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("fileBrowser.iconItem")

    /// `nonisolated(unsafe)` は `deinit` から取り消すためだけ(書くのはメインアクターだけで、`deinit` の時点で他に触る者はいない)。
    private nonisolated(unsafe) var thumbnailTask: Task<Void, Never>?
    private var loadedEntryID: String?
    private var loadedContentKey = ""
    private var loadedTier: CGFloat = 0
    private var requestedKey = ""

    var cell: FileBrowserIconCellView {
        // loadView が必ず FileBrowserIconCellView を作る。
        view as! FileBrowserIconCellView // swiftlint:disable:this force_cast
    }

    override func loadView() {
        view = FileBrowserIconCellView(frame: .zero)
    }

    override var isSelected: Bool {
        didSet {
            cell.isSelected = isSelected
        }
    }

    /// 絵の依頼だけを取り消す(持っている絵は残す。画面に戻ったら `requestThumbnail` が頼み直す)。
    func cancelThumbnailRequest() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        requestedKey = ""
    }

    /// **捨てられるアイテムの絵の依頼を取り消す**(2026-09-15 の 4 回目の監査)。`dismantleNSView` が取り消すのは見えているアイテムだけで、
    /// スクロールに備えて画面の外に用意されたアイテムは `prepareForReuse` も `didEndDisplaying` も通らずに一覧ごと捨てられる。
    /// Task は `[weak self]` なので、取り消さなければ提供役が本の展開・QuickLook を最後まで続けた。
    deinit {
        thumbnailTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        cell.thumbnail = nil
        loadedEntryID = nil
        loadedContentKey = ""
        loadedTier = 0
        requestedKey = ""
    }

    /// 絵を頼む。持っている絵は新しい絵が届くまで手放さない(別の項目になったときだけ捨てる)。小さくする方向では読み直さない。
    func requestThumbnail(
        entry: FileBrowserEntry, kind: BookThumbnailer.Kind?, iconSize: CGFloat, revision: UInt64,
        provider: FileBrowserThumbnailProvider, savesToDisk: Bool
    ) {
        if loadedEntryID != entry.id {
            thumbnailTask?.cancel()
            thumbnailTask = nil
            cell.thumbnail = nil
            loadedEntryID = entry.id
            loadedContentKey = ""
            loadedTier = 0
            requestedKey = ""
        }
        guard let kind else {
            thumbnailTask?.cancel()
            thumbnailTask = nil
            cell.thumbnail = nil
            loadedContentKey = ""
            requestedKey = ""
            return
        }
        let modified = entry.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        let contentKey = "\(entry.id)|\(modified)|\(entry.fileSize ?? -1)|\(revision)|\(kind)"
        let tier = FileBrowserThumbnailProvider.pixelTier(
            forDisplaySize: kind == .folder ? iconSize * FileBrowserIconCellView.folderImageScale : iconSize
        )
        if cell.thumbnail != nil, loadedContentKey == contentKey, tier <= loadedTier { return }
        let request = "\(contentKey)|\(tier)"
        guard request != requestedKey else { return }
        requestedKey = request
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            let buffer = await provider.thumbnail(for: entry, kind: kind, pixelSize: tier, savesToDisk: savesToDisk)
            guard !Task.isCancelled, let self, self.requestedKey == request else { return }
            self.thumbnailTask = nil
            self.requestedKey = ""
            guard let buffer, let image = buffer.makeImage() else {
                // 中身が変わって作れなくなった(画像を消した等)ときだけ種類のアイコンへ戻す。
                if self.loadedContentKey != contentKey { self.cell.thumbnail = nil }
                return
            }
            self.cell.thumbnail = image
            self.loadedContentKey = contentKey
            self.loadedTier = tier
        }
    }
}

/// アイコン表示のセルの見た目(型コメント「輪郭」)。絵・地・名前は `draw` で描き、`FileBrowserNameField` は名前を編集するときだけ出す。
///
/// **名前は欄に描かせない**(2026-09-15 の実機検証)。欄(`FileBrowserOutlinedTextFieldCell`)に描かせると、本文と後ろに重ねる輪郭の折り返しが
/// 幅いっぱいの名前で食い違い、白 100% の面で文字が潰れた。本文も輪郭も同じ矩形・同じ属性で描けば必ず重なる。
final class FileBrowserIconCellView: NSView {
    /// フォルダに重ねる絵の大きさ(アイコンに対する比)。
    static let folderImageScale: CGFloat = 0.56

    let nameField: FileBrowserNameField
    private var entry: FileBrowserEntry?
    private var kind: BookThumbnailer.Kind?
    private var iconSize: CGFloat = 64
    private var outlineWidth: CGFloat = 0
    private var displayName = ""
    private var isEditingName = false

    var thumbnail: CGImage? {
        didSet { if thumbnail !== oldValue { needsDisplay = true } }
    }

    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    var isDropTarget = false {
        didSet { if isDropTarget != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// **セルの中の部品(名前の欄)を当たり先にしない。当たり先はこのセル**(編集中の欄の中だけは欄へ通す)。クリックはセルから
    /// 一覧(`FileBrowserCollectionView`)の `mouseDown` / `menu(for:)` へ上がり、標準の選択・帯・ドラッグへ通る
    /// (リストの `FileBrowserTableView.hitTest` と同じ理由)。
    ///
    /// **一覧の `hitTest` で一覧自身を返してはいけない**(2026-09-15 の実機検証)。`NSCollectionView` は当たり先のビューからセルを見分けるので、
    /// `indexPathForItem(at:)` が nil を返し、見えているセルをクリックしても選択もダブルクリックも効かなかった。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if isEditingName, hit === nameField || hit.isDescendant(of: nameField) { return hit }
        return hit.isDescendant(of: self) ? self : hit
    }

    override init(frame: NSRect) {
        let field = FileBrowserNameField(frame: .zero)
        field.font = FileBrowserIconView.nameFont
        field.alignment = .center
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byCharWrapping
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.isHidden = true
        nameField = field
        super.init(frame: frame)
        wantsLayer = true
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(
        entry: FileBrowserEntry, kind: BookThumbnailer.Kind?, iconSize: CGFloat, outlineWidth: CGFloat, isCut: Bool, isDropTarget: Bool
    ) {
        self.entry = entry
        self.kind = kind
        self.iconSize = iconSize
        self.outlineWidth = outlineWidth
        self.isDropTarget = isDropTarget
        alphaValue = isCut ? 0.5 : 1
        toolTip = entry.displayName
        let width = FileBrowserIconView.cellWidth(iconSize: iconSize)
        displayName = FileBrowserIconView.twoLineName(entry.displayName, width: width - 8)
        needsDisplay = true
    }

    private var nameTop: CGFloat {
        FileBrowserIconView.nameTop(iconSize: iconSize)
    }

    /// 名前の文字の上か(セルの座標)。
    func isNameHit(_ point: NSPoint) -> Bool {
        FileBrowserIconView.nameRect(of: displayName, cellWidth: bounds.width, top: nameTop).contains(point)
    }

    // MARK: 名前の編集

    /// 焦点を名前の欄へ移せたら true。
    @discardableResult
    func beginEditing(name: String, selectsWholeName: Bool, delegate: NSTextFieldDelegate) -> Bool {
        guard let window else { return false }
        isEditingName = true
        layer?.zPosition = 10
        needsDisplay = true
        nameField.editingName = name
        nameField.selectsWholeName = selectsWholeName
        nameField.delegate = delegate
        nameField.stringValue = name
        nameField.isHidden = false
        fitEditingHeight()
        // 焦点が入った時点で FileBrowserNameField が実名へ差し替えて、拡張子の前までを選ぶ。
        return window.makeFirstResponder(nameField)
    }

    /// 打った文字に合わせて欄を下へ伸ばす(Finder と同じ)。
    func fitEditingHeight() {
        guard isEditingName else { return }
        let width = FileBrowserIconView.cellWidth(iconSize: iconSize)
        let text = nameField.currentEditor()?.string ?? nameField.stringValue
        let measuring = NSTextFieldCell(textCell: text.isEmpty ? " " : text)
        measuring.font = FileBrowserIconView.nameFont
        measuring.wraps = true
        measuring.isBezeled = true
        measuring.bezelStyle = .squareBezel
        let height = measuring.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        nameField.frame = NSRect(x: 0, y: nameTop - 2, width: width, height: ceil(height))
    }

    func endEditing() {
        guard isEditingName else { return }
        nameField.abortEditing()
        nameField.delegate = nil
        nameField.editingName = nil
        nameField.isHidden = true
        isEditingName = false
        layer?.zPosition = 0
        needsDisplay = true
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        let boxSide = iconSize + 8
        let box = NSRect(x: (bounds.width - boxSide) / 2, y: 0, width: boxSide, height: boxSide)
        let boxPath = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            boxPath.fill()
            strokeOutline(around: box, radius: 6)
        } else if isSelected {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            boxPath.fill()
            strokeOutline(around: box, radius: 6)
        }

        let iconRect = box.insetBy(dx: 4, dy: 4)
        if let thumbnail, let kind, kind != .folder {
            drawThumbnail(thumbnail, in: iconRect, withShadow: kind != .application)
        } else {
            let icon = FileBrowserIconProvider.icon(for: entry)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            if let thumbnail, kind == .folder {
                let side = iconSize * Self.folderImageScale
                // フォルダのアイコンの胴(上の耳を除いた部分)の中ほどへ。
                let rect = NSRect(x: iconRect.midX - side / 2, y: iconRect.midY - side / 2 + iconSize * 0.06, width: side, height: side)
                drawThumbnail(thumbnail, in: rect, withShadow: true)
            }
        }

        guard !isEditingName else { return }
        if isSelected {
            let pill = FileBrowserIconView.nameRect(of: displayName, cellWidth: bounds.width, top: nameTop).insetBy(dx: 2, dy: 2)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            strokeOutline(around: pill, radius: 4)
        }
        drawName()
    }

    /// 名前を描く。未選択なら反対色の文字を上下左右にずらして後ろへ敷く(`FileBrowserOutlinedTextFieldCell` と同じ輪郭)。
    /// 選択中はアクセント地の上の白い文字なので輪郭は掛けない。
    private func drawName() {
        let rect = NSRect(
            x: 4, y: nameTop + 1, width: bounds.width - 8, height: FileBrowserIconView.nameLineHeight * 2 + 1
        )
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        let name = displayName as NSString
        if !isSelected, outlineWidth > 0 {
            let outline = FileBrowserIconView.nameAttributes(color: fileBrowserOutlineColor(for: self))
            for direction in PanelContentShadow.outlineDirections {
                name.draw(
                    with: rect.offsetBy(dx: direction.x * outlineWidth, dy: direction.y * outlineWidth),
                    options: options, attributes: outline
                )
            }
        }
        name.draw(with: rect, options: options, attributes: FileBrowserIconView.nameAttributes(color: isSelected ? .white : .labelColor))
    }

    /// 面の色に溶けないよう、反対色の縁を付ける(輪郭の太さが 0 なら付けない)。
    private func strokeOutline(around rect: NSRect, radius: CGFloat) {
        guard outlineWidth > 0 else { return }
        fileBrowserOutlineColor(for: self).setStroke()
        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2), xRadius: radius, yRadius: radius
        )
        border.lineWidth = outlineWidth
        border.stroke()
    }

    /// 絵を枠に収めて描く。本・画像には白いページがすりガラス面の明るい地に溶けないよう薄い影を付ける(アプリのアイコンは自前の影を持つ)。
    private func drawThumbnail(_ image: CGImage, in frame: NSRect, withShadow: Bool) {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return }
        let scale = min(frame.width / width, frame.height / height)
        let size = NSSize(width: width * scale, height: height * scale)
        let rect = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        if withShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
        }
        NSImage(cgImage: image, size: size).draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}
