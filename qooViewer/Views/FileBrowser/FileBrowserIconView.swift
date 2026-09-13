import AppKit
import SwiftUI

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
/// ■ 輪郭(すりガラス面の決まりごと)
/// - 名前 → 未選択は`.panelOutlinedContent()`、選択中はアクセント地なので`.panelOutlinedAccent(in:)`
/// - アイコン → 種類のアイコン(色付きの絵)なので掛けない。選択中の地(薄い灰)は
///   `.panelOutlinedFrame(in:)`で縁取る(薄い地だけでは面の色に溶ける)
struct FileBrowserIconView: View {
    @ObservedObject var state: FileBrowserState
    let actions: FileBrowserActions

    @State private var marquee = MarqueeSelection()
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
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
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
                    actions.open(state.selectedEntries)
                    return .handled
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
    }

    /// セルの幅。アイコンの大きさに、名前の2行ぶんの横の余裕を足す。
    private var cellWidth: CGFloat {
        max(state.iconSize + 24, 84)
    }

    private func cell(for entry: FileBrowserEntry) -> some View {
        let isSelected = state.selection.contains(entry.id)
        let iconShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let nameShape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return VStack(spacing: 4) {
            Image(nsImage: FileBrowserIconProvider.icon(for: entry))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: state.iconSize, height: state.iconSize)
                .padding(4)
                .background(iconShape.fill(isSelected ? Color.primary.opacity(0.12) : Color.clear))
                .panelOutlinedFrame(in: iconShape, isEnabled: isSelected)
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
        .frame(width: cellWidth)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            actions.open([entry])
        }
        .simultaneousGesture(TapGesture().onEnded {
            isFocused = true
            state.click(entry.id, modifier: Self.currentClickModifier)
        })
        .contextMenu {
            FileBrowserContextMenuItems(entries: contextTargets(for: entry), actions: actions)
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
