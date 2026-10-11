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
        newWindowFrame: NSRect? = nil,
        onOpened: (() -> Void)? = nil
    ) {
        let windowGroupID = BookWindowGroup.id(for: destination, inheritingFrom: source)
        let opensPrivately = (windowGroupID == "private")

        // シークレットフォルダの本で、環境設定「常にシークレットウインドウで開く」が ON なら、ノーマルの窓は作らずにシークレットウインドウへ
        // 回す(openSecretBookPrivatelyIfNeeded)。回した先はこの関数へシークレットの行き先で戻ってくるので、ここを二度は通らない。
        // onOpened は回した先が開き終えたときに呼ぶ(開けなければ呼ばない ―― 呼ぶと、編集ウインドウが本も出ないまま閉じる。
        // コードレビューの指摘)。
        if openSecretBookPrivatelyIfNeeded(request, opensPrivately: opensPrivately, source: source,
                                           launchCoordinator: launchCoordinator, openWindow: openWindow, onOpened: onOpened) {
            return
        }

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
            source: source, openWindow: openWindow, frameOverride: newWindowFrame, onOpened: onOpened
        )
    }

    // MARK: - シークレットフォルダの本をシークレットウインドウで開く(2026-10-03)

    /// その要求をシークレットウインドウへ回すか。ノーマルの行き先で、環境設定「シークレットフォルダの本は常にシークレットウインドウで
    /// 開く」が ON で、要求の本(のどれか)がシークレットフォルダの中にあるとき。値で試せるよう、設定と判定は引数で受ける。
    nonisolated static func shouldOpenPrivately(
        _ request: BookOpenRequest, opensPrivately: Bool, isEnabled: Bool, isSecret: (URL) -> Bool
    ) -> Bool {
        isEnabled && !opensPrivately && request.urls.contains(where: isSecret)
    }

    /// アプリの設定と一覧で決める版(`shouldOpenPrivately` の値を入れたもの)。
    static func shouldOpenSecretBookPrivately(_ request: BookOpenRequest, opensPrivately: Bool) -> Bool {
        shouldOpenPrivately(request, opensPrivately: opensPrivately,
                            isEnabled: AppPreferences.opensSecretFolderBooksPrivately,
                            isSecret: SecretFolderStore.isSecretAppWide)
    }

    /// 回すなら回して true を返す。**新しい窓を作る所(ここと QooViewerApp.openInNewWindow)は、窓を作る前に**呼ぶ ―― ノーマルの窓が
    /// 一瞬でも出ないように(利用者の要望: 「透明で起動して、透明なまま閉じる」ように、そもそも開いたように見えない)。今の窓で開く所
    /// (AppState.open)は窓を作らないので、AppState.privateRedirect を経て ContentView がここの `openSecretBookPrivately` を呼ぶ。
    @discardableResult
    static func openSecretBookPrivatelyIfNeeded(
        _ request: BookOpenRequest, opensPrivately: Bool, source: AppState?,
        launchCoordinator: LaunchCoordinator, openWindow: OpenWindowAction, newWindowFrame: NSRect? = nil,
        onOpened: (() -> Void)? = nil
    ) -> Bool {
        guard shouldOpenSecretBookPrivately(request, opensPrivately: opensPrivately) else { return false }
        openSecretBookPrivately(request, source: source, launchCoordinator: launchCoordinator, openWindow: openWindow,
                                newWindowFrame: newWindowFrame, onOpened: onOpened)
        return true
    }

    /// シークレットウインドウで開く。開き先は環境設定(`SecretFolderPrivatePlacement`): いちばん手前のシークレットウインドウのタブ、
    /// その窓の本と入れ替え(どちらも、シークレットウインドウが無ければ新しいシークレットウインドウ)、毎回新しいシークレットウインドウ。同じ本を開いているシークレットウインドウがあれば
    /// それを前に出すだけ(`open` の重複の判定)。
    ///
    /// - Parameter newWindowFrame: 新しいシークレットウインドウを作るときの位置と大きさ。**回さなければ作られていたノーマルの窓の
    ///   位置**を渡す(QooViewerApp.openInNewWindow)。とくに、窓が 1 つも無い状態で Finder から開いたときは主ウインドウの記憶した
    ///   位置 ―― 起動時に透明のまま閉じる主ウインドウが出るはずだった所 ―― で、ずらすと利用者からは意味も無くずれたように見える
    ///   (2026-10-03、利用者の指摘)。nil なら元の窓を基準にずらす(`placedFrame`)。今の画面に載らない位置(外したディスプレイの
    ///   上など)なら使わない(`visibleFrameOrNil`)。
    /// - Parameter initialEdge, startsSlideshow: 着地の指定とスライドショー。今あるシークレットウインドウで入れ替えるときだけ効く
    ///   (AppState.PrivateRedirect のコメント)。
    /// - Parameter quietly: 通り抜けの移動(サイドパネルのフォルダブラウザで画像のフォルダへ入った。`recordsInHistory == false`)から
    ///   回すとき true。`openSecretBookPrivatelyQuietly` のコメント。
    static func openSecretBookPrivately(
        _ request: BookOpenRequest, source: AppState?, launchCoordinator: LaunchCoordinator, openWindow: OpenWindowAction,
        newWindowFrame: NSRect? = nil, initialEdge: InitialPageEdge? = nil, startsSlideshow: Bool = false,
        quietly: Bool = false, onOpened: (() -> Void)? = nil
    ) {
        if quietly, let source {
            openSecretBookPrivatelyQuietly(request, source: source, launchCoordinator: launchCoordinator, openWindow: openWindow)
            return
        }
        let placement = AppPreferences.currentSecretFolderPrivatePlacement
        if placement != .newPrivateWindow, let host = frontmostPrivateAppState(launchCoordinator: launchCoordinator) {
            switch placement {
            case .replaceInPrivateWindow:
                // その窓の本(またはホーム)と入れ替える。同じ本を別のシークレットウインドウで開いていれば、そちらを前に出す
                // (AppState.open の重複の判定)。
                host.hostWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                host.open(request: request, initialEdge: initialEdge, startsSlideshow: startsSlideshow)
                onOpened?()
            default:
                open(request, to: .newTab, from: host, launchCoordinator: launchCoordinator, openWindow: openWindow,
                     onOpened: onOpened)
            }
        } else {
            // 大きさ・位置の基準は元の窓(シークレットかどうかは行き先が決める)。決まった位置があればそこ。
            open(request, to: .newPrivateWindow, from: source, launchCoordinator: launchCoordinator, openWindow: openWindow,
                 newWindowFrame: newWindowFrame.flatMap(visibleFrameOrNil), onOpened: onOpened)
        }
    }

    /// 通り抜けの移動から回すとき(2026-10-04 の監査 O-4・決定 4 の (b))。「常にシークレットウインドウで開く」は破らずに回すが、
    /// **焦点を移さず、前回この窓から回したシークレットウインドウのタブを入れ替える**。以前は名指しの「開く」と同じ扱いで、ノーマルの窓の
    /// サイドパネルでシークレットフォルダの中を行き来すると、画像のフォルダへ入るたびにシークレットウインドウへタブが 1 枚ずつ足され、
    /// 焦点もそちらへ移った(実測)。
    ///
    /// - 同じ本をもうシークレットウインドウで出していれば、何もしない(前にも出さない)。
    /// - 前回回した先(`AppState.passThroughPrivateTarget`。まだその本を出している・読み込み中のとき)があれば、そこで入れ替える。
    ///   無ければ、前回回した本をいま出しているシークレットウインドウを探す。
    /// - どちらも無い初回は、環境設定の開き先(タブ・入れ替え・新しい窓)のとおりに開き、開いた後で元の窓へ焦点を戻す。開いた窓が
    ///   その時点で分かれば、次の回のためにそれを控える。
    private static func openSecretBookPrivatelyQuietly(
        _ request: BookOpenRequest, source: AppState, launchCoordinator: LaunchCoordinator, openWindow: OpenWindowAction
    ) {
        guard let url = request.primaryURL else { return }
        if let shown = launchCoordinator.openAppState(forBookAt: url, isPrivate: true) {
            source.notePassThroughPrivateTarget(shown, url: url)
            return
        }
        if let target = source.passThroughPrivateTarget(in: launchCoordinator) {
            target.open(request: request, reusesExistingWindow: false)
            // 開いた**後**の意図を控える(この要求そのものは数え終えている。R7-5)。
            source.notePassThroughPrivateTarget(target, url: url)
            return
        }
        // 初回のタブ・窓を作っている最中(まだどの窓か分からない)なら、作り終えてからそこで開く(2026-10-04 のレビューの R7-5。
        // 以前はこの間の通り抜けごとにタブを足し、焦点も一瞬移った)。窓が分からないまま上限を過ぎたら回し直す(RC-6)。
        if source.deferPassThroughWhileTargetIsPending(request) {
            retryPassThroughPendingWhenExpired(source: source, launchCoordinator: launchCoordinator, openWindow: openWindow)
            return
        }
        source.notePassThroughPrivateTargetPending(url: url)
        let sourceWindow = source.hostWindow
        openSecretBookPrivately(
            request, source: source, launchCoordinator: launchCoordinator, openWindow: openWindow,
            onOpened: { [weak source, weak sourceWindow] in
                // 開いた窓はこの時点で手前(キー)にある。次の回の入れ替え先として控えてから、焦点を元の窓へ戻す。
                if let source, let key = NSApp.keyWindow, key !== sourceWindow,
                   let opened = launchCoordinator.allOpenAppStates.first(where: { $0.hostWindow === key && $0.isPrivateWindow }) {
                    source.notePassThroughPrivateTarget(opened, url: url)
                    // 作っている間に来た次の通り抜けは、ここで同じ窓に入れ替える。
                    if let pending = source.takePassThroughPending(), let pendingURL = pending.primaryURL {
                        opened.open(request: pending, reusesExistingWindow: false)
                        source.notePassThroughPrivateTarget(opened, url: pendingURL)
                    }
                } else if let source, let pending = source.takePassThroughPending() {
                    // 開いた窓を見分けられなかった。作っている間に来た次の通り抜けは捨てずに、同じ静かな経路で回し直す
                    // (前回回した本を出しているシークレットウインドウがあればそこで入れ替わる。2026-10-04 のレビューの RC-6 ――
                    // 以前は黙って捨てていた)。
                    openSecretBookPrivatelyQuietly(
                        pending, source: source, launchCoordinator: launchCoordinator, openWindow: openWindow)
                }
                sourceWindow?.makeKeyAndOrderFront(nil)
            })
    }

    /// 初回の窓が分かるのを待つ間に控えた通り抜けを、上限(`AppState.passThroughPendingLimit`)を過ぎても窓が分からなければ回し直す
    /// (2026-10-04 のレビューの RC-6)。新しい窓が見つからないと `presentNewWindow` は onOpened を呼ばないので、以前は控えた要求が
    /// 次の通り抜けまで残り、次が来なければ黙って捨てられた。回し直すときも「常にシークレットウインドウで開く」の決まりは守る ――
    /// その間に設定が切れていたら、この窓で開く代わりに鳴らす(移動はもう済んでおり、後から勝手に本を出すと別の頼みに見える)。
    private static func retryPassThroughPendingWhenExpired(
        source: AppState, launchCoordinator: LaunchCoordinator, openWindow: OpenWindowAction
    ) {
        Task { @MainActor [weak source] in
            try? await Task.sleep(for: .seconds(AppState.passThroughPendingLimit + 0.1))
            guard let source, source.hostWindow != nil,
                  let pending = source.takeExpiredPassThroughPending() else { return }
            guard shouldOpenSecretBookPrivately(pending, opensPrivately: source.isPrivateWindow) else {
                UserFeedback.beep()
                return
            }
            openSecretBookPrivatelyQuietly(pending, source: source, launchCoordinator: launchCoordinator, openWindow: openWindow)
        }
    }

    /// 今つながっている画面のどれかに十分に載る位置ならそのまま、載らなければ nil(元の窓を基準にずらす側へ倒す)。
    /// 記憶した主ウインドウの位置が、外したディスプレイの上だったときのため(`placedFrame` は画面の内側へ押し戻すが、決め打ちの
    /// 位置にはそれが無い。コードレビューの指摘)。
    static func visibleFrameOrNil(_ frame: NSRect) -> NSRect? {
        let isVisible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= min(frame.width, 200) && overlap.height >= min(frame.height, 100)
        }
        return isVisible ? frame : nil
    }

    /// 画面のいちばん手前にある(最小化されていない)シークレットウインドウ。
    private static func frontmostPrivateAppState(launchCoordinator: LaunchCoordinator) -> AppState? {
        let candidates = launchCoordinator.allOpenAppStates.filter { $0.isPrivateWindow && $0.hostWindow != nil }
        for window in NSApp.orderedWindows where !window.isMiniaturized {
            if let match = candidates.first(where: { $0.hostWindow === window }) { return match }
        }
        return nil
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
        frameOverride: NSRect? = nil,
        onOpened: (() -> Void)?
    ) {
        let sourceWindow = source?.hostWindow
        let opensPrivately = (windowGroupID == "private")
        // タブとして開けるのは、追加先のウインドウが実在する場合だけ。
        let asTab = destination.isTab && sourceWindow != nil
        // 位置の指定はタブでないときだけ効く(タブは追加先の窓の大きさになる)。
        let frameOverride = asTab ? nil : frameOverride
        expectNewWindow(
            frame: frameOverride ?? sourceWindow.map { placedFrame(basedOn: $0, asTab: asTab) },
            basedOn: sourceWindow, hidesUntilTabbed: asTab
        )
        let existingWindowIDs = Set(NSApp.windows.map(ObjectIdentifier.init))
        // 窓を作ると頼んだ時点の開く意図の番号を控える(作られた窓が最初の要求を開くときに引き取る。AppState.OpenIntent、
        // 2026-10-04 のレビューの RC-2)。
        if let request = value.bookRequest { AppState.noteWindowCreatingRequest(request) }
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
            if let frameOverride {
                if newWindow.frame != frameOverride { newWindow.setFrame(frameOverride, display: true) }
            } else {
                place(newWindow, basedOn: sourceWindow, asTab: asTab)
            }
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

