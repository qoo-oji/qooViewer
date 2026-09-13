import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ファイルブラウザのアイコン表示(改善要望7 段階3、2026-09-13)。SwiftUIの`LazyVGrid`。
///
/// リストとツリーはAppKitだが、ここはSwiftUIのまま(決定事項 Q3)。本棚の2画面と同じ部品 ――
/// 固定幅の列(WelcomeGridColumns)・ピンチ(welcomeGridPinch)・余白から引く帯(MarqueeSelection)――
/// がそのまま使え、`Table`の退行とも関係が無い。
///
/// ■ クリック(Finderと同じ)
/// 単発 = その1件だけを選ぶ(⌘で反転、⇧で範囲)、ダブルクリック = 開く、余白 = 選択を外す、
/// 余白からのドラッグ = 帯で選ぶ(修飾キーなしなら置き換え)。単発は`simultaneousGesture`で即時に効かせる
/// (`onTapGesture`の1回と2回を並べると、単発がダブルクリックの間隔ぶん遅れる ―― qooLibrary 実測)。
///
/// ■ 名前の変更(段階4b)
/// **選ばれている1件の名前をもう一度クリックすると、ダブルクリックの間隔を待って編集が始まる**(Finder と同じ。
/// アイコンの部分のクリックでは始めない。途中でもう一度クリックすれば取りやめ)。新規フォルダの直後・右クリックの
/// 「名前を変更」は`FileBrowserState.renameRequest`で頼まれ、その項目が一覧に現れた時点で始める。編集中は名前の
/// 位置に`FileBrowserIconNameEditor`を出し、そのセルのクリック・ダブルクリック・ドラッグのジェスチャーを外す
/// (欄の中のクリックでカーソルを置けるように)。
///
/// ■ type-select(段階4b)
/// 文字のキーで名前の先頭が一致する項目を選ぶ(`FileBrowserState.typeSelect`。リスト表示は`NSTableView`の標準)。
/// **編集中はこの一覧の`.onKeyPress`を全部素通しにする** ―― SwiftUI の焦点が一覧に残っていると、AppKit の
/// ファーストレスポンダが編集欄でも`.onKeyPress`が先にキーを取る(打った文字が type-select に、Return が「開く」に
/// 化けた。実機 2026-09-14)。あわせて編集を始めるときに一覧の焦点を外す。
///
/// ■ ドラッグ&ドロップ(段階4b)
/// セルを掴むと、選ばれていればその全部、選ばれていなければその1件だけを選び直して運ぶ(Finder と同じ)。
/// 運ぶのは AppKit のドラッグセッション(FileBrowserIconDragHandle のコメント)。フォルダのセルは受け口で、
/// 反応している間はアイコンの地をアクセント色にする。それ以外(ファイルのセル・余白)へ落とすと、
/// 右ペイン全体の受け口(FileBrowserPane)が表示中のフォルダへ落とす。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// - 名前 → 未選択は`.panelOutlinedContent()`、選択中はアクセント地なので`.panelOutlinedAccent(in:)`
/// - アイコン → 種類のアイコン(色付きの絵)なので掛けない。選択中の地(薄い灰)は
///   `.panelOutlinedFrame(in:)`で縁取る(薄い地だけでは面の色に溶ける)
/// - ドロップの受け口になっているフォルダの地(アクセント色)→ `.panelOutlinedAccent(in:)`
struct FileBrowserIconView: View {
    @ObservedObject var state: FileBrowserState
    let actions: FileBrowserActions

    @State private var marquee = MarqueeSelection()
    @State private var dragHandle = FileBrowserIconDragHandle()
    /// ドロップの受け口として反応しているフォルダのセル。
    @State private var dropTargetID: String?
    /// 名前を編集しているセルと、打っている文字(欄の高さを測り直すため)。
    @State private var editingID: String?
    @State private var editingText = ""
    /// クリックのたびに進む番号。名前のクリックから編集を始めるまでの間に次のクリックがあれば取りやめる。
    @State private var clickSerial = 0
    /// 直前の単発クリックの項目と時刻(ダブルクリックの2回目を名前のクリックと取り違えないため)。
    /// `NSApp.currentEvent`はジェスチャーの閉包の中ではマウスのイベントではなく、`clickCount`が読めなかった(実機 2026-09-14)。
    @State private var lastTap: (id: String, time: TimeInterval)?
    /// 最後に拾った名前の編集の依頼(同じ依頼で2回始めない)。
    @State private var appliedRenameSerial: Int?
    @FocusState private var isFocused: Bool

    private static let spacing: CGFloat = 12
    private static let padding: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let columns = WelcomeGridColumns(
                availableWidth: geometry.size.width, itemWidth: cellWidth,
                spacing: Self.spacing, padding: Self.padding
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns.gridItems(alignment: .top), spacing: Self.spacing) {
                        ForEach(state.entries) { entry in
                            cell(for: entry)
                                .id(entry.id)
                                .marqueeCell(entry.id, in: marquee)
                        }
                    }
                    .padding(Self.padding)
                    .marqueeSelectable(
                        marquee, isEnabled: true, minimumHeight: geometry.size.height,
                        selection: $state.selection, shownIDs: Set(state.entries.map(\.id)),
                        mode: .replacing,
                        onBackgroundClick: { [weak state] in
                            state?.selection = []
                            isFocused = true
                        }
                    )
                }
                .background(FileBrowserIconDragSource(handle: dragHandle))
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                    guard editingID == nil else { return .ignored }
                    if press.modifiers.contains(.command) {
                        // ⌘↑ は上へ、⌘↓ は開く(リストと同じ)。
                        if press.key == .upArrow { actions.perform(.goUp) }
                        if press.key == .downArrow { actions.open(state.selectedEntries) }
                        return .handled
                    }
                    let direction: GridKeyboardNavigation.Direction = switch press.key {
                    case .upArrow: .up
                    case .downArrow: .down
                    case .leftArrow: .left
                    default: .right
                    }
                    state.moveSelection(direction, columns: columns.count)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard editingID == nil else { return .ignored }
                    actions.open(state.selectedEntries)
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    guard editingID == nil, let characters = Self.typeSelectCharacters(of: press) else { return .ignored }
                    state.typeSelect(characters)
                    return .handled
                }
                // 編集メニューのコピー・カット・ペースト(段階4)。焦点がこの一覧にあるときだけ届く。
                // ⌘⌫ / ⌥⌘V / ⌘[ / ⌘] は AppKit のキー監視で受ける(FileBrowserKeyMonitor のコメント)。
                .background(FileBrowserKeyMonitor(actions: actions))
                .onCommand(#selector(NSText.copy(_:))) { actions.perform(.copy) }
                .onCommand(#selector(NSText.cut(_:))) { actions.perform(.cut) }
                .onCommand(#selector(NSText.paste(_:))) { actions.perform(.paste) }
                .contextMenu {
                    // 空きスペースの右クリック(セルの上ではセルのメニューが先に出る)。
                    FileBrowserContextMenuItems(
                        context: FileBrowserMenuContext(kind: .background, entries: [], folder: state.currentFolder),
                        actions: actions
                    )
                }
                .onChange(of: state.scrollRequest) { _, request in
                    guard let request else { return }
                    proxy.scrollTo(request.id)
                }
                .welcomeGridPinch(scrollBox: marquee.scrollBox) { [weak state] magnification in
                    guard let state else { return }
                    let range = FileBrowserState.iconSizeRange
                    let next = min(range.upperBound, max(range.lowerBound, state.iconSize * (1 + magnification)))
                    if next != state.iconSize { state.iconSize = next }
                }
            }
        }
        .onChange(of: state.currentFolder) { _, _ in
            // 並ぶものが総入れ替えになったので、前のフォルダのセルの矩形を捨てる(MarqueeSelection.forgetFrames)。
            marquee.forgetFrames()
        }
        .onAppear {
            // リスト表示で頼まれて済んだ依頼を、表示形式を切り替えた直後に拾い直さない。
            appliedRenameSerial = state.renameRequest?.serial
        }
        .onChange(of: state.renameRequest) { _, _ in applyRenameRequest() }
        .onChange(of: state.entriesRevision) { _, _ in
            applyRenameRequest()
            // 編集中の項目が一覧から消えた(外で消された・移された)。欄はセルごと消えて確定済み。
            if let editingID, state.entry(withID: editingID) == nil { self.editingID = nil }
        }
    }

    // MARK: - 名前の変更

    /// 頼まれた項目が一覧にあれば編集を始める。まだ無ければ(新規フォルダの読み直し待ち)一覧が変わったときにもう一度。
    private func applyRenameRequest() {
        guard let request = state.renameRequest, request.serial != appliedRenameSerial,
              let entry = state.entry(withID: request.id)
        else { return }
        appliedRenameSerial = request.serial
        state.finishRenameRequest(request)
        beginEditing(entry)
    }

    private func beginEditing(_ entry: FileBrowserEntry) {
        guard !entry.isVolume else { return }
        clickSerial += 1
        editingText = entry.url.lastPathComponent
        editingID = entry.id
        isFocused = false
    }

    private func commitEditing(_ entry: FileBrowserEntry, name: String) {
        if editingID == entry.id { endEditing() }
        if name != entry.url.lastPathComponent {
            state.operations.rename(entry, to: name)
        }
    }

    private func endEditing() {
        editingID = nil
        isFocused = true
    }

    /// 名前のクリックから編集を始める(型コメント)。ダブルクリックの間隔を待ち、その間に次のクリックが無く、
    /// まだその1件だけを選んでいれば始める。
    private func scheduleRenameFromClick(_ entry: FileBrowserEntry) {
        let serial = clickSerial
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard clickSerial == serial, editingID == nil, state.selection == [entry.id],
                  let current = state.entry(withID: entry.id)
            else { return }
            beginEditing(current)
        }
    }

    /// type-select に使う文字。⌘・⌃・⌥ 付き、制御文字(Return / Tab / Esc / Delete)、矢印などの機能キー
    /// (U+F700〜U+F8FF)は受けない。
    private static func typeSelectCharacters(of press: KeyPress) -> String? {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        let characters = press.characters
        guard !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
                      && scalar.value != 0x7F
              })
        else { return nil }
        return characters
    }

    /// セルの幅。アイコンの大きさに、名前の2行ぶんの横の余裕を足す。
    private var cellWidth: CGFloat {
        max(state.iconSize + 24, 84)
    }

    private func cell(for entry: FileBrowserEntry) -> some View {
        let isSelected = state.selection.contains(entry.id)
        let isEditing = editingID == entry.id
        // 編集中はこのセルのジェスチャーを外し、欄(子の NSView)だけがクリックを受ける。
        let gestureMask: GestureMask = isEditing ? .subviews : .all
        // 名前の上端(アイコンの枠 + 余白 4 + 間隔 4)。これより下のクリックを「名前のクリック」とみなす。
        let nameTop = state.iconSize + 8 + 4
        let isDropTarget = dropTargetID == entry.id
        let iconShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let nameShape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return VStack(spacing: 4) {
            Image(nsImage: FileBrowserIconProvider.icon(for: entry))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: state.iconSize, height: state.iconSize)
                .padding(4)
                .background(iconShape.fill(
                    isDropTarget ? Color.accentColor.opacity(0.35) : isSelected ? Color.primary.opacity(0.12) : Color.clear
                ))
                .panelOutlinedFrame(in: iconShape, isEnabled: isSelected && !isDropTarget)
                .panelOutlinedAccent(in: iconShape, isEnabled: isDropTarget)
            if isEditing {
                FileBrowserIconNameEditor(
                    name: entry.url.lastPathComponent,
                    selectsWholeName: entry.isNavigableFolder,
                    width: cellWidth,
                    text: editingText,
                    onTextChange: { editingText = $0 },
                    onCommit: { name in commitEditing(entry, name: name) },
                    onCancel: { endEditing() }
                )
                .frame(width: cellWidth)
            } else {
                Text(entry.displayName)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .panelOutlinedContent(isEnabled: !isSelected)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .background(nameShape.fill(isSelected ? Color.accentColor : Color.clear))
                    .panelOutlinedAccent(in: nameShape, isEnabled: isSelected)
            }
        }
        .frame(width: cellWidth)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded {
            clickSerial += 1
            actions.open([entry])
        }, including: gestureMask)
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            isFocused = true
            let modifier = Self.currentClickModifier
            let wasOnlySelection = state.selection == [entry.id]
            let now = ProcessInfo.processInfo.systemUptime
            let isSecondClick = lastTap.map { $0.id == entry.id && now - $0.time < NSEvent.doubleClickInterval } ?? false
            lastTap = (entry.id, now)
            clickSerial += 1
            state.click(entry.id, modifier: modifier)
            // ダブルクリックの2回目では始めない。
            if modifier == .none, wasOnlySelection, !isSecondClick,
               value.location.y >= nameTop, !entry.isVolume {
                scheduleRenameFromClick(entry)
            }
        }, including: gestureMask)
        .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in
            // 掴んだセルが選ばれていなければ、その1件だけを選び直して運ぶ(型コメント)。
            if !state.selection.contains(entry.id) { state.click(entry.id, modifier: .none) }
            clickSerial += 1
            dragHandle.beginIfNeeded(
                gestureStart: value.startLocation, entries: state.selectedEntries, iconSize: state.iconSize
            )
        }, including: gestureMask)
        .modifier(FileBrowserFolderDropTarget(
            entry: entry, actions: actions,
            onTargetChange: { isTargeted in
                if isTargeted {
                    dropTargetID = entry.id
                } else if dropTargetID == entry.id {
                    dropTargetID = nil
                }
            }
        ))
        .opacity(state.isCut(entry) ? 0.5 : 1)
        .contextMenu {
            FileBrowserContextMenuItems(
                context: FileBrowserMenuContext(
                    kind: .of(entry), entries: contextTargets(for: entry), folder: state.currentFolder
                ),
                actions: actions
            )
        }
        .help(entry.displayName)
    }

    /// 右クリックの対象: 選択に含まれていればその全部、外ならその1件だけ(選択は変えない)。
    private func contextTargets(for entry: FileBrowserEntry) -> [FileBrowserEntry] {
        state.selection.contains(entry.id) ? state.selectedEntries : [entry]
    }

    private static var currentClickModifier: FileBrowserState.ClickModifier {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command) { return .toggle }
        if flags.contains(.shift) { return .range }
        return .none
    }
}

/// アイコン表示のファイル操作のキー(⌘⌫ / ⌥⌘V / ⌘[ / ⌘])を、このビューが出ている間だけ受ける。
///
/// ■ なぜ `.onKeyPress` ではないのか
/// `.onKeyPress(phases:)` でも、キーを列挙した `.onKeyPress(keys:)` でも、ScrollView に焦点がある状態で
/// ⌘⌫ と ⌘[ が届かなかった(⌘↑ は矢印キーの `.onKeyPress` で届いた。段階4の実機検証 2026-09-13、macOS 26.6)。
/// リストは `NSTableView.keyDown` で同じキーを受けているので、割り当ては `FileBrowserEditCommand.forKey` を共有する。
///
/// ■ 受けない場合
/// 別のウインドウのキー、**テキストを編集中**(検索欄での ⌘⌫ は行頭まで消す操作)。監視は
/// `dismantleNSView` で必ず外す(CLAUDE.md: 閉包がウインドウより長生きしてリークする)。
struct FileBrowserKeyMonitor: NSViewRepresentable {
    let actions: FileBrowserActions

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view, actions: actions)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.actions = actions
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var actions: FileBrowserActions?
        private weak var view: NSView?
        private var monitor: Any?

        func install(on view: NSView, actions: FileBrowserActions) {
            self.view = view
            self.actions = actions
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // NSEvent は Sendable でないので、メインアクターの閉包へは値だけを渡す(Swift 6)。
                let windowNumber = event.windowNumber
                let keyCode = event.keyCode
                let flags = event.modifierFlags
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.view?.window, windowNumber == window.windowNumber,
                          !((window.firstResponder as? NSTextView)?.isEditable ?? false),
                          let command = FileBrowserEditCommand.forKey(keyCode: keyCode, flags: flags), command != .goUp,
                          let actions = self.actions
                    else { return false }
                    actions.perform(command)
                    return true
                }
                return handled ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            actions = nil
        }
    }
}

/// フォルダのセルだけを受け口にする(ファイルのセルに付けると、右ペイン全体の受け口 = 表示中のフォルダへ
/// 落ちなくなる)。
private struct FileBrowserFolderDropTarget: ViewModifier {
    let entry: FileBrowserEntry
    let actions: FileBrowserActions
    let onTargetChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if entry.isNavigableFolder {
            content.onDrop(
                of: [.fileURL],
                delegate: FileBrowserDropDelegate(destination: entry.url, actions: actions, onTargetChange: onTargetChange)
            )
        } else {
            content
        }
    }
}
