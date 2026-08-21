import AppKit
import Foundation

/// メニューバーのメニューが開いている間、**メニューの内容に影響する状態の更新を保留**し、
/// 閉じたあとにまとめて適用するための調整役。アプリ全体で1つ(shared)。
///
/// ■ 何を防ぐのか(実機で確認したクラッシュ)
/// SwiftUIの`Commands`は、`@FocusedValue`や`ObservableObject`が変化するたびにメニュー項目を
/// 作り直す(`AppKitMainMenuItem.menuNeedsUpdate` → `NSMenu setItemArray:`)。これが
/// **メニューを開いている最中**に起きると、macOS 26のメニュー実装(`NSContextMenuImpl` /
/// `NSTableViewBackedMenuRepresentation`)が行高キャッシュの範囲外アクセスで
/// `NSRangeException`(`index 2 beyond bounds [0 .. 1]`)を投げ、アプリが落ちる
/// (Xcodeから起動していると`_crashOnException:`で止まり、ハングしたように見える)。
///
/// このアプリでメニュー項目を左右する値の多くは、**ユーザーの操作とは無関係に非同期で**変わる:
///
/// - `AppState.hasPartnerPageDisplayed` — 見開きのデコードが終わった瞬間。
///   「画像のエクスポート」(1項目→3項目)とLayoutメニューの構成(左右2サブメニュー↔平坦)が変わる。
/// - `AppState.siblingBooks` — 同じフォルダの走査が終わった瞬間。
///   「同じフォルダのファイルを開く」が1項目(権限付与)↔N項目に変わる。
/// - `AppState.currentBookmarks` — 本を開いた後の反映。「ブックマーク一覧」の項目数が変わる。
/// - `RecentFilesStore.entries` — 本を開き終えた瞬間・ボリュームのマウント。「最近開いた
///   ファイル」が「(なし)」↔N項目に変わる。
/// - `FavoritesStore` — お気に入り一覧そのもの。
///
/// つまり「大きな書庫を開く → メニューを開いたまま待つ」だけで再現しうる。
///
/// ■ なぜ「値の凍結」ではなく「更新の保留」なのか
/// 以前は`MenuTrackingFreezer`という、`.commands`が読む**値だけ**をメニュー追跡中に凍結する
/// 仕組みがあった。これは効かなかった: 凍結しても大元の`@Published`は発火しているため、
/// SwiftUIは結局`.commands`を再評価して`setItemArray:`を呼ぶ。内容が同じでも呼ばれること自体が
/// クラッシュの条件だったため、症状は残った(そのためcommit e235563で削除された)。
///
/// こちらは**発火そのものを起こさせない**。値が変わらなければSwiftUIはメニューを作り直さない。
///
/// ■ なぜ閉じた直後ではなく1回ランループを跨ぐのか
/// `NSMenu.didEndTrackingNotification`は、メインスレッドからpostされる場合
/// `addObserver(forName:object:queue:)`に`queue: .main`を指定していても**同期配送**される。
/// つまりハンドラは、AppKitがまだトラッキングを巻き戻している最中(メニューウインドウが
/// 消えきる前)に走る。そこで`setItemArray:`やSwiftUIのビュー削除を行うのは、開いている最中に
/// 行うのと同じ危うさが残るため、`DispatchQueue.main.async`で1回ランループを跨いでから適用する。
///
/// ■ 使い方
/// ```swift
/// MenuBarMenuGate.shared.run("someKey") { … }   // 追跡中でなければ即実行
/// ```
/// 同じキーで追跡中に何度も予約した場合、**最後の1つだけ**が実行される(ページ送りのように
/// 追跡中に何度も変わる値でも、適用されるのは最終状態だけで済む)。キーは呼び出し箇所ごとに
/// 固有にすること(ウインドウごとに別インスタンスがある値は、キーにインスタンスの識別子を
/// 混ぜること。`AppState.menuGateKey(_:)`参照)。
@MainActor
final class MenuBarMenuGate {
    static let shared = MenuBarMenuGate()

    /// 開いているメニューバーのメニューの数。メニューバー直下のメニューを開いてから
    /// サブメニューへカーソルを移すと、その分だけ入れ子に増える。
    private var trackingDepth = 0
    /// 保留中の適用処理(キー → 最後に予約された処理)。
    private var pending: [String: () -> Void] = [:]
    /// 予約された順序。適用も同じ順序で行う(辞書の列挙順は不定のため別に持つ)。
    private var pendingOrder: [String] = []
    /// メニューが閉じるたびに毎回実行する処理(onMenuBarMenuDidClose参照)。
    private var closeHandlers: [String: () -> Void] = [:]
    private var closeHandlerOrder: [String] = []
    /// 適用をランループの次の回へ予約済みか(二重に予約しないための目印)。
    private var isFlushScheduled = false
    private let tokens = NotificationObserverTokens()

    private init() {
        let center = NotificationCenter.default
        tokens.add(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                // ウインドウ内のPicker/Menuのドロップダウンやコンテキストメニューでは何もしない
                // (それらはSwiftUIの`Commands`とは無関係で、保留する理由が無い)。
                // 詳細はMenuBarTracking.isMainMenu(_:)のコメント参照。
                guard MenuBarTracking.isMainMenu(notification) else { return }
                self?.beginTracking()
            }
        })
        tokens.add(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard MenuBarTracking.isMainMenu(notification) else { return }
                self?.endTracking()
            }
        })
        // 保険: 何らかの理由でdidBeginとdidEndの数が釣り合わなくなっても、保留した更新が
        // 永久に適用されないままにならないようにする。アプリが非アクティブになる時点で
        // メニューは必ず閉じているため、ここで数え直してよい。
        tokens.add(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetTracking()
            }
        })
    }

    /// メニューバーのメニューが開いているか。
    var isTracking: Bool { trackingDepth > 0 }

    /// メニューバーのメニューが開いていなければ`work`を即実行する。開いている場合は、
    /// 閉じたあと(さらにランループを1回跨いだあと)まで保留する。
    ///
    /// - Parameter key: 保留の単位。追跡中に同じキーで複数回予約された場合、最後の1つだけが
    ///   実行される。
    func run(_ key: String, _ work: @escaping () -> Void) {
        guard isTracking else {
            work()
            return
        }
        if pending.updateValue(work, forKey: key) == nil {
            pendingOrder.append(key)
        }
    }

    /// メニューバーのメニューが閉じるたびに毎回実行する処理を登録する
    /// (run(_:_:)の一度きりの予約と違い、解除するまで残る)。
    ///
    /// 「メニューバーに出す一覧を、次に開いたときに最新にしておく」という保険のための入口。
    /// FavoritesStore/BookmarkStoreがこれを使う。
    ///
    /// これらのストアが自前で`NSMenu.didEndTrackingNotification`を購読してはいけない。
    /// 同じ通知をこのゲート自身も購読しているため、**どちらのオブザーバが先に呼ばれるかは
    /// 決まっておらず**、ゲートが先に呼ばれた場合はtrackingDepthが既に0になっていて、
    /// ストア側のreload()が`run(_:_:)`をすり抜けてその場で(=AppKitがまだトラッキングを
    /// 巻き戻している最中に)@Publishedを発火させてしまう。ここへ集約すれば、実行位置は常に
    /// 「トラッキングが完全に終わり、さらにランループを1回跨いだあと」に揃う。
    ///
    /// 登録した処理はアプリの終了まで残る(解除の口は設けていない。deinitはnonisolatedのため
    /// @MainActorのこの型へ触れられず、現在の利用者はどちらもアプリ全体で1つのストアで、
    /// 実際にdeinitされることが無いため)。**必ず`[weak self]`で捕まえること**。
    ///
    /// - Parameter key: 登録の単位。同じキーで登録し直すと置き換わる。
    func onMenuBarMenuDidClose(_ key: String, _ work: @escaping () -> Void) {
        if closeHandlers.updateValue(work, forKey: key) == nil {
            closeHandlerOrder.append(key)
        }
    }

    // MARK: - 追跡状態

    private func beginTracking() {
        trackingDepth += 1
    }

    private func endTracking() {
        trackingDepth = max(trackingDepth - 1, 0)
        guard trackingDepth == 0 else { return }
        scheduleFlush()
    }

    private func resetTracking() {
        guard trackingDepth > 0 else { return }
        trackingDepth = 0
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !pending.isEmpty || !closeHandlers.isEmpty, !isFlushScheduled else { return }
        isFlushScheduled = true
        // 型のコメント「なぜ閉じた直後ではなく1回ランループを跨ぐのか」参照。
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
    }

    private func flush() {
        isFlushScheduled = false
        // 跨いでいる間に次のメニューが開かれていたら、それが閉じるまでさらに待つ
        // (そのメニューのendTrackingが改めてscheduleFlushを呼ぶ)。
        guard !isTracking else { return }
        let work = pendingOrder.compactMap { pending[$0] }
        pending.removeAll()
        pendingOrder.removeAll()
        for item in work {
            item()
        }
        // 保留していた更新をすべて適用したあとで、一覧の最新化(保険)を走らせる。この順序なら、
        // 最新化が更新の結果を上書きすることも、その逆も起こらない。
        for item in closeHandlerOrder.compactMap({ closeHandlers[$0] }) {
            item()
        }
    }
}
