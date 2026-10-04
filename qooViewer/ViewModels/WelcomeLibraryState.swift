import Combine
import Foundation
import SwiftUI

/// ウェルカム画面(ライブラリ/コレクション)の**表示の状態**をまとめて持つ(改善要望5)。
/// ContentViewが`@StateObject`で1ウインドウに1つ作る。
///
/// ■ CollectionStoreとの分担
/// 保存されるデータ(ライブラリ・コレクション・本)はCollectionStoreが持ち、こちらは
/// 「いまどのライブラリを見ているか」「編集モードか」「どの並び順・どの大きさで並べるか」
/// といった、**画面側の都合でしかない値**だけを持つ。並び順をストアに持たせなかったのは、
/// 同じデータを別のウインドウが別の並びで見られるようにするため(FavoritesStoreは
/// メニューバーと共有する都合で並び順を自分で持っているが、こちらにその制約は無い)。
///
/// ■ 保存先のキーが`qooViewer.pref.*`ではない理由
/// これらは環境設定ウインドウに現れない値なので、「初期設定に戻す」(AppPreferencesが
/// `qooViewer.pref.`で始まるキーだけを消す)の対象から外してある。「すべてのデータを削除」は
/// ドメインごと消すため、そちらでは一緒に消える。
@MainActor
final class WelcomeLibraryState: ObservableObject {
    /// コレクションの一覧と中身のスクロール位置の控え(本を開いて戻ってきても同じ所から。HomeScrollMemory)。
    let scrollMemory = HomeScrollMemory()

    /// ライブラリのコレクションの一覧の位置の鍵。
    static func scrollKey(library: UUID) -> String { "library|\(library.uuidString)" }
    /// コレクションの中身の位置の鍵。
    static func scrollKey(collection: UUID) -> String { "collection|\(collection.uuidString)" }

    private enum Keys {
        static let selectedLibraryID = "qooViewer.welcome.selectedLibraryID"
        static let collectionSort = "qooViewer.welcome.collectionSort"
        static let itemSort = "qooViewer.welcome.itemSort"
        static let tileSize = "qooViewer.welcome.tileSize"
        static let coverSize = "qooViewer.welcome.coverSize"
        static let mode = "qooViewer.welcome.mode"
        static let showsInspector = "qooViewer.welcome.showsInspector"
        static let inspectorWidth = "qooViewer.welcome.inspectorWidth"
    }

    /// 本棚かファイルブラウザか(改善要望7 段階3、2026-09-13)。帯の左端のボタンで切り替える。
    ///
    /// **保存する**(次に開くウインドウは前回のモードで始まる ―― Finderの代わりに使う人は
    /// いつもファイルブラウザから始めたい)。本を開いて「ウェルカム画面へ戻る」で帰ってきたときは、
    /// このウインドウで離れたときのモードのまま(openedCollectionIDと同じ扱い)。
    ///
    /// 本棚へ戻ったら編集モードからは出る(ファイルブラウザの間に編集中のまま残っていると、
    /// 戻った瞬間にクリックの意味が変わっている理由が画面から読めない。isEditingのコメント参照)。
    @Published var mode: WelcomeMode {
        didSet {
            // 環境設定で機能をOFFにしている間は、出せるモードが限られる(isLibraryFeatureEnabledのコメント)。
            let allowed = Self.constrained(
                mode, library: isLibraryFeatureEnabled, fileBrowser: isFileBrowserFeatureEnabled,
                smart: isSmartLibraryFeatureEnabled
            )
            if mode != allowed {
                isForcingMode = true
                mode = allowed
                isForcingMode = false
                return
            }
            guard mode != oldValue else { return }
            // 押し込まれたぶん(機能の ON/OFF に合わせた読み替え)は保存しない(機能を ON へ戻したときに、前に見ていたほうへ
            // 戻れるように)。利用者が選んだモードは、ほかの機能が OFF の間でも保存する(3 つに増えて、全部 ON のときだけ
            // 保存するのでは、どれか 1 つを OFF にしている人の選択がずっと残らなくなった)。
            if !isForcingMode { defaults.set(mode.rawValue, forKey: Keys.mode) }
            isEditing = false
            clearSelection()
            inspectorFocusRequest = nil
        }
    }

    /// 機能の ON/OFF に合わせてモードを読み替えている最中か(その間の `mode` の変更は保存しない)。
    private var isForcingMode = false

    /// ホームのライブラリ機能・ファイルブラウザ機能・スマートライブラリが有効か(環境設定「一般」→「ホーム」。2026-09-21、
    /// スマートライブラリは 2026-09-22、ユーザー要望)。値の持ち主は AppPreferences で、ContentView が写す ―― ただし
    /// **最初の値は init で保存先から読む**(写しが届くのは最初の1コマの後で、その1コマを別のモードで描かない)。
    ///
    /// OFF の機能のモードは出せない(`constrained`)。3 つとも OFF なら `.classic`(本棚を足す前のウェルカム画面)。
    /// 切り替える手段(帯のボタン・「ホーム」メニュー)も OFF の機能のぶんは画面から消える。ON へ戻したら、保存してあるモード
    /// (OFFにする前に見ていたほう)へ戻る。
    @Published var isLibraryFeatureEnabled: Bool {
        didSet {
            guard isLibraryFeatureEnabled != oldValue else { return }
            applyFeatureChange()
        }
    }

    @Published var isFileBrowserFeatureEnabled: Bool {
        didSet {
            guard isFileBrowserFeatureEnabled != oldValue else { return }
            applyFeatureChange()
        }
    }

    @Published var isSmartLibraryFeatureEnabled: Bool {
        didSet {
            guard isSmartLibraryFeatureEnabled != oldValue else { return }
            applyFeatureChange()
        }
    }

    /// 帯を出すか。ライブラリかスマートライブラリがあるときだけ(ファイルブラウザだけのホームは帯なし ―― 切り替える相手が無い)。
    var showsTopBar: Bool { isLibraryFeatureEnabled || isSmartLibraryFeatureEnabled }

    /// ホームへ戻ったとき、直前に開いていた本をファイルブラウザに選ばせるか(2026-09-28、利用者の要望「ホームから前の本に戻る
    /// ボタン」)。**帯が無く、ファイルブラウザだけのホーム**のとき。帯があればその左端に「直前の本へ戻る」のボタンを置き、
    /// 帯もファイルブラウザも無ければ旧ウェルカム画面の左上に置く(`HomeLastBookButton`)が、この組だけはボタンの置き場が無い。
    /// 代わりに、戻った時点でファイルブラウザがその本を表示・選択している状態にする(Finder などから開いた本も含めて、
    /// **ビューアを開く前のフォルダへ戻すのではなく**その本の場所へ行く。`WelcomeView` の onAppear)。
    var revealsLastBookInFileBrowser: Bool { !showsTopBar && isFileBrowserFeatureEnabled }

    /// 機能のON/OFFが変わった。保存してあるモードを、いま出せるモードへ読み替えて当てる。
    private func applyFeatureChange() {
        isForcingMode = true
        mode = Self.constrained(
            WelcomeMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .shelf,
            library: isLibraryFeatureEnabled, fileBrowser: isFileBrowserFeatureEnabled, smart: isSmartLibraryFeatureEnabled
        )
        isForcingMode = false
    }

    /// 帯のボタン・「ホーム」メニューの切り替え。**いま出ているモードをもう一度押しても、そのまま**(2026-09-23、利用者の指示)。
    ///
    /// 以前は `toggleMode` で、もう一度押すとほかの出せるモード(本棚があれば本棚)へ戻っていた。ファイルブラウザ・
    /// スマートライブラリを見ているときに同じボタンを押すと最後に使ったライブラリへ飛ぶのは、選んだ画面が勝手に替わるだけで
    /// 期待と逆だった(ボタンは「その画面を出す」もの。本棚へはライブラリのチップ、ほかの画面へはそのボタンで行ける)。
    func selectMode(_ target: WelcomeMode) {
        guard mode != target else { return }
        mode = target
    }

    /// `wanted` を、機能のON/OFFの組で出せるモードへ読み替える(`isLibraryFeatureEnabled` のコメント)。
    /// 出せなければ 本棚 → ファイルブラウザ → スマートライブラリ の順で出せるもの、どれも出せなければ `.classic`。
    static func constrained(_ wanted: WelcomeMode, library: Bool, fileBrowser: Bool, smart: Bool) -> WelcomeMode {
        let allowed: [WelcomeMode] = [library ? .shelf : nil, fileBrowser ? .browser : nil, smart ? .smart : nil]
            .compactMap { $0 }
        guard let fallback = allowed.first else { return .classic }
        return allowed.contains(wanted) ? wanted : fallback
    }

    // MARK: - インスペクタ(右ペイン。2026-09-30)

    /// インスペクタ(ホームの右ペイン)を出しているか(2026-09-30、利用者の要望。`HomeInspectorPane`)。
    ///
    /// **ファイルブラウザ・スマートライブラリ・ライブラリで共通の 1 つの値**(利用者の指定)。表示メニューの「インスペクタを表示/隠す」
    /// (⇧⌘P)・帯の右端のボタン・帯の無いホームではファイルブラウザの操作列の右端のボタンで切り替える。値はウインドウごとに持ち、
    /// 最後に切り替えた値を次に開くウインドウが引き継ぐ(ファイルブラウザの表示形式・隠しファイルと同じ扱い)。
    /// 3 つとも OFF のホーム(`.classic`)には出さない(`showsInspector`)。
    @Published var isInspectorShown: Bool {
        didSet {
            guard isInspectorShown != oldValue else { return }
            defaults.set(isInspectorShown, forKey: Keys.showsInspector)
            if !isInspectorShown { inspectorFocusRequest = nil }
        }
    }

    /// インスペクタの幅(左の区切り線を掴んで変える。ファイルブラウザのツリーの幅と同じく、離したときに書く)。
    @Published var inspectorWidth: CGFloat {
        didSet {
            guard inspectorWidth != oldValue else { return }
            defaults.set(Double(inspectorWidth), forKey: Keys.inspectorWidth)
        }
    }

    static let inspectorWidthRange: ClosedRange<CGFloat> = 220...480
    static let defaultInspectorWidth: CGFloat = 280

    /// いまインスペクタを描くか(出す設定で、かつ出せるモード)。
    var showsInspector: Bool { isInspectorShown && canShowInspector }

    /// インスペクタを出せるモードか。3 つの機能が全部 OFF のホーム(本棚を足す前のウェルカム画面)には無い。
    var canShowInspector: Bool { mode != .classic }

    /// 「メタデータの編集…」から来た、インスペクタの題の欄へ焦点を入れる頼み(2026-09-30。以前はシートを出していた)。
    /// インスペクタのメタデータの欄がその本を出したときに拾って `nil` へ戻す(`takeInspectorFocusRequest(for:)`)。
    /// 本かどうかを調べている間(フォルダ)は欄がまだ無いので、頼みは拾われるまで残す。別の本を選んだら、その本の欄は
    /// 拾わない(本の id で突き合わせる)。**拾われないまま古くなった頼みは効かない**(`focusRequestLifetime`)―― 残った頼みが、
    /// 後でその本を選び直したときに頼んでもいない焦点を欄へ入れないように。モードを移ったときも捨てる。
    @Published private(set) var inspectorFocusRequest: InspectorFocusRequest?

    struct InspectorFocusRequest: Equatable {
        let id = UUID()
        /// 本の id(パス)。
        let bookID: String
        let date: Date
    }

    /// 頼みが効く間。本かどうかの確かめ(フォルダを 1 つ読む)より十分に長く、利用者が次の操作へ移るより短く。
    static let focusRequestLifetime: TimeInterval = 10

    /// 欄が頼みを拾った時刻。一覧が選択の変化で焦点を取り返さないために見る(`isInspectorTakingFocus`)。
    private var inspectorFocusTakenAt: Date?

    /// インスペクタが焦点を取りにいっている最中か。コレクションの中のグリッドは、選択が変わると焦点を自分へ移す
    /// (CollectionDetailView)ので、「メタデータの編集…」で選び直したときはそれを控えてもらう(控えないと題の欄から焦点を奪う)。
    /// 拾われないまま古くなった頼みは数えない(`focusRequestLifetime`。2026-10-01 のレビュー: 数えていたので、拾われなかった頼みが
    /// 残ると、モードを移るかインスペクタを隠すまで、選び直してもグリッドへ焦点が戻らず ⌘C・矢印キーが届かなかった)。
    func isInspectorTakingFocus(now: Date = Date()) -> Bool {
        if let request = inspectorFocusRequest, now.timeIntervalSince(request.date) < Self.focusRequestLifetime { return true }
        guard let taken = inspectorFocusTakenAt else { return false }
        return now.timeIntervalSince(taken) < 1
    }

    /// 右クリックの「メタデータの編集…」: インスペクタを出し、その本の題の欄へ焦点を入れる頼みを置く。
    /// 選ぶのは呼び出し側(その画面の選択の持ち主)。
    func revealInspector(editingMetadataOf bookID: String, now: Date = Date()) {
        guard canShowInspector else { return }
        if !isInspectorShown { isInspectorShown = true }
        inspectorFocusRequest = InspectorFocusRequest(bookID: bookID, date: now)
    }

    /// その本への、まだ効く頼みがあるか(拾わない)。インスペクタが「本かどうか」を調べずに本として出してよい印にもなる ―― 頼みを
    /// 置いた入り口(「メタデータの編集…」)が、本であることを確かめてから置いている。
    func hasInspectorFocusRequest(for bookID: String, now: Date = Date()) -> Bool {
        guard let request = inspectorFocusRequest, request.bookID == bookID else { return false }
        return now.timeIntervalSince(request.date) < Self.focusRequestLifetime
    }

    /// インスペクタのメタデータの欄が、自分の本への頼みなら拾う。古くなった頼みは拾わずに捨てる。
    func takeInspectorFocusRequest(for bookID: String, now: Date = Date()) -> Bool {
        guard let request = inspectorFocusRequest, request.bookID == bookID else { return false }
        inspectorFocusRequest = nil
        guard now.timeIntervalSince(request.date) < Self.focusRequestLifetime else { return false }
        inspectorFocusTakenAt = now
        return true
    }

    /// コレクションのタイルの大きさ。**札はこの幅ちょうどで並ぶ**(2026-09-13まではLazyVGridの
    /// `.adaptive(minimum:)`に渡す下限で、列数が変わる瞬間にしか大きさが変わらなかった。
    /// WelcomeGridColumns参照)。
    static let tileSizeRange: ClosedRange<CGFloat> = 120...320
    static let defaultTileSize: CGFloat = 180
    /// コレクションの中に並ぶカバーの大きさ。
    static let coverSizeRange: ClosedRange<CGFloat> = 80...300
    static let defaultCoverSize: CGFloat = 140

    /// 帯で選択中のライブラリ。ウインドウをまたいで同じものを選んだ状態から始めたいので保存する。
    /// 実体が消えている(削除された)場合の読み替えは表示側(WelcomeView.resolvedLibrary)が行う。
    @Published var selectedLibraryID: UUID? {
        didSet {
            guard selectedLibraryID != oldValue else { return }
            defaults.set(selectedLibraryID?.uuidString, forKey: Keys.selectedLibraryID)
            // 画面が移ったら編集モードから出て、選択も捨てる(isEditing・selectedCollectionIDsのコメント参照)。
            isEditing = false
            clearSelection()
            // 別の棚を見始めたら検索も捨てる(searchTextのコメント参照)。
            searchText = ""
        }
    }

    /// いま中を開いているコレクション。nilなら一覧(タイル)を表示する。
    ///
    /// **保存しない。** ただし本を開いて「ウェルカム画面へ戻る」で帰ってきたときは、
    /// このAppState(=ウインドウ)が生きている限り同じコレクションの中に戻る(Kindleと同じ)。
    @Published var openedCollectionID: UUID? {
        didSet {
            guard openedCollectionID != oldValue else { return }
            // 出たコレクションの位置の控えは捨てる(入り直したら先頭から。一覧へ戻ったときは一覧の控えから ―― HomeScrollMemory)。
            if let oldValue { scrollMemory.forget(Self.scrollKey(collection: oldValue)) }
            // 画面が移ったら編集モードから出て、選択も捨てる(isEditing・selectedCollectionIDsのコメント参照)。
            isEditing = false
            clearSelection()
            // 検索はここでは触らない。一覧へ戻るときは残し、中へ入るときに残すかどうかは
            // 入り口のopenCollection(_:keepingSearch:)が先に決めてある(searchTextのコメント参照)。
        }
    }

    /// 検索欄の文字列(ユーザー要望 2026-09-13)。一覧ではコレクションを、コレクションの中では
    /// 本を絞り込む(照合の規則はLibrarySearchQuery)。
    ///
    /// **保存しない。捨てる契機は2つ**(ユーザー指示 2026-09-13。検討の途中で「戻るでも捨てる」
    /// に一度振れてから、この形に落ち着いた):
    /// - ライブラリを切り替えたとき(別の棚を見始めたので、前の棚向けの絞り込みを持ち越さない)
    /// - 絞り込んだ一覧からコレクションを開いて、**その中に一致する本が無い**とき
    ///   (名前だけが一致した棚を開いたのに中身が空に見える、を作らない。
    ///   openCollection(_:keepingSearch:))
    ///
    /// **コレクションから一覧へ戻るときは残す**(戻るボタン・選択中のライブラリのチップ)。
    /// 絞り込んだ一覧から棚を覗いて戻り、隣の棚を開く、を続けられるようにするため。
    /// 中に一致する本がある棚を開いたときも残す ―― 探していた本がそのまま絞り込まれて出る。
    ///
    /// **変わったら選択を捨てる。** 絞り込みで見えなくなったものが選択に残ると、ゴミ箱が
    /// 見えていないものを消す(selectedCollectionIDsのコメントと同じ決まり)。
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            clearSelection()
        }
    }

    /// コレクションの中へ入る。一覧から開く道はすべてここを通す(クリック・右クリックの「開く」)。
    ///
    /// - Parameter keepingSearch: 検索を残すか。呼び出し側が「この棚の中に検索に一致する本が
    ///   あるか」を調べて渡す(searchTextのコメント参照)。
    func openCollection(_ id: UUID, keepingSearch: Bool) {
        if !keepingSearch { searchText = "" }
        openedCollectionID = id
    }

    /// 編集モード。**コレクションに入れる・外す操作を前に出すモード**(2026-09-27 から。ホームの操作の統一、
    /// docs/plans/home-interaction-design.md)。効くのは、ドロップの意味(開く → 登録する)・全選択とゴミ箱・右クリックの
    /// 「削除…」「コレクションから削除」・見出しの名前のクリックでの名前の変更・選択の丸い印。**クリックの意味は変えない**
    /// (モードの外でも中でも「選ぶ」。以前は外で「開く」、中で選択のトグルだった)。「足す」操作はモードと無関係
    /// (LibraryPaneControls.isEditingのコメント参照)。
    ///
    /// **入っても出ても選択は捨てない**(選択はモードの外でもできるようになったので、出入りで消すと、選んでから鉛筆を押した
    /// ものが消える)。見えていないものをゴミ箱が消さない決まりは、画面が移ったときに捨てることで守る(selectedCollectionIDs)。
    ///
    /// **画面が移ったら必ず解除する。** 本を開いたとき(ContentViewの`currentBook`のonChange)に
    /// 加えて、ライブラリを移ったとき・コレクションの中へ入った/出たときも解除する
    /// (ユーザー指摘 2026-09-09)。編集モードはいま見えているものに手を入れるための状態なので、
    /// 別のものを見始めた時点で持ち越す理由が無い ―― 持ち越すと、入った先でクリックの意味が
    /// 変わったままなのに、なぜそうなっているのかが画面から読めない。
    @Published var isEditing = false

    /// 選んだコレクション/本。規則はスマートライブラリのグリッドと同じ `GridSelection`(クリックで選ぶ、⌘ で足す/外す、
    /// ⇧ で範囲、矢印キー。2026-09-27 から。それまでは編集モードの中でだけ、クリックで選ぶ/外すができた)。
    ///
    /// **画面が変わったら必ず捨てる。** 選択は「いま目に見えている印」がすべてなので、
    /// ライブラリ・モードを移ったとき・コレクションの中へ入った/出たときに残っていると、
    /// **見えていないものをゴミ箱が消す**ことになる。捨てる契機はそれぞれのdidSetに集約してある
    /// (どの画面も自前では消さない)。本を開いて戻ってきたとき(同じ画面)は残す(スマートライブラリと同じ)。
    /// **画面が移らずに見えなくなったもの**(検索から外れた・別のウインドウで消えた・移った)は、並びが変わるたびに
    /// `showCollections` / `showItems` が外す。操作の相手は `targetCollectionIDs` / `targetItemIDs`(表示中 ∩ 選択)で作る
    /// (2026-10-04、監査 H-1)。
    ///
    /// idで持つ理由はCollectionGridView.renamingCollectionIDと同じ ―― `@Model`のクラスを
    /// そのまま集合に入れない(BookLibrary.swift末尾のコメント参照)。実体が別のウインドウから
    /// 消された場合は、削除の直前にidを引き直す側(画面)が黙って取りこぼす。
    @Published var collectionSelection = GridSelection<UUID>()
    @Published var itemSelection = GridSelection<UUID>()

    /// 選んだコレクションの集合(帯・全選択・メニューが書く。起点と位置は残っていれば保つ)。
    var selectedCollectionIDs: Set<UUID> {
        get { collectionSelection.ids }
        set { collectionSelection.set(newValue, cursor: collectionSelection.cursor) }
    }

    var selectedItemIDs: Set<UUID> {
        get { itemSelection.ids }
        set { itemSelection.set(newValue, cursor: itemSelection.cursor) }
    }

    // MARK: - 表示中の並びと、操作の相手(2026-10-04、状態と画面の監査 H-1)

    /// 一覧にいま並んでいるコレクション(表示順)。一覧(CollectionGridView)が並びの変わるたびに知らせる(`showCollections`)。
    /// **publish しない**(画面の評価のたびに届くので。選択が変われば選択のほうが publish する)。
    private(set) var shownCollectionIDs: [UUID] = []
    /// コレクションの中にいま並んでいる本(表示順)。CollectionDetailView が知らせる(`showItems`)。
    private(set) var shownItemIDs: [UUID] = []

    /// 一覧の並びが変わった(検索・並べ替え・改名・別のウインドウでの削除や移動・ライブラリの読み替え)。**選択を並びに絞る**。
    ///
    /// 以前は選択を捨てる契機が画面を移る didSet(モード・ライブラリ・開いているコレクション・検索)だけで、画面が移らずに見えなくなった
    /// もの ―― 中の本を外して検索に当たらなくなった棚、別のウインドウが別のライブラリへ移した棚 ―― が選択に残り、ゴミ箱とホーム ▸
    /// 「コレクションを削除…」「別のライブラリへ移動」が、見えていない棚まで消した・移した(監査 H-1)。スマートライブラリが並びの変わる
    /// たびに `prune(to:)` しているのと同じ決まりにした(docs/14「選択の決まり」)。
    func showCollections(_ order: [UUID]) {
        let previousTargets = targetCollectionIDs
        shownCollectionIDs = order
        var pruned = collectionSelection
        pruned.prune(to: order)
        // @Published は同じ値の代入でも publish するので、変わったときだけ書く(clearSelection と同じ)。
        if pruned != collectionSelection {
            collectionSelection = pruned
        } else if targetCollectionIDs != previousTargets {
            // 選択は同じでも相手の並び(表示順)が変わった ―― メニューバーの値を作り直させる(`shownCollectionIDs` は publish しない)。
            objectWillChange.send()
        }
    }

    /// コレクションの中の並びが変わった。選択を並びに絞る(`showCollections` と同じ)。
    func showItems(_ order: [UUID]) {
        let previousTargets = targetItemIDs
        shownItemIDs = order
        var pruned = itemSelection
        pruned.prune(to: order)
        if pruned != itemSelection {
            itemSelection = pruned
        } else if targetItemIDs != previousTargets {
            objectWillChange.send()
        }
    }

    /// インスペクタのメタデータの欄に焦点がある間、コレクションの中の検索から外れても並びに残す本(bookID。2026-10-04 のレビューの R2-2)。
    ///
    /// コレクションの中の検索はメタデータの題も照合するので、インスペクタで題を直して検索から外れると、並びの変化で `showItems` が
    /// 選択を絞り、インスペクタが「選択されていません」になって次の欄の焦点と打ちかけの文字が消えた(監査 H-1 の直しの副作用)。
    /// スマートライブラリの `SmartLibraryViewState.bookKeptWhileEditing`(監査 SL-3)と同じ決まり: 欄に焦点がある間は残し
    /// (`CollectionStore.items(in:sort:matching:keeping:)`)、焦点が離れたらふつうに絞る。
    @Published private(set) var bookKeptWhileEditing: String?

    /// 欄に焦点が入った(`HomeInspectorMetadataSection`)。
    func keepWhileEditing(_ bookID: String) {
        guard bookKeptWhileEditing != bookID else { return }
        bookKeptWhileEditing = bookID
    }

    /// 欄から焦点が離れた・欄が消えた。ほかの本の欄が既に入れ替えていれば何もしない。
    func stopKeepingWhileEditing(_ bookID: String) {
        guard bookKeptWhileEditing == bookID else { return }
        bookKeptWhileEditing = nil
    }

    /// 一覧で操作の相手にするコレクション = **表示中 ∩ 選択**(表示順)。ゴミ箱・ホームメニュー・インスペクタはこれを読む
    /// (右クリックの `contextTargets`・Return・⌘C は前から表示中の並びから引いていた)。並びが変わるたびに選択は絞られるが、
    /// 絞る前の一瞬(ストアの変化から画面の onChange まで)にも隠れたものを相手にしないよう、読む側でも交わりを取る。
    var targetCollectionIDs: [UUID] {
        collectionSelection.isEmpty ? [] : shownCollectionIDs.filter(collectionSelection.contains)
    }

    /// コレクションの中で操作の相手にする本 = 表示中 ∩ 選択(表示順)。
    var targetItemIDs: [UUID] {
        itemSelection.isEmpty ? [] : shownItemIDs.filter(itemSelection.contains)
    }

    @Published var collectionSort: FavoritesSortOption {
        didSet {
            guard collectionSort != oldValue else { return }
            defaults.set(collectionSort.rawValue, forKey: Keys.collectionSort)
        }
    }

    @Published var itemSort: FavoritesSortOption {
        didSet {
            guard itemSort != oldValue else { return }
            defaults.set(itemSort.rawValue, forKey: Keys.itemSort)
        }
    }

    @Published var tileSize: CGFloat {
        didSet {
            guard tileSize != oldValue else { return }
            defaults.set(Double(tileSize), forKey: Keys.tileSize)
        }
    }

    @Published var coverSize: CGFloat {
        didSet {
            guard coverSize != oldValue else { return }
            defaults.set(Double(coverSize), forKey: Keys.coverSize)
        }
    }

    /// トラックパッドのピンチで札の大きさを変える(ユーザー要望 2026-09-13)。`magnification`は
    /// 1イベントぶんの変化量なので、いまの大きさに`(1 + magnification)`を掛けて積み上げる
    /// (ThumbnailGridView.handleMagnifyと同じ扱い。刻みへ丸めない理由もあちら)。
    func resizeTiles(byMagnification magnification: CGFloat) {
        let next = Self.tileSizeRange.clamping(tileSize * (1 + magnification))
        // 上限・下限に張り付いている間、同じ値を書き続けない(UserDefaultsへの空振りの書き込み)。
        if next != tileSize { tileSize = next }
    }

    /// コレクションの中のカバーの大きさ版(resizeTiles(byMagnification:)と同じ)。
    func resizeCovers(byMagnification magnification: CGFloat) {
        let next = Self.coverSizeRange.clamping(coverSize * (1 + magnification))
        if next != coverSize { coverSize = next }
    }

    /// 名前の入力を待っている「これから作るコレクション」の待ち行列。
    ///
    /// 編集モード中に棚(本が並んだフォルダ)を複数まとめてドロップできるため、名前を訊く
    /// シートは**1つずつ順番に**出す。先頭を出し、Create/Cancelのどちらでも先頭を取り除いて
    /// 次へ進む。
    @Published var pendingCreations: [PendingCollectionCreation] = []

    /// 「本を追加」パネルの対象。nilなら出していない。
    @Published var addingBooks: AddBooksTarget?

    /// メニューバーの「ホーム」メニューから届いた、画面の側でしかできない操作(2026-09-15)。
    ///
    /// 名前を訊くシート・削除の確認・設定のポップオーバー・「本が見つかりません」は、それぞれの画面が`@State`で
    /// 持っている(右クリックから出すものと同じ)。メニューはそれを直接は開けないので、ここへ依頼を置き、出している
    /// 画面(WelcomeTopBar / CollectionGridView / CollectionDetailView / LibraryPaneControls)が拾って
    /// **自分の右クリックと同じ経路で**開く。拾った画面が`nil`へ戻す。
    ///
    /// シートやアラートを出さずに済む操作(本の追加・別のライブラリへ移動・編集モード)はメニューが直接行う。
    @Published var menuRequest: HomeMenuRequest?

    struct HomeMenuRequest: Equatable {
        /// 同じ依頼を続けて出しても`onChange`が拾えるように、毎回別の値にする。
        let id = UUID()
        let kind: Kind

        enum Kind: Equatable {
            case createLibrary
            case renameLibrary(UUID)
            case deleteLibrary(UUID)
            case renameCollection(UUID)
            case deleteCollections([UUID])
            case removeItems([UUID])
            case showSettings
            case focusSearch
            case showItemInFinder(UUID)
            case showItemInFileBrowser(UUID)
            /// スマートライブラリで選んでいる本(パス。2026-09-23)。
            case showSmartBookInFinder(String)
            case showSmartBookInFileBrowser(String)
        }
    }

    /// スマートライブラリで選んでいる本のパス(束は含めない。2026-09-23)。スマートライブラリの画面が出ている間だけ詰まり、
    /// 消えるときに空へ戻す。メニューバーの項目がこれを相手にする(HomeMenuState.smartBookPaths)。
    @Published var smartSelectedBookPaths: [String] = []

    func request(_ kind: HomeMenuRequest.Kind) {
        menuRequest = HomeMenuRequest(kind: kind)
    }

    /// 依頼を拾う。`accepts`が受け持つ種類なら`nil`へ戻して返す(受け持たない依頼は、それを出している別の画面に残す)。
    func takeMenuRequest(where accepts: (HomeMenuRequest.Kind) -> Bool) -> HomeMenuRequest.Kind? {
        guard let request = menuRequest, accepts(request.kind) else { return nil }
        menuRequest = nil
        return request.kind
    }

    /// 「本を追加」パネルが相手にしているコレクション。
    ///
    /// **`collectionID`がnilの状態がある。** 空のコレクションは作らない方針(CollectionStore.
    /// createCollectionのコメント参照)なので、「＋」で名前だけ決めた直後はまだ行が無く、
    /// 1冊目が入った時点で`createCollection`が行を作る。1冊も入れずにパネルを閉じれば、
    /// 何も残らない。
    ///
    /// モデルの参照ではなくidで持つのは、パネルを開いている間に別のウインドウがその
    /// コレクションを消しうるため(消えていればパネルは何も足さずに「コレクションがありません」と知らせる ―― 以前は
    /// nil を「まだ作っていない」と区別せず、同じ名前の新しいコレクションを作っていた。2026-10-04、監査 H-9)。
    struct AddBooksTarget: Identifiable {
        let id = UUID()
        var collectionID: UUID?
        /// まだ作っていないときの名前。
        var name: String
        var libraryID: UUID
        /// 名前を決めるときに選ばれた自動登録フォルダ(BookCollection.autoFolderPath)。
        ///
        /// 行がまだ無い状態を跨いで運ぶために持つ ―― 1冊目が入って`createCollection`が行を
        /// 作った直後に、このパネルがコレクションへ書き込む。
        var autoFolder: URL?
    }

    struct PendingCollectionCreation: Identifiable {
        let id = UUID()
        /// 名前欄の初期値。棚から来たものはフォルダ名、本をまとめて落としたものは空。
        var defaultName: String
        var books: [URL]
        /// 棚(フォルダ)由来かどうか。文言の出し分けには使っていないが、由来が分かるように残す。
        let fromShelf: Bool
        /// ウェルカム画面へのドロップから始まった作成か(ユーザー指示 2026-09-09)。
        ///
        /// 名前を決めたあとに「本を追加」パネルを出すかどうかがこれで決まる ――
        /// ドロップで作ったコレクションには入れたい本がもう渡っているので、パネルは出さない
        /// (WelcomeView.finishCreation参照)。「＋」から作った場合だけ、本を入れる場が要る。
        ///
        /// `books`が空かどうかでは代用しない ―― 「＋」から自動登録フォルダだけを選んだ場合も
        /// 作成の途中で本が入る(finishCreation)ので、由来は由来として持つ。
        let fromDrop: Bool
        /// 自動登録フォルダの欄の初期値(ユーザー要望 2026-09-09)。
        ///
        /// 棚を落としたときはその棚、本のファイルを落としたときはそれらが入っていたフォルダ
        /// (全部が同じフォルダのときだけ)。「＋」から作るときは常にnil = 空欄。
        ///
        /// **ファイル由来の初期値には、そのフォルダを列挙する権限が付いてこない**
        /// (サンドボックス。CLAUDE.md)。パスは初期値として出すが、実際に自動登録が動き出す
        /// のはユーザーがアクセスを許可してから(CollectionAutoFolderRow参照)。
        var autoFolder: URL?
        /// 作る先のライブラリ。nil なら本棚で選んでいるライブラリ(「＋」・ドロップ)。ファイルブラウザの「コレクションを作成」▸
        /// ライブラリ で選んだときだけ入る(2026-09-21、ユーザー要望 ―― ファイルブラウザの間は本棚のライブラリの選択が見えず、
        /// 選び直す手段も無かった)。idで持つのは、名前を訊いている間に別のウインドウが消しうるため(消えていれば選んでいるライブラリへ)。
        var libraryID: UUID?
    }

    /// 保存先。通常はアプリの`UserDefaults.standard`で、テストだけが専用のsuiteを渡す
    /// (AppPreferences.defaultsと同じ理由 ―― テストは共有状態に触らない)。
    private let defaults: UserDefaults

    /// - Parameter restoresMode: false なら保存したモードを読まずに本棚で始める(保存値は書き換えない)。
    ///   **テストホストのウインドウ用**: ファイルブラウザで始めると、テストの実行中にウインドウが実際のホームを
    ///   読みに行く(共有の状態に触れる。環境によってはデスクトップ・書類の TCC の確認が出うる)。
    ///   しかもテストがメインスレッドを塞ぐので、そのウインドウは虹色のカーソルのまま見えていた(2026-09-13 ユーザー報告)。
    init(defaults: UserDefaults = .standard, restoresMode: Bool = true) {
        self.defaults = defaults
        selectedLibraryID = (defaults.string(forKey: Keys.selectedLibraryID)).flatMap(UUID.init(uuidString:))
        // テストホストのウインドウ(restoresMode == false)は、設定に関わらず本棚で始める(下の引数のコメント)。
        let isLibraryEnabled = restoresMode ? AppPreferences.storedLibraryFeatureEnabled(in: defaults) : true
        let isFileBrowserEnabled = restoresMode ? AppPreferences.storedFileBrowserFeatureEnabled(in: defaults) : true
        let isSmartEnabled = restoresMode ? AppPreferences.storedSmartLibraryFeatureEnabled(in: defaults) : true
        isLibraryFeatureEnabled = isLibraryEnabled
        isFileBrowserFeatureEnabled = isFileBrowserEnabled
        isSmartLibraryFeatureEnabled = isSmartEnabled
        mode = Self.constrained(
            restoresMode ? (WelcomeMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .shelf) : .shelf,
            library: isLibraryEnabled, fileBrowser: isFileBrowserEnabled, smart: isSmartEnabled
        )
        collectionSort = FavoritesSortOption(
            rawValue: defaults.string(forKey: Keys.collectionSort) ?? ""
        ) ?? .nameAscending
        itemSort = FavoritesSortOption(
            rawValue: defaults.string(forKey: Keys.itemSort) ?? ""
        ) ?? .nameAscending
        // objectがnil(まだ一度も保存していない)ときだけ既定値。0.0との区別が要るため
        // double(forKey:)を直に読まない。
        tileSize = (defaults.object(forKey: Keys.tileSize) as? Double)
            .map { Self.tileSizeRange.clamping(CGFloat($0)) } ?? Self.defaultTileSize
        coverSize = (defaults.object(forKey: Keys.coverSize) as? Double)
            .map { Self.coverSizeRange.clamping(CGFloat($0)) } ?? Self.defaultCoverSize
        isInspectorShown = defaults.bool(forKey: Keys.showsInspector)
        inspectorWidth = (defaults.object(forKey: Keys.inspectorWidth) as? Double)
            .map { Self.inspectorWidthRange.clamping(CGFloat($0)) } ?? Self.defaultInspectorWidth
    }

    /// 本を開いたとき・ウェルカム画面から離れるときの後始末。編集モードと出しかけのシートを
    /// 畳む(コレクションの中に居ることと選択は保つ ―― openedCollectionID・selectedCollectionIDsのコメント参照)。
    func endEditing() {
        isEditing = false
        pendingCreations = []
        addingBooks = nil
        menuRequest = nil
    }

    /// 選択を捨てる。@Publishedは同じ値の代入でも発火するので、変化したときだけ書く。
    func clearSelection() {
        if collectionSelection != GridSelection() { collectionSelection = GridSelection() }
        if itemSelection != GridSelection() { itemSelection = GridSelection() }
    }

    /// ⌘ クリック。選ばれていなければ足し、選ばれていれば外す。
    func toggleCollectionSelection(_ id: UUID) {
        collectionSelection.click(id, .toggle, order: [])
    }

    func toggleItemSelection(_ id: UUID) {
        itemSelection.click(id, .toggle, order: [])
    }

    /// コレクションの中から一覧へ戻る(見出しの ‹・⌘↑・Esc)。出てきたコレクションを選んだ状態にする
    /// (スマートライブラリで束から出たときと同じ。矢印キーでそのまま隣へ進める)。
    ///
    /// 出てきた棚が一覧に出ない(中で外した本が検索に当たっていた・消えた・別のライブラリへ移った)ときは、一覧が出た時点の
    /// `showCollections` が選択から外す(監査 H-1 ―― 以前は無条件に選び、見えない棚が選択に残った)。
    func leaveCollection() {
        guard let opened = openedCollectionID else { return }
        openedCollectionID = nil
        collectionSelection.select(opened)
    }

    /// ライブラリを見せる(帯のチップ・ホーム ▸ ライブラリの項目。2026-10-04 の監査 H-13 で入口を 1 つにした ―― 以前メニューは
    /// 見ているライブラリでも `openedCollectionID = nil` だけで、チップと違い出てきた棚を選ばなかった)。
    ///
    /// ほかのモードの間は本棚へ戻る(見ていたライブラリなら、開いていたコレクションもそのまま ―― 離れたときの棚へ戻る)。
    /// 本棚で見ているライブラリならそのコレクション一覧へ戻り、出てきた棚を選ぶ(`leaveCollection`。検索は残す)。
    /// 別のライブラリなら移る(開いていたコレクションからは出る ―― 今のライブラリには無い)。
    ///
    /// - Parameter currentLibraryID: いま本棚が見せているライブラリ(未選択なら先頭へ落とした後の値。帯・メニューの値)。
    func showLibrary(_ id: UUID, currentLibraryID: UUID?) {
        if mode != .shelf {
            mode = .shelf
            if id == currentLibraryID { return }
        }
        guard id != currentLibraryID else {
            leaveCollection()
            return
        }
        selectedLibraryID = id
        openedCollectionID = nil
    }

    /// コレクションを別のライブラリへ移した後(右クリック・ホーム ▸ 別のライブラリへ移動。監査 H-13 で入口を 1 つにした)。
    /// 移したものだけを選択から外し(今は見えていない ―― 見えていないものをゴミ箱が消さないための決まり)、開いていたなら一覧へ戻る。
    /// **関係ない選択は残す** ―― 以前の右クリックは、選択の外のタイルを移しても選択を丸ごと捨てた。
    func collectionsMovedAway(_ ids: Set<UUID>) {
        if let opened = openedCollectionID, ids.contains(opened) { openedCollectionID = nil }
        var remaining = collectionSelection
        remaining.remove(ids)
        if remaining != collectionSelection { collectionSelection = remaining }
    }
}

private extension ClosedRange where Bound == CGFloat {
    /// 保存されていた値が範囲外(将来スライダーの上限を変えた場合など)でもそのまま使えるように、
    /// 読み出した時点で丸める。
    func clamping(_ value: CGFloat) -> CGFloat {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
