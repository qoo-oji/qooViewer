import SwiftUI
import AppKit
import SwiftData
import CoreGraphics

struct ViewerView: View {
    @StateObject private var viewModel: ViewerViewModel
    @ObservedObject private var preferences: AppPreferences
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var keyBindingStore: KeyBindingStore
    @FocusState private var isFocused: Bool
    @State private var scrollMonitor: Any?
    @State private var isCursorHidden = false
    @State private var cursorHideTask: Task<Void, Never>?
    /// メニューバーのメニュー(このアプリのもの)が現在開いているかどうか。開いている間は
    /// カーソルが動かなくても自動的には隠さない(NSMenu.didBeginTracking/didEndTracking参照)。
    @State private var isMenuTracking = false
    @State private var showThumbnailGrid = false
    @State private var showBookmarkList = false
    /// このビューを表示しているウインドウ本体。フルスクリーンの入退場通知の登録・解除や、
    /// マウス位置と画面端との距離判定に使う。
    @State private var hostWindow: NSWindow?
    /// 現在フルスクリーン表示中かどうか。
    @State private var isFullScreen = false
    /// 自動隠し中のツールバー・スクラバーを、マウスが画面端に近いために一時的に表示しているか
    /// どうか。フルスクリーン中、またはウインドウ表示でもhideToolbar/hideProgressBarが
    /// ONのときに使われる(自動隠しが有効でないときは常にtrue相当として扱う。bodyの表示条件参照)。
    @State private var isAutoHiddenChromeRevealed = true
    /// NSWindow.didEnterFullScreenNotification / didExitFullScreenNotification /
    /// didResignKeyNotification のオブザーバートークン。onDisappearで確実に解除するために保持する。
    @State private var windowObservers: [NSObjectProtocol] = []
    /// Fileメニューの「閉じる」(Cmd+W)を「本を閉じる」動作に変更するためのウインドウデリゲート。
    /// NSWindow.delegateは弱参照のため、ここで強参照を保持しておかないと解放されてしまう。
    @State private var bookClosingDelegate: BookClosingWindowDelegate?

    init(book: MangaBook, modelContext: ModelContext, preferences: AppPreferences) {
        _viewModel = StateObject(
            wrappedValue: ViewerViewModel(book: book, modelContext: modelContext, preferences: preferences)
        )
        _preferences = ObservedObject(wrappedValue: preferences)
    }

    var body: some View {
        // フルスクリーン表示中は、表示メニューの「ツールバーを隠す」「プログレスバーを隠す」の
        // 設定に関わらず、常に自動隠しになる。ウインドウ表示のときは、それぞれの設定がONの
        // ときだけ自動隠しになる(OFFなら常に表示)。
        let toolbarAutoHides = isFullScreen || appState.hideToolbar
        let progressBarAutoHides = isFullScreen || appState.hideProgressBar
        // 自動隠し中のツールバー・プログレスバーを、マウスが画面端に近づいたことで
        // 一時的に表示している状態かどうか。
        let showToolbarOverlay = toolbarAutoHides && isAutoHiddenChromeRevealed
        let showProgressBarOverlay = progressBarAutoHides && isAutoHiddenChromeRevealed

        // 自動隠しでない(常に表示する)ときは、以前と同じくVStackの一部として組み込み、
        // 画像表示エリアはその分だけ縮んだ残りの領域を使う。
        // 一方、自動隠し中にマウスを近づけて一時的に表示するときは、画像表示エリアの
        // サイズを一切変えたくない(表示するたびに画像が拡大縮小されるのを避けるため)ので、
        // ZStackで画像の上に半透明のパネルとして重ねて表示する形にしている。
        ZStack {
            VStack(spacing: 0) {
                if !toolbarAutoHides {
                    toolbar
                    Divider()
                }
                pageArea
                    .contextMenu {
                        contextMenuContent
                    }
                if !progressBarAutoHides {
                    PageScrubberView(viewModel: viewModel)
                }
            }

            if toolbarAutoHides {
                VStack(spacing: 0) {
                    toolbar
                        .background(.ultraThinMaterial)
                    Spacer(minLength: 0)
                }
                .opacity(showToolbarOverlay ? 1 : 0)
                .allowsHitTesting(showToolbarOverlay)
                .animation(.easeInOut(duration: 0.15), value: showToolbarOverlay)
            }

            if progressBarAutoHides {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PageScrubberView(viewModel: viewModel)
                        .background(.ultraThinMaterial)
                }
                .opacity(showProgressBarOverlay ? 1 : 0)
                .allowsHitTesting(showProgressBarOverlay)
                .animation(.easeInOut(duration: 0.15), value: showProgressBarOverlay)
            }
        }
        .background(preferences.backgroundColorOption.color)
        .background(WindowAccessor { window in
            guard hostWindow !== window else { return }
            hostWindow = window
            setUpWindowObservers(for: window)
        })
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            viewModel.onRequestSiblingBook = { forward in
                if forward {
                    appState.openSibling(after: viewModel.book.sourceURL)
                } else {
                    appState.openSibling(before: viewModel.book.sourceURL)
                }
            }
            appState.performViewerAction = { action in
                perform(action)
            }
            // メニューバーの「ブックマーク」メニュー下部に、現在の本のブックマーク一覧を
            // 表示するための橋渡し(詳細はAppState.swiftのコメント参照)。
            appState.jumpToBookmark = { bookmark in
                viewModel.jump(to: bookmark)
            }
            appState.updateCurrentBookmarks(viewModel.bookmarks)
            // メニューバーの「表示モード切替」サブメニューから、特定のモードへ直接切り替える
            // ための橋渡し。
            appState.setScalingMode = { mode in
                viewModel.setScalingMode(mode)
            }
            // メニューバーの「スライドショー」「見開き」「右から左へ」「表示モード切替」の
            // 左に表示するチェックマークのための、現在値の初期反映。
            appState.updateMenuCheckmarkState(
                isSlideshowActive: viewModel.isSlideshowActive,
                displayMode: viewModel.displayMode,
                readingDirection: viewModel.readingDirection,
                scalingMode: viewModel.scalingMode
            )
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .mouseMoved]) { event in
                // NSEvent.addLocalMonitorForEventsは「このアプリのどのウインドウ宛てのイベントか」に
                // 関わらず、アプリ全体のイベントを受け取ってしまう。複数のウインドウ(タブ)を
                // 開けるようになったため、ここでイベント自身の宛先ウインドウ(event.window)が
                // 自分自身のウインドウ(hostWindow)と一致するときだけ処理するようにする。
                // これがないと、スクロール操作が他のqooViewerウインドウはもちろん、
                // 環境設定ウインドウやファイル選択パネルにまで影響してしまう。
                guard let hostWindow, event.window === hostWindow else { return event }
                switch event.type {
                case .scrollWheel:
                    handleScroll(deltaY: event.scrollingDeltaY)
                case .swipe:
                    handleSwipe(deltaX: event.deltaX)
                default:
                    registerMouseActivity()
                    updateAutoHiddenChromeVisibility(forMouseLocationInWindow: event.locationInWindow)
                }
                return event
            }
        }
        .onDisappear {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
            }
            scrollMonitor = nil
            if appState.performViewerAction != nil {
                appState.performViewerAction = nil
            }
            appState.jumpToBookmark = nil
            appState.updateCurrentBookmarks([])
            appState.setScalingMode = nil
            appState.resetMenuCheckmarkState()
            viewModel.stopSlideshow()
            viewModel.flushPendingSave()
            cursorHideTask?.cancel()
            cursorHideTask = nil
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers = []
        }
        .onKeyPress(phases: .down) { press in
            guard let key = RemappableKey.from(press) else { return .ignored }
            guard let action = keyBindingStore.action(for: key) else { return .ignored }
            perform(action)
            return .handled
        }
        // ブックマークの追加/削除/名前変更のたびに、メニューバーの「ブックマーク」メニュー
        // 下部の一覧を最新の内容に更新する。
        .onChange(of: viewModel.bookmarks) { _, newValue in
            appState.updateCurrentBookmarks(newValue)
        }
        // スライドショー実行中/表示モード/読み方向/拡大縮小モードが変わるたびに、
        // メニューバーの該当項目のチェックマークを最新の状態に更新する。
        .onChange(of: viewModel.isSlideshowActive) { _, newValue in
            appState.updateMenuCheckmarkState(
                isSlideshowActive: newValue,
                displayMode: viewModel.displayMode,
                readingDirection: viewModel.readingDirection,
                scalingMode: viewModel.scalingMode
            )
        }
        .onChange(of: viewModel.displayMode) { _, newValue in
            appState.updateMenuCheckmarkState(
                isSlideshowActive: viewModel.isSlideshowActive,
                displayMode: newValue,
                readingDirection: viewModel.readingDirection,
                scalingMode: viewModel.scalingMode
            )
        }
        .onChange(of: viewModel.readingDirection) { _, newValue in
            appState.updateMenuCheckmarkState(
                isSlideshowActive: viewModel.isSlideshowActive,
                displayMode: viewModel.displayMode,
                readingDirection: newValue,
                scalingMode: viewModel.scalingMode
            )
        }
        .onChange(of: viewModel.scalingMode) { _, newValue in
            appState.updateMenuCheckmarkState(
                isSlideshowActive: viewModel.isSlideshowActive,
                displayMode: viewModel.displayMode,
                readingDirection: viewModel.readingDirection,
                scalingMode: newValue
            )
        }
        .sheet(isPresented: $showThumbnailGrid) {
            ThumbnailGridView(viewModel: viewModel)
        }
        .sheet(isPresented: $showBookmarkList) {
            BookmarkListView(viewModel: viewModel)
        }
        // 環境設定「本を再度開いたときの動作」が「問い合わせる」のときだけ、
        // 前回位置から再開するかどうかを尋ねる(ViewerViewModel.init参照)。
        .alert(
            "Resume from where you left off?",
            isPresented: Binding(
                get: { viewModel.needsResumeConfirmation },
                set: { isPresented in
                    if !isPresented {
                        viewModel.confirmResumeFromLastPage(true)
                    }
                }
            )
        ) {
            Button("Start from Beginning") {
                viewModel.confirmResumeFromLastPage(false)
            }
            Button("Resume") {
                viewModel.confirmResumeFromLastPage(true)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            // ページ移動・ファイル移動のボタン群。ブラウザの「戻る」「進む」ボタンのように、
            // ファイル名表示(アドレスバー相当)より左側に配置する。

            // 次の画像/前の画像(見開き時は2枚、単ページ時は1枚移動。読み方向によって左右の意味が入れ替わる)
            HStack(spacing: 4) {
                Button {
                    viewModel.advance(forward: viewModel.readingDirection == .rightToLeft)
                } label: {
                    Image(systemName: "chevron.left.2")
                }
                .help(
                    viewModel.readingDirection == .rightToLeft
                        ? "Next Image (2 in spread view, 1 in single-page view)"
                        : "Previous Image (2 in spread view, 1 in single-page view)"
                )

                Button {
                    viewModel.advance(forward: viewModel.readingDirection == .leftToRight)
                } label: {
                    Image(systemName: "chevron.right.2")
                }
                .help(
                    viewModel.readingDirection == .leftToRight
                        ? "Next Image (2 in spread view, 1 in single-page view)"
                        : "Previous Image (2 in spread view, 1 in single-page view)"
                )
            }

            // 1枚だけ次の画像/前の画像(見開きのページの組み合わせがずれたときの調整用)
            HStack(spacing: 4) {
                Button {
                    viewModel.shiftByOnePage(forward: viewModel.readingDirection == .rightToLeft)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help(
                    viewModel.readingDirection == .rightToLeft
                        ? "Next Image by One (to adjust misaligned spread pairs)"
                        : "Previous Image by One (to adjust misaligned spread pairs)"
                )

                Button {
                    viewModel.shiftByOnePage(forward: viewModel.readingDirection == .leftToRight)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help(
                    viewModel.readingDirection == .leftToRight
                        ? "Next Image by One (to adjust misaligned spread pairs)"
                        : "Previous Image by One (to adjust misaligned spread pairs)"
                )
            }

            // 前の本へ/次の本へ(同じフォルダ内の、同じ種類[アーカイブ/PDFファイルまたはフォルダ]の
            // 本の間を移動する。読み方向に関係なく、上が前、下が次。詳細はSiblingFinder参照)
            HStack(spacing: 4) {
                Button {
                    appState.openSibling(before: viewModel.book.sourceURL)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous Book")

                Button {
                    appState.openSibling(after: viewModel.book.sourceURL)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next Book")
            }

            Spacer()

            // ファイル名表示。ブラウザのアドレスバーのように、ツールバー中央に配置する
            // (前後のSpacerが左右の残り幅を均等に分け合うことで中央寄せになる)。
            Text(viewModel.book.title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button {
                showBookmarkList = true
            } label: {
                Image(systemName: "bookmark")
            }
            .help("Bookmark List")

            Button {
                viewModel.addBookmark()
            } label: {
                Image(systemName: "bookmark.fill")
            }
            .help("Add Current Page to Bookmarks")

            Button {
                showThumbnailGrid = true
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .help("Show Page Grid")

            Button {
                viewModel.toggleSlideshow()
            } label: {
                Image(systemName: viewModel.isSlideshowActive ? "pause.fill" : "play.fill")
            }
            .help("Start/Stop Slideshow")
        }
        .padding(10)
    }

    /// ページ表示エリアを右クリックしたときのコンテキストメニュー。ページ移動・ブック移動を
    /// サブメニューにまとめ、見開き・読み方向・ブックマーク追加・スライドショー・フルスクリーンを
    /// 単独の項目として並べる。メニューバー(QooViewerApp.swiftのCommandGroup/CommandMenu)とは
    /// 異なり、ここではこのビュー自身の@StateObjectであるviewModelを直接参照できるため、
    /// チェックマークの更新にFocusedValueの値型変換のような回避策は不要
    /// (bodyがviewModelの@Publishedプロパティの変化のたびに再評価されるため)。
    /// 各アクションは、キーボードショートカットやメニューバーと同じ経路(perform(_:))を
    /// そのまま呼ぶことで、実装の重複や挙動のズレを防いでいる。
    @ViewBuilder
    private var contextMenuContent: some View {
        let isRightToLeft = viewModel.readingDirection == .rightToLeft

        Menu("Page Navigation") {
            Button("Move to Next") {
                perform(isRightToLeft ? .spatialLeft : .spatialRight)
            }
            Button("Move to Previous") {
                perform(isRightToLeft ? .spatialRight : .spatialLeft)
            }

            Divider()

            Button("Shift One Page to Next") {
                perform(isRightToLeft ? .shiftOnePageLeft : .shiftOnePageRight)
            }
            Button("Shift One Page to Previous") {
                perform(isRightToLeft ? .shiftOnePageRight : .shiftOnePageLeft)
            }

            Divider()

            Button("Move to First") {
                perform(.firstPage)
            }
            Button("Move to Last") {
                perform(.lastPage)
            }
        }

        Menu("Book Navigation") {
            Button("Go to Previous Book") {
                perform(.previousBook)
            }
            Button("Go to Next Book") {
                perform(.nextBook)
            }
        }

        Divider()

        Toggle(
            "Spread",
            isOn: Binding(
                get: { viewModel.displayMode == .spread },
                set: { _ in perform(.toggleDisplayMode) }
            )
        )

        Toggle(
            "Right-to-Left",
            isOn: Binding(
                get: { viewModel.readingDirection == .rightToLeft },
                set: { _ in perform(.toggleReadingDirection) }
            )
        )

        Divider()

        Button("Add Current Page to Bookmarks") {
            perform(.addBookmark)
        }

        Divider()

        Toggle(
            "Slideshow",
            isOn: Binding(
                get: { viewModel.isSlideshowActive },
                set: { _ in perform(.toggleSlideshow) }
            )
        )

        Toggle(
            "Full Screen",
            isOn: Binding(
                get: { isFullScreen },
                set: { _ in hostWindow?.toggleFullScreen(nil) }
            )
        )
    }

    /// 読み方向(右開き/左開き)を反映した表示順の画像配列。
    /// pageArea と showActualSizeWindow の両方で同じ並び替えロジックが必要なため、
    /// ロジックの重複(将来どちらかだけ直し忘れるバグの元)を避けるために1箇所にまとめている。
    private var orderedCurrentImages: [CGImage] {
        viewModel.readingDirection == .rightToLeft
            ? Array(viewModel.currentImages.reversed())
            : viewModel.currentImages
    }

    private var pageArea: some View {
        GeometryReader { geo in
            let orderedImages = orderedCurrentImages
            let contentSize = totalContentSize(for: orderedImages)
            let scale = renderScale(contentSize: contentSize, containerSize: geo.size)

            let imagesRow = HStack(spacing: 0) {
                ForEach(Array(orderedImages.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1)
                        .interpolation(preferences.interpolationQuality.swiftUIInterpolation)
                        .resizable()
                        .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                }
            }

            ZStack {
                if viewModel.scalingMode == .fitToScreen {
                    imagesRow
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                } else {
                    ScrollView(viewModel.scalingMode == .noScale ? [.horizontal, .vertical] : [.vertical]) {
                        imagesRow
                            .frame(
                                width: max(contentSize.width * scale, geo.size.width),
                                height: contentSize.height * scale
                            )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                // クリックでのページ送り(画面内に収めるモードのみ。他のモードはスクロール操作を優先する)
                HStack(spacing: 0) {
                    Button {
                        perform(keyBindingStore.action(for: .clickLeftZone))
                    } label: {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        perform(keyBindingStore.action(for: .clickRightZone))
                    } label: {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .allowsHitTesting(viewModel.scalingMode == .fitToScreen)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func totalContentSize(for images: [CGImage]) -> CGSize {
        guard !images.isEmpty else { return .zero }
        let width = images.reduce(CGFloat(0)) { $0 + CGFloat($1.width) }
        let height = images.map { CGFloat($0.height) }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    private func renderScale(contentSize: CGSize, containerSize: CGSize) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return 1
        }
        let maxUpscale = CGFloat(preferences.maxUpscalePercent / 100)
        switch viewModel.scalingMode {
        case .fitToScreen:
            let fitScale = min(containerSize.width / contentSize.width, containerSize.height / contentSize.height)
            return min(fitScale, maxUpscale)
        case .fitWidth:
            let widthScale = containerSize.width / contentSize.width
            return min(widthScale, maxUpscale)
        case .noScale:
            return 1
        }
    }

    private func handleScroll(deltaY: CGFloat) {
        // 横幅フィット/拡大縮小しないモードではScrollView自体がホイール操作を処理するため、
        // ここでのページ送りは「画面内に収める」モードのときだけ行う
        //
        // NSEvent.scrollingDeltaYの符号は、ホイールを物理的に上へ回す(指を上に動かす)と
        // 正の値になる(以前の実装ではここが逆になっており、ホイールを上に回すと.wheelDownに
        // 割り当てた操作が実行されてしまっていた。設定画面の「Scroll Wheel Up」という表示と
        // 実際の動作が食い違うバグだったため、対応する分岐を入れ替えて修正している)。
        if deltaY > 2 {
            perform(keyBindingStore.action(for: .wheelUp))
        } else if deltaY < -2 {
            perform(keyBindingStore.action(for: .wheelDown))
        }
    }

    /// トラックパッドの「ページ間をスワイプ」ジェスチャー(3本指スワイプ等、指を払うフリック操作)。
    /// 設定がONのときだけ、ホイールと同じ割り当て(既定はページ送り)として扱う。
    /// 2本指の通常スクロールとは別のイベント種別(NSEvent.swipe)なので、
    /// 横幅フィット/拡大縮小しないモードでのスクロール操作とは競合しない。
    private func handleSwipe(deltaX: CGFloat) {
        guard preferences.treatTrackpadFlickAsWheel else { return }
        if deltaX > 0 {
            perform(keyBindingStore.action(for: .wheelDown))
        } else if deltaX < 0 {
            perform(keyBindingStore.action(for: .wheelUp))
        }
    }

    private func registerMouseActivity() {
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        cursorHideTask?.cancel()
        guard preferences.autoHideCursor else { return }
        let delaySeconds = max(preferences.cursorAutoHideDelay, 0.1)
        cursorHideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 念のための保険: このウインドウが今アクティブでなければ隠さない。
                // 通常はウインドウが非アクティブになった時点でdidResignKeyNotification
                // (setUpWindowObservers参照)によりこのタスク自体がキャンセルされるはずだが、
                // タイミングによっては間に合わない可能性があるため、発火時にも再確認する。
                guard hostWindow?.isKeyWindow == true else { return }
                // メニューバーのメニューを開いている間、またはカーソルがメニューバー上に
                // ある間は、マウスを動かさなくても隠さない。
                guard !isMenuTracking, !isCursorOverMenuBar() else { return }
                NSCursor.hide()
                isCursorHidden = true
            }
        }
    }

    /// 現在のマウスカーソルの位置(スクリーン座標)が、メニューバーの帯の中にあるかどうか。
    /// メニューバーはメニューが開いていなくてもカーソルを乗せて操作する対象なので、
    /// 自動非表示のタイマーが発火する瞬間にここにカーソルがあれば隠さないようにする。
    private func isCursorOverMenuBar() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let mouseLocation = NSEvent.mouseLocation
        guard screen.frame.contains(mouseLocation) else { return false }
        // メニューバーの帯は、画面全体のframeのうち、Dock/メニューバーを除いたvisibleFrameの
        // 上端からframeの上端までの部分(Dockが画面上部にある設定の場合は理論上ズレるが、
        // メニューバー自体は常に画面最上部にあるため、実用上はこれで十分)。
        return mouseLocation.y >= screen.visibleFrame.maxY
    }

    /// このビューを表示しているウインドウのフルスクリーン入退場・キーウインドウからの離脱を
    /// 監視し、あわせてマウス移動イベントを受け取れるようにする。WindowAccessor経由で
    /// ウインドウを取得できた時点(1回だけ)で呼ばれる。
    private func setUpWindowObservers(for window: NSWindow?) {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        guard let window else { return }

        // 既定では、ウインドウはマウスのドラッグを伴わない単純な移動(.mouseMoved)の
        // イベントを受け取らない設定になっている。これが無効なままだと、カーソル自動非表示
        // 機能で「隠れたあとウインドウ内でマウスを動かしても再表示されない」不具合が起きる
        // (ウインドウの外に出て初めて、OS側の別の仕組みで再表示されたように見えてしまう)。
        window.acceptsMouseMovedEvents = true

        isFullScreen = window.styleMask.contains(.fullScreen)
        isAutoHiddenChromeRevealed = true

        // Fileメニューの標準「閉じる」(Cmd+W)を「本を閉じる」動作に変更する。既に何らかの
        // デリゲートが設定されている場合(SwiftUI/AppKitがタブ管理や状態復元のために設定して
        // いることがある)は、windowShouldClose以外のメソッドをすべてそちらへ転送するので、
        // 既存の機能を壊さない(BookClosingWindowDelegate参照)。
        if bookClosingDelegate == nil {
            let delegate = BookClosingWindowDelegate()
            delegate.appState = appState
            delegate.originalDelegate = window.delegate
            delegate.window = window
            delegate.preferences = preferences
            window.delegate = delegate
            bookClosingDelegate = delegate
        }
        // ウインドウ左上の赤い閉じるボタンは、標準では上のwindowShouldCloseを経由してしまい
        // (「本だけ閉じる」動作が優先されてしまう)、常にウインドウ自体を閉じてほしいという
        // 要望と食い違う。そのため、このボタンのtarget/actionだけを直接差し替えて、
        // windowShouldCloseを経由しない専用のforceCloseWindow(_:)を呼ぶようにする。
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = bookClosingDelegate
            closeButton.action = #selector(BookClosingWindowDelegate.forceCloseWindow(_:))
        }

        let enter = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { _ in
            isFullScreen = true
            isAutoHiddenChromeRevealed = true
        }
        let exit = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { _ in
            isFullScreen = false
            isAutoHiddenChromeRevealed = true
        }
        // NSCursor.hide()/unhide()はウインドウ単位ではなくアプリ全体に効く。そのため、
        // このウインドウがアクティブでなくなった(環境設定ウインドウや他のqooViewer
        // ウインドウに切り替わった)ときは、予約済みの「しばらくしたら隠す」タイマーを
        // 直ちにキャンセルし、隠れていたら再表示しておく。これがないと、バックグラウンドに
        // 回ったこのウインドウのタイマーが後から発火し、今操作している別のウインドウの
        // カーソルまで隠してしまう不具合が起きる。
        let resignKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            cursorHideTask?.cancel()
            cursorHideTask = nil
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
        }
        // メニューバーのメニュー(このアプリのもの)が開いている間は、マウスを動かさなくても
        // カーソルを隠さないようにする。object: nilなので、このアプリ内のどのメニュー
        // (メニューバーだけでなく右クリックメニュー等も含む)が開いても反応する。
        let menuBegin = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            isMenuTracking = true
            cursorHideTask?.cancel()
            cursorHideTask = nil
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
        }
        let menuEnd = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { _ in
            isMenuTracking = false
            registerMouseActivity()
        }
        windowObservers = [enter, exit, resignKey, menuBegin, menuEnd]
    }

    /// フルスクリーン表示中、または表示メニューの「ツールバーを隠す」「プログレスバーを隠す」の
    /// どちらかがONのウインドウ表示中に、マウスカーソルが画面(ウインドウ)の上端または下端に
    /// 近づいたときだけツールバー・スクラバーを表示する。どちらの自動隠しも有効でない
    /// (フルスクリーンでなく、かつ両方の設定がOFFの)ときは何もしない(常に表示するため)。
    /// カーソルのx座標と同様、実際に表示が変わる(=真偽値が反転する)ときだけ@Stateを
    /// 書き換える(過去のスクラバーの不具合の反省を踏まえた安全策)。
    private func updateAutoHiddenChromeVisibility(forMouseLocationInWindow location: CGPoint) {
        guard isFullScreen || appState.hideToolbar || appState.hideProgressBar,
              let windowHeight = hostWindow?.frame.height else { return }
        let edgeThreshold: CGFloat = 60
        let shouldShow = location.y > windowHeight - edgeThreshold || location.y < edgeThreshold
        if isAutoHiddenChromeRevealed != shouldShow {
            isAutoHiddenChromeRevealed = shouldShow
        }
    }

    /// 操作(キー/マウス)に対応する実際の処理を行う
    private func perform(_ action: ViewerAction?) {
        guard let action else { return }
        switch action {
        case .spatialLeft:
            viewModel.advance(forward: viewModel.readingDirection == .rightToLeft)
        case .spatialRight:
            viewModel.advance(forward: viewModel.readingDirection == .leftToRight)
        case .moveNext:
            viewModel.advance(forward: true)
        case .movePrevious:
            viewModel.advance(forward: false)
        case .shiftOnePageLeft:
            viewModel.shiftByOnePage(forward: viewModel.readingDirection == .rightToLeft)
        case .shiftOnePageRight:
            viewModel.shiftByOnePage(forward: viewModel.readingDirection == .leftToRight)
        case .firstPage:
            viewModel.jump(toPageIndex: 0)
        case .lastPage:
            viewModel.jump(toPageIndex: viewModel.pageCount - 1)
        case .toggleDisplayMode:
            viewModel.toggleDisplayMode()
        case .toggleReadingDirection:
            viewModel.toggleReadingDirection()
        case .cycleScalingMode:
            viewModel.cycleScalingMode()
        case .previousBook:
            appState.openSibling(before: viewModel.book.sourceURL)
        case .nextBook:
            appState.openSibling(after: viewModel.book.sourceURL)
        case .addBookmark:
            viewModel.addBookmark()
        case .nextBookmark:
            viewModel.jumpToNextBookmark()
        case .previousBookmark:
            viewModel.jumpToPreviousBookmark()
        case .showBookmarkList:
            showBookmarkList = true
        case .showThumbnailGrid:
            showThumbnailGrid = true
        case .toggleSlideshow:
            viewModel.toggleSlideshow()
        case .showActualSizeLeft:
            showActualSizeWindow(forLeftPage: true)
        case .showActualSizeRight:
            showActualSizeWindow(forLeftPage: false)
        case .none:
            break
        }
    }

    /// 見開きの左/右ページを原寸大の別ウインドウで表示する(cooViewerの「実寸表示ウィンドウ」相当)
    private func showActualSizeWindow(forLeftPage: Bool) {
        let orderedImages = orderedCurrentImages
        guard !orderedImages.isEmpty else { return }
        let index = forLeftPage ? 0 : orderedImages.count - 1
        let image = orderedImages[index]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(CGFloat(image.width), 900), height: min(CGFloat(image.height), 700)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: ActualSizePageView(image: image, backgroundColor: preferences.backgroundColorOption.color)
        )
        window.title = "Actual Size"
        window.center()
        window.isReleasedWhenClosed = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// SwiftUIのView階層から、それを表示しているNSWindowを取得するためのヘルパー。
/// 自身は何も描画しない透明な1x1のNSViewを差し込み、それがウインドウに追加された
/// タイミング(makeNSView/updateNSViewの両方)でwindowプロパティを読み取ってコールバックする。
/// フルスクリーンの入退場通知(NSWindow.didEnterFullScreenNotificationなど)を
/// 登録するために、対象ウインドウそのものへの参照が必要なので使っている。
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = true
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}
