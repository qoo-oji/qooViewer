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
        let sourceWindow = source?.hostWindow
        let windowGroupID = BookWindowGroup.id(for: destination, inheritingFrom: source)
        let opensPrivately = (windowGroupID == "private")
        // タブとして開けるのは、追加先のウインドウが実在する場合だけ。
        let asTab = destination.isTab && sourceWindow != nil

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

        let existingWindowIDs = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: windowGroupID, value: request)

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
        var frame = newWindow.frame
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
        newWindow.setFrame(frame, display: true)
    }
}
