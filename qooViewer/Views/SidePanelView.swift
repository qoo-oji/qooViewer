import SwiftUI
import AppKit

/// サイドパネル本体。既定では常時表示、表示メニューの「サイドパネルを隠す」がONのときだけ
/// ウインドウ左端へのホバーで一時的に表示される(ContentView参照)。上段(folderState、
/// フォルダブラウザ)は常に表示し、下段(bookContentsState、本の中身ブラウザ)は本を開いていて
/// 対応フォーマット(フォルダ、またはzip/cbz/rar/cbr/7z/cb7)のときだけ、ドラッグでサイズ
/// 調整可能な形で追加表示する。PDF/EPUBはページがファイル単位で存在しない、またはzip
/// コンテナの生の中身を見せてもかえって分かりづらいため下段は非表示のまま
/// (BookContentsBrowserState.init?がnilを返す)。
///
/// 背景はViewerView.swiftの他のパネル(サムネイル一覧・Get Info)と違い自身で持つ
/// (フローティングカードではなく左端フル高さのサイドバーとして背景を持つ。
/// SidebarVisualEffectView参照)。ユーザー要望により、ページ表示エリアなどパネルの外側を
/// クリックしても閉じない(常時表示が既定のため、クリックで閉じる仕組みは本を読む操作の
/// 妨げになる)。
struct SidePanelView: View {
    /// 初期・既定の幅。ContentView側の@State(sidePanelWidth)の初期値として使う。
    static let defaultWidth: CGFloat = 280
    private static let widthRange: ClosedRange<CGFloat> = 220...480

    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var folderState: SidePanelBrowserState
    var bookContentsState: BookContentsBrowserState?
    /// パネルの幅。ContentViewが@Stateとして保持し、Bindingで渡す(ドッキング表示・
    /// ホバーオーバーレイ表示のどちらでも同じ幅を共有するため)。右端のドラッグハンドルで
    /// ユーザーが調整できる。
    @Binding var width: CGFloat
    /// 下段のダブルクリックで、クリックした画像が本の何ページ目かを特定するための一覧
    /// (AppState.currentBookPages。並び替え/除外の変更を追従できるよう、本を開いた時点の
    /// スナップショットではなく最新値をContentViewから渡してもらう)。
    var bookPages: [PageRef]
    /// 一覧のファイル/フォルダを本として開く(上段のファイル・フォルダ行、下段の
    /// 「新しい本として開く」フォールバックの両方から呼ばれる)。呼び出し側でパネルを
    /// 閉じてからAppState.open(url:)を行う。
    var onOpen: (URL) -> Void
    /// 下段で、既に本のページ一覧に含まれている画像をダブルクリックしたときのジャンプ。
    var onJumpToPage: (Int) -> Void

    @State private var topSectionFraction: CGFloat = 0.5
    @GestureState private var dragOffset: CGFloat = 0
    @GestureState private var widthDragOffset: CGFloat = 0

    /// ドラッグ中、ContentView.body(HStack)がこのパネルのために確保する幅・パネル自身の
    /// 中身(panelBody)の幅とも、ライブな値(effectiveWidth)に追随させている。以前は
    /// どちらも確定値(width)のまま固定し、ドラッグ中はマテリアル背景だけを伸縮させていた
    /// (HStackの再レイアウトを通じてViewerView側のGeometryReaderによる画像再スケーリングや、
    /// panelBody自身のGeometryReader+ScrollView+LazyVStackが毎フレーム再計算されると
    /// 描画が追いつかず振動して見える不具合があったため)。ドラッグハンドル自体の震え
    /// (widthDragHitAreaのコメント参照、ハンドルの位置が自分自身のジェスチャー出力に
    /// 依存する自己参照ループが原因)を解決した後にあらためて試したところ問題なく追随できた
    /// ため、ライブ追従に戻した。実機で重さが気になるようなら、この2箇所を再びwidthへ
    /// 戻せば以前の(背景だけライブな)方式に戻せる。
    var body: some View {
        Color.clear
            .frame(width: effectiveWidth)
            .frame(maxHeight: .infinity)
            .transaction { $0.animation = nil }
            .overlay(alignment: .leading) {
                SidebarVisualEffectView()
                    .frame(width: effectiveWidth)
                    .frame(maxHeight: .infinity)
                    .transaction { $0.animation = nil }
            }
            .overlay(alignment: .leading) {
                panelBody
                    .frame(width: effectiveWidth)
                    .frame(maxHeight: .infinity)
                    .transaction { $0.animation = nil }
            }
            // ドラッグの当たり判定を持つビュー(widthDragHitArea)自体は、レイアウト上も
            // 見た目上も一切動かさない(offsetも含めて)。ジェスチャーを載せているビュー
            // 自身の位置・オフセットがそのジェスチャー自身の出力(widthDragOffset)に
            // 依存してしまうと、値がわずかでも動くたびにジェスチャーの基準座標がずれて
            // 再計算され、それがまた値を動かす……という自己参照ループになり、ドラッグの
            // 方向・量に応じて震えて見える不具合になっていた(ユーザー報告: 縮小方向は
            // 小刻みに、拡大方向は大きく震える ― offset(x: effectiveWidth - 3)という、
            // ハンドル自身の出力に依存するoffsetを与えていたのが原因)。
            .overlay(alignment: .leading) {
                widthDragHitArea
            }
            // 見た目としてドラッグ位置を追従させる表示は、当たり判定を持たない別のビュー
            // (widthDragIndicator)に分離する。こちらはジェスチャーを一切持たないため、
            // 自己参照ループが起きようがない。
            .overlay(alignment: .leading) {
                widthDragIndicator
            }
            .zIndex(1)
    }

    private var panelBody: some View {
        Group {
            if let bookContentsState {
                GeometryReader { geometry in
                    let fraction = effectiveTopFraction(totalHeight: geometry.size.height)
                    VStack(spacing: 0) {
                        folderSection
                            .frame(height: max(80, geometry.size.height * fraction - 4))
                            .clipped()
                        dragHandle(totalHeight: geometry.size.height)
                        BookContentsSectionView(
                            state: bookContentsState,
                            bookPages: bookPages,
                            onOpen: onOpen,
                            onJumpToPage: onJumpToPage
                        )
                        .frame(maxHeight: .infinity)
                        .clipped()
                    }
                }
            } else {
                folderSection
            }
        }
    }

    private var effectiveWidth: CGFloat {
        Self.clampWidth(width + widthDragOffset)
    }

    private static func clampWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    /// パネル右端(ビューアとの境界)の幅調整用、ドラッグの当たり判定だけを持つ透明な領域。
    /// 上下分割のdragHandleと違い、こちらは意図的に**見た目上・レイアウト上まったく
    /// 動かさない**(常に確定済みのwidth基準の位置に固定)。DragGesture自身の出力
    /// (widthDragOffset)にこのビュー自身の位置を依存させてしまうと、自己参照の
    /// フィードバックループでドラッグ中に震えて見える不具合になるため(widthDragIndicator
    /// 参照)。.overlay(alignment: .leading)の基準(x:0、パネル左端)から、確定済みの
    /// width(ドラッグ中も変化しない値なのでフィードバックループの心配は無い)を使って
    /// パネル右端(境界)へ移動させている。
    private var widthDragHitArea: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: width - 3)
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($widthDragOffset) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        width = Self.clampWidth(width + value.translation.width)
                    }
            )
    }

    /// ドラッグ中、現在の確定予定位置を示す見た目だけの縦線。widthDragHitAreaとは別の
    /// ビュー(ジェスチャーを持たない)にすることで、自己参照ループを避けている。
    @ViewBuilder
    private var widthDragIndicator: some View {
        if widthDragOffset != 0 {
            Rectangle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: effectiveWidth - 1)
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
        }
    }

    private func effectiveTopFraction(totalHeight: CGFloat) -> CGFloat {
        guard totalHeight > 0 else { return topSectionFraction }
        return Self.clampFraction(topSectionFraction + dragOffset / totalHeight)
    }

    private static func clampFraction(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.15), 0.85)
    }

    private func dragHandle(totalHeight: CGFloat) -> some View {
        ZStack {
            Color.primary.opacity(0.0001)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 2)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    guard totalHeight > 0 else { return }
                    topSectionFraction = Self.clampFraction(topSectionFraction + value.translation.height / totalHeight)
                }
        )
    }

    // MARK: - 上段(フォルダブラウザ)

    private var folderSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SidePanelNavButton(systemName: "chevron.left", isDisabled: !folderState.canGoBack, help: "Back") {
                    folderState.goBack()
                }
                SidePanelNavButton(systemName: "chevron.right", isDisabled: !folderState.canGoForward, help: "Forward") {
                    folderState.goForward()
                }
                SidePanelNavButton(systemName: "arrow.up", isDisabled: !folderState.canGoUp, help: "Enclosing Folder") {
                    folderState.goUp()
                }
                Spacer(minLength: 0)
            }
            .padding(10)

            Text(folderState.currentDirectory.map(DirectoryBrowser.displayName(for:)) ?? String(localized: "Computer"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .help(folderState.currentDirectory?.path ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if folderState.needsFolderAccessGrant {
                VStack(spacing: 8) {
                    Text("This folder isn't accessible yet.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Grant Access…") { folderState.requestFolderAccess() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(folderState.entries) { entry in
                                folderRow(entry)
                            }
                        }
                    }
                    // ScrollView(NSScrollViewをラップ)は既定でキーボードフォーカスを受け取れる。
                    // このパネルはクリック操作のみを想定しているため、Tabキーでの移動などで
                    // 意図せずスクロール領域へフォーカスが移らないようにしておく
                    // (フォーカスリング自体の抑制はContentView.body側の
                    // .focusEffectDisabled()で行っている)。
                    .focusable(false)
                    .onChange(of: folderState.entries) { _, _ in
                        guard let highlighted = folderState.highlightedURL else { return }
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(highlighted.path, anchor: .center) }
                        }
                    }
                }
            }
        }
    }

    private func folderRow(_ entry: DirectoryBrowser.Entry) -> some View {
        // entry.urlはFileManagerが返した素のURL、highlightedURLは(最近使ったファイルなど
        // 経由の場合)セキュリティスコープ付きブックマークから解決したURLであることがあり、
        // パスの文字列は同じでも素のURL同士の==比較が一致しないことがある。下のscrollTo側は
        // 既にEntry.id(= url.path)を使っておりこの問題を回避できているため、ここも合わせて
        // パス文字列で比較する。
        let isHighlighted = entry.url.path == folderState.highlightedURL?.path
        let label = rowLabel(
            icon: iconName(fileName: entry.isDirectory ? nil : entry.url.lastPathComponent, isDirectory: entry.isDirectory),
            name: entry.displayName
        )
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)

        return Group {
            if entry.isDirectory {
                if preferences.sidePanelUsesDoubleClick {
                    // シングルクリックが使えないため、「移動する」「画像フォルダとして開く」の
                    // 2つの意味をダブルクリック1つに割り当てる必要がある。直下に画像ファイルが
                    // あれば開く、無ければ移動する、で判定する(ユーザー要望)。
                    label.onTapGesture(count: 2) { handleFolderDoubleClick(entry) }
                } else {
                    label
                        .onTapGesture(count: 2) { onOpen(entry.url) }
                        .onTapGesture(count: 1) { folderState.navigate(into: entry.url) }
                }
            } else {
                label.onTapGesture(count: preferences.sidePanelUsesDoubleClick ? 2 : 1) { onOpen(entry.url) }
            }
        }
    }

    private func handleFolderDoubleClick(_ entry: DirectoryBrowser.Entry) {
        if DirectoryBrowser.directlyContainsImageFile(entry.url) {
            onOpen(entry.url)
        } else {
            folderState.navigate(into: entry.url)
        }
    }

    private func rowLabel(icon: String, name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func iconName(fileName: String?, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        guard let fileName else { return "doc" }
        if isArchiveFile(fileName) { return "doc.zipper" }
        if isPDFFile(fileName) { return "doc.richtext" }
        if isEpubFile(fileName) { return "book" }
        return "doc"
    }
}

/// サイドパネル下段(本の中身ブラウザ)。@ObservedObjectはOptionalなObservableObjectを
/// 直接ラップできないため、親(SidePanelView)がbookContentsStateの有無で表示自体を
/// 出し分け、非nilのときだけこの専用のView(stateを非Optionalで受け取る)を使う構成にしている。
private struct BookContentsSectionView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var state: BookContentsBrowserState
    var bookPages: [PageRef]
    var onOpen: (URL) -> Void
    var onJumpToPage: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SidePanelNavButton(systemName: "chevron.left", isDisabled: !state.canGoBack, help: "Back") {
                    state.goBack()
                }
                SidePanelNavButton(systemName: "chevron.right", isDisabled: !state.canGoForward, help: "Forward") {
                    state.goForward()
                }
                SidePanelNavButton(systemName: "arrow.up", isDisabled: !state.canGoUp, help: "Enclosing Folder") {
                    state.goUp()
                }
                Spacer(minLength: 0)
            }
            .padding(10)

            // ユーザー要望: 本の中の階層を移動しているときは、今どこにいるか分かるよう
            // ボタンの下にフォルダ/書庫のファイル名を表示する。ルート階層(本自身)にいる
            // ときはstate.currentLocationNameがnilになり、この行自体を出さない。
            if let locationName = state.currentLocationName {
                Text(locationName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .help(locationName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if let errorMessage = state.navigationErrorMessage {
                VStack {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(state.entries) { entry in
                                row(for: entry)
                            }
                        }
                    }
                    // folderSectionの同名の.focusable(false)と同じ理由。
                    .focusable(false)
                    // ページ送りでハイライト対象が変わるたび、またはハイライト対象を含む
                    // 新しい階層へ切り替わって一覧そのものが変わるたびに、その行が常に
                    // 表示枠内に見えるようスクロールする(ユーザー要望)。
                    .onChange(of: state.highlightedMatchKeys) { _, _ in scrollToHighlighted(proxy: proxy) }
                    .onChange(of: state.entries) { _, _ in scrollToHighlighted(proxy: proxy) }
                }
            }
        }
    }

    private func scrollToHighlighted(proxy: ScrollViewProxy) {
        guard let target = state.entries.first(where: { state.highlightedMatchKeys.contains($0.matchKey) }) else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target.id, anchor: .center) }
        }
    }

    private func row(for entry: BookInternalBrowsing.Entry) -> some View {
        let isHighlighted = state.highlightedMatchKeys.contains(entry.matchKey)
        let label = HStack(spacing: 8) {
            Image(systemName: icon(for: entry))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(entry.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)

        // 下段のコンテナ・画像はどちらも1つの意味しか持たない(上段のフォルダのような
        // 「移動する」「開く」の使い分けが無い)ため、設定に応じてクリック回数を
        // そのまま切り替えるだけでよい。
        let clickCount = preferences.sidePanelUsesDoubleClick ? 2 : 1
        return Group {
            if entry.isContainer {
                label.onTapGesture(count: clickCount) { state.navigate(entry) }
            } else if entry.isImage {
                label.onTapGesture(count: clickCount) { handleImageClick(entry) }
            } else {
                label
            }
        }
    }

    private func icon(for entry: BookInternalBrowsing.Entry) -> String {
        if entry.isImage { return "photo" }
        switch entry.navigateTarget {
        case .realFolder, .archiveVirtualFolder:
            return "folder"
        case .archiveFileOnDisk, .nestedArchiveEntry:
            return "doc.zipper"
        case nil:
            return "doc"
        }
    }

    private func handleImageClick(_ entry: BookInternalBrowsing.Entry) {
        switch state.resolveImageClick(on: entry, bookPages: bookPages) {
        case .jumpToPage(let index):
            onJumpToPage(index)
        case .openAsNewBook(let url):
            onOpen(url)
        case .unavailable:
            break
        }
    }
}

/// 上段・下段で共通の、戻る/進む/1階層上への移動ボタン。ユーザー要望: 既定のボタンサイズは
/// 小さく操作しづらいため、アイコンサイズ・タップ領域とも一回り大きくしている。
private struct SidePanelNavButton: View {
    let systemName: String
    let isDisabled: Bool
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help(help)
    }
}

/// サイドパネルの背景に使う、AppKit本来の「サイドバー」用マテリアル
/// (NSVisualEffectView.Material.sidebar)。SwiftUIの.background(.regularMaterial)は
/// 汎用のマテリアルのため、フル高さでタイトルバー直下から続くサイドバー配置だと、
/// ウインドウがキーのときだけ境界に沿って青いアクセントカラーの線が描画されてしまう
/// 不具合が実機で確認された(SidePanelView.bodyのコメント参照)。実際のFinder等のサイドバーと
/// 同じ.sidebarマテリアルを直接指定することでこれを回避する。
private struct SidebarVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        // .behindWindowは、ウインドウの「背後」(デスクトップ/他のウインドウ)を透過して
        // 見せる方式で、ウインドウ全面がマテリアルになる典型的なサイドバー構成を想定した
        // モード。本アプリはウインドウの一部(このパネルの幅)だけがマテリアルで、残り
        // (ViewerView)は不透明なSwiftUIコンテンツという構成のため、ドラッグでパネルを
        // 拡大してViewerView側の描画領域へ一時的にはみ出す瞬間、.behindWindowのサンプリング
        // 対象(ウインドウの背後)と、そこに重なって描画され続けているViewerViewの不透明な
        // 内容とが競合し、拡大方向へドラッグしたときだけ震えて見える不具合が実機で確認
        // された(縮小方向は単に隠れていた領域を再び見せるだけのため問題が起きなかった)。
        // 同じウインドウ内の描画を基準にする.withinWindowに変更することでこれを避ける。
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
