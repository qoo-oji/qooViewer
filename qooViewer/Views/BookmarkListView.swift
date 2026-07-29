import SwiftUI
import AppKit

/// 「ブックマークの編集」ウインドウ(独立ウインドウ。Window("Edit Bookmarks", id: "editBookmarks")、
/// QooViewerApp.swift参照)の実際のコンテンツ。
///
/// 以前は「今開いている本」のブックマークだけを、その本のAppState経由で扱っていたが、
/// 「お気に入りの整理」ウインドウと見た目・操作感を揃えるため、左ペインに(ブックマークを
/// 1件以上持つ)すべての本の一覧、右ペインに選択中の本のブックマーク一覧を表示する2ペイン構成に
/// 作り直した。データの実体はBookmarkStoreがすべての本を横断して持つ(本を開いているかどうかに
/// 関わらず削除・リネームができる)。
///
/// 「その本の現在のページを追加」は、その本を今開いているウインドウ/タブがある場合にのみ
/// 有効になる(LaunchCoordinator.openAppState(forBookID:)で判定する。「現在のページ」という
/// 概念自体が、開いていない本には無いため)。
///
/// 一方「クリックしてジャンプ」(ダブルクリック)は、その本を今開いていない場合でも動作する。
/// すでに他のウインドウ/タブで開いていればそれをアクティブにし、開いていなければ状況に応じて
/// (ウェルカム画面で開く/新しいウインドウで開く/他の本を置き換えて開く)その本を開いた上で
/// ジャンプする(詳細はBookmarkDetailPane.openBookAndJump(to:)参照)。
///
/// 左ペイン・右ペインとも、右ペインで元々使っていたFavoritesSortOption(名前・追加日時・
/// 更新日時、それぞれ昇順・降順)で並べ替えられる。ただし2つのペインの並べ替え基準
/// (bookmarkStore.bookSortOption/sortOption)は独立しており、片方を変えてももう片方には
/// 影響しない(要望: 左ペインにも並べ替え手段を追加してほしいが、本を選び替えるたびに
/// ブックマークの並びまで変わる体験は避けたい)。
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
    /// 2. 無ければ、一覧の先頭の本(bookmarkStore.bookSortOptionに従った現在の並び順で先頭)。
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
                // 左ペイン(本一覧)の並べ替え基準を切り替えるコントロール。右ペインの
                // 「Sort By」メニュー(BookmarkDetailPane参照)と全く同じFavoritesSortOptionを
                // 使うが、値自体は独立している(bookmarkStore.bookSortOption)。本を選び替える
                // たびに右ペインのブックマークの並びまで変わってしまう体験を避けるため
                // (要望: 左ペインも右ペインと同じルールでソートできるようにしてほしい)。
                .safeAreaInset(edge: .top) {
                    HStack {
                        Spacer()
                        Picker(selection: $bookmarkStore.bookSortOption) {
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

    /// 「新しいウインドウで開く」相当の処理(要望3)で、SwiftUIにウインドウ作成そのものを
    /// 管理させるために使う(QooViewerApp.swiftの"book" WindowGroup参照)。
    @Environment(\.openWindow) private var openWindow

    /// 右ペインで今クリックして選択中のブックマークのid。以前はクリックしても
    /// (本を開いていない場合は特に)見た目の変化が無く、選択できているのか分かりにくいという
    /// 指摘があったため、左ペインの選択と同じ見た目でハイライトする(row(for:)参照)。
    @State private var selectedBookmarkID: UUID?

    /// ダブルクリックしたブックマークの本を開こうとしたが、ファイル/フォルダが見つからない、
    /// またはアクセスできなかった場合に、その本の表示名(左ペインの行と同じ生成方法)を
    /// アラートのメッセージに埋め込むために保持する(openBookAndJump(to:)参照)。
    @State private var openErrorBookName: String?

    /// この「ブックマークの編集」ウインドウ自身のNSWindow。WindowAccessor経由で設定する。
    /// 右ペインでのダブルクリックでページへジャンプしてビューアウインドウへフォーカスが
    /// 移ったとき、このウインドウ自身を自動的に閉じるために使う(closeEditorWindow参照)。
    @State private var editorWindow: NSWindow?

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
        // このウインドウ自身のNSWindowを取得しておく(closeEditorWindow参照)。ViewerView/
        // ContentView/FavoritesOrganizerViewと同じWindowAccessorパターン。
        .background(WindowAccessor { window in
            editorWindow = window
        })
        // 対象の本を開けなかった場合(ファイル/フォルダが見つからない、またはアクセスできな
        // かった場合)のアラート。ContentView.missingFavoriteの見た目・文言と揃えている。
        // 文字列補間をそのままText("...")に渡すと手書きのLocalizable.xcstringsでは翻訳と
        // 紐付かないため、ContentView.missingFavoriteのアラートと同じく、固定文字列の断片を
        // Text同士の+でつなぐ形にしている。
        .alert(
            "Could Not Open Book",
            isPresented: Binding(
                get: { openErrorBookName != nil },
                set: { isPresented in if !isPresented { openErrorBookName = nil } }
            )
        ) {
            Button("OK") { openErrorBookName = nil }
        } message: {
            Text("The file or folder for “") + Text(openErrorBookName ?? "")
                + Text("” could not be found. It may have been moved or deleted.")
        }
    }

    /// 右ペインでブックマークをダブルクリックしたときの処理。
    ///
    /// 1. 対象の本をすでにどこかのウインドウ/タブで開いている → そのウインドウ/タブを
    ///    アクティブにしてジャンプする(以前からの動作)。
    /// 2. コンテンツウインドウ(ウェルカム画面を含む。「ブックマークの編集」「お気に入りの
    ///    編集」「環境設定」などは含まない)が1つもない → 新しいウインドウで開いてジャンプする。
    /// 3. コンテンツウインドウはあるが対象の本はどこにも開いていない → 今いちばん手前にある
    ///    コンテンツウインドウで開く。そのウインドウがウェルカム画面(本を開いていない)か、
    ///    既に別の本を開いているかは区別しない。どちらもAppState.open(url:)を呼ぶだけで、
    ///    「開いていない状態から開く」「別の本を置き換える」の両方に対応できるため
    ///    (Finderから別の本を開いたときの「現在の本を置き換える」動作と同じ仕組み)。
    private func openBookAndJump(to bookmark: Bookmark) {
        // 1. すでに開いている場合。
        if let existingAppState = launchCoordinator.openAppState(forBookID: bookmark.bookID) {
            existingAppState.jumpToBookmark?(bookmark)
            existingAppState.hostWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            closeEditorWindow()
            return
        }

        guard let url = resolvedURL(for: bookmark) else {
            // 表示名は左ペインの行(BookmarkBookGroup.displayName)と同じ生成方法(パスの
            // 最後の部分)を使う。ブックマーク自体はページの名前(bookmark.name)しか
            // 持っておらず、本の名前は保存していないため。
            openErrorBookName = URL(fileURLWithPath: bookmark.bookID)
                .deletingPathExtension()
                .lastPathComponent
            return
        }
        _ = url.startAccessingSecurityScopedResource()

        if let targetAppState = launchCoordinator.frontmostContentAppState() {
            // 2/4: 既存のコンテンツウインドウ(ウェルカム画面、または他の本を開いているウインドウ)
            // で開く。
            targetAppState.open(url: url)
            waitAndJump(appState: targetAppState, to: bookmark)
        } else {
            // 3: コンテンツウインドウが1つも無い → 新しいウインドウを開く。
            openWindow(id: "book", value: url)
            Task { @MainActor in
                // openWindowが実際にNSWindowを作り終え、その本の読み込みが完了して
                // launchCoordinatorに登録されるまで、短い間隔で繰り返し確認する
                // (QooViewerApp.openURLInNewWindowの待機ロジックと同じ考え方)。
                for _ in 0..<200 {
                    if let newAppState = launchCoordinator.openAppState(forBookID: bookmark.bookID) {
                        waitAndJump(appState: newAppState, to: bookmark)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
            }
        }
    }

    /// 指定したAppStateが対象の本を読み込み終え、jumpToBookmarkクロージャが登録される
    /// (=ViewerViewが実際に表示された)のを短い間隔で待ってからジャンプし、ウインドウを
    /// 最前面にする。読み込みに失敗した場合(errorMessageが立った場合)はそれ以上待たずに
    /// あきらめる(エラー自体はContentView.swiftの.alertが表示する)。
    private func waitAndJump(appState: AppState, to bookmark: Bookmark) {
        Task { @MainActor in
            for _ in 0..<200 {
                if appState.currentBook?.id == bookmark.bookID, let jump = appState.jumpToBookmark {
                    jump(bookmark)
                    appState.hostWindow?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    closeEditorWindow()
                    return
                }
                if appState.currentBook == nil, appState.errorMessage != nil {
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    /// 右ペインでのダブルクリックにより、対象の本が実際にどこか(既存ウインドウ/新しい
    /// ウインドウ)で開かれ/ジャンプが行われ、ビューアウインドウへフォーカスが移った直後に呼ぶ。
    /// このウインドウ(ブックマークの編集ウインドウ)自身はもう用済みなので、自動的に閉じる
    /// (要望: ページへジャンプしたら/本を開いたら、その操作の元になった編集ウインドウは
    /// 自動的に閉じてほしい。「お気に入りの整理」ウインドウのcloseEditorWindowと同じ考え方)。
    /// ファイルが見つからない場合(openErrorBookNameを立てて処理を打ち切る場合)や、
    /// 本の読み込みに失敗した場合(waitAndJump内でerrorMessageが立って諦める場合)は
    /// この関数自体が呼ばれないため、フォーカス移動を伴わない失敗時に誤って閉じてしまうことはない。
    private func closeEditorWindow() {
        editorWindow?.close()
    }

    /// ブックマークが指す本のURLを解決する。セキュリティスコープ付きブックマーク
    /// (bookmarkData)があればそれを解決し、実際にファイル/フォルダがまだ存在するかまで
    /// 確認する。無い場合(この機能を追加する前に作られたブックマーク)、または解決に失敗した
    /// 場合は、bookIDの素のパスへフォールバックする(環境設定「アクセス権」で許可済みの
    /// フォルダ配下であれば、これでも開ける)。どちらの方法でも見つからなければnilを返す。
    private func resolvedURL(for bookmark: Bookmark) -> URL? {
        if let data = bookmark.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallbackURL = URL(fileURLWithPath: bookmark.bookID)
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }
        return fallbackURL
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
        //
        // この本を今開いていない場合も、openBookAndJump(to:)が「すでに開いている/ウェルカム
        // 画面のみ/ウインドウが1つも無い/他の本を開いている」の4通りに応じて適切なウインドウ/
        // タブで開いた上でジャンプする(詳細はopenBookAndJump(to:)のコメント参照)。
        .onTapGesture(count: 2) {
            openBookAndJump(to: bookmark)
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
