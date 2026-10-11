import AppKit

// MARK: - ビューアへ届いた入力の振り分け(2026-10-11)
//
// ビューア(ViewerView)のローカルのイベントモニタ・ホイール・スワイプ・トラックパッドの処理は、以前はすべてビューの中に書かれて
// いて、テストから一度も通せなかった(「GUI 無しで確かめる口」の点検、docs/02「テストの口」)。ここに置くのは**判定だけ** ――
// どのイベントを何に使うか・連続発火をどう間引くか・1 画面ぶんの送りがどこへ動くか。実際にスクロールさせる・操作を実行する・
// カーソルを出すのはビューの仕事のまま(ViewerView.makeScrollMonitor が判定を受けて実行する)。
//
// どの判定も、ユーザー報告で直してきた振る舞いの集まりなので、**理由のコメントは判定と一緒にここへ移してある**。

/// モニタが受け取った 1 つのイベントのうち、振り分けに要るもの。`NSEvent` そのものを持たないのは、テストが組み立てられるようにするため。
struct ViewerInputEvent: Equatable {
    enum Kind: Equatable { case scrollWheel, swipe, magnify, smartMagnify, mouseMoved, keyDown, other }

    var kind: Kind
    var keyCode: UInt16 = 0
    var charactersIgnoringModifiers: String?
    var modifierFlags: NSEvent.ModifierFlags = []
    var phase: NSEvent.Phase = []
    var momentumPhase: NSEvent.Phase = []
    /// キーなら、そのキーに今の表示モードで割り当てられている操作(RemappableKey → KeyBindingStore)。
    var resolvedKeyAction: ViewerAction?
    /// カーソルが常時表示のサイドパネルの上にあるか。
    var isPointerInDockedSidePanel = false

    /// トラックパッド(またはMagic Mouseなど)由来のスクロールか。
    ///
    /// トラックパッド由来のスクロールイベントにはphase/momentumPhase(.began/.changed/.ended/momentum中など)が付与される。
    /// 通常の物理マウスホイールのノッチ操作では、これらは常に空(.phase == [])。
    var isTrackpadOriginated: Bool { !phase.isEmpty || !momentumPhase.isEmpty }
}

extension ViewerInputEvent {
    /// 実物のイベントから組み立てる(ViewerView のモニタ)。
    init(_ event: NSEvent, resolvedKeyAction: ViewerAction?, isPointerInDockedSidePanel: Bool) {
        let kind: Kind = switch event.type {
        case .scrollWheel: .scrollWheel
        case .swipe: .swipe
        case .magnify: .magnify
        case .smartMagnify: .smartMagnify
        case .mouseMoved: .mouseMoved
        case .keyDown: .keyDown
        default: .other
        }
        self.init(
            kind: kind,
            keyCode: event.type == .keyDown ? event.keyCode : 0,
            charactersIgnoringModifiers: event.type == .keyDown ? event.charactersIgnoringModifiers : nil,
            modifierFlags: event.modifierFlags,
            phase: event.type == .scrollWheel ? event.phase : [],
            momentumPhase: event.type == .scrollWheel ? event.momentumPhase : [],
            resolvedKeyAction: resolvedKeyAction,
            isPointerInDockedSidePanel: isPointerInDockedSidePanel
        )
    }
}

/// 振り分けの時点のビューアの状態。
struct ViewerInputContext: Equatable {
    var isThumbnailGridShown = false
    var isSidePanelFloatingOverlay = false
    var isPageInfoPanelShown = false
    /// このウインドウ内のテキストフィールドを編集中か(ファーストレスポンダがフィールドエディタ)。
    var isEditingText = false
    var isLoupeActive = false
    var pinchZoomFactor: CGFloat = 1
    var maxPinchZoomFactor: CGFloat = 4
    var isPageAreaScrollable = false
    /// 環境設定「トラックパッドのスワイプでページ送り」(treatTrackpadFlickAsWheel)。
    var treatsTrackpadFlickAsWheel = false
    /// 環境設定「2本指スクロールを反転」(invertTwoFingerScrolling)。
    var invertsTwoFingerScrolling = false
}

/// 振り分けの結果。ビューはこれを受けて実行する(`pass` はイベントをそのまま通す、それ以外は特記の無い限り消費する)。
enum ViewerInputDecision: Equatable {
    /// イベントをそのまま通す。
    case pass
    /// 何もせず消費する。
    case consume
    /// カーソルの自動非表示の解除・クロームの自動表示を行ってから通す。
    case mouseMoved
    case perform(ViewerAction)
    case closeThumbnailGrid
    case moveThumbnailGridCursor(keyCode: UInt16)
    case closePageInfoPanel
    /// 2本指のトラックパッドのジェスチャー(`ViewerWheelInput.trackpadGesture`)へ渡す。`invertsScroll` なら、そのぶんの素のスクロールを
    /// 反対向きに肩代わりする(引き受けたら消費、引き受けなければ通す)。それ以外は通す。
    case trackpadGesture(invertsScroll: Bool)
    /// ホイール(`ViewerWheelInput.wheel`)へ渡す。`modifiers` が nil なら割り当ての対象外の修飾キー。
    /// `invertsScroll` なら、ホイールが何もしなかったときに反対向きのスクロールを肩代わりし、どちらでも消費する。そうでなければ通す。
    case wheel(isInverted: Bool, modifiers: MouseTrigger.Modifiers?, invertsScroll: Bool)
    case magnify
    case smartMagnify
    /// 3本指/4本指のスワイプ(`ViewerWheelInput.swipe`)へ渡してから通す。
    case swipe
    case zoomIn
    /// 断ったことをビープで知らせて消費する。
    case beep
    case closeLoupe
    case resetPinchZoom
}

enum ViewerInputRouter {
    /// Esc・Return・Enter のキーコード。
    static let dismissKeyCodes: Set<UInt16> = [53, 36, 76]
    /// 矢印キー(← → ↓ ↑)のキーコード。
    static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    static func route(_ event: ViewerInputEvent, in context: ViewerInputContext) -> ViewerInputDecision {
        let menuModifiers = event.modifierFlags.intersection([.command, .option, .control])
        // マウス移動(.mouseMoved)は、カーソル自動非表示の解除・ツールバー/プログレスバーの
        // 自動表示のトリガーとして、サムネイル一覧表示中かどうかに関わらず常に処理する必要が
        // ある。下のサムネイル一覧のガードより後ろにあると、サムネイル一覧を開いている間
        // マウスを動かしてもregisterMouseActivity()が呼ばれず、カーソル自動非表示のタイマーが
        // 解除されない(ユーザー報告: サムネイル一覧上でカーソルが見えなくなる)。
        if event.kind == .mouseMoved { return .mouseMoved }

        // サムネイル一覧(ThumbnailGridView)を表示している間は、スクロール/スワイプによる
        // ページ送りやキーボードショートカットが背後の本へ影響しないようにする(以前は
        // 独立したシートとして表示していたため、シート自身が別ウインドウ扱いとなり
        // event.window(モニタのウインドウのガード)が一致せず自動的に素通りしていた。同一ウインドウ内の
        // 重ね表示に変更したことに伴い、ここで明示的に無視する必要がある)。
        // サイドパネル(フォルダブラウザ + 本の中身ブラウザ、ContentView.swift側で管理)
        // 表示中も、サムネイル一覧と同じ理由で背後の本のページ送りへ影響しないようにする。
        // 例外: サムネイル一覧の表示中でも、「ページ一覧を表示/非表示」に割り当てられた
        // キーだけは通す。この操作はトグルなので、開いたときと同じキーでもう一度押したら
        // 閉じられる必要がある(ユーザー報告: tキーで開いたページ一覧がtキーで閉じられず、
        // パネルの外側をクリックするしかなかった)。
        // マウス側は、パネルを閉じるクリックを拾う専用のモニタ
        // (ViewerView.installThumbnailGridDismissMonitorIfNeeded)が閉じる役目を果たしている。
        let gridTakesKeys = context.isThumbnailGridShown && !context.isSidePanelFloatingOverlay
            && event.kind == .keyDown && !context.isEditingText
        if gridTakesKeys, event.resolvedKeyAction == .showThumbnailGrid {
            return .perform(.showThumbnailGrid)
        }
        // ページ一覧のキー(2026-09-27、監査 32): Esc・Return・Enter で閉じる、矢印キーで表示中のページを動かす
        // (パネルの外のクリックで閉じるのは従来どおり)。修飾キーの付いたキーはメニューへ渡す。
        if gridTakesKeys, menuModifiers.isEmpty {
            if dismissKeyCodes.contains(event.keyCode) { return .closeThumbnailGrid }
            if arrowKeyCodes.contains(event.keyCode) { return .moveThumbnailGridCursor(keyCode: event.keyCode) }
        }
        guard !context.isThumbnailGridShown, !context.isSidePanelFloatingOverlay else { return .pass }

        // 「情報を見る」のパネルを出している間は、背後の本を送らない(2026-10-04 の監査 V-11。以前は送れて、パネルが黙って
        // 別のページの情報に変わった)。Esc・Return・Enter で閉じる(ページ一覧と同じ)。修飾キーの付いたキーはメニューへ渡す。
        if context.isPageInfoPanelShown {
            switch event.kind {
            case .keyDown:
                guard menuModifiers.isEmpty else { return .pass }
                return dismissKeyCodes.contains(event.keyCode) ? .closePageInfoPanel : .consume
            case .scrollWheel, .swipe:
                return .consume
            default:
                return .pass
            }
        }

        // 常時表示のサイドパネルの上での操作は、パネル自身のスクロールに任せて
        // ページ送りには使わない(ユーザー報告: 一覧の上でホイールを回すと、一覧が
        // スクロールすると同時にページ送りまで起きてしまう)。イベント自体は消費せず
        // そのまま通す ―― 一覧のスクロールはこのモニタではなくパネル側の仕事のため。
        // キー入力(.keyDown)は対象外。カーソルの位置に関わらず効くべきものであるため。
        // 浮かせて表示しているパネルは、上のisSidePanelFloatingOverlayで既に除かれている。
        if event.kind != .keyDown, event.isPointerInDockedSidePanel { return .pass }

        switch event.kind {
        case .scrollWheel:
            return routeScrollWheel(event, in: context)
        case .magnify:
            // 標準の処理(SwiftUIのScrollViewは既定でmagnificationを受け付けないが、
            // 将来にわたって二重に処理されないことを保証するため)へは渡さない。
            return .magnify
        case .smartMagnify:
            return .smartMagnify
        case .swipe:
            // 「ページ間をスワイプ」が3本指/4本指設定の場合は、こちらの専用イベントで
            // 届く(2本指設定の場合の扱いはrouteScrollWheelのtrackpadGesture参照)。
            return .swipe
        case .keyDown:
            return routeKeyDown(event, in: context, menuModifiers: menuModifiers)
        case .mouseMoved, .other:
            // .mouseMovedは上で早期リターン済みのため、ここには実質到達しない。
            return .pass
        }
    }

    private static func routeScrollWheel(_ event: ViewerInputEvent, in context: ViewerInputContext) -> ViewerInputDecision {
        // 【調査で判明した重要な事実】「システム設定」>「トラックパッド」の
        // 「ページ間をスワイプ」が2本指設定の場合、その操作は専用のイベント種別
        // (NSEvent.swipe)としては届かず、通常の.scrollWheelイベントの並びとして
        // 届く(ログで確認済み。横方向にスワイプしていても、deltaXが大きい
        // .scrollWheelイベントが連続するだけで、.swipeイベントは一切発生しない)。
        // そのため、1個ずつの.scrollWheelイベントのdeltaYだけを見てページ送りする
        // 従来のhandleScrollのロジックのままでは、意図的な横方向スワイプの最中に
        // 生じるわずかな縦方向のぶれ(deltaY)にまで反応してしまい、1回のつもりの
        // スワイプで複数回・意図しないページ送りが発生する原因になっていた
        // (これが一連の不具合報告の実際の原因だった)。
        //
        // 「スワイプでページ送り」がONのときは、トラックパッド由来の
        // .scrollWheelイベントをホイールには渡さず、代わりに
        // trackpadGestureへ渡す。そちらでは指が触れてから離れるまでの
        // 一連のイベント(1回のジェスチャー全体)をまとめて扱い、ジェスチャー全体で
        // 見て横方向優位だった場合にだけ、ジェスチャーの終わりに1回だけページ送りを
        // 行う。縦方向優位だった場合(2本指の縦スクロール)は何もしない
        // (完全に無視する)。物理マウスホイールでのページ送りはこれまでどおり
        // 影響を受けない。
        let isTrackpadOriginated = event.isTrackpadOriginated
        // 環境設定「2本指スクロールを反転」(AppPreferences.invertTwoFingerScrolling)は、
        // phaseを伴うスクロール ― トラックパッドやMagic Mouseの、指でなぞる操作 ―
        // だけを対象にする。物理マウスホイールのノッチ(phaseが空)は対象外。
        let isInverted = context.invertsTwoFingerScrolling && isTrackpadOriginated
        // ホイールの割り当てを引くための修飾キー。shiftを受け付けないのは、macOSが
        // ホイール由来のスクロールイベントについてshift押下時にdeltaXとdeltaYを
        // 入れ替えるため、向きの判定が信用できないから(MouseTrigger参照)。
        // nil(=control/command/shiftのいずれか)の場合、ホイールは何もしない。
        let wheelModifiers = MouseTrigger.Modifiers.from(event.modifierFlags, allowsShift: false)
        // ピンチ拡大中は、2本指の横方向の動きは「拡大した画像を横へ動かしたい」で
        // あってページ送りではない。ここを通すと、拡大して読んでいる最中に画像を
        // 横へずらしただけでページが送られ(そのうえ拡大も解除され)てしまう。
        // 3本指/4本指の.swipeは、スクロールと取り違えようのない
        // 明示的なページ送り操作なので、拡大中でもそのまま働かせる。
        if context.treatsTrackpadFlickAsWheel && isTrackpadOriginated && context.pinchZoomFactor == 1 {
            // このぶんの素のスクロールは、通常はイベントをそのまま通して
            // ScrollViewに任せる。反転が有効なときだけ肩代わりする
            // (ViewerView.performInvertedScrollのコメント参照)。
            return .trackpadGesture(invertsScroll: isInverted)
        }
        if isInverted, context.isPageAreaScrollable {
            // 端でのページ送り判定(ホイール)を先に済ませてから動かす。
            // 判定は「このイベントを処理する**前**の位置」で行う必要があるため
            // (ViewerWheelInput.wheelのコメント参照)、順番を入れ替えられない。
            return .wheel(isInverted: true, modifiers: wheelModifiers, invertsScroll: true)
        }
        return .wheel(isInverted: false, modifiers: wheelModifiers, invertsScroll: false)
    }

    private static func routeKeyDown(
        _ event: ViewerInputEvent, in context: ViewerInputContext, menuModifiers: NSEvent.ModifierFlags
    ) -> ViewerInputDecision {
        // サイドパネルの絞り込み検索欄など、このウインドウ内のテキストフィールドを
        // 編集している間は、キー入力をページ送り等のショートカットとして横取りしない
        // (横取りすると「a」と打っただけでブックマークが追加される、といった挙動に
        // なってしまう)。AppKitではテキストフィールドの編集中、実際のファースト
        // レスポンダはフィールド自身ではなくウインドウ共有の「フィールドエディタ」
        // (NSTextView)になるため、それを見て判定する。ブックマーク名の変更シートなどが
        // 別ウインドウとして開く場合は、モニタのevent.window === hostWindowのガードで
        // 既に除外されている(ここで拾うのは同じウインドウ内の入力欄)。
        if context.isEditingText { return .pass }
        // ⌘= も「拡大」にする。表示メニューの「拡大」は ⌘+ で、US 配列の ⌘=(Shift 無し)はメニューに届かない
        // (ホームの HomeZoomInEqualsKeyMonitor と同じ理由。JIS 配列の ⇧⌘- も "=" なので Shift は問わない)。
        if menuModifiers == .command, event.charactersIgnoringModifiers == "=" {
            // 上限では、淡色のメニュー項目のキーと同じく鳴らす(2026-10-04 の監査 V-19)。
            if !context.isLoupeActive, context.pinchZoomFactor >= context.maxPinchZoomFactor { return .beep }
            return .zoomIn
        }
        // ESCキー(keyCode 53)は、RemappableKey/keyBindingStoreによる
        // カスタマイズ可能なキー割り当ての対象には含めず、常に固定の「閉じる」操作
        // という慣習に合わせて別枠で扱う。拡大鏡(ルーペ)表示中に押すと、
        // ページ送りなど他の操作には一切影響させずに拡大鏡だけを閉じる。
        // 拡大鏡が出ていなければ、ピンチ拡大の解除に使う。どちらにも当てはまらない
        // ときはイベントを消費せずそのまま通し、フルスクリーンの解除など
        // macOS標準のESCの働きを妨げない。
        if event.keyCode == 53 {
            if context.isLoupeActive { return .closeLoupe }
            if context.pinchZoomFactor > 1 { return .resetPinchZoom }
        }
        // キー入力の検知は、以前はSwiftUIの.onKeyPressで行っていたが、
        // 環境によっては矢印キーがそちらまで届かない(ビープ音が鳴るだけで
        // 何も起きない)不具合があったため、動作が確実なこちらのNSEventベースの
        // 経路に統合した(詳細はRemappableKey.from(nsEvent:)のコメント参照)。
        // 割り当てがあればイベントをここで消費し、これ以上(標準のフォーカス移動や
        // ビープ音などへ)伝播させない。
        if let action = event.resolvedKeyAction { return .perform(action) }
        return .pass
    }
}

// MARK: - ホイール・スワイプ・トラックパッドの連続発火の間引き

/// ホイールの割り当てを引く手立て(向きと修飾キー → 今の表示モードで割り当てられた操作)。
typealias ViewerWheelActionResolver = (MouseTrigger.WheelDirection, MouseTrigger.Modifiers) -> ViewerAction?

/// ホイール・スワイプ・2本指のトラックパッドのジェスチャーが、いつ・どの操作になるか。間引きのための時刻と積算値を持つ
/// (ViewerView が `@State` で 1 つ持つ)。時刻は呼び出し側が渡す(テストが進められるように)。
struct ViewerWheelInput: Equatable {
    /// 直前にスクロールホイールでページ送りを実行した時刻。一部のマウス/ドライバが
    /// 1ノッチの回転を複数の細かいscrollWheelイベントに分けて送ってくることがあり、
    /// それによって1ノッチのつもりが2回ページ送りされてしまう現象を防ぐために使う(`wheel` 参照)。
    private(set) var lastWheelActionAt: Date?
    static let wheelActionCooldown: TimeInterval = 0.04
    /// 直前にトラックパッドのスワイプ(3本指/4本指設定の場合)でページ送りを実行した時刻(`swipe` 参照)。
    private(set) var lastSwipeActionAt: Date?
    /// `swipe`(3本指/4本指設定の場合の.swipeイベント)用の連続発火防止の間隔。
    /// 2本指設定の場合(`trackpadGesture`)はジェスチャー全体を1回だけ判定する
    /// 作りになっており、この定数は使わない(詳細は`swipe`のコメント参照)。
    static let swipeActionCooldown: TimeInterval = 0.3
    /// 現在進行中の2本指トラックパッド操作(.scrollWheelイベントのphaseで区切られる
    /// 一連のジェスチャー)における、縦横それぞれの動きの累計値(`trackpadGesture` 参照)。
    private(set) var trackpadGestureDeltaX: CGFloat = 0
    private(set) var trackpadGestureDeltaY: CGFloat = 0

    /// ホイールの結果。
    enum WheelOutcome: Equatable {
        /// 何もしない(ScrollView標準のスクロール、または反転の肩代わりに任せる)。
        case unhandled
        /// この操作を実行する(nil = 割り当てが無い。それでも「スクロールには使わなかった」扱い)。
        case perform(ViewerAction?)
        /// 1画面ぶん送る(ViewerScrollPlanner.oneScreen)。
        case scrollByOneScreen(forward: Bool, allowPageChange: Bool)

        /// このイベントをスクロールに使わなかったか(反転の肩代わりをしない)。
        var didHandle: Bool { self != .unhandled }
    }

    /// ホイールのイベント 1 つ。
    ///
    /// - Parameter isInverted: 環境設定「2本指スクロールを反転」が、このイベントに効いているか
    ///   (AppPreferences.invertTwoFingerScrolling参照)。
    /// - Parameter modifiers: このイベントの修飾キー。**nilは「割り当ての対象外」を意味する**
    ///   (control/command、およびホイールにおけるshift。MouseTrigger.Modifiers.from参照)。
    ///   その場合は何もせず、スクロール自体は呼び出し側の経路
    ///   (ScrollView標準、または反転が有効ならperformInvertedScroll)にそのまま任される。
    /// - Parameter configuredBehavior: 環境設定「スクロールできるとき」(WheelScrollBehavior、cooViewerのCanScrollMode相当)の今の表示モードの値。
    /// - Parameter metrics: スクロール位置(このイベントを ScrollView が処理する**前**の位置)。取れなければ nil。
    mutating func wheel(
        deltaY: CGFloat, isInverted: Bool, modifiers: MouseTrigger.Modifiers?,
        isPageAreaScrollable: Bool, pinchZoomFactor: CGFloat, configuredBehavior: WheelScrollBehavior,
        metrics: ViewerScrollMetrics?, now: Date, action: ViewerWheelActionResolver
    ) -> WheelOutcome {
        // 「画面内に収める」モードにはスクロールする余地が無いため、従来どおりホイールの
        // 割り当て(既定はページ送り)をそのまま実行する。
        // それ以外のモードでは、環境設定「スクロールできるとき」に従う。
        // 「画面内に収める」でもピンチ拡大中はスクロールできる余地があるため、そちらの経路に乗せる。
        if isPageAreaScrollable {
            return wheelInScrollableMode(
                deltaY: deltaY, isInverted: isInverted, modifiers: modifiers, pinchZoomFactor: pinchZoomFactor,
                configuredBehavior: configuredBehavior, metrics: metrics, now: now, action: action
            )
        }
        guard let modifiers else { return .unhandled }

        // NSEvent.scrollingDeltaYの符号は、ホイールを物理的に上へ回す(指を上に動かす)と
        // 正の値になる(以前の実装ではここが逆になっており、ホイールを上に回すと.wheelDownに
        // 割り当てた操作が実行されてしまっていた。設定画面の「Scroll Wheel Up」という表示と
        // 実際の動作が食い違うバグだったため、対応する分岐を入れ替えて修正している)。
        guard deltaY > 2 || deltaY < -2 else { return .unhandled }

        // 一部のマウス/ドライバでは、物理的には1ノッチしか回していなくても、その回転が
        // ごく短い間隔の複数のscrollWheelイベントに分かれて届くことがある。それらを
        // まとめて1回のページ送りとして扱うため、直前のページ送りからこの間隔未満での
        // 連続発火は無視する(意図的に素早く連続でノッチを回したときの間隔は、通常
        // これよりも空くため、そちらは取りこぼさない)。
        guard !isCoolingDown(since: lastWheelActionAt, now: now, cooldown: Self.wheelActionCooldown) else { return .unhandled }
        lastWheelActionAt = now

        // ここは「向き→操作」の割り当てそのものなので、反転設定の影響を受けない
        // (AppPreferences.invertTwoFingerScrolling参照)。そもそもこの分岐に来るのは
        // スクロールする余地が無いときだけで、反転させる対象のスクロールが存在しない。
        return .perform(action(deltaY > 0 ? .up : .down, modifiers))
    }

    /// スクロールできるモード(横幅に合わせる/同(単ページ)/拡大縮小しない)でホイールを回したときの処理。
    /// cooViewerの`wheelAction:`の`canScrollMode`による分岐をそのまま移植したもの
    /// (WheelScrollBehavior参照)。
    ///
    /// 「まだスクロールできるか」は、ScrollViewがこのイベントを処理する**前**の位置で判定する。
    /// そのため、端に着くまでは普通にスクロールし、端に着いた状態でもう一度回したときに初めて
    /// 横への回り込みやページ送りが起きる ― cooViewerと同じ操作感になる。
    private mutating func wheelInScrollableMode(
        deltaY: CGFloat, isInverted: Bool, modifiers: MouseTrigger.Modifiers?, pinchZoomFactor: CGFloat,
        configuredBehavior: WheelScrollBehavior, metrics: ViewerScrollMetrics?, now: Date,
        action: ViewerWheelActionResolver
    ) -> WheelOutcome {
        // 割り当ての対象外の修飾キー(control/command/shift)が押されている場合は、何もせず
        // ScrollView標準のスクロールに任せる(`wheel`のmodifiers引数のコメント参照)。
        guard let modifiers else { return .unhandled }

        // 修飾キー付きのホイールは、スクロール操作ではなく**明示的な指示**なので、
        // 「スクロールできるとき」(WheelScrollBehavior)の判定を通さず、割り当てられた操作を
        // そのまま実行する。素のホイールでスクロールしたいモードでも、option+ホイールには
        // 別の操作を割り当てておける、という使い分けのため。割り当てが無ければ従来どおり
        // ScrollViewに任せる。
        if !modifiers.isEmpty {
            let direction: MouseTrigger.WheelDirection = deltaY > 0 ? .up : .down
            guard deltaY > 2 || deltaY < -2 else { return .unhandled }
            guard let assigned = action(direction, modifiers), assigned != .none else { return .unhandled }
            guard !isCoolingDown(since: lastWheelActionAt, now: now, cooldown: Self.wheelActionCooldown) else {
                return .unhandled
            }
            lastWheelActionAt = now
            return .perform(assigned)
        }

        // ピンチ拡大中は、どのモードでもホイールをスクロール専用にする(ユーザーの判断)。
        // 拡大して細部を読んでいる最中に端まで来たからといってページが送られると、
        // 拡大も一緒に解除されて読んでいた場所を見失う。拡大を解除すれば、そのモード本来の
        // 設定(WheelScrollBehavior)にそのまま戻る。
        let behavior: WheelScrollBehavior = pinchZoomFactor > 1 ? .scrollOnly : configuredBehavior
        // スクロールのみ: ScrollViewに任せる(何もしない)。
        guard behavior != .scrollOnly else { return .unhandled }

        guard deltaY > 2 || deltaY < -2 else { return .unhandled }
        guard !isCoolingDown(since: lastWheelActionAt, now: now, cooldown: Self.wheelActionCooldown) else { return .unhandled }

        // NSEvent.scrollingDeltaYは、ホイールを上へ回すと正になる(`wheel`のコメント参照)。
        //
        // 向きの意味が2種類あることに注意。
        // - assignedForward: 「ホイール上/下」への**割り当て**を引くための向き。反転設定の
        //   影響を受けない(反転は画像が動く向きだけを変える設定であり、割り当ての上下まで
        //   入れ替えると「キー・マウス」設定側の入れ替えと二重になるため。
        //   AppPreferences.invertTwoFingerScrolling参照)。
        // - scrollForward: 実際にページの**内容が進む**向き。端まで来たときのスクロール送り
        //   /ページ送りは、いま行っているスクロールの延長なので、こちらを使う。
        let assignedForward = deltaY < 0
        let scrollForward = isInverted ? deltaY > 0 : deltaY < 0

        if behavior == .turnPage {
            // スクロールには使わず、常に割り当てられた操作を行う。
            lastWheelActionAt = now
            return .perform(action(assignedForward ? .down : .up, []))
        }

        // まだ縦に動ける間はScrollViewに任せ、端に着いてから初めてこちらが引き取る。
        guard let metrics else { return .unhandled }
        guard !metrics.canScrollVertically(forward: scrollForward) else { return .unhandled }

        lastWheelActionAt = now
        switch behavior {
        case .scrollAndTurnPage:
            return .scrollByOneScreen(forward: scrollForward, allowPageChange: true)
        case .scrollAndWrap:
            // 横へは回り込むが、ページはめくらない(cooViewerのcanScrollMode == 1)。
            return .scrollByOneScreen(forward: scrollForward, allowPageChange: false)
        case .scrollOnly, .turnPage:
            return .unhandled  // 上で処理済み
        }
    }

    /// トラックパッドの「ページ間をスワイプ」ジェスチャーが3本指/4本指設定になっている
    /// 場合の処理。この場合はNSEvent.swipeという専用のイベント種別で届く(2本指設定の
    /// 場合は専用イベントではなく通常の.scrollWheelイベントとして届くため、
    /// `trackpadGesture`で別途処理している。詳細はViewerInputRouterのコメント参照)。
    /// 設定がONのときだけ、ホイールと同じ割り当て(既定はページ送り)として扱う。
    ///
    /// 2本指設定の場合(`trackpadGesture`)は、ジェスチャー全体をまとめて
    /// 一度だけ判定する作りになっているため、1回のスワイプで複数回反応してしまう心配は
    /// 構造的にない。一方、この3本指/4本指設定の場合に.swipeイベントが1回のフリックに対して
    /// 実際に何回発生するのかは動作確認ができておらず不明なため、念のため
    /// swipeActionCooldownによる連続発火防止を残している(ホイールのwheelActionCooldownと
    /// 同じ考え方)。
    ///
    /// - Returns: ホイールのどちらの向きの割り当てを実行するか(nil = 何もしない)。修飾キー付きのスワイプは扱わない
    ///   (ホイールの素の割り当てをそのまま使う)。
    mutating func swipe(deltaX: CGFloat, isEnabled: Bool, now: Date) -> MouseTrigger.WheelDirection? {
        guard isEnabled else { return nil }
        guard !isCoolingDown(since: lastSwipeActionAt, now: now, cooldown: Self.swipeActionCooldown) else { return nil }
        lastSwipeActionAt = now
        // NSEvent.swipeのdeltaXは、指を左から右へ払う(スワイプする)と正の値になる。
        if deltaX > 0 { return .up }
        if deltaX < 0 { return .down }
        return nil
    }

    /// トラックパッドの「ページ間をスワイプ」ジェスチャーが2本指設定になっている場合の処理。
    /// この場合のジェスチャーは専用のイベント種別ではなく、通常の.scrollWheelイベントの並びとして届く
    /// (ViewerInputRouterのコメント参照)。
    /// 指が触れてから離れるまで(phaseが.beganで始まり.endedで終わる一連のイベント)を
    /// 1回のジェスチャーとしてまとめ、その間のdeltaX/deltaYを積算しておいて、ジェスチャーが
    /// 終わった時点で初めて「横方向優位だったか、縦方向優位だったか」を判定する。
    ///
    /// - 横方向優位だった場合: 意図的なページ送りスワイプとみなし、その時点で1回だけ
    ///   ページ送りを行う(1個ずつのイベントに反応するわけではないので、1回のスワイプで
    ///   複数回ページ送りされてしまうことはない)。
    /// - 縦方向優位だった場合: 2本指の縦スクロールとみなし、何もしない(完全に無視する)。
    ///
    /// 指を離した後の慣性スクロール(momentumPhase)中のイベントは、
    /// phaseが空になるため、ここではそのまま無視される(判定は指を離した瞬間の
    /// ジェスチャーの向きだけで決まる)。
    ///
    /// - Returns: ホイールのどちらの向きの割り当てを実行するか(nil = 何もしない)。
    mutating func trackpadGesture(phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat) -> MouseTrigger.WheelDirection? {
        if phase.contains(.began) {
            trackpadGestureDeltaX = 0
            trackpadGestureDeltaY = 0
        }
        guard !phase.isEmpty else { return nil }
        trackpadGestureDeltaX += deltaX
        trackpadGestureDeltaY += deltaY

        guard phase.contains(.ended) else { return nil }
        defer {
            trackpadGestureDeltaX = 0
            trackpadGestureDeltaY = 0
        }

        // 極端に小さい動き(触れただけ、など)まで反応しないよう、最低限の移動量を求める。
        guard abs(trackpadGestureDeltaX) >= 10 else { return nil }
        guard abs(trackpadGestureDeltaX) > abs(trackpadGestureDeltaY) else { return nil }

        // ジェスチャー全体につき、ここに到達するのは(.endedを受け取る)1回だけなので、
        // swipeのような連続発火防止のクールダウンは不要。
        // 指を左から右へ払う(スワイプする)と、積算したdeltaXは正の値になる。
        // 修飾キー付きのスワイプは扱わない(swipeと同じ)。
        return trackpadGestureDeltaX > 0 ? .up : .down
    }

    private func isCoolingDown(since last: Date?, now: Date, cooldown: TimeInterval) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) < cooldown
    }
}

// MARK: - 1 画面ぶんの送り

/// ページ表示の ScrollView のスクロール位置(ScrollViewBounds の値の写し)。左上を原点とし、下へ進むほど y が増える向き。
struct ViewerScrollMetrics: Equatable {
    var position: CGPoint
    var maxX: CGFloat
    var maxY: CGFloat
    var visibleSize: CGSize

    /// 端に着いているかどうかの判定に使う許容誤差。拡大率の計算にはどうしても浮動小数の
    /// 誤差が乗るため、厳密比較にすると1px未満ずれているだけで「まだ動ける」と誤判定し、
    /// ページが送られずその場で止まってしまう。
    static let edgeEpsilon: CGFloat = 1

    /// その向きへまだ縦に動けるか。
    func canScrollVertically(forward: Bool) -> Bool {
        forward ? position.y < maxY - Self.edgeEpsilon : position.y > Self.edgeEpsilon
    }
}

/// 1 画面ぶん・決まった量の送り、ページの入りの隅(cooViewerの CustomImageView.next/prev・firstScroll 相当)の行き先。
enum ViewerScrollPlanner {
    enum Step: Equatable {
        /// このスクロール位置へ動かす。
        case scroll(to: CGPoint)
        /// 縦にも横にも余地が無いのでページを送る。`entersAtEnd` なら、移動先のページを読み終わり側の隅から表示し始める
        /// (cooViewerのsetStartFromEnd:YES相当)。
        case advance(forward: Bool, entersAtEnd: Bool)
        /// スクロールという概念が無い(画面内に収める)ので、素直にページ送りへ縮退する(入りの隅の指定は変えない)。
        case turnPage(forward: Bool)
        /// その場で止まる。
        case none
    }

    /// 1画面分スクロールし、それ以上動けなければページを送る
    /// (cooViewerのCustomImageView.next/prevと同じ3段階。ViewerAction.scrollAndMoveNext参照)。
    /// - allowPageChange: 縦にも横にも余地が無くなったときにページを送るかどうか。
    ///   falseだと、その場で止まる(ホイール動作「スクロール」= cooViewerのcanScrollMode == 1)。
    /// - metrics: スクロールできない(画面内に収める)・位置が取れないときは nil。
    static func oneScreen(
        forward: Bool, allowPageChange: Bool, metrics: ViewerScrollMetrics?, readingDirection: ReadingDirection
    ) -> Step {
        // 画面内に収めるモードにはスクロールという概念が無いので、素直にページ送りへ縮退する。
        // この縮退があるおかげで、cooViewerがモード別のキー設定で実現していた既定の操作感を
        // 1つの割り当てで再現できる(ViewerAction.scrollAndMoveNextのコメント参照)。
        guard let metrics else { return allowPageChange ? .turnPage(forward: forward) : .none }
        let epsilon = ViewerScrollMetrics.edgeEpsilon
        let position = metrics.position
        let screen = metrics.visibleSize

        // 1. まだ縦に動けるなら、縦に1画面分動かすだけ
        if let vertical = verticalOneScreen(down: forward, metrics: metrics) { return .scroll(to: vertical) }

        // 2. 縦は端に着いている。横に余地があれば読み方向へ1画面分ずらし、縦は反対の端へ移す
        //    (進むときは次の列の最上部から、戻るときは前の列の最下部から読み始める)
        let forwardSign: CGFloat = readingDirection == .rightToLeft ? -1 : 1
        let step = (forward ? forwardSign : -forwardSign) * screen.width
        let hasHorizontalRoom = step > 0 ? position.x < metrics.maxX - epsilon : position.x > epsilon
        if hasHorizontalRoom {
            return .scroll(to: CGPoint(x: position.x + step, y: forward ? 0 : metrics.maxY))
        }

        // 3. どちらにも余地が無い ― ページを送る。戻る場合は、移動先のページを
        //    読み終わり側の隅から表示し始める(cooViewerのsetStartFromEnd:YES相当)。
        guard allowPageChange else { return .none }
        return .advance(forward: forward, entersAtEnd: !forward)
    }

    /// 縦方向にだけ1画面分スクロールした位置(cooViewerの「1画面分下へ/上へ」相当)。動けなければ nil
    /// (横への回り込み・ページ送りは行わない)。
    static func verticalOneScreen(down: Bool, metrics: ViewerScrollMetrics) -> CGPoint? {
        let epsilon = ViewerScrollMetrics.edgeEpsilon
        let position = metrics.position
        if down, position.y < metrics.maxY - epsilon {
            return CGPoint(x: position.x, y: position.y + metrics.visibleSize.height)
        }
        if !down, position.y > epsilon {
            return CGPoint(x: position.x, y: position.y - metrics.visibleSize.height)
        }
        return nil
    }

    /// ページを表示し始めるときのスクロール位置(cooViewerのfirstScroll相当)。
    /// 読み始め側の隅は読み方向で変わる ― 右開きなら右上、左開きなら左上。
    /// atEndがtrueなら読み終わり側の隅(右開きなら左下、左開きなら右下)。
    ///
    /// これが無いと、右開きの本で「横幅に合わせる(単ページ)」にしたときに毎回「左半分」から表示が始まり、
    /// ページをめくるたびに自分で右へスクロールし直すことになる。
    static func pageCorner(atEnd: Bool, readingDirection: ReadingDirection, metrics: ViewerScrollMetrics) -> CGPoint {
        let isRightToLeft = readingDirection == .rightToLeft
        let startX: CGFloat = isRightToLeft ? metrics.maxX : 0
        let endX: CGFloat = isRightToLeft ? 0 : metrics.maxX
        return CGPoint(x: atEnd ? endX : startX, y: atEnd ? metrics.maxY : 0)
    }
}
