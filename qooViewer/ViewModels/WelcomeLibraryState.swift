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

    /// コレクションのタイルの大きさ(LazyVGridの`.adaptive(minimum:)`に渡す下限)。
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
        }
    }

    /// いま中を開いているコレクション。nilなら一覧(タイル)を表示する。
    ///
    /// **保存しない。** ただし本を開いて「ウェルカム画面へ戻る」で帰ってきたときは、
    /// このAppState(=ウインドウ)が生きている限り同じコレクションの中に戻る(Kindleと同じ)。
    @Published var openedCollectionID: UUID? {
        didSet {
            guard openedCollectionID != oldValue else { return }
            // 見ている場所が変わったら選択は捨てる(selectedCollectionIDsのコメント参照)。
            clearSelection()
        }
    }

    /// 編集モード。コレクションの作成・リネーム・削除、本の追加・削除ができる状態。
    /// 本を開いたら解除する(ContentViewの`currentBook`のonChange)。
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
    }

    struct PendingCollectionCreation: Identifiable {
        let id = UUID()
        /// 名前欄の初期値。棚から来たものはフォルダ名、本をまとめて落としたものは空。
        var defaultName: String
        var books: [URL]
        /// 棚(フォルダ)由来かどうか。文言の出し分けには使っていないが、由来が分かるように残す。
        let fromShelf: Bool
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
