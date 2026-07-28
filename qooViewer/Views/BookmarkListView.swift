import SwiftUI

/// 「ブックマークの編集」ウインドウ(独立ウインドウ。Window("Edit Bookmarks", id: "editBookmarks")、
/// QooViewerApp.swift参照)の実際のコンテンツ。
///
/// 以前は「今開いている本」のブックマークだけを、その本のAppState経由で扱っていたが、
/// 「お気に入りの整理」ウインドウと見た目・操作感を揃えるため、左ペインに(ブックマークを
/// 1件以上持つ)すべての本の一覧、右ペインに選択中の本のブックマーク一覧を表示する2ペイン構成に
/// 作り直した。データの実体はBookmarkStoreがすべての本を横断して持つ(本を開いているかどうかに
/// 関わらず削除・リネームができる)。
///
/// 「その本の現在のページを追加」および「クリックしてジャンプ」は、その本を今開いている
/// ウインドウ/タブがある場合にのみ有効になる(LaunchCoordinator.openAppState(forBookID:)で
/// 判定する。開いていない本を新たに開いてジャンプする機能は今回は追加していない)。
struct BookmarkEditorView: View {
    @ObservedObject var bookmarkStore: BookmarkStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator

    @State private var selectedBookID: String?
    @State private var renamingBookmark: Bookmark?
    @State private var renameText = ""

    /// 左ペイン(サイドバー)の幅。ウインドウを開いた時点で登録されている本の名前の長さに応じて
    /// onAppearで一度だけ計算する(SidebarWidthEstimator参照)。既定値220は、名前が無い/短い場合の
    /// フォールバック。
    @State private var sidebarWidth: CGFloat = 220
    /// sidebarWidthの計算を、ウインドウを開いた時点の1回だけに限定するためのフラグ
    /// (以後、本を追加/削除してもリストの内容が変わるたびに勝手にリサイズされないようにする)。
    @State private var hasComputedSidebarWidth = false

    /// 実際に使う選択中のbookID。selectedBookIDが未選択(nil)、またはその本の最後の
    /// ブックマークが削除されて一覧から消えてしまった場合は、以下の優先順でフォールバックする
    /// (お気に入りの整理画面と違い「ルート直下」に相当する概念が無いため、常にどれか1冊が
    /// 選ばれた状態にしておくほうが自然だと判断した)。
    /// 1. 今読んでいる本(launchCoordinator.activeBookAppState)にブックマークがあれば、それを
    ///    ウインドウを開いた時点で自動的に選択する(要望: 今開いている本のエントリへ最初から
    ///    フォーカスを合わせてほしい)。
    /// 2. 無ければ、一覧の先頭の本(名前の自然順)。
    private var effectiveSelectedBookID: String? {
        if let selectedBookID, bookmarkStore.groups.contains(where: { $0.bookID == selectedBookID }) {
            return selectedBookID
        }
        if let activeBookID = launchCoordinator.activeBookAppState?.currentBook?.id,
           bookmarkStore.groups.contains(where: { $0.bookID == activeBookID }) {
            return activeBookID
        }
        return bookmarkStore.groups.first?.bookID
    }

    var body: some View {
        if bookmarkStore.groups.isEmpty {
            // ブックマークが1件も無い場合の案内画面に、「現在のページをブックマークに追加」ボタンを
            // 追加した(要望)。今読んでいる本(launchCoordinator.activeBookAppState)が無い場合は
            // 押せない。ここで追加すると、bookmarkStore.groupsが(通知経由で)非空になり、
            // if/elseの分岐が自動的に2ペイン構成側へ切り替わる。effectiveSelectedBookIDが
            // 「今読んでいる本にブックマークがあればそれを自動選択する」ロジックを既に持っているため、
            // 追加した本・ブックマークがそのまま右ペインに表示された状態で遷移する
            // (追加の特別な状態管理は不要)。
            ContentUnavailableView {
                Label("No Bookmarks Yet", systemImage: "bookmark.slash")
            } description: {
                Text("Bookmarks you add to any book will appear here.")
            } actions: {
                Button("Add Current Page to Bookmarks") {
                    launchCoordinator.activeBookAppState?.addBookmarkAction?()
                }
                .disabled(launchCoordinator.activeBookAppState?.currentBook == nil)
            }
            .frame(minWidth: 640, minHeight: 420)
        } else {
            NavigationSplitView {
                // お気に入りの整理画面のサイドバー(OrganizerFolderRow)と同じく、SwiftUI標準の
                // List(selection:)は使わず、Button+手動のlistRowBackgroundで選択状態を表現する
                // (2つの編集ウインドウで見た目・操作感を完全に揃えるため)。
                List {
                    ForEach(bookmarkStore.groups) { group in
                        // 今この本を開いているウインドウ/タブがあるかどうか。これがtrueの本だけ、
                        // 右ペインの「Add Current Page」・クリックでのジャンプが有効になるため、
                        // 他の(クリックしても本を開けない)行とはっきり見分けられるよう、
                        // アイコン・文字の太さ・「Now Reading」バッジの3点で強調する
                        // (以前は小さな緑の丸だけだったが、選択中のハイライト(listRowBackground)
                        // と紛らわしく、目立たないという指摘があったため強化した)。
                        let isOpen = launchCoordinator.openAppState(forBookID: group.bookID) != nil
                        // 以前はここもButton(label:)にしていたが、AppKitのList行内のButtonは
                        // 「ウインドウ/行にまだフォーカスが無いときの最初のクリックは選択のみで
                        // 実際のアクションが発火しない(もう一度クリックしないと反応しない)」
                        // という既知のクセがあり、これが「開いていない本の名前をクリックしたときの
                        // 反応が遅い(実際には1回目のクリックが効いていないだけ)」という指摘の
                        // 原因だった。右ペインの各行・お気に入りの整理画面の詳細ペインの各行と
                        // 同様に、Buttonをやめてプレーンな.onTapGesture(+contentShape)に
                        // 置き換えることで、常に1回のクリックで即座に反応するようにした。
                        HStack {
                            Image(systemName: isOpen ? "book.fill" : "book.closed")
                                .foregroundStyle(isOpen ? Color.accentColor : Color.primary)
                            Text(group.displayName)
                                .fontWeight(isOpen ? .semibold : .regular)
                            if isOpen {
                                Text("Now Reading")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Text("\(group.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedBookID = group.bookID
                        }
                        // 左ペインの幅が狭く、本の名前が省略表示("…")になっていることが多いため、
                        // カーソルを合わせるとフルネームをツールチップで表示する
                        // (本の名前が、タイトルバー・左ペイン・右ペインの3箇所に重複して
                        // 表示されていたのをやめ、左ペインだけに一本化したことへの対応)。
                        .help(group.displayName)
                        .listRowBackground(
                            effectiveSelectedBookID == group.bookID
                                ? Color.accentColor.opacity(0.15) : Color.clear
                        )
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Bookmarks")
                // 左ペインの幅を、開いた時点で登録されている本の名前の長さに応じて広げる
                // (要望: 名前が長い本が多い場合、既定の幅では省略表示になりがちで読みにくい)。
                // ideal:に渡した値はウインドウの初期サイズのヒントとしても使われるため、
                // 初めて開いたとき(まだウインドウサイズが記憶されていないとき)は、この幅を
                // 反映した状態で開く。一度ユーザーが手動でリサイズした後は、通常通りその
                // サイズが記憶・復元される。
                .navigationSplitViewColumnWidth(min: 220, ideal: sidebarWidth, max: 560)
                .onAppear {
                    guard !hasComputedSidebarWidth else { return }
                    hasComputedSidebarWidth = true
                    sidebarWidth = SidebarWidthEstimator.idealWidth(
                        forNames: bookmarkStore.groups.map(\.displayName)
                    )
                }
            } detail: {
                if let bookID = effectiveSelectedBookID,
                   bookmarkStore.groups.contains(where: { $0.bookID == bookID }) {
                    BookmarkDetailPane(
                        bookID: bookID,
                        bookmarkStore: bookmarkStore,
                        renamingBookmark: $renamingBookmark,
                        renameText: $renameText
                    )
                } else {
                    ContentUnavailableView(
                        "Select a Book",
                        systemImage: "book",
                        description: Text("Choose a book on the left to see its bookmarks.")
                    )
                }
            }
            // 左ペインが広がった分、右ペインが窮屈にならないよう、ウインドウ全体の最小幅も
            // 追随させる(要望: 右ペインがしわ寄せを受けるくらいなら、ウインドウ全体を
            // 広げてよい)。400は右ペインに最低限確保したい幅の目安。
            .frame(minWidth: max(640, sidebarWidth + 400), minHeight: 420)
            .alert(
                "Rename Bookmark",
                isPresented: Binding(
                    get: { renamingBookmark != nil },
                    set: { isPresented in if !isPresented { renamingBookmark = nil } }
                )
            ) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let bookmark = renamingBookmark {
                        bookmarkStore.rename(bookmark, to: renameText)
                    }
                    renamingBookmark = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingBookmark = nil
                }
            }
        }
    }
}

/// 選択中の本1冊分のブックマーク一覧(右ペイン)。
private struct BookmarkDetailPane: View {
    let bookID: String
    @ObservedObject var bookmarkStore: BookmarkStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Binding var renamingBookmark: Bookmark?
    @Binding var renameText: String

    /// 右ペインで今クリックして選択中のブックマークのid。以前はクリックしても
    /// (本を開いていない場合は特に)見た目の変化が無く、選択できているのか分かりにくいという
    /// 指摘があったため、左ペインの選択と同じ見た目でハイライトする(row(for:)参照)。
    @State private var selectedBookmarkID: UUID?

    /// この本を今開いているウインドウ/タブのAppState(無ければnil)。
    private var openAppState: AppState? {
        launchCoordinator.openAppState(forBookID: bookID)
    }

    var body: some View {
        List {
            ForEach(bookmarkStore.bookmarks(forBookID: bookID)) { bookmark in
                row(for: bookmark)
            }
        }
        // 並べ替え基準を切り替えるコントロール。お気に入りの整理画面(FavoritesOrganizerView)の
        // 「Sort By」メニューと同じFavoritesSortOptionをそのまま使い、見た目・文言を揃えている。
        //
        // 本の名前はここには表示しない。以前はここ・左ペインの行・ウインドウのタイトルバーの
        // 3箇所に同じ名前が重複して表示されており鬱陶しいという指摘があったため、左ペインの
        // 行だけに一本化した(ウインドウのタイトルバーへの反映は.navigationTitleを参照)。
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                Picker(selection: $bookmarkStore.sortOption) {
                    ForEach(FavoritesSortOption.allCases) { option in
                        Label {
                            Text(option.titleKey)
                        } icon: {
                            Image(systemName: option.systemImage)
                        }
                        .tag(option)
                    }
                } label: {
                    Label("Sort By", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        // 「お気に入りの整理」ウインドウの「Add Current Book」ボタンに相当する。この本を
        // 今開いているウインドウ/タブがある場合にのみ有効になる(閉じている本には「現在の
        // ページ」という概念が無いため)。
        .safeAreaInset(edge: .bottom) {
            Button {
                openAppState?.addBookmarkAction?()
            } label: {
                Label("Add Current Page", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(openAppState?.addBookmarkAction == nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        // 以前はここで.navigationTitle(displayName)を指定しており、選択中の本の名前が
        // ウインドウのタイトルバーにも表示されていたが、左ペインの行と重複して鬱陶しいという
        // 指摘があったため削除した。ただしタイトルを完全に省略すると、NavigationSplitViewは
        // (サイドバー側の.navigationTitle("Bookmarks")ではなく)このWindowシーン自身の
        // タイトル文字列(QooViewerApp.swiftのWindow("Edit Bookmarks", id: "editBookmarks"))を
        // そのままタイトルバーに表示するため、英語のまま("Edit Bookmarks")になってしまい、
        // 「お気に入りの編集」ウインドウと日本語/英語が揃わないという指摘があった。
        // そのため、本の名前の代わりに常に固定の文言を明示的に指定している
        // (FavoritesOrganizerViewの.navigationTitle("Edit Favorites")と同じ理由・同じ対応)。
        .navigationTitle("Edit Bookmarks")
    }

    @ViewBuilder
    private func row(for bookmark: Bookmark) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.name)
                (Text("Page ") + Text("\(bookmark.pageIndex + 1)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // お気に入りの整理画面の各行と見た目を揃えた、インラインの削除ボタン。
            Button {
                bookmarkStore.delete(bookmark)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        // 左ペインの行と同様、カーソルを合わせるとフルネームをツールチップで表示する
        // (要望: 右ペインのアイテムについてもホバーでフルネームを見られるようにしてほしい)。
        .help(bookmark.name)
        // クリックして選択したことが分かるよう、左ペインと同じ見た目でハイライトする
        // (要望: 右ペインの項目を選択したとき、選択されているか分かりにくい、という指摘への対応。
        // 特にその本を今開いていない場合、以前はクリックしても何も起きず、選択できているのか
        // 分からなかった)。
        .listRowBackground(
            selectedBookmarkID == bookmark.id ? Color.accentColor.opacity(0.15) : Color.clear
        )
        // シングルクリックは選択のみ、ダブルクリックでそのページへジャンプする(要望:
        // シングルクリックでいきなりジャンプするのではなく、選択とジャンプを分けてほしい)。
        // お気に入りの整理画面のフォルダ行(シングルクリック=選択、ダブルクリック=移動)と
        // 同じ考え方・同じ実装パターン。
        .onTapGesture(count: 2) {
            // この本が今開いていない場合はページへのジャンプは行わない(要望: 開いていない本の
            // ブックマークは削除・リネームのみ可能とし、開く機能は今回は追加しない)。
            guard let openAppState else { return }
            openAppState.jumpToBookmark?(bookmark)
            openAppState.hostWindow?.makeKeyAndOrderFront(nil)
        }
        .onTapGesture(count: 1) {
            selectedBookmarkID = bookmark.id
        }
        .contextMenu {
            Button("Rename") {
                renameText = bookmark.name
                renamingBookmark = bookmark
            }
            Button("Delete", role: .destructive) {
                bookmarkStore.delete(bookmark)
            }
        }
    }
}

/// 「ブックマークの編集」ウインドウのトップレベルのコンテンツ。QooViewerApp.swiftの
/// Window("Edit Bookmarks", id: "editBookmarks")から引数なしで呼ばれるため、実際に必要な
/// BookmarkStoreは環境値経由で受け取る。
struct BookmarkEditorWindow: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore

    var body: some View {
        BookmarkEditorView(bookmarkStore: bookmarkStore)
    }
}
