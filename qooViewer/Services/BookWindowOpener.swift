import SwiftUI
import AppKit

/// 「この本を新しいウインドウ/タブで開く」の**唯一の実装**。
///
/// ■ なぜ切り出したのか
/// この処理はもともと5箇所にコピーされていた ―― メニューバー(QooViewerApp)、ビューアの
/// お気に入り一覧(ViewerView、ウインドウ用とタブ用で2つ)、「お気に入りの編集」ウインドウ
/// (FavoritesOrganizerView、同じく2つ)。どれも
///   ①WindowGroupのidを決める → ②セキュリティスコープを渡す → ③開く直前のNSApp.windowsを
///   控える → ④openWindow → ⑤ポーリングで増えたウインドウを見つける → ⑥位置とサイズを
///   決める → ⑦タブなら親へ追加する → ⑧前面に出す
/// という同じ8手順を書いており、実際にコピーごとの食い違いも生じていた
/// (「すでに同じ本を開いているウインドウがあればそれを前面に出す」重複判定と、カスケード
/// 位置が画面からはみ出す場合の押し戻しが、メニューバー版にしか無かった)。
/// サイドパネル等の右クリックメニュー(BookOpenContextMenuItems)を足すにあたり、6つ目の
/// コピーを作らずに済むよう、ここへ集約した。
///
/// ■ 例外: QooViewerApp.openInNewWindow
/// 「主ウインドウの役割を引き継ぐ」経路(actsAsPrimaryWindow。Finder/Dockから渡された本を、
/// 再利用できるmainウインドウが無いときに受ける場合)だけは、前回終了時のフレームの復元と
/// PrimaryWindowFrameKeeperによる追従という固有の後始末があり、あちらに残してある。
/// ただし⑤⑥にあたる`newlyOpenedWindow(excluding:)`と`place(_:basedOn:asTab:)`は
/// こちらのものを共有しているので、「新しいウインドウの見つけ方」と「置き方」の実装は1つだけ。
@MainActor
enum BookWindowOpener {
    /// `request`の本を`destination`で開く。
    ///
    /// - Parameter source: この操作の派生元となるウインドウのAppState。
    ///   シークレットかどうかの引き継ぎ(`BookWindowGroup`)、新しいウインドウのサイズと
    ///   カスケードの基準、タブの追加先(`source.hostWindow`)を、すべてここから取る。
    ///   派生元が無い場合(本を1つも開いていない、独立した編集ウインドウからの操作)はnil。
    ///   nilのときは`.newTab`も新しいウインドウとして開く ―― タブを追加すべき相手が
    ///   存在しないため。
    /// - Parameter onOpened: 実際に開き終えた(または既存のウインドウを前面に出し終えた)
    ///   あとに呼ぶ。「お気に入りの編集」ウインドウが自分自身を閉じるために使う。
    ///   開けなかった場合(ウインドウが見つからなかった場合)は呼ばれない。
    static func open(
        _ request: BookOpenRequest,
        to destination: BookOpenDestination,
        from source: AppState?,
        launchCoordinator: LaunchCoordinator,
        openWindow: OpenWindowAction,
        onOpened: (() -> Void)? = nil
    ) {
        let windowGroupID = BookWindowGroup.id(for: destination, inheritingFrom: source)
        let opensPrivately = (windowGroupID == "private")

        // すでにこの本を開いているウインドウ/タブがあれば、同じ本をもう1つ開く代わりに
        // それをアクティブにする。探す相手は「これから作ろうとしているウインドウと**同じ
        // 性質**のもの」に限る(記録の残るウインドウで開きたいのにシークレットウインドウが
        // 前面に出てきては、開いたつもりの記録がどこにも残らない。その逆も同じ)。
        // 複数の画像を1冊にまとめる要求は対象外(まとめた本は「同じ本」という同一性を
        // 持たない。LaunchCoordinator.openAppState(forBookAt:isPrivate:)参照)。
        if !request.bundlesMultipleImages, let url = request.primaryURL,
           let existingAppState = launchCoordinator.openAppState(forBookAt: url, isPrivate: opensPrivately),
           let existingWindow = existingAppState.hostWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            onOpened?()
            return
        }

        // 上限を超える要求は、この後どのウインドウが受け取っても`AppState.open(request:)`が
        // 弾く。渡しのためのセキュリティスコープをここで開くと、拒否されるだけの要求のために
        // URLの数だけ拡張を消費することになる(BookOpenRequest.exceedsImageSelectionLimit参照)。
        // ウインドウ自体は開く ―― 黙って何も起きないより、開いた先でエラーが出るほうがよい。
        if !request.exceedsImageSelectionLimit {
            SecurityScopedHandoff.begin(request.urls)
        }

        presentNewWindow(
            groupID: windowGroupID, value: .book(request), destination: destination,
            source: source, openWindow: openWindow, onOpened: onOpened
        )
    }

    /// フォルダを`destination`のファイルブラウザで開く(改善要望7 段階3)。
    ///
    /// 本と違って**重複の判定をしない**(同じフォルダを2枚で見るのは普通のこと。
    /// WindowContentRequestの型コメント)。セキュリティスコープの受け渡しは本と同じ10秒
    /// (SecurityScopedHandoff)。受け取った側がFolderAccessStoreの許可で読み直すまでの橋渡し。
    ///
    /// - Parameter item: 開いたフォルダの中で選ぶ項目(「ファイルブラウザで開く」でファイルを示すとき。段階 8)。
    static func openFolder(
        _ folder: URL,
        selecting item: URL? = nil,
        to destination: BookOpenDestination,
        from source: AppState?,
        openWindow: OpenWindowAction
    ) {
        SecurityScopedHandoff.begin(folder)
        presentNewWindow(
            groupID: BookWindowGroup.id(forBrowsing: destination, inheritingFrom: source),
            value: .browse(folder, selecting: item), destination: destination, source: source,
            openWindow: openWindow, onOpened: nil
        )
    }

    /// ③〜⑧(型コメントの手順)。本もフォルダも同じ。
    private static func presentNewWindow(
        groupID windowGroupID: String,
        value: WindowContentRequest,
        destination: BookOpenDestination,
        source: AppState?,
        openWindow: OpenWindowAction,
        onOpened: (() -> Void)?
    ) {
        let sourceWindow = source?.hostWindow
        let opensPrivately = (windowGroupID == "private")
        // タブとして開けるのは、追加先のウインドウが実在する場合だけ。
        let asTab = destination.isTab && sourceWindow != nil
        expectNewWindow(
            frame: sourceWindow.map { placedFrame(basedOn: $0, asTab: asTab) }, basedOn: sourceWindow, hidesUntilTabbed: asTab
        )
        let existingWindowIDs = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: windowGroupID, value: value)

        Task { @MainActor in
            guard let newWindow = await newlyOpenedWindow(excluding: existingWindowIDs) else { return }
            detachIfTabbedWithMismatchedPrivacy(
                newWindow,
                sourceWindow: sourceWindow,
                sourceIsPrivate: source?.isPrivateWindow,
                opensPrivately: opensPrivately,
                asTab: asTab
            )
            place(newWindow, basedOn: sourceWindow, asTab: asTab)
            // 透明を戻すのはタブへ入れる**前**(revealIfHiddenUntilTabbed のコメント)。
            revealIfHiddenUntilTabbed(newWindow)
            if asTab, let sourceWindow {
                sourceWindow.addTabbedWindow(newWindow, ordered: .above)
            }
            newWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            onOpened?()
        }
    }

    /// 記録の残るウインドウと残らないウインドウが、同じタブバーに並んでしまうのを防ぐ。
    ///
    /// macOSは「タブ環境設定」(システム設定 › デスクトップとDock ›「書類を開くときはタブで開く」)が
    /// 「常に」のとき、`tabbingMode`が`.automatic`のウインドウを、同じ`tabbingIdentifier`を持つ
    /// 既存のウインドウのタブとして自動的に開く。SwiftUIはWindowGroupごとに別の
    /// `tabbingIdentifier`を振るはずなので、"book"のウインドウが"private"のウインドウへ
    /// 合流することは本来起こらない ―― **これは実機で「起きた」のを直したコードではなく、
    /// 起きた場合の被害が大きいことに対する保険である**(その前提が将来のmacOSで変わっても
    /// 気づけない類の挙動なので、明示的に打ち消しておく)。
    ///
    /// 被害が大きい理由: タイトルバーの「(シークレット)」表示は最前面のタブのぶんしか出ない
    /// ため、両者が同じタブバーに並ぶと、今読んでいる本が記録されるのかどうかを見分けられなく
    /// なる。シークレットウインドウという機能の前提そのものが壊れる。
    ///
    /// 逆に、性質が一致している場合(通常→通常、シークレット→シークレット)にタブへまとまるのは
    /// **ユーザーがOSに設定したとおりの挙動**なので、何もしない。
    private static func detachIfTabbedWithMismatchedPrivacy(
        _ newWindow: NSWindow,
        sourceWindow: NSWindow?,
        sourceIsPrivate: Bool?,
        opensPrivately: Bool,
        asTab: Bool
    ) {
        // 明示的に「新規タブで開く」を選んだ場合は、そもそも派生元の性質を引き継いでいるので
        // 食い違いようがない(BookOpenDestination.newTab参照)。
        guard !asTab, let sourceWindow, let sourceIsPrivate,
              sourceIsPrivate != opensPrivately,
              let group = newWindow.tabGroup, group === sourceWindow.tabGroup
        else { return }
        group.removeWindow(newWindow)
    }

    /// `openWindow(id:)`で開いたばかりのウインドウのNSWindowを取り出す。openWindowが実際に
    /// NSWindowを作り終えるのは次以降のランループになるため、短い間隔で何度か確認し、新しく
    /// 増えたウインドウを見つける。
    ///
    /// - Parameter existingWindowIDs: openWindowを呼ぶ**直前**のNSApp.windowsから作った集合。
    static func newlyOpenedWindow(excluding existingWindowIDs: Set<ObjectIdentifier>) async -> NSWindow? {
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if let found = NSApp.windows.first(where: { !existingWindowIDs.contains(ObjectIdentifier($0)) }) {
                return found
            }
        }
        return nil
    }

    /// 新しく開いたウインドウ(「新しいウインドウ/タブで開く」および「新規ノーマル/シークレット
    /// ウインドウ」)のサイズ・位置を決める。
    ///
    /// 新しいウインドウのサイズは、元になったウインドウ(`previousKeyWindow`)と同じ大きさに
    /// する。元のウインドウが見つからない場合(環境設定ウインドウがアクティブだった場合など)は
    /// SwiftUIの既定サイズのままにする。
    /// 「新しいタブで開く」の場合は、この後addTabbedWindowで元のウインドウのタブグループに
    /// 加わり、位置は自動的にそのウインドウに揃うため、位置の調整は不要。
    /// 「新しいウインドウで開く」の場合は、元のウインドウとほぼ重なる位置に開かれてしまい
    /// 2枚あることが分かりにくいという指摘を受け、右下方向へ明確にずらして配置する
    /// (Macの標準的な「カスケード」表示を、より分かりやすい間隔で自前に行っている)。
    /// ずらした結果、画面の表示可能領域からはみ出してしまう場合は、はみ出さない範囲に
    /// 収まるよう位置を調整し直す。これにより、元のウインドウがすでに画面いっぱいに
    /// 広がっている場合は(はみ出す分だけ押し戻された結果)実質的にずれない、上下どちらかだけ
    /// いっぱいの場合はその方向だけずれない、という見た目に自然となる(個別に「いっぱいか
    /// どうか」を判定するよりも、この方法の方が中途半端なサイズのウインドウにも正しく対応できる)。
    static func place(_ newWindow: NSWindow, basedOn previousKeyWindow: NSWindow?, asTab: Bool) {
        guard let previousKeyWindow else { return }
        let frame = placedFrame(basedOn: previousKeyWindow, asTab: asTab)
        if newWindow.frame != frame {
            newWindow.setFrame(frame, display: true)
        }
    }

    /// `place(_:basedOn:asTab:)`が決める位置・大きさ。新しいウインドウ自身の値は使わないので、開く前にも求められる
    /// (`expectNewWindow`)。
    static func placedFrame(basedOn previousKeyWindow: NSWindow, asTab: Bool) -> NSRect {
        var frame = NSRect.zero
        frame.size = previousKeyWindow.frame.size
        if asTab {
            frame.origin = previousKeyWindow.frame.origin
        } else {
            let cascadeOffset: CGFloat = 48
            var origin = CGPoint(
                x: previousKeyWindow.frame.origin.x + cascadeOffset,
                y: previousKeyWindow.frame.origin.y - cascadeOffset
            )
            if let visibleFrame = (previousKeyWindow.screen ?? NSScreen.main)?.visibleFrame {
                if origin.x + frame.size.width > visibleFrame.maxX {
                    origin.x = visibleFrame.maxX - frame.size.width
                }
                if origin.x < visibleFrame.minX {
                    origin.x = visibleFrame.minX
                }
                if origin.y + frame.size.height > visibleFrame.maxY {
                    origin.y = visibleFrame.maxY - frame.size.height
                }
                if origin.y < visibleFrame.minY {
                    origin.y = visibleFrame.minY
                }
            }
            frame.origin = origin
        }
        return frame
    }

    // MARK: - 開く前に決めた位置・大きさを、画面に出る前に当てる

    /// これから`openWindow`で開くウインドウの位置・大きさ(2026-09-27、利用者の指摘)。
    ///
    /// ■ なぜ要るか
    /// 位置・大きさは`newlyOpenedWindow`で新しいウインドウを見つけてから`place`で決めていたが、見つかるのは画面に出た後で、
    /// それまでの約 70ms は WindowGroup の既定の大きさ(900×640)で画面の中ほどに出て、開くアニメーションのあと元のウインドウの
    /// 大きさへ飛んでいた(CGWindowList を 4ms おきに読んで実測)。タブで開くときは、タブへ入る前の 1 枚のウインドウとしても見えていた。
    /// そこで開く前に行き先を控え、SwiftUI がウインドウを作るときに`.defaultWindowPlacement`(`pendingWindowPlacement`)で最初の
    /// 位置・大きさとして渡し、画面に出たその場(`prepareNextNewWindowOnceShown`)でも当て直す。ContentView の WindowAccessor
    /// (画面に出てから約 20ms 後)は`applyPendingPlacement`で同じ値を当て直し、`place`も後からもう一度同じ値を当てる
    /// (どこかで当て損ねても、以前と同じ結果に落ちる)。
    ///
    /// - Parameter frame: nil なら位置・大きさは SwiftUI に任せる(隠すだけ)。
    /// - Parameter hidesUntilTabbed: タブで開くとき。タブへ入れるまで透明にしておく(`revealIfHiddenUntilTabbed`で戻す)。
    static func expectNewWindow(frame: NSRect?, basedOn source: NSWindow? = nil, hidesUntilTabbed: Bool) {
        guard frame != nil || hidesUntilTabbed else {
            pendingPlacement = nil
            return
        }
        pendingPlacement = PendingPlacement(
            frame: frame,
            styleMask: source?.styleMask ?? [.titled, .closable, .miniaturizable, .resizable],
            hidesUntilTabbed: hidesUntilTabbed,
            deadline: Date().addingTimeInterval(1)
        )
        prepareNextNewWindowOnceShown(frame: frame, hides: hidesUntilTabbed)
    }

    /// 新しいウインドウに、画面に出たその場で行き先を当てる(タブで開くときは透明にもする)。
    ///
    /// WindowAccessor が呼ばれるのは画面に出てから約 20ms 後で、その間、タブへ入る前の 1 枚のウインドウ(ホーム)が元のウインドウに
    /// 少しずらして重なって見えていた(CGWindowList で実測)。SwiftUI がウインドウを前へ出すとキーウインドウの知らせが同期で届くので、
    /// その場で当てれば最初の描画に間に合う。相手は「控えた時点で無かったウインドウ」だけ。1 秒で見張りをやめる。
    ///
    /// ■ 位置・大きさもここで当てる(2026-09-27、表示の切り替えの監査)
    /// 本を指定して開くウインドウ(`openWindow(id:value:)`)は、`.defaultWindowPlacement`で渡した位置・大きさより**タイトルバーの
    /// 高さ(32pt)だけ上端が下がって短く**作られ、約 20ms 後に WindowAccessor が当て直した瞬間に 32pt 跳んでいた(開くアニメーションの
    /// 途中で跳ぶ。値を渡さない ⌘N では起きない。CGWindowList で実測)。作られたばかりのウインドウにはまだ`.fullSizeContentView`が
    /// 付いていて、中身の領域として渡した矩形がフレームとして使われたと見られる(値の有無で扱いが違う理由は分からない)。
    /// SwiftUI の解釈に頼らず、ここで`.fullSizeContentView`を外して(WindowAccessor が後でするのと同じ)フレームを当てる。
    private static func prepareNextNewWindowOnceShown(frame: NSRect?, hides: Bool) {
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let tokens = NotificationObserverTokens()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            tokens.add(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow,
                          !existing.contains(ObjectIdentifier(window)) else { return }
                    tokens.removeAll()
                    if let frame {
                        window.styleMask.remove(.fullSizeContentView)
                        if window.frame != frame {
                            window.setFrame(frame, display: false)
                        }
                    }
                    guard hides else { return }
                    window.alphaValue = 0
                    // タブへ入れる側が見つけ損ねたときに、透明のまま残さない(applyPendingPlacement と同じ保険)。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
                        MainActor.assumeIsolated { if let window { revealIfHiddenUntilTabbed(window) } }
                    }
                }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { tokens.removeAll() }
        }
    }

    struct PendingPlacement {
        let frame: NSRect?
        /// 大きさの基準にしたウインドウのスタイル(フレームから中身の領域を出すため)。
        let styleMask: NSWindow.StyleMask
        let hidesUntilTabbed: Bool
        /// `newlyOpenedWindow`が探すのをやめるまで(約 0.5 秒)より少し長く。過ぎたら、あとから現れた別のウインドウに当てない。
        let deadline: Date
    }

    private static var pendingPlacement: PendingPlacement?

    /// 控えてある行き先を 1 回だけ渡す(期限を過ぎていれば nil)。
    static func takePendingPlacement() -> PendingPlacement? {
        defer { pendingPlacement = nil }
        guard let pendingPlacement, pendingPlacement.deadline > Date() else { return nil }
        return pendingPlacement
    }

    /// 本のウインドウの WindowGroup("book"/"normal"/"private")の`.defaultWindowPlacement`から、SwiftUI がウインドウを作るときに呼ばれる。
    /// 控えてある行き先があれば、それをウインドウの最初の位置・大きさにする(控えは消さない ―― 透明にする指定と、当て損ねたときの
    /// やり直しは WindowAccessor の`applyPendingPlacement`が受け取る)。無ければ WindowGroup の既定のまま。
    ///
    /// `.defaultWindowPlacement`の閉包はメインアクタの外として型付けされているので、控えを読むところだけを
    /// `MainActor.assumeIsolated`に入れ、そこから返すのは Sendable な`CGRect`にする。macOS 26 の SDK では`WindowPlacement`の
    /// Sendable 適合が使えない(unavailable)ので、`WindowPlacement`そのものを assumeIsolated から返すと Swift 6 ではエラー
    /// (2026-09-27、CI の Xcode 26.6。Xcode 27 では通っていた)。
    nonisolated static func pendingWindowPlacement() -> WindowPlacement {
        guard let content = MainActor.assumeIsolated({ pendingContentRect() }) else { return WindowPlacement() }
        return WindowPlacement(content.origin, size: content.size)
    }

    /// 控えてある行き先の中身の領域を、`WindowPlacement`の座標で。
    private static func pendingContentRect() -> CGRect? {
        guard let pendingPlacement, pendingPlacement.deadline > Date(), let frame = pendingPlacement.frame else { return nil }
        // WindowPlacement の位置と大きさは**中身の領域**(タイトルバーを除く)のもので、座標は左上が原点で下向き(主画面の左上が 0)。
        // AppKit のフレームは左下が原点で上向きで、タイトルバーを含む。
        let content = NSWindow.contentRect(forFrameRect: frame, styleMask: pendingPlacement.styleMask)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? content.maxY
        return CGRect(origin: CGPoint(x: content.minX, y: primaryHeight - content.maxY), size: content.size)
    }

    /// 新しく決まったウインドウに、控えてある行き先を当てる(ContentView の WindowAccessor から、ウインドウが決まった最初の 1 回)。
    static func applyPendingPlacement(to window: NSWindow) {
        guard let placement = takePendingPlacement() else { return }
        if let frame = placement.frame {
            window.setFrame(frame, display: false)
        }
        if placement.hidesUntilTabbed {
            window.alphaValue = 0
            // タブへ入れる側が見つけ損ねた(newlyOpenedWindow が nil を返した)ときに、透明のまま残さない。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
                MainActor.assumeIsolated { if let window { revealIfHiddenUntilTabbed(window) } }
            }
        }
    }

    /// `applyPendingPlacement`で透明にしたウインドウを見えるように戻す。
    ///
    /// **タブへ入れる前に呼ぶ**(2026-09-27、表示の切り替えの監査)。`addTabbedWindow`は元のタブをその場で画面から外すが、透明を戻した
    /// 新しいタブが画面に出るのは次の描画で、タブへ入れた後に戻していた間は約 10〜27ms、このアプリのウインドウがどこにも無いフレームが
    /// 出ていた(後ろのデスクトップが透ける。⌘T と「新しいタブで開く」で CGWindowList と画面の取り込みで実測)。新しいウインドウは
    /// 元のウインドウとまったく同じ位置・大きさで作ってある(`placedFrame(asTab: true)`)ので、先に見せても元のウインドウの上に重なる
    /// だけで、ずれて見えることは無い。
    static func revealIfHiddenUntilTabbed(_ window: NSWindow) {
        if window.alphaValue == 0 { window.alphaValue = 1 }
    }
}

