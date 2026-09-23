import Foundation

/// メニューバーの「ホーム」メニューに並べるライブラリとコレクションの名前(2026-09-15、ユーザー決定)。
///
/// ■ なぜ値の写しを別に持つのか
/// `CollectionStore` は表紙の抽出・自動登録フォルダの走査・存在確認のたびに publish する。そのままメニューバーへ
/// つなぐと、名前が 1 つも変わっていないのにメニュー全体が作り直される(AppStores の型コメント、お気に入りの轍)。
/// メニューが要るのは「ライブラリとコレクションの id・名前・並び」だけなので、それだけを値で写し、**変わったときだけ**
/// 知らせる(HomeMenuDirectoryStore)。
///
/// 件数の見積もり(2026-09-15 にダミーデータで実測。docs/09): SwiftUI はサブメニューの中身を開くまで作らないので、
/// 名前が変わったときの作り直しは件数に関係なく数 ms。開くときだけ件数に比例し、1000 件で約 0.14 秒(名前が変わった
/// 直後の 1 回)・約 20 ms(2 回目以降)。数千件を並べる使い方は想定しない(ユーザー判断)。
struct HomeMenuDirectory: Equatable {
    struct Library: Equatable, Identifiable {
        let id: UUID
        /// DB の文字列。既定のライブラリは表示言語で組み立てる(`usesDefaultName`。BookLibrary.displayName)。
        let name: String
        let usesDefaultName: Bool
        /// 並びは名前の昇順(「常に先頭/末尾」の指定は効かせる)。本棚の並び順はウインドウごとに違うので、
        /// メニューは誰にとっても同じ並びにする。
        let collections: [Collection]

        func displayName(language: Locale) -> String {
            usesDefaultName ? BookLibrary.defaultName(language: language) : name
        }
    }

    struct Collection: Equatable, Identifiable {
        let id: UUID
        let name: String
    }

    var libraries: [Library] = []

    func library(withID id: UUID) -> Library? {
        libraries.first { $0.id == id }
    }

    /// そのライブラリに、この名前のコレクションがあるか(移動の可否。CollectionStore.hasCollectionNamed と同じ
    /// 比較 ―― 前後の空白を除いた完全一致)。**淡色にするかどうかの見た目だけに使う**: 押された時点で
    /// CollectionStore.canMove が改めて確かめる。
    func library(withID id: UUID, hasCollectionNamed name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return library(withID: id)?.collections.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        } ?? false
    }
}

/// 1 つのウインドウのホーム画面が、メニューバーへ出す値(2026-09-15)。ContentView が詰め、AppState が
/// **メニューを開いている間は反映を保留して**持つ(AppState.homeMenu)。
///
/// 選択は id の並びで持つ。選んだものが変われば値が変わり、メニューが作り直される ―― 範囲選択のドラッグ中も、
/// 選ばれているものの集合が変わったときだけ。
///
/// **何を相手にするか**はここで決める(ユーザー決定 2026-09-15):
/// - コレクションの中にいるときは、そのコレクション
/// - 一覧で選んでいるときは、選んだもの(名前の変更と本の追加は 1 つだけのとき)
/// - 編集モードに入っていなくてもメニューからは使える(確認は右クリックと同じものを出す)
struct HomeMenuState: Equatable {
    /// 本を開いていない(ホーム画面が出ている)。false の間、ホームメニューはすべて淡色。
    var isShown = false
    var mode: WelcomeMode = .shelf
    /// 保存データへ書く操作を許すか(シークレットウインドウでは false)。
    var allowsEditing = false
    /// いま見ているライブラリ(保存されていた id の実体が無ければ先頭へ読み替えた後)。
    var libraryID: UUID?
    var openedCollectionID: UUID?
    var isEditing = false
    /// 一覧で選んでいるコレクション(表示順)。コレクションの中にいる間は空。
    var selectedCollectionIDs: [UUID] = []
    /// コレクションの中で選んでいる本(表示順)。
    var selectedItemIDs: [UUID] = []
    /// スマートライブラリで選んでいる本のパス(2026-09-23。束は含めない)。メニューバーの「Finder で表示」「ファイルブラウザで表示」
    /// 「メタデータの編集…」が相手にする。
    var smartBookPaths: [String] = []

    // 表示メニューのチェックマーク(ホーム画面の間は、表示メニューの中身がこれに入れ替わる)。
    /// 本棚の並び順(コレクションの中なら本の並び、一覧ならコレクションの並び)。
    var shelfSort: FavoritesSortOption = .nameAscending
    var browserViewMode: FileBrowserViewMode = .list
    var browserSortKey: FolderBrowserSortKey = .name
    var browserSortDirection: FolderBrowserSortDirection = .ascending
    /// リストで隠している列(FileBrowserState.hiddenListColumns を並びを固定して)。
    var hiddenListColumns: [String] = []

    var isShelfShown: Bool { isShown && mode == .shelf }

    // MARK: - 相手

    /// コレクションを相手にする操作(削除・別のライブラリへ移動)の対象。
    var collectionTargets: [UUID] {
        guard isShelfShown else { return [] }
        if let openedCollectionID { return [openedCollectionID] }
        return selectedCollectionIDs
    }

    /// 1 つだけを相手にする操作(名前の変更・本の追加)の対象。
    var singleCollectionTarget: UUID? {
        let targets = collectionTargets
        return targets.count == 1 ? targets.first : nil
    }

    /// コレクションから削除する本。
    var itemTargets: [UUID] {
        guard isShelfShown, openedCollectionID != nil else { return [] }
        return selectedItemIDs
    }

    /// 1 冊だけを相手にする操作(Finder で開く・メタデータの編集)の対象。
    var singleItemTarget: UUID? {
        let targets = itemTargets
        return targets.count == 1 ? targets.first : nil
    }

    /// スマートライブラリで 1 冊だけ選んでいる本(`singleItemTarget` のスマートライブラリ版)。
    var singleSmartBookTarget: String? {
        guard isShown, mode == .smart, smartBookPaths.count == 1 else { return nil }
        return smartBookPaths.first
    }

    /// ホームで 1 冊だけ選んでいる本があるか(コレクションの中・スマートライブラリ)。
    var hasSingleBookTarget: Bool { singleItemTarget != nil || singleSmartBookTarget != nil }

    // MARK: - 可否

    var canCreateLibrary: Bool { isShown && allowsEditing }
    var canRenameLibrary: Bool { isShown && allowsEditing && libraryID != nil }
    /// 最後の 1 つは消させない(CollectionStore.delete(_ library:))。
    func canDeleteLibrary(in directory: HomeMenuDirectory) -> Bool {
        canRenameLibrary && directory.libraries.count > 1
    }
    var canCreateCollection: Bool { isShelfShown && allowsEditing && libraryID != nil }
    var canAddBooks: Bool { allowsEditing && singleCollectionTarget != nil }
    var canRenameCollection: Bool { allowsEditing && singleCollectionTarget != nil }
    var canDeleteCollections: Bool { allowsEditing && !collectionTargets.isEmpty }
    var canRemoveItems: Bool { allowsEditing && !itemTargets.isEmpty }
    var canToggleEditing: Bool { isShelfShown && allowsEditing }
    var canShowLibrarySettings: Bool { isShelfShown && allowsEditing && openedCollectionID == nil }
    var canShowCollectionSettings: Bool { isShelfShown && allowsEditing && openedCollectionID != nil }

    /// 「別のライブラリへ移動」▸ そのライブラリを選べるか。いま居るライブラリと、対象のどれかと同じ名前のコレクションが
    /// ある先は選べない ―― 1 つでも衝突したら行き先ごと選べない(CollectionStore.move(_ collections:to:) と同じ規則)。
    func canMoveCollections(to libraryID: UUID, in directory: HomeMenuDirectory) -> Bool {
        let targets = collectionTargets
        guard allowsEditing, !targets.isEmpty, libraryID != self.libraryID,
              let current = self.libraryID.flatMap({ directory.library(withID: $0) })
        else { return false }
        return targets.allSatisfy { id in
            guard let name = current.collections.first(where: { $0.id == id })?.name else { return false }
            return !directory.library(withID: libraryID, hasCollectionNamed: name)
        }
    }
}

/// ファイルブラウザで選んでいる項目について、メニューバーの項目を押せるか(2026-09-15)。右クリックと同じ判定
/// (FileBrowserMenuCommand.isEnabled)を ContentView がいまの選択で引いて詰める。
///
/// `selectionRevision` は判定には使わない。「このアプリケーションで開く」「コレクションに登録」のサブメニューの中身は
/// 開いたときに組まれ、入力が変わらない限り SwiftUI が前の中身を使い回す(2026-09-15 の実測)ので、選択が変わったら
/// 値ごと変えて作り直させる。以前は選んだ項目の id の配列を持っていたが、ContentView の本体の評価のたびに作って比べるので、
/// 10 万件を選んだままのピンチで毎回その分を払った(4 回目の監査)。いまは `FileBrowserState.selectionRevision`(アプリ全体で通し)。
struct FileBrowserMenuSelection: Equatable {
    var selectionRevision = 0
    var canOpen = false
    var canOpenWith = false
    var canRename = false
    /// 名前の変更の題に出す件数(複数なら「N 項目の名前を変更…」)。
    var renameCount = 0
    var canMoveToTrash = false
    var canDeleteImmediately = false
    var canCompress = false
    var canExtract = false
    /// 「〈名前〉に展開」の題(1 つの書庫なら作るフォルダの名前、複数なら nil)。
    var extractFolderName: String?
    var canAddToFavoriteLocations = false
    var canShowInFinder = false
    var canUseAsBooks = false
    var canEditMetadata = false
    var canExportBook = false
    /// 「ここに項目を移動」(⌥⌘V)。ペーストボードの変化は購読できないので、アプリ・ウインドウが前に来たときとこのアプリが
    /// ファイルを書いたときに取った写し(`FileBrowserState.pasteboardHasFiles`)で決める(2026-09-19。それまでは書き込めるフォルダを
    /// 表示しているかだけで決め、空のペーストボードでも押せて黙って何もしなかった)。写しが古いときは押した時点で確かめて鳴らす。
    var canMoveItemHere = false
}
