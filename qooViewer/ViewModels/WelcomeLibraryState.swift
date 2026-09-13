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
    }

    /// 保存先。通常はアプリの`UserDefaults.standard`で、テストだけが専用のsuiteを渡す
    /// (AppPreferences.defaultsと同じ理由 ―― テストは共有状態に触らない)。
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedLibraryID = (defaults.string(forKey: Keys.selectedLibraryID)).flatMap(UUID.init(uuidString:))
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
