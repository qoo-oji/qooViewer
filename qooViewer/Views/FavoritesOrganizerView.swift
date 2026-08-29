import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// 「お気に入りの整理」ウインドウ(要望3)。左側にフォルダツリー、右側に選択中のフォルダの
/// 中身(サブフォルダ + お気に入り)を表示する2ペイン構成。
///
/// - フォルダの作成・リネーム・削除
/// - お気に入りの削除
/// - ドラッグ&ドロップによる、お気に入り/フォルダの別フォルダへの移動
/// - 実体ファイルが見つからないお気に入りのグレー表示
///
/// をここでまとめて行う(メニューバー・ツールバーの一覧では、開く/新しいウインドウで開く/
/// 新しいタブで開くのみに絞っているため、整理系の操作はすべてこのウインドウの役割になる)。
struct FavoritesOrganizerView: View {
    @ObservedObject var favoritesStore: FavoritesStore
    /// ツールバーの「現在の本を追加」ボタンが「今読んでいる本」を特定するために参照する
    /// (launchCoordinator.activeBookAppState?.currentBook。ViewerView.setUpWindowObservers参照)。
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    /// 右ペインでお気に入りをダブルクリックして開いたときの挙動(favoriteOpenBehavior)を
    /// 判定するために必要(openFavoriteAccordingToPreference参照)。
    @EnvironmentObject private var preferences: AppPreferences
    /// ダブルクリック・右クリックメニューでお気に入りを新しいウインドウ/タブとして開くために
    /// 使う(openFavorite(_:to:relativeTo:) → BookWindowOpener参照)。
    @Environment(\.openWindow) private var openWindow

    /// 右ペインの1行が名前以外に使う幅(本のアイコン・形式バッジ・件数・削除ボタン)。
    /// SidebarWidthEstimatorが見込んでいる分(アイコン+件数)より、形式バッジと削除ボタンの
    /// ぶんだけ広い。
    private static let detailRowExtraChrome: CGFloat = 40
    /// 右ペインがこれ以上狭く/広くならない下限・上限。上限は、名前が極端に長いお気に入りが
    /// 1件あるだけでウインドウが画面いっぱいに開いてしまわないようにするためのもの。
    private static let detailMinWidth: CGFloat = 400
    private static let detailMaxWidth: CGFloat = 640

    /// nilは「お気に入りの一番上の階層(ルート直下)」を表す。
    @State private var selectedFolder: FavoriteFolder?

    /// 並べ替えメニューの「基準」側。昇順/降順は保ったまま基準だけを差し替える
    /// (「ブックマーク・レイアウトの編集」ウインドウのsortFieldBindingと同じもの)。
    private var sortFieldBinding: Binding<FavoritesSortOption.Field> {
        Binding(
            get: { favoritesStore.sortOption.field },
            set: { newField in
                favoritesStore.sortOption = FavoritesSortOption(
                    field: newField, ascending: favoritesStore.sortOption.isAscending
                )
            }
        )
    }

    /// 並べ替えメニューの「昇順/降順」側。基準は保ったまま向きだけを差し替える。
    private var sortAscendingBinding: Binding<Bool> {
        Binding(
            get: { favoritesStore.sortOption.isAscending },
            set: { isAscending in
                favoritesStore.sortOption = FavoritesSortOption(
                    field: favoritesStore.sortOption.field, ascending: isAscending
                )
            }
        )
    }

    /// 右ペイン(詳細ペイン)で、今クリックして選択中の項目(フォルダ/お気に入り)のid。
    /// クリックしても選択されているのかどうか分かりにくいという指摘への対応で、左ペインの
    /// 選択中フォルダ(selectedFolder)とは別に、右ペイン内の「今どの行を選んでいるか」を
    /// 表す状態として持つ。select(_:)で左ペインの選択(=表示するフォルダ自体)が変わったときは、
    /// 右ペインの中身が総入れ替えになるため、古い選択が残らないようここもリセットする。
    @State private var selectedEntryID: UUID?
    /// シングル/ダブルクリック識別(自前実装)用、右ペインの項目(フォルダ/お気に入り)ごとの
    /// 直近のクリック時刻(entry.idをキーにする)。詳細は各行の.simultaneousGestureのコメント参照。
    @State private var lastEntryTapDates: [UUID: Date] = [:]

    @State private var isShowingNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var newFolderErrorMessage: String?

    @State private var renamingFolder: FavoriteFolder?
    @State private var renameText = ""

    /// リネーム中のお気に入り(本)。renamingFolder/renameTextと同じ考え方・同じ実装パターン
    /// (BookmarkEditorView.renamingBookmarkも同様)。フォルダのリネームとお気に入りのリネームは
    /// 同時に開くことがないため、テキスト入力欄(renameText)は共用している。
    @State private var renamingBook: FavoriteBook?

    @State private var folderPendingDeletion: FavoriteFolder?
    @State private var bookPendingDeletion: FavoriteBook?

    @State private var isRootTargeted = false

    /// サイドバーのフォルダツリーで、DisclosureGroupが開いている(展開されている)フォルダのid一覧。
    /// 既定では各DisclosureGroupの開閉はSwiftUI側の内部状態に任せているが、選択中フォルダの
    /// 祖先だけはこのSetを通じて明示的に開いた状態にする(select(_:)参照)。
    @State private var expandedFolderIDs: Set<UUID> = []

    /// 左ペイン(サイドバー)の幅。ウインドウを開いた時点で登録されているフォルダ名の長さに
    /// 応じてonAppearで一度だけ計算する(SidebarWidthEstimator参照)。既定値220は、
    /// フォルダが無い/名前が短い場合のフォールバック。
    @State private var sidebarWidth: CGFloat = 220
    /// 右ペインの「開いた直後の幅」。左ペインと同じく、登録されている名前の実測から決める
    /// (ユーザー要望: 左右のペインとも、登録されている一番長い文字列に合わせること。
    /// ただし広くなりすぎないよう上限を設けること)。
    @State private var detailWidth: CGFloat = Self.detailMinWidth
    /// sidebarWidthの計算を、ウインドウを開いた時点の1回だけに限定するためのフラグ
    /// (以後、フォルダを追加/削除してもリストの内容が変わるたびに勝手にリサイズされないようにする)。
    @State private var hasComputedSidebarWidth = false

    // 「現在の本を追加」ボタン(addCurrentBook参照)用の状態。FavoriteFolderPickerView.swiftの
    // 同名の仕組みと同じ理由・同じ構造(重複登録の確認、件数上限エラーの表示)。
    @State private var pendingBookForDuplicateConfirmation: MangaBook?
    @State private var duplicateConfirmationBreadcrumb: String?
    @State private var addCurrentBookErrorMessage: String?

    /// このウインドウ(お気に入りの整理ウインドウ)自身のNSWindow。WindowAccessor経由で設定する。
    /// 右ペインでのダブルクリックで本を開いてビューアウインドウへフォーカスが移ったとき、
    /// このウインドウ自身を自動的に閉じるために使う(closeEditorWindow参照)。
    /// 予防: NSWindowは強参照で持たない(ViewerView.WeakWindowBoxのコメント参照)。
    @State private var editorWindowBox = WeakWindowBox()
    private var editorWindow: NSWindow? { editorWindowBox.window }

    var body: some View {
        NavigationSplitView {
            List {
                Button {
                    select(nil)
                } label: {
                    Label("Favorites (Top Level)", systemImage: "star")
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    (selectedFolder == nil || isRootTargeted) ? Color.accentColor.opacity(0.15) : Color.clear
                )
                .onDrop(of: [.text], isTargeted: $isRootTargeted) { providers in
                    handleDrop(providers: providers, targetFolder: nil)
                }

                ForEach(favoritesStore.rootFolders, id: \.id) { folder in
                    OrganizerFolderRow(
                        folder: folder,
                        favoritesStore: favoritesStore,
                        selectedFolder: $selectedFolder,
                        expandedFolderIDs: $expandedFolderIDs,
                        onRename: { folder in
                            // BookmarkEditorView.onRenameBookmarkと同じ不具合・同じ対策
                            // (詳細はそちらのコメント参照: 同じ項目を続けてリネームすると
                            // renameTextの値が変化せず、.alertのTextFieldに反映されないことがある)。
                            renameText = ""
                            renamingFolder = folder
                            DispatchQueue.main.async {
                                renameText = folder.name
                            }
                        },
                        onDelete: { folder in folderPendingDeletion = folder },
                        onDrop: { providers, target in handleDrop(providers: providers, targetFolder: target) }
                    )
                }
            }
            .listStyle(.sidebar)
            // サイドバーの空白部分を右クリックしたときにも「新規フォルダ」を作成できるようにする
            // (ユーザーからの指摘: ツールバーのボタンだけでは新規フォルダの作成方法が
            // 分かりづらいため)。SwiftUIではListの各行にcontextMenuが付いていても、行の無い
            // 空白部分をクリックした場合はList自身に付けたcontextMenuが呼ばれる。
            .contextMenu {
                Button("New Folder") {
                    newFolderName = ""
                    isShowingNewFolderPrompt = true
                }
                .disabled(!favoritesStore.canCreateSubfolder(in: selectedFolder))
            }
            // 「新規フォルダ」ボタンをツールバーのアイコンだけに頼らず、サイドバー下部に文字付きの
            // ボタンとして常時表示する(Finderのサイドバーや「メモ」アプリのフォルダ一覧と同様の
            // 見せ方。ツールバーのアイコンのみのボタンだと、何のボタンか分かりづらいという
            // ユーザーからの指摘への対応)。
            .safeAreaInset(edge: .bottom) {
                Button {
                    newFolderName = ""
                    isShowingNewFolderPrompt = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!favoritesStore.canCreateSubfolder(in: selectedFolder))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Favorites")
            // 左ペインの幅を、開いた時点で登録されているフォルダ名の長さ(階層の字下げ込み)に
            // 応じて広げる(ブックマーク編集画面の同様の対応と揃えている)。ideal:に渡した値は
            // ウインドウの初期サイズのヒントとしても使われるため、初めて開いたとき(まだ
            // ウインドウサイズが記憶されていないとき)は、この幅を反映した状態で開く。
            .navigationSplitViewColumnWidth(min: 220, ideal: sidebarWidth, max: 560)
            .onAppear {
                guard !hasComputedSidebarWidth else { return }
                hasComputedSidebarWidth = true
                sidebarWidth = SidebarWidthEstimator.idealWidth(for: allFolderNamesWithDepth())
                // 右ペインは、どのフォルダを選んでも同じ幅で開くよう、登録されている
                // すべての名前(フォルダ名・お気に入りのタイトル)から測る。
                detailWidth = SidebarWidthEstimator.idealWidth(
                    forNames: allEntryNames(),
                    minWidth: Self.detailMinWidth - Self.detailRowExtraChrome,
                    maxWidth: Self.detailMaxWidth - Self.detailRowExtraChrome
                ) + Self.detailRowExtraChrome
            }
            // 以前はここにツールバーの「新規フォルダ」ボタン(ToolbarItem)を置いていたが、
            // .labelStyle(.titleAndIcon)で文字付きにした結果ツールバーに収まりきらず、
            // macOSが自動的に「>>」という隠れた項目を表示するための折りたたみボタンを
            // 追加してしまっていた。サイドバー下部のボタン・空白部分の右クリックメニューで
            // 「新規フォルダ」は既に分かりやすく提供できているため、ツールバーのボタン自体を
            // 削除して「>>」も出ないようにした。
        } detail: {
            // フォルダ・お気に入りの両方をFavoritesStore.entries(in:)で1つの並びとして取得し、
            // switchでそれぞれの見た目(フォルダ行/お気に入り行)を出し分ける。以前はフォルダ用・
            // お気に入り用の2つのForEachに分かれていたが、フォルダを常に先頭にするかどうか
            // (foldersAlwaysOnTop)を切り替え可能にしたことで、両者が混在した1つの並びを
            // そのまま描画する必要が生じたため、1つのForEachにまとめた。
            List {
                ForEach(favoritesStore.entries(in: selectedFolder)) { entry in
                    switch entry {
                    case .folder(let folder):
                        let itemCount = favoritesStore.subfolders(of: folder).count + favoritesStore.books(in: folder).count
                        HStack {
                            Image(systemName: "folder")
                            Text(folder.name)
                            Spacer()
                            Text("\(itemCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // ブックマーク編集画面の各行と見た目を揃えた、インラインの削除ボタン
                            // (以前は右クリックメニューの「Delete」のみだった)。既存の
                            // folderPendingDeletion・「Delete Folder?」アラートをそのまま再利用する。
                            Button {
                                folderPendingDeletion = folder
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            // ユーザー報告: このボタンにカーソルを合わせても、行全体に付けている
                            // .help(folder.name)(フォルダ名のツールチップ)を引き継いでしまい、
                            // 削除ボタンだとわかるツールチップが出ない。ボタン自身にも.help()を
                            // 付けることで、このボタンの上だけは行のツールチップより優先させる。
                            .help("Delete Folder")
                        }
                        .contentShape(Rectangle())
                        // シングルクリックでは選択状態(下のlistRowBackground)にするだけ、
                        // ダブルクリックでそのフォルダの中へ移動する。
                        //
                        // 以前はクリック回数違いの.onTapGesture(count: 2)/.onTapGesture(count: 1)を
                        // 重ねていたが、これだとクリック回数の異なるジェスチャーが同居する形になり、
                        // シングルクリックでの選択(ハイライト表示)がシステムのダブルクリック間隔
                        // だけ遅延してしまう不具合があった(BookmarkListView.PageRowView.
                        // selectableContentの同種の不具合・修正コメント参照。ユーザー報告により
                        // 同じ問題がここにもないか確認して発覚)。ここではクリック回数1の
                        // ジェスチャーだけを使い、選択は毎回のクリックで即座に行い、フォルダへの
                        // 移動は自前で前回クリックからの経過時間をダブルクリック間隔と比較して
                        // 判定する。
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                selectedEntryID = entry.id
                                let now = Date()
                                if let last = lastEntryTapDates[entry.id],
                                   now.timeIntervalSince(last) <= NSEvent.doubleClickInterval {
                                    lastEntryTapDates[entry.id] = nil
                                    select(folder)
                                } else {
                                    lastEntryTapDates[entry.id] = now
                                }
                            }
                        )
                        // 右ペインの行も、左ペインの行と同様にカーソルを合わせるとフルネームを
                        // ツールチップで表示する(要望: 右ペインのアイテムについてもホバーで
                        // フルネームを見られるようにしてほしい)。
                        .help(folder.name)
                        // クリックして選択したことが分かるよう、左ペインと同じ見た目でハイライトする
                        // (要望: 右ペインの項目を選択したとき、選択されているか分かりにくい、
                        // という指摘への対応)。
                        .listRowBackground(
                            selectedEntryID == entry.id ? Color.accentColor.opacity(0.15) : Color.clear
                        )
                        .contextMenu {
                            Button("Rename") {
                                // onRename(上のOrganizerFolderRowの.init呼び出し箇所)と同じ対策。
                                renameText = ""
                                renamingFolder = folder
                                DispatchQueue.main.async {
                                    renameText = folder.name
                                }
                            }
                            Button("Delete", role: .destructive) {
                                folderPendingDeletion = folder
                            }
                        }
                        .onDrag { NSItemProvider(object: "favoriteFolder:\(folder.id.uuidString)" as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            handleDrop(providers: providers, targetFolder: folder)
                        }

                    case .book(let favorite):
                        // 実体ファイルが見つからない項目はグレー表示で区別する(要望3の追加要件)。
                        // 以前はここから行ごとに.task(id:)でfavoritesStore.fileExists(for:)を
                        // 呼んでいたが、SwiftUIの.taskはビューと同じMainActor上で走るため、
                        // 非同期にしてもメインスレッドが止まることに変わりはなかった(お気に入りが
                        // 外付け/ネットワークボリューム上にあると一覧の描画がもたつく)。
                        // 現在はストア側がメインアクターの外でまとめて確認してキャッシュしており、
                        // ここはその結果を読むだけ(ファイルアクセスなし)。
                        // 詳細はFavoritesStore.existenceByFavoriteIDのコメント参照。
                        let exists = favoritesStore.cachedFileExists(for: favorite)
                        HStack {
                            Image(systemName: "book.closed")
                            Text(favorite.title)
                            // タイトルは拡張子を除いた名前のため、同名のcbz/epubが並ぶと
                            // 見分けがつかない(ユーザー報告)。拡張子バッジで区別できるようにする。
                            FormatBadgeView(bookID: favorite.bookID)
                            if !exists {
                                Text("Not Found")
                                    .font(.caption)
                                    .padding(.leading, 4)
                            }
                            Spacer()
                            // ブックマーク編集画面の各行と見た目を揃えた、インラインの削除ボタン
                            // (以前は右クリックメニューの「Remove from Favorites」のみだった)。
                            // 「Not Found」表示を右端に押し出していたSpacerは、このボタンを
                            // 常に右端に置くための1つのSpacerに統合した。
                            Button {
                                bookPendingDeletion = favorite
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            // ユーザー報告: このボタンにカーソルを合わせても、行全体に付けている
                            // .help(favorite.title)(本のタイトルのツールチップ)を引き継いでしまい、
                            // 削除ボタンだとわかるツールチップが出ない。ボタン自身にも.help()を
                            // 付けることで、このボタンの上だけは行のツールチップより優先させる。
                            .help("Remove from Favorites")
                        }
                        .foregroundStyle(exists ? .primary : .secondary)
                        .opacity(exists ? 1 : 0.6)
                        .contentShape(Rectangle())
                        // シングルクリックは選択のみ、ダブルクリックで実際にその本を開く
                        // (要望: お気に入り一覧から本を開く場合と同じ開き方でよい、とのこと。
                        // このウインドウ自体は特定の本のウインドウには属さない独立ウインドウのため、
                        // 「今読んでいる本」の代わりにlaunchCoordinator.activeBookAppStateを
                        // 判定材料にする。詳細はopenFavoriteAccordingToPreference参照)。
                        //
                        // 上のフォルダの行と同じ理由(コメント参照)で、クリック回数違いの
                        // .onTapGestureを重ねる方式は選択のハイライト表示が遅延するため、
                        // クリック回数1のジェスチャー+自前のダブルクリック間隔判定に変更した。
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                selectedEntryID = entry.id
                                let now = Date()
                                if let last = lastEntryTapDates[entry.id],
                                   now.timeIntervalSince(last) <= NSEvent.doubleClickInterval {
                                    lastEntryTapDates[entry.id] = nil
                                    openFavoriteAccordingToPreference(favorite)
                                } else {
                                    lastEntryTapDates[entry.id] = now
                                }
                            }
                        )
                        // 左ペインの行と同様、カーソルを合わせるとフルネームをツールチップで表示する。
                        .help(favorite.title)
                        // クリックして選択したことが分かるよう、左ペインと同じ見た目でハイライトする。
                        .listRowBackground(
                            selectedEntryID == entry.id ? Color.accentColor.opacity(0.15) : Color.clear
                        )
                        .contextMenu {
                            // ユーザー要望: サイドパネルの本の行と同じ「開き方」の項目を、
                            // ここにも同じ並びで置く(BookOpenContextMenuItems)。
                            // 「開く」に相当するのはダブルクリック(環境設定
                            // 「お気に入りを開くとき」に従う)なので、ここでは
                            // openFavoriteAccordingToPreferenceを呼ぶ形で1項目として出す。
                            //
                            // 派生元は「今読んでいる本のウインドウ」―― このウインドウ自体は
                            // 特定の本には属さない独立ウインドウなので、ダブルクリックの経路
                            // (openFavoriteAccordingToPreference)とまったく同じ探し方をする。
                            //
                            // その探索は**選ばれた時点**で行うこと。`.contextMenu`の中身は
                            // 行の本体評価の一部として組み立てられるため、ここで直に呼ぶと
                            // 表示中の全行ぶん走るうえ、メニューを開いてから選ぶまでの間に
                            // 手前のウインドウが変わっても古い答えのままになる。
                            BookOpenContextMenuItems(
                                onOpen: { openFavoriteAccordingToPreference(favorite) },
                                onOpenIn: { destination in
                                    let activeAppState = launchCoordinator.activeBookAppState
                                        ?? launchCoordinator.frontmostContentAppState()
                                    openFavorite(favorite, to: destination, relativeTo: activeAppState)
                                }
                            )
                            Divider()
                            Button("Rename") {
                                // 上のフォルダの「Rename」と同じ対策(詳細はそちらのコメント参照)。
                                renameText = ""
                                renamingBook = favorite
                                DispatchQueue.main.async {
                                    renameText = favorite.title
                                }
                            }
                            Button("Remove from Favorites", role: .destructive) {
                                bookPendingDeletion = favorite
                            }
                        }
                        .onDrag { NSItemProvider(object: "favoriteBook:\(favorite.id.uuidString)" as NSString) }
                    }
                }
            }
            // 詳細ペインの空白部分を右クリックした場合も、現在選択中のフォルダの直下に
            // 新規フォルダを作成できるようにする(サイドバー側の同様のcontextMenuと同じ理由)。
            .contextMenu {
                Button("New Folder") {
                    newFolderName = ""
                    isShowingNewFolderPrompt = true
                }
                .disabled(!favoritesStore.canCreateSubfolder(in: selectedFolder))
            }
            // 「フォルダを上に」と「並べ替え」は、ウインドウのツールバーの**右ペイン側**へ載せる。
            // このウインドウは左ペイン側にツールバーのボタンを持たないため、左右で釣り合いを
            // 取る必要が無く、置き場所は右端(.primaryAction)にしてある(ユーザー要望。
            // 「ブックマーク・レイアウトの編集」ウインドウは左ペイン側にもボタンがあり、
            // どちらのペインへの操作か分かるよう両方とも.principal=各ペインの真上に中央揃え)。どちらもフォルダ単位ではなく
            // お気に入り全体に対する設定で、変更するとメニューバー・ツールバーのサブメニュー側にも
            // 即座に反映される(FavoritesStore.sortOption/foldersAlwaysOnTopのコメント参照)。
            //
            // 経緯: 以前はサイドバーへ「新規フォルダ」のツールバーボタンを置いたところ、文字付きの
            // ラベルが収まりきらず「>>」の折りたたみが出たため、ツールバーを避けてペイン内の
            // safeAreaInsetに並べていた。ここはボタン2つだけで、かつ「ブックマーク・レイアウトの
            // 編集」ウインドウと同じ「ペインへの操作はそのペインの真上」という置き方に揃えるため、
            // ツールバーへ移してある(「新規フォルダ」は今までどおりサイドバー下部のまま)。
            //
            // ツールバーにチェックボックスは載らないため、「フォルダを上に」はONのときだけ点灯する
            // トグルボタンにする(EPUB/PDF/CBZ書き出しウインドウの「すべて選択」と同じ形)。
            // ラベルはツールバーの上だと既定でアイコンだけに畳まれるので、.titleAndIconを明示する。
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $favoritesStore.foldersAlwaysOnTop) {
                        Label("Folders on Top", systemImage: "folder")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.titleAndIcon)
                    .help("Folders on Top")

                    // 並べ替えは、ボタンも中身も「ブックマーク・レイアウトの編集」ウインドウの
                    // ものに合わせる(ユーザー要望): 上下矢印のアイコンだけのメニューボタンで、
                    // 中は「基準(名前・追加日時・更新日時)」と「昇順/降順」の2つのグループに
                    // 分け、それぞれにチェックマークが付く形。以前はこのウインドウだけ
                    // 「名前(A→Z)」…と6項目を平らに並べていた。保存される値は従来どおり
                    // FavoritesSortOptionの6つのcaseのままで、その2つの軸へ分解して読み書き
                    // している(FavoritesSortOption.field/isAscending参照)。
                    //
                    // PickerのままだとボタンにFavoritesSortOption.systemImageが出るが、
                    // 名前順のアイコン(textformat)は表示言語で字形が変わるシンボルで、
                    // 日本語ではボタンに「あぁ」という文字が出てしまう(実機で確認)。
                    Menu {
                        Picker(selection: sortFieldBinding) {
                            ForEach(FavoritesSortOption.Field.allCases) { field in
                                Label {
                                    Text(field.titleKey)
                                } icon: {
                                    Image(systemName: field.systemImage)
                                }
                                .tag(field)
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)

                        Divider()

                        Picker(selection: sortAscendingBinding) {
                            Text("Ascending").tag(true)
                            Text("Descending").tag(false)
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort By", systemImage: "arrow.up.arrow.down")
                    }
                    .labelStyle(.iconOnly)
                    .fixedSize()
                    .help("Sort By")
                }
            }
            // ブックマーク編集画面の「Add This Page」ボタンと、位置(ペイン下部)・見た目
            // (行全体を左寄せのプレーンボタンとして使う、.bar背景の帯)を完全に揃えた
            // 「Add This Book」ボタン。今読んでいる本(launchCoordinator.activeBookAppState?.
            // currentBook)を、現在選択中のフォルダへ直接登録する(addCurrentBook参照)。
            // 本を1つも開いていない場合は無効化する。
            .safeAreaInset(edge: .bottom) {
                Button {
                    addCurrentBook()
                } label: {
                    Label("Add This Book", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(launchCoordinator.activeBookAppState?.currentBook == nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
            // 以前はここで選択中フォルダのパンくず(breadcrumb)を表示しており、フォルダを
            // 移動するたびにウインドウのタイトルが変わっていたが、「ブックマークの編集」
            // ウインドウのタイトルが常に固定(ブックマークの編集)なのに対しこちらだけ
            // 可変なのはUIが揃わないという指摘があったため、こちらも常に固定のタイトルにした。
            .navigationTitle("Edit Favorites")
        }
        // 左ペインが広がった分、右ペインが窮屈にならないよう、ウインドウ全体の最小幅も
        // 追随させる(要望: 右ペインがしわ寄せを受けるくらいなら、ウインドウ全体を広げてよい)。
        // 最小幅は「左ペインの実測 + 右ペインの下限(detailMinWidth)」。
        //
        // idealWidthには左右の実測値の合計を渡してあるが、実測したところ、ウインドウの初期
        // サイズはNavigationSplitView自身が持つ幅から決まっており、ここのidealは効いていない
        // (今のデータでは合計860ptに対し、実際は900ptで開く)。それでも値としては正しいので
        // ヒントとして残してある。なお、ウインドウの大きさを一度変えるとmacOSがそちらを
        // 記憶するため、初期サイズが問題になるのは「まだ大きさを覚えていないウインドウ」だけ。
        .frame(
            minWidth: max(640, sidebarWidth + Self.detailMinWidth),
            idealWidth: sidebarWidth + detailWidth,
            minHeight: 420
        )
        // ツールバーの下へ潜る一覧の、上端の縁の効果(ScrollEdgeEffect.swift参照)。
        .hardTopScrollEdgeEffect()
        // このウインドウ自身のNSWindowを取得しておく(closeEditorWindow参照)。ViewerView/
        // ContentViewと同じWindowAccessorパターン。
        .background(WindowAccessor { window in
            editorWindowBox.window = window
        })
        .alert("New Folder", isPresented: $isShowingNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Cannot Create Folder",
            isPresented: Binding(
                get: { newFolderErrorMessage != nil },
                set: { isPresented in if !isPresented { newFolderErrorMessage = nil } }
            )
        ) {
            Button("OK") { newFolderErrorMessage = nil }
        } message: {
            Text(newFolderErrorMessage ?? "")
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { renamingFolder != nil },
                set: { isPresented in if !isPresented { renamingFolder = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let folder = renamingFolder {
                    favoritesStore.rename(folder, to: renameText)
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .alert(
            "Rename Favorite",
            isPresented: Binding(
                get: { renamingBook != nil },
                set: { isPresented in if !isPresented { renamingBook = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let favorite = renamingBook {
                    favoritesStore.rename(favorite, to: renameText)
                }
                renamingBook = nil
            }
            Button("Cancel", role: .cancel) { renamingBook = nil }
        }
        .alert(
            "Delete Folder?",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { isPresented in if !isPresented { folderPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let folder = folderPendingDeletion {
                    if selectedFolder?.id == folder.id {
                        select(folder.parent)
                    }
                    favoritesStore.delete(folder)
                }
                folderPendingDeletion = nil
            }
        } message: {
            Text("This also deletes any subfolders and favorites inside it.")
        }
        .alert(
            "Remove from Favorites?",
            isPresented: Binding(
                get: { bookPendingDeletion != nil },
                set: { isPresented in if !isPresented { bookPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { bookPendingDeletion = nil }
            Button("Remove", role: .destructive) {
                if let favorite = bookPendingDeletion {
                    favoritesStore.delete(favorite)
                }
                bookPendingDeletion = nil
            }
        }
        // 「現在の本を追加」ボタン用の確認・エラー表示。FavoriteFolderPickerView.swiftの
        // 同名のアラートと文言を完全に揃えてあり(同じLocalizable.xcstringsのキーを再利用する)、
        // 「別フォルダに既に登録されている」「999件の上限に達した」という2つの分岐も同じ。
        .alert(
            "Already in Favorites",
            isPresented: Binding(
                get: { duplicateConfirmationBreadcrumb != nil },
                set: { isPresented in
                    if !isPresented {
                        duplicateConfirmationBreadcrumb = nil
                        pendingBookForDuplicateConfirmation = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                duplicateConfirmationBreadcrumb = nil
                pendingBookForDuplicateConfirmation = nil
            }
            Button("Add Anyway") {
                duplicateConfirmationBreadcrumb = nil
                if let book = pendingBookForDuplicateConfirmation {
                    handle(favoritesStore.forceAddFavorite(book: book, to: selectedFolder))
                }
                pendingBookForDuplicateConfirmation = nil
            }
        } message: {
            Text("This book is already in “") + Text(duplicateConfirmationBreadcrumb ?? "")
                + Text("”. Add it here as well?")
        }
        .alert(
            "Could Not Add to Favorites",
            isPresented: Binding(
                get: { addCurrentBookErrorMessage != nil },
                set: { isPresented in if !isPresented { addCurrentBookErrorMessage = nil } }
            )
        ) {
            Button("OK") { addCurrentBookErrorMessage = nil }
        } message: {
            Text(addCurrentBookErrorMessage ?? "")
        }
    }

    /// 詳細ペインでお気に入りをダブルクリックしたときに呼ぶ。ViewerView内の「お気に入り一覧」
    /// (openFavoriteAccordingToPreference)と同じく、環境設定「本を開く」の「お気に入りから」
    /// (favoriteOpenBehavior)に従って開く。このウインドウ自体は特定の本のウインドウに
    /// 属さない独立ウインドウのため、「今読んでいる本」の代わりに
    /// launchCoordinator.activeBookAppState(Add This Bookボタンと同じ判定材料)を使う。
    ///
    /// activeBookAppState(本を表示しているウインドウが最後にキーウインドウになったときにだけ
    /// 更新される)が無い場合、以前は「まだ本を1つも開いていない」とみなし常に新しいウインドウで
    /// 開いていたが、これだとウェルカム画面(本を1冊も開いていないだけの、既に開いている
    /// コンテンツウインドウ)が手前に表示されている状態でダブルクリックしても、そのウインドウを
    /// 無視して余分な新しいウインドウが開いてしまっていた(要望: ウェルカム画面がアクティブな
    /// 状態でダブルクリックしたら、そのウインドウにそのまま表示してほしい)。
    /// launchCoordinator.frontmostContentAppState()(BookmarkListView.openBookAndJump(to:)が
    /// 同じ場面で使っているのと同じもの。本を表示中か、ウェルカム画面かを問わず、今いちばん
    /// 手前にあるコンテンツウインドウを返す)をフォールバックとして使うことで、既存のウインドウ
    /// (通常はウェルカム画面)があればそこへ、1つも無い場合(このウインドウ以外どこにも
    /// コンテンツウインドウが無い場合)にのみ新しいウインドウを開くようにする。
    private func openFavoriteAccordingToPreference(_ favorite: FavoriteBook) {
        guard let activeAppState = launchCoordinator.activeBookAppState ?? launchCoordinator.frontmostContentAppState() else {
            openFavorite(favorite, to: .newWindow, relativeTo: nil)
            return
        }
        guard activeAppState.currentBook != nil else {
            activeAppState.openFavorite(favorite)
            activeAppState.hostWindow?.makeKeyAndOrderFront(nil)
            closeEditorWindow()
            return
        }
        switch preferences.favoriteOpenBehavior {
        case .replaceCurrentBook:
            activeAppState.openFavorite(favorite)
            activeAppState.hostWindow?.makeKeyAndOrderFront(nil)
            closeEditorWindow()
        case .newTab:
            openFavorite(favorite, to: .newTab, relativeTo: activeAppState)
        case .newWindow:
            openFavorite(favorite, to: .newWindow, relativeTo: activeAppState)
        }
    }

    /// 指定したお気に入りを、新しいウインドウ/タブで開く。
    ///
    /// 以前はここに「ポーリングで増えたウインドウを見つけ、サイズと位置を整え、タブなら親へ
    /// 追加する」という手順をウインドウ用とタブ用に1つずつ書いていたが、同じ手順が
    /// アプリ内に5つコピーされていた状態を解消するためBookWindowOpenerへ集約した
    /// (そちらの型コメント参照)。
    ///
    /// - Parameter activeAppState: 今読んでいる本のウインドウ(あれば)。新しいウインドウの
    ///   サイズとカスケードの基準、タブの追加先、シークレットの引き継ぎ元になる。
    ///   本を1つも開いていない場合はnilで、そのときは環境設定に従った素の新しいウインドウ
    ///   として開く(`.newTab`を指定していてもタブの追加先が無いため新しいウインドウになる)。
    private func openFavorite(
        _ favorite: FavoriteBook, to destination: BookOpenDestination, relativeTo activeAppState: AppState?
    ) {
        guard let url = favoritesStore.resolvedExistingURL(for: favorite) else {
            activeAppState?.missingFavorite = favorite
            return
        }
        BookWindowOpener.open(
            BookOpenRequest(url),
            to: destination,
            from: activeAppState,
            launchCoordinator: launchCoordinator,
            openWindow: openWindow,
            // 開き終えたらこの整理ウインドウは役目を終える(従来どおり)。
            onOpened: { closeEditorWindow() }
        )
    }

    /// ツールバーの「Add This Book」ボタンから呼ぶ。今読んでいる本を、現在選択中のフォルダへ
    /// 登録する。結果の分岐(重複確認・上限エラー)はhandle(_:)で行う
    /// (FavoriteFolderPickerView.performRegistration/handleと同じ構造)。
    private func addCurrentBook() {
        guard let book = launchCoordinator.activeBookAppState?.currentBook else { return }
        pendingBookForDuplicateConfirmation = book
        handle(favoritesStore.addFavorite(book: book, to: selectedFolder))
    }

    private func handle(_ outcome: FavoriteAddOutcome) {
        switch outcome {
        case .added, .overwritten:
            pendingBookForDuplicateConfirmation = nil
        case .needsDuplicateConfirmation(let breadcrumb):
            // pendingBookForDuplicateConfirmationはaddCurrentBook()側で既にセット済み
            // (「Add Anyway」が押されたときにforceAddFavoriteへ渡す対象を覚えておくため)。
            duplicateConfirmationBreadcrumb = breadcrumb
        case .limitReached:
            pendingBookForDuplicateConfirmation = nil
            addCurrentBookErrorMessage = FavoritesLimitError.favoritesLimitReached.errorDescription
        case .failed:
            pendingBookForDuplicateConfirmation = nil
            addCurrentBookErrorMessage = String(localized: "The favorite could not be registered.")
        }
    }

    /// 右ペインでのダブルクリックにより、お気に入りの本がどこか(既存ウインドウ/新しいタブ/
    /// 新しいウインドウ)で実際に開かれ、ビューアウインドウへフォーカスが移った直後に呼ぶ。
    /// このウインドウ(お気に入りの整理ウインドウ)自身はもう用済みなので、自動的に閉じる
    /// (要望: 本を開いたら/ページへジャンプしたら、その操作の元になった編集ウインドウは
    /// 自動的に閉じてほしい)。実体ファイルが見つからずopenFavorite(_:to:relativeTo:)が
    /// missingFavoriteを立てて処理を打ち切った場合はこの関数自体が呼ばれないため、
    /// フォーカス移動を伴わない失敗時に誤って閉じてしまうことはない。
    private func closeEditorWindow() {
        editorWindow?.close()
    }

    /// 選択中のフォルダを変更する。selectedFolderへの代入は(サイドバーの行自身をクリックする
    /// OrganizerFolderRow内を除き)すべてここを経由する。右ペインでのダブルクリックによる
    /// 「フォルダの奥へ移動」など、サイドバーのツリーを直接操作しない経路で選択が変わった場合でも、
    /// サイドバー上で「今どこにいるか」が分かるよう、選択したフォルダの祖先をすべて自動的に
    /// 展開する(要望: 現在いる階層に合わせてツリーを展開し、現在のフォルダを強調表示してほしい)。
    /// 選択中フォルダ自身の強調表示は、OrganizerFolderRow/ルート行のlistRowBackgroundが
    /// selectedFolderと突き合わせて行う。
    private func select(_ folder: FavoriteFolder?) {
        selectedFolder = folder
        // 表示するフォルダ自体が変わると右ペインの中身が総入れ替えになるため、古いフォルダの
        // 項目を選択したままにしない。
        selectedEntryID = nil
        var current = folder?.parent
        while let ancestor = current {
            expandedFolderIDs.insert(ancestor.id)
            current = ancestor.parent
        }
    }

    /// サイドバー(フォルダツリー)に現在表示されているすべてのフォルダについて、
    /// (名前, 階層の深さ)を再帰的に集める。SidebarWidthEstimatorへ渡すためだけの用途で、
    /// 並び順は問わない。
    private func allFolderNamesWithDepth() -> [(name: String, depth: Int)] {
        var result: [(name: String, depth: Int)] = []
        func walk(_ folders: [FavoriteFolder], depth: Int) {
            for folder in folders {
                result.append((name: folder.name, depth: depth))
                walk(favoritesStore.subfolders(of: folder), depth: depth + 1)
            }
        }
        walk(favoritesStore.rootFolders, depth: 0)
        return result
    }

    /// 右ペインに並びうるすべての名前(フォルダ名・お気に入りのタイトル)。
    /// 右ペインの幅の実測に使うだけで、並び順は問わない。
    private func allEntryNames() -> [String] {
        var names: [String] = []
        func walk(_ folder: FavoriteFolder?) {
            names.append(contentsOf: favoritesStore.books(in: folder).map(\.title))
            for subfolder in favoritesStore.subfolders(of: folder) {
                names.append(subfolder.name)
                walk(subfolder)
            }
        }
        walk(nil)
        return names
    }

    private func createFolder() {
        switch favoritesStore.createFolder(name: newFolderName, parent: selectedFolder) {
        case .success:
            break
        case .failure(let error):
            newFolderErrorMessage = error.errorDescription
        }
    }

    /// サイドバーのフォルダ行・「お気に入り(ルート直下)」行の両方から呼ぶ、共通のドロップ処理。
    /// ドラッグ側は"favoriteBook:<uuid>"または"favoriteFolder:<uuid>"というプレーンテキストとして
    /// 識別子を渡す(Transferableプロトコルを使った型安全な実装の方が本来望ましいが、
    /// お気に入り/フォルダという2種類のドラッグ元を単純な文字列プレフィックスで区別する
    /// 手軽な方法として、ここではNSItemProvider + テキストで実装している)。
    private func handleDrop(providers: [NSItemProvider], targetFolder: FavoriteFolder?) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let string = reading as? String else { return }
            Task { @MainActor in
                if string.hasPrefix("favoriteBook:"),
                   let uuid = UUID(uuidString: String(string.dropFirst("favoriteBook:".count))),
                   let favorite = favoritesStore.book(withID: uuid) {
                    favoritesStore.move(favorite, to: targetFolder)
                } else if string.hasPrefix("favoriteFolder:"),
                          let uuid = UUID(uuidString: String(string.dropFirst("favoriteFolder:".count))),
                          let folder = favoritesStore.folder(withID: uuid) {
                    _ = favoritesStore.move(folder, to: targetFolder)
                }
            }
        }
        return true
    }
}

/// サイドバーのフォルダ1件分の折りたたみ行。SwiftUIでは`some View`を返す関数は自分自身を
/// 再帰呼び出しできないため、専用のView構造体として実装する(他のファイルの同様の行と同じ理由)。
/// onRename/onDeleteはfolderを引数に取る形にしてあり、再帰的に同じクロージャをそのまま
/// 子階層へ渡しても、それぞれの行が自分自身のfolderを渡して呼び出すため正しく動作する。
private struct OrganizerFolderRow: View {
    let folder: FavoriteFolder
    @ObservedObject var favoritesStore: FavoritesStore
    @Binding var selectedFolder: FavoriteFolder?
    /// 開いている(展開されている)フォルダのid一覧。FavoritesOrganizerView.select(_:)が、
    /// 選択中フォルダの祖先をここへ自動的に追加する(要望: 右ペインでのドリルダウンでも
    /// サイドバーのツリー上で現在地が分かるようにしてほしい)。DisclosureGroupの開閉を
    /// このSetと直接結び付けることで、祖先が追加されると該当するDisclosureGroupが
    /// 自動的に展開される。
    @Binding var expandedFolderIDs: Set<UUID>
    let onRename: (FavoriteFolder) -> Void
    let onDelete: (FavoriteFolder) -> Void
    let onDrop: ([NSItemProvider], FavoriteFolder?) -> Bool

    @State private var isTargeted = false

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedFolderIDs.contains(folder.id) },
            set: { expanded in
                if expanded {
                    expandedFolderIDs.insert(folder.id)
                } else {
                    expandedFolderIDs.remove(folder.id)
                }
            }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(favoritesStore.subfolders(of: folder), id: \.id) { child in
                OrganizerFolderRow(
                    folder: child,
                    favoritesStore: favoritesStore,
                    selectedFolder: $selectedFolder,
                    expandedFolderIDs: $expandedFolderIDs,
                    onRename: onRename,
                    onDelete: onDelete,
                    onDrop: onDrop
                )
            }
        } label: {
            Button {
                selectedFolder = folder
            } label: {
                Label(folder.name, systemImage: "folder")
            }
            .buttonStyle(.plain)
            // 左ペインの幅が狭く、フォルダ名が省略表示("…")になっていることがあるため、
            // カーソルを合わせるとフルネームをツールチップで表示する
            // (ブックマーク編集画面の左ペインの行と同様の対応)。
            .help(folder.name)
            // 右クリックメニューはラベル(このフォルダ自身の行)だけに限定する。以前は
            // DisclosureGroup全体(展開中の子フォルダの表示領域も含む)にcontextMenuを
            // 付けていたため、階層化したフォルダで子フォルダの行を右クリックしても、SwiftUIの
            // ヒットテストの都合で親フォルダ側のcontextMenuが表示されてしまい、「削除」を選ぶと
            // 右クリックした子ではなく親(選択中だったフォルダ)が削除されてしまう不具合があった。
            // ラベル部分だけに絞ることで、子フォルダの行は子フォルダ自身のOrganizerFolderRowが
            // 持つcontextMenu(このコードと同じ構造)が優先されるようになる。
            .contextMenu {
                Button("Rename") { onRename(folder) }
                Button("Delete", role: .destructive) { onDelete(folder) }
            }
        }
        .listRowBackground(
            (selectedFolder?.id == folder.id || isTargeted) ? Color.accentColor.opacity(0.15) : Color.clear
        )
        .onDrag { NSItemProvider(object: "favoriteFolder:\(folder.id.uuidString)" as NSString) }
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            onDrop(providers, folder)
        }
    }
}
