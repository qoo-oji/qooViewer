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
    private enum Keys {
        static let selectedLibraryID = "qooViewer.welcome.selectedLibraryID"
        static let collectionSort = "qooViewer.welcome.collectionSort"
        static let itemSort = "qooViewer.welcome.itemSort"
        static let tileSize = "qooViewer.welcome.tileSize"
        static let coverSize = "qooViewer.welcome.coverSize"
        static let mode = "qooViewer.welcome.mode"
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
            // 画面が移ったら編集モードから出る(isEditingのコメント参照)。
            isEditing = false
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
            // 画面が移ったら編集モードから出る(isEditingのコメント参照)。didSetの中で
            // clearSelection()も走るので、選択を捨てるのはここに書かなくてよい。
            isEditing = false
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

    /// 編集モード。いま効くのは**ゴミ箱を出すかどうか**と、クリック/ドロップの意味
    /// (開く ↔ 選ぶ・登録する)だけ ―― 「足す」操作はモードと無関係になった
    /// (LibraryPaneControls.isEditingのコメント参照)。
    ///
    /// **画面が移ったら必ず解除する。** 本を開いたとき(ContentViewの`currentBook`のonChange)に
    /// 加えて、ライブラリを移ったとき・コレクションの中へ入った/出たときも解除する
    /// (ユーザー指摘 2026-09-09)。編集モードはいま見えているものに手を入れるための状態なので、
    /// 別のものを見始めた時点で持ち越す理由が無い ―― 持ち越すと、入った先でクリックの意味が
    /// 変わったままなのに、なぜそうなっているのかが画面から読めない。
    @Published var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            clearSelection()
        }
    }

    /// 編集モード中に選んだコレクション/本(ゴミ箱でまとめて削除するための選択)。
    ///
    /// **画面が変わったら必ず捨てる。** 選択は「いま目に見えている印」がすべてなので、
    /// 編集モードを抜けたとき・コレクションの中へ入った/出たときに残っていると、
    /// **見えていないものをゴミ箱が消す**ことになる。捨てる契機はこの2つのdidSetに集約してある
    /// (どの画面も自前では消さない)。
    ///
    /// idで持つ理由はCollectionGridView.renamingCollectionIDと同じ ―― `@Model`のクラスを
    /// そのまま集合に入れない(BookLibrary.swift末尾のコメント参照)。実体が別のウインドウから
    /// 消された場合は、削除の直前にidを引き直す側(画面)が黙って取りこぼす。
    @Published var selectedCollectionIDs: Set<UUID> = []
    @Published var selectedItemIDs: Set<UUID> = []

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
    /// コレクションを消しうるため(消えていれば解決に失敗して、パネルは何もしない)。
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
    }

    /// 本を開いたとき・ウェルカム画面から離れるときの後始末。編集モードと出しかけのシートを
    /// 畳む(コレクションの中に居ることだけは保つ ―― openedCollectionIDのコメント参照)。
    func endEditing() {
        // isEditingのdidSetが選択も捨てる。
        isEditing = false
        pendingCreations = []
        addingBooks = nil
        menuRequest = nil
    }

    /// 選択を捨てる。@Publishedは同じ値の代入でも発火するので、変化したときだけ書く。
    func clearSelection() {
        if !selectedCollectionIDs.isEmpty { selectedCollectionIDs = [] }
        if !selectedItemIDs.isEmpty { selectedItemIDs = [] }
    }

    /// 編集モード中のクリック。選ばれていなければ選び、選ばれていれば外す。
    func toggleCollectionSelection(_ id: UUID) {
        if selectedCollectionIDs.contains(id) {
            selectedCollectionIDs.remove(id)
        } else {
            selectedCollectionIDs.insert(id)
        }
    }

    func toggleItemSelection(_ id: UUID) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }
}

private extension ClosedRange where Bound == CGFloat {
    /// 保存されていた値が範囲外(将来スライダーの上限を変えた場合など)でもそのまま使えるように、
    /// 読み出した時点で丸める。
    func clamping(_ value: CGFloat) -> CGFloat {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
