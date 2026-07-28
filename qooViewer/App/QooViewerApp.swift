import SwiftUI
import SwiftData
import AppKit

/// アプリ構造体自体を明示的に@MainActorにしておく。SwiftUIのAppプロトコル自体、bodyなどの
/// 要求はもともと@MainActorだが、favoritesStoreをModelContext付きで組み立てるための独自init()を
/// 追加した際、他の@StateObjectプロパティ(recentFilesなど)の宣言時デフォルト値の評価まわりで
/// 分離状態があいまいになり、「main actor-isolated instance method 'reload()' in a synchronous
/// nonisolated context」のようなビルドエラーが連鎖する事象があったため、型そのものに明示しておく。
@MainActor
@main
struct QooViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences = AppPreferences()
    @StateObject private var keyBindingStore = KeyBindingStore()
    @StateObject private var recentFiles = RecentFilesStore()
    @StateObject private var folderAccess = FolderAccessStore()
    /// お気に入り(階層フォルダ + 登録した本)。RecentFilesStore等と違いSwiftDataで永続化するため、
    /// modelContainerから作ったModelContextを渡す必要があり、下のinit()で明示的に生成している。
    @StateObject private var favoritesStore: FavoritesStore
    /// 複数ウインドウ/タブに対応するための調整役。詳細はLaunchCoordinator.swiftのコメント参照。
    @StateObject private var launchCoordinator = LaunchCoordinator()
    /// メニューバー(アプリ全体で1つ)から、今アクティブな(キーウインドウの)AppStateを
    /// 参照するための仕組み。詳細はAppState.swiftのFocusedValues拡張のコメント参照。
    @FocusedValue(\.qooViewerAppState) private var focusedAppState
    /// メニューバーのチェックマーク表示専用の値型。AppStateというクラス参照だけを
    /// FocusedValueとして公開していたときはチェックマークが更新されなかったため、
    /// 値型(Equatable)として別途公開したものをこちらで読む(書き込みはfocusedAppState経由の
    /// まま)。詳細はAppState.swiftのMenuCheckmarkStateのコメント参照。
    @FocusedValue(\.qooViewerMenuCheckmarkState) private var menuCheckmarkState
    /// 「新しいウインドウで開く」「新しいタブで開く」で、指定したURLを持つ新しいウインドウを
    /// SwiftUIに作らせるための仕組み(下の"book" WindowGroup参照)。
    @Environment(\.openWindow) private var openWindow

    /// SwiftDataのモデルコンテナ。`.modelContainer(for:)`という簡易版ではなく明示的な
    /// インスタンスとして1つだけ持っておくことで、「新しいウインドウで開く」「新しいタブで開く」で
    /// AppKitから直接組み立てる追加ウインドウにも、メインウインドウと同じコンテナ(同じ保存先)を
    /// 渡せるようにしている。
    /// static: favoritesStoreの初期化(下のinit()参照)で、StateObject(wrappedValue:)へ渡す
    /// escaping autoclosureの中からこの値を参照する必要がある。インスタンスプロパティ(let)の
    /// ままだと、構造体(QooViewerApp)がまだ初期化を終えていない段階でselfをエスケープする
    /// クロージャに捕まえてしまうことになり、「Escaping autoclosure captures mutating 'self'
    /// parameter」というビルドエラーになった。staticにすることでselfを介さずに参照できるため、
    /// この問題を避けられる(値そのものはアプリ全体で1つだけ、という意図は変わらない)。
    private static let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: BookReadingState.self, Bookmark.self, FavoriteFolder.self, FavoriteBook.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    /// 環境設定「表示言語」を実際のLocaleに変換したもの。「システムに従う」のときはnilを渡し、
    /// SwiftUIにシステムのロケールをそのまま使わせる。
    /// WindowGroup・Settings両方のScene(メニューバーのcommandsを含む)にこれを適用することで、
    /// アプリ内でシステム言語とは独立して表示言語を切り替えられるようにしている。
    private var currentLocale: Locale {
        preferences.displayLanguage.localeOverride ?? .autoupdatingCurrent
    }

    /// favoritesStoreはmodelContainerから作ったModelContextを必要とするため、他のStateObjectと
    /// 違って宣言時のデフォルト値だけでは初期化できない。そのためこのinit()で明示的に組み立てる
    /// (modelContainer自身は宣言時のデフォルト値でそのまま初期化される。他の@StateObjectプロパティも
    /// 同様に、ここで触れていないものは宣言時のデフォルト値がそのまま使われる)。
    @MainActor
    init() {
        _favoritesStore = StateObject(
            wrappedValue: FavoritesStore(modelContext: ModelContext(QooViewerApp.modelContainer))
        )
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(preferences)
                .environmentObject(keyBindingStore)
                .environmentObject(recentFiles)
                .environmentObject(folderAccess)
                .environmentObject(favoritesStore)
                .environmentObject(launchCoordinator)
                .onAppear {
                    appDelegate.preferences = preferences
                    appDelegate.launchCoordinator = launchCoordinator
                    // Finderから別の本を開こうとしたとき(環境設定「Finderから開いたとき」が
                    // 「新しいタブ/ウインドウで開く」の場合)に、AppDelegate自身は持たない
                    // openWindow環境値を使ってウインドウ/タブを作るための橋渡し。
                    appDelegate.openInNewWindowOrTab = { url, asTab, tabTarget in
                        openURLInNewWindow(url, asTab: asTab, tabTarget: tabTarget)
                    }
                }
        }
        // .contentSizeのままだと、SwiftUIがコンテンツ(ContentView)のサイズから毎回ウインドウの
        // フレームを計算し直そうとするため、ContentView側でsetFrameAutosaveNameを使って
        // 復元している「前回終了時の位置・サイズ」と競合し、起動のたびに位置がずれてしまって
        // いた。.automaticにすると今度は初期サイズの手がかりが無くなり、ウインドウが画面
        // いっぱいに広がってしまっていた(v119で確認済み)。.defaultSize(width:height:)で
        // 「保存された状態が無いときの初期サイズ」だけを別途指定した上で.automaticにすることで、
        // 初回起動時は900x640相当のサイズになりつつ、2回目以降はSwiftUI側がフレームに
        // 干渉せず、setFrameAutosaveNameによる復元がそのまま反映されるようにする。
        .windowResizability(.automatic)
        .defaultSize(width: 900, height: 640)
        .modelContainer(QooViewerApp.modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {
                // グループ1: 通常の「開く」(単一ウインドウ内で、選んだファイル/フォルダに置き換える)
                Button("Open…") {
                    focusedAppState?.openWithPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(focusedAppState == nil)

                Divider()

                // グループ2: 新しいウインドウ/タブとして開く
                Button("Open in New Window…") {
                    openPickedURLInNewWindow(asTab: false)
                }

                Button("Open in New Tab…") {
                    openPickedURLInNewWindow(asTab: true)
                }

                Divider()

                // グループ3: 現在の本と関連するファイルを開く(同じフォルダ内)
                Menu("Open File in Same Folder") {
                    if let focusedAppState, !focusedAppState.siblingBooks.isEmpty {
                        ForEach(focusedAppState.siblingBooks, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                focusedAppState.open(url: url)
                            }
                        }
                    } else {
                        Button("Grant Access to This Folder…") {
                            focusedAppState?.grantAccessToCurrentFolder()
                        }
                        .disabled(focusedAppState?.currentBook == nil)
                    }
                }

                Divider()

                // グループ4: 開いた履歴から選んで開く
                Menu("Open Recent") {
                    if recentFiles.entries.isEmpty {
                        Text("(None)")
                    } else {
                        ForEach(recentFiles.entries) { entry in
                            Button(entry.displayName) {
                                _ = entry.url.startAccessingSecurityScopedResource()
                                focusedAppState?.open(url: entry.url)
                            }
                        }
                    }
                }
            }

            // 以前は「Viewer」という独立したメニューだったが、標準の「表示」(View)メニューに
            // 統合してほしいという要望を受けて、CommandMenu("View")という「新しいトップレベル
            // メニューを作る」仕組みを使っていた。しかしCommandMenuは、たとえ既存メニューと
            // 同じタイトルを付けても実際にはマージされず、標準の「View」メニュー(AppKitが
            // 自動的に追加する「Enter Full Screen」などを含む)とは別に、同名の2つ目のメニューが
            // できてしまっていた。CommandGroup(after: .toolbar)を使うと、既存の標準「View」
            // メニューの中に項目を追記する形になり、メニューが1つにまとまる。
            // ページ/ファイルの移動に関する項目は「移動」(Move)メニューへ、ブックマーク関連の
            // 項目は「ブックマーク」(Bookmark)メニューへ、それぞれ分離してある。
            // 「閉じる」は、Fileメニューの標準「閉じる」(Cmd+W)がこの役割を兼ねるように
            // したため、ここからは削除した(QooViewerApp.swift下部のBookClosingWindowDelegate、
            // およびViewerView.swiftのsetUpWindowObserversでの委譲設定を参照)。
            CommandGroup(after: .toolbar) {
                let hasBook = focusedAppState?.currentBook != nil

                // ウインドウ表示のときは、この設定のON/OFFで表示/非表示を切り替える。
                // フルスクリーン中は、この設定に関わらず常にフルスクリーン用の自動隠し/自動表示
                // (マウスを画面端に近づけたときだけ表示)が優先される。ONのときは、ウインドウ
                // 表示中でもフルスクリーンと同様、マウスを上下端に近づけると一時的に表示される
                // (ViewerView.bodyのshowToolbar/showProgressBar、
                // updateAutoHiddenChromeVisibility参照)。
                Toggle(
                    "Hide Toolbar",
                    isOn: Binding(
                        get: { menuCheckmarkState?.hideToolbar ?? false },
                        set: { focusedAppState?.hideToolbar = $0 }
                    )
                )
                .disabled(!hasBook)

                Toggle(
                    "Hide Progress Bar",
                    isOn: Binding(
                        get: { menuCheckmarkState?.hideProgressBar ?? false },
                        set: { focusedAppState?.hideProgressBar = $0 }
                    )
                )
                .disabled(!hasBook)

                Divider()

                Button("Show Page Grid") {
                    focusedAppState?.performViewerAction?(.showThumbnailGrid)
                }
                .disabled(!hasBook)

                Divider()

                // 実行中かどうかという明確なON/OFF状態があるため、Buttonではなく
                // Toggleにして、実行中は左にチェックマークが表示されるようにしている
                // (isOnの値自体はAppState側の状態から取るだけで、setクロージャでは
                // クリックのたびにトグル用のアクションを呼ぶだけでよい)。
                Toggle(
                    "Slideshow",
                    isOn: Binding(
                        get: { menuCheckmarkState?.isSlideshowActive ?? false },
                        set: { _ in focusedAppState?.performViewerAction?(.toggleSlideshow) }
                    )
                )
                .disabled(!hasBook)

                Divider()

                // 見開き/単ページも同様に、ON/OFFのチェックマークで表す
                // (ONのとき見開き表示、OFFのとき単ページ表示)。
                // EPUBがrendition:spreadで本全体の見開き/単ページを強制している間は、
                // 設定を無視して強制値に従うことをグレーアウトで示す
                // (詳細はViewerViewModel.isDisplayModeLocked参照)。
                Toggle(
                    "Spread",
                    isOn: Binding(
                        get: { menuCheckmarkState?.isSpreadMode ?? false },
                        set: { _ in focusedAppState?.performViewerAction?(.toggleDisplayMode) }
                    )
                )
                .disabled(!hasBook || (menuCheckmarkState?.isDisplayModeLocked ?? false))

                // 読み方向も同様に、現在右から左かどうかというON/OFF状態をチェックマークで表す
                // (ONのとき右から左=マンガの標準的な読み方向。「移動」メニューの各項目の
                // 左右の意味も、この値によって切り替わる)。
                // EPUBがpage-progression-directionで読み方向を明示している間は同様にグレーアウトする。
                Toggle(
                    "Right-to-Left",
                    isOn: Binding(
                        get: { menuCheckmarkState?.isRightToLeft ?? false },
                        set: { _ in focusedAppState?.performViewerAction?(.toggleReadingDirection) }
                    )
                )
                .disabled(!hasBook || (menuCheckmarkState?.isReadingDirectionLocked ?? false))

                // 表示モードの切り替え(画面に合わせる/幅に合わせる/拡大縮小なし)は3択のため、
                // 単純なON/OFFのToggleではなく、3つから直接選べるサブメニューにし、
                // 現在選ばれているモードにチェックマークを表示する。
                Menu("Cycle Display Mode") {
                    ForEach(ScalingMode.allCases) { mode in
                        Toggle(
                            mode.titleKey,
                            isOn: Binding(
                                get: { menuCheckmarkState?.scalingMode == mode },
                                set: { isOn in
                                    guard isOn else { return }
                                    focusedAppState?.setScalingMode?(mode)
                                }
                            )
                        )
                    }
                }
                .disabled(!hasBook)

                // macOSが自動的に追加する「フルスクリーンにする」/「フルスクリーンを解除」は、
                // 左にアイコンが付くため、区切り線を挟まず同じ並びにしてしまうと、
                // 「見開き」「右から左へ」「表示モード切替」の文字列がアイコンの分だけ余分に
                // 右にインデントされてしまう。区切り線を入れてフルスクリーン項目を独立した
                // グループにすることで、この並びのインデントをそろえる。
                Divider()
            }

            CommandMenu("Move") {
                let hasBook = focusedAppState?.currentBook != nil
                // 「右から左へ」がONのときは左方向が「次」、右方向が「前」になる
                // (マンガの標準的な読み方向)。OFFのときはその逆(左が前、右が次)。
                // menuCheckmarkStateを読むのはチェックマークの不具合と同じ理由
                // (値型のFocusedValueでないと変化が検知されないため)。
                let isRightToLeft = menuCheckmarkState?.isRightToLeft ?? false

                Button("Move to Next") {
                    focusedAppState?.performViewerAction?(isRightToLeft ? .spatialLeft : .spatialRight)
                }
                .disabled(!hasBook)

                Button("Move to Previous") {
                    focusedAppState?.performViewerAction?(isRightToLeft ? .spatialRight : .spatialLeft)
                }
                .disabled(!hasBook)

                Divider()

                // EPUBが見開き内の配置(page-spread-left/right/center)を明示している場合、
                // この調整でその組み合わせを崩してしまわないよう無効化する
                // (詳細はViewerViewModel.isPageShiftLocked参照)。
                Button("Shift One Page to Next") {
                    focusedAppState?.performViewerAction?(isRightToLeft ? .shiftOnePageLeft : .shiftOnePageRight)
                }
                .disabled(!hasBook || (menuCheckmarkState?.isPageShiftLocked ?? false))

                Button("Shift One Page to Previous") {
                    focusedAppState?.performViewerAction?(isRightToLeft ? .shiftOnePageRight : .shiftOnePageLeft)
                }
                .disabled(!hasBook || (menuCheckmarkState?.isPageShiftLocked ?? false))

                Divider()

                Button("Move to First") {
                    focusedAppState?.performViewerAction?(.firstPage)
                }
                .disabled(!hasBook)

                Button("Move to Last") {
                    focusedAppState?.performViewerAction?(.lastPage)
                }
                .disabled(!hasBook)

                Divider()

                Button("Go to Previous Book") {
                    if let url = focusedAppState?.currentBook?.sourceURL {
                        focusedAppState?.openSibling(before: url)
                    }
                }
                .disabled(!hasBook)

                Button("Go to Next Book") {
                    if let url = focusedAppState?.currentBook?.sourceURL {
                        focusedAppState?.openSibling(after: url)
                    }
                }
                .disabled(!hasBook)
            }

            // 標準の「ウインドウ」(Window)メニューに「ウインドウを閉じる」を追加する。
            // Cmd+W(File>閉じる)やタブバー自身の×ボタンは、AppKit上まったく同じ経路
            // (NSWindow.performClose(_:) → windowShouldClose)で処理されるためプログラム的に
            // 区別できない。そのため複数タブの確認ダイアログはそちらには出さず、赤い閉じるボタン
            // (forceCloseWindow(_:)。BookClosingWindowDelegate参照)とこの「ウインドウを閉じる」
            // メニュー項目だけに絞っている。この2つは自分たちで直接呼び出しているコードのため、
            // 実行前に確実に確認を挟める。
            CommandGroup(before: .windowArrangement) {
                Button("Close Window") {
                    guard let window = NSApp.keyWindow else { return }
                    if let delegate = window.delegate as? BookClosingWindowDelegate {
                        delegate.forceCloseWindow(nil)
                    } else {
                        window.performClose(nil)
                    }
                }
                Divider()
            }

            // 以前は「ブックマーク」という独立したメニューだったが、要望6により
            // 「お気に入り」メニューへ統合した。ブックマーク(本を開いている間だけ有効な、
            // ページ位置の目印)とお気に入り(本そのものを、階層フォルダで整理して保存する)は
            // 別の仕組みのため、Dividerでグループを分けて並べる。
            // グループの並び順(お気に入りが上、ブックマークが下)、および各グループ内の並び順
            // (追加→編集→一覧)はユーザーからの指示により統一している。「編集」の文言も
            // 「ブックマークの編集…」と表現をそろえ、以前の「お気に入りを整理…」から
            // 「お気に入りの編集…」に変更した(ViewerAction.showFavoritesOrganizer、
            // Window("Edit Favorites", ...)も同様に変更済み)。
            CommandMenu("Favorites") {
                let hasBook = focusedAppState?.currentBook != nil

                // グループ1: お気に入り(追加→編集→一覧の順)
                Button("Add Current Book to Favorites…") {
                    focusedAppState?.performViewerAction?(.addToFavorites)
                }
                .disabled(!hasBook)

                Button("Edit Favorites…") {
                    openWindow(id: "favoritesOrganizer")
                }

                // 階層構造のままサブメニューで一覧表示する(要望4)。開く/新しいウインドウで開く/
                // 新しいタブで開くのみに絞り、並べ替え・移動はここでは行わない
                // (「お気に入りの編集」ウインドウ側の役割。favorites_feature_assessment.md参照)。
                Menu("Favorites List") {
                    FavoritesMenuContent(
                        favoritesStore: favoritesStore,
                        onOpen: { favorite in openFavoriteAccordingToPreference(favorite) }
                    )
                }

                Divider()

                // グループ2: ブックマーク(追加→編集→一覧の順)
                Button("Add Current Page to Bookmarks") {
                    focusedAppState?.performViewerAction?(.addBookmark)
                }
                .disabled(!hasBook)

                Button("Edit Bookmarks…") {
                    focusedAppState?.performViewerAction?(.showBookmarkList)
                }
                .disabled(!hasBook)

                // ブックマーク一覧を(要望6により)フラットな並びではなくサブメニューにまとめる。
                Menu("Bookmark List") {
                    if let focusedAppState, !focusedAppState.currentBookmarks.isEmpty {
                        ForEach(focusedAppState.currentBookmarks, id: \.id) { bookmark in
                            Button("\(bookmark.name) (\(bookmark.pageIndex + 1))") {
                                focusedAppState.jumpToBookmark?(bookmark)
                            }
                        }
                    } else {
                        Text("(No Bookmarks)")
                    }
                }
                .disabled(!hasBook)
            }
        }
        .environment(\.locale, currentLocale)

        // 「新しいウインドウで開く」「新しいタブで開く」専用のWindowGroup。URLを値として渡せる
        // (`openWindow(id: "book", value: url)`)ことで、SwiftUIにウインドウ作成そのものを
        // 管理させる。直接AppKitでNSWindow/NSHostingViewを組み立てる方法だと、SwiftUIのScene
        // 管理の外側になってしまい、作成直後は「今アクティブなウインドウ」としてメニューバー側の
        // `.focusedSceneValue`/`@FocusedValue`にすぐには認識されず、Viewerメニューの項目が
        // 一時的にすべてグレーアウトしてしまう不具合があったため、この方式に変更した。
        WindowGroup(id: "book", for: URL.self) { urlBinding in
            ContentView(initialURL: urlBinding.wrappedValue)
                .environmentObject(preferences)
                .environmentObject(keyBindingStore)
                .environmentObject(recentFiles)
                .environmentObject(folderAccess)
                .environmentObject(favoritesStore)
                .environmentObject(launchCoordinator)
        }
        .windowResizability(.contentSize)
        .modelContainer(QooViewerApp.modelContainer)
        .environment(\.locale, currentLocale)

        Settings {
            SettingsView()
                .environmentObject(preferences)
                .environmentObject(keyBindingStore)
                .environmentObject(folderAccess)
                .environment(\.locale, currentLocale)
        }

        // 「お気に入りの編集」ウインドウ(要望3。以前は「お気に入りの整理」という表現だったが、
        // 「ブックマークの編集」と表現をそろえるため「編集」に変更した)。Settingsと同様、
        // 本を開いているウインドウとは独立した単独のウインドウとして、
        // openWindow(id: "favoritesOrganizer")で開く。
        Window("Edit Favorites", id: "favoritesOrganizer") {
            FavoritesOrganizerView(favoritesStore: favoritesStore)
                .environment(\.locale, currentLocale)
        }
        .windowResizability(.contentSize)
    }

    /// 「新しいウインドウで開く」「新しいタブで開く」。ファイル/フォルダ選択パネルを表示し、
    /// 選択したURLを新しく作成したウインドウ(またはタブ)で開く。
    ///
    /// ウインドウ自体は`openWindow(id: "book", value: url)`でSwiftUIに作らせる
    /// (上の"book" WindowGroup参照)。以前は直接AppKitでNSWindow/NSHostingViewを
    /// 組み立てていたが、その方法だとSwiftUIのScene管理の外側になってしまい、
    /// 作成直後にメニューバーのViewerメニューがすべてグレーアウトする不具合があったため、
    /// この方式に変更した。ウインドウのサイズを元のウインドウに合わせる処理・タブとして
    /// 追加する処理は、SwiftUIが実際にNSWindowを作り終えるのを少し待ってから、
    /// NSApp.windowsの差分で新しいウインドウを見つけて後処理する形で行う。
    private func openPickedURLInNewWindow(asTab: Bool) {
        let locale = currentLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open", locale: locale)
        panel.message = String(
            localized: "Choose a manga folder, or a zip/cbz, rar/cbr, 7z/cb7, PDF, or EPUB file.",
            locale: locale
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openURLInNewWindow(url, asTab: asTab, tabTarget: nil)
    }

    /// 「お気に入り」メニューの一覧から「新しいウインドウで開く」「新しいタブで開く」を
    /// 選んだときに呼ぶ。開く前にセキュリティスコープ付きブックマークを解決し、実際に
    /// ファイル/フォルダが存在するかを確認する(要望5)。見つからなければ、通常の「開く」
    /// (AppState.openFavorite)と同じくmissingFavoriteをセットしてアラートを出す。
    private func openFavorite(_ favorite: FavoriteBook, asTab: Bool) {
        guard let url = favoritesStore.resolvedExistingURL(for: favorite) else {
            focusedAppState?.missingFavorite = favorite
            return
        }
        openURLInNewWindow(url, asTab: asTab, tabTarget: nil)
    }

    /// メニューバーの「お気に入り一覧」からお気に入りをクリックしたときの実際の分岐処理。
    /// 以前はお気に入りごとに「開く/新しいウインドウで開く/新しいタブで開く」をサブメニューから
    /// 毎回選ぶ形式だったが、Finderから開いたときの挙動(AppDelegate.application(_:open:)の
    /// finderOpenBehavior判定)と同じ考え方で、環境設定「お気に入りを開くとき」
    /// (preferences.favoriteOpenBehavior)1箇所で挙動を決めるように変更した。
    /// まだ本を表示していない(Welcome画面)場合は、Finderから開いたときと同様、設定に関わらず
    /// 常にそのウインドウでそのまま開く(閉じるべき「現在の本」がそもそも無いため)。
    private func openFavoriteAccordingToPreference(_ favorite: FavoriteBook) {
        guard let focusedAppState, focusedAppState.currentBook != nil else {
            focusedAppState?.openFavorite(favorite)
            return
        }
        switch preferences.favoriteOpenBehavior {
        case .replaceCurrentBook:
            focusedAppState.openFavorite(favorite)
        case .newTab:
            openFavorite(favorite, asTab: true)
        case .newWindow:
            openFavorite(favorite, asTab: false)
        }
    }

    /// 指定したURLを、新しいウインドウ(またはタブ)で開く実際の処理。上のメニュー
    /// (openPickedURLInNewWindow、ファイル選択パネルで選んだURL)だけでなく、Finderから
    /// (ダブルクリックや「このアプリケーションで開く」で)別の本を開こうとしたときの環境設定
    /// 「Finderから開いたとき」が「新しいタブ/ウインドウで開く」の場合にも使う
    /// (AppDelegate.openInNewWindowOrTab経由。AppDelegate自身はSwiftUIのopenWindow環境値を
    /// 持てないため、その処理自体はこちらに委譲している)。
    ///
    /// - Parameter tabTarget: タブとして追加する先を明示的に指定したい場合に渡す
    ///   (Finderからの「開く」で、本を開いているAppStateのウインドウへ確実に追加するために使う。
    ///   詳細はAppState.hostWindowのコメント参照)。nilの場合は、これまで通り呼び出し時点の
    ///   NSApp.keyWindowを使う(メニューからの「新しいタブで開く」は、操作時に必ずこのアプリが
    ///   最前面にあるため、この既定の挙動で問題ない)。
    ///
    /// なお、指定したURLの本がすでに他のウインドウ/タブで開かれている場合は、新しく
    /// ウインドウ/タブを作らず、既存のものをアクティブにするだけにする
    /// (LaunchCoordinator.registerOpenAppState/openAppState(forBookAt:)参照)。
    private func openURLInNewWindow(_ url: URL, asTab: Bool, tabTarget: NSWindow?) {
        // すでにこの本を(このウインドウ以外の別のウインドウ/タブで)開いている場合は、
        // 同じ本をもう1つ開いてしまわないよう、新しいウインドウ/タブを作る代わりに
        // そのウインドウ/タブをアクティブにするだけにする(タブの場合、makeKeyAndOrderFrontで
        // そのタブ自体も自動的に最前面に選択される)。
        if let existingAppState = launchCoordinator.openAppState(forBookAt: url),
           let existingWindow = existingAppState.hostWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        _ = url.startAccessingSecurityScopedResource()

        let previousKeyWindow = tabTarget ?? NSApp.keyWindow
        let existingWindowIDs = Set(NSApp.windows.map(ObjectIdentifier.init))

        openWindow(id: "book", value: url)

        Task { @MainActor in
            // openWindowが実際にNSWindowを作り終えるのは次以降のrunloopになるため、
            // 短い間隔で何度か確認し、新しく増えたウインドウを見つける。
            var newWindow: NSWindow?
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                if let found = NSApp.windows.first(where: { !existingWindowIDs.contains(ObjectIdentifier($0)) }) {
                    newWindow = found
                    break
                }
            }
            guard let newWindow else { return }

            // 新しいウインドウのサイズは、元になったウインドウ(今アクティブだったウインドウ、
            // またはtabTargetで明示的に指定されたウインドウ)と同じ大きさにする。元のウインドウが
            // 見つからない場合(環境設定ウインドウがアクティブだった場合など)はSwiftUIの
            // 既定サイズのままにする。
            // 「新しいタブで開く」の場合は、この後addTabbedWindowで元のウインドウのタブ
            // グループに加わり、位置は自動的にそのウインドウに揃うため、位置の調整は不要。
            // 「新しいウインドウで開く」の場合は、元のウインドウとほぼ重なる位置に開かれてしまい
            // 2枚あることが分かりにくいという指摘を受け、右下方向へ明確にずらして配置する
            // (Macの標準的な「カスケード」表示を、より分かりやすい間隔で自前に行っている)。
            // ずらした結果、画面の表示可能領域からはみ出してしまう場合は、はみ出さない範囲に
            // 収まるよう位置を調整し直す。これにより、元のウインドウがすでに画面いっぱいに
            // 広がっている場合は(はみ出す分だけ押し戻された結果)実質的にずれない、
            // 上下どちらかだけいっぱいの場合はその方向だけずれない、という見た目に自然と
            // なる(個別に「いっぱいかどうか」を判定するよりも、この方法の方が中途半端な
            // サイズのウインドウにも正しく対応できる)。
            if let previousKeyWindow {
                var frame = newWindow.frame
                frame.size = previousKeyWindow.frame.size
                if asTab {
                    frame.origin = previousKeyWindow.frame.origin
                } else {
                    let cascadeOffset: CGFloat = 48
                    var origin = CGPoint(
                        x: previousKeyWindow.frame.origin.x + cascadeOffset,
                        y: previousKeyWindow.frame.origin.y - cascadeOffset
                    )
                    if let visibleFrame = (previousKeyWindow.screen ?? NSScreen.main)?.visibleFrame {
                        if origin.x + frame.size.width > visibleFrame.maxX {
                            origin.x = visibleFrame.maxX - frame.size.width
                        }
                        if origin.x < visibleFrame.minX {
                            origin.x = visibleFrame.minX
                        }
                        if origin.y + frame.size.height > visibleFrame.maxY {
                            origin.y = visibleFrame.maxY - frame.size.height
                        }
                        if origin.y < visibleFrame.minY {
                            origin.y = visibleFrame.minY
                        }
                    }
                    frame.origin = origin
                }
                newWindow.setFrame(frame, display: true)
            }

            if asTab, let previousKeyWindow {
                previousKeyWindow.addTabbedWindow(newWindow, ordered: .above)
            }
            newWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Finderで「このアプリケーションで開く」を選んだときや、対応拡張子のファイルを
/// ダブルクリックしたときに呼ばれる。起動時に最初に作られたウインドウのAppState
/// (launchCoordinator.primaryAppState)に橋渡しするだけの薄いクラス。
/// また、すべてのウインドウが閉じられたときにアプリを終了するかどうかもここで判定する。
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var preferences: AppPreferences?
    weak var launchCoordinator: LaunchCoordinator?
    /// Finderから(ダブルクリックや「このアプリケーションで開く」で)別の本を開こうとしたときの
    /// 環境設定「Finderから開いたとき」が「新しいタブ/ウインドウで開く」の場合に使う、実際に
    /// ウインドウ/タブを開くためのクロージャ(QooViewerApp.openURLInNewWindow(_:asTab:tabTarget:)
    /// への橋渡し。AppDelegate自身はSwiftUIのopenWindow環境値を持てないため)。
    /// 第2引数はasTab(trueなら新しいタブ、falseなら新しいウインドウ)、第3引数は
    /// タブとして追加する先を明示的に指定する場合のウインドウ(通常はprimaryAppState.hostWindow。
    /// nilならNSApp.keyWindowが使われる)。
    var openInNewWindowOrTab: ((URL, Bool, NSWindow?) -> Void)?

    /// ツールバー・プログレスバーなど、`.help()`で付けたツールチップが表示されるまでの
    /// 待ち時間を短くする。SwiftUI/AppKitにはこの待ち時間を直接指定する公開APIがないため、
    /// AppKitのツールチップ機構が参照する非公開のUserDefaultsキー(NSInitialToolTipDelay。
    /// 単位はミリ秒。既定はおよそ1000〜1500ms)にごく短い値を登録することで実現する。
    /// ウインドウが作られる前(起動のごく初期)に登録しておく必要があるため、
    /// applicationDidFinishLaunchingよりも早いタイミングのapplicationWillFinishLaunchingで行う。
    /// registerはあくまで「まだ値がない場合の既定値」を与えるだけなので、他の設定と衝突しない。
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])
    }

    /// macOSの「ウインドウのサイズ・位置などの状態を保存して次回起動時に復元する」機能
    /// (secure state restoration)に対応していることを表明する。trueを返すことで、通常どおり
    /// 前回終了時のウインドウサイズ・位置が次回起動時に復元されるようにする。
    /// (Finderから別の本を開いたときに余分な空ウインドウが増える不具合の調査中、一時的に
    /// これをfalseにして「状態復元の仕組みそのものが原因では」と検証したことがあったが、
    /// 実際の原因は別(ContentView.onAppear/WindowAccessorの実行順序の問題)だったと判明した。
    /// falseのままにしていると状態復元の仕組みごと無効になり、ウインドウのサイズ・位置の
    /// 記憶も一緒に失われてしまう副作用があったため、trueに戻した)
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Finderから(すでに起動済みの)qooViewerに別のファイルを渡して開こうとしたとき、
    /// このアプリ自身はapplication(_:open:)で明示的にウインドウ/タブを開いているにも
    /// 関わらず、AppKit/SwiftUIのWindowGroupが標準の「ウインドウが1つも無いなら新しい
    /// (空の)ウインドウを自動的に開く」という既定動作もあわせて行ってしまい、意図しない
    /// ウェルカム画面のウインドウがもう1つ余分に開いてしまう不具合があった。
    /// falseを返すことでこの既定動作を無効にし、ウインドウ管理は常にこのアプリ自身の
    /// コード(application(_:open:)・ContentView.performLaunchActionsIfNeededなど)だけで
    /// 行うようにする。
    /// (Dockアイコンをクリックしてウインドウが1つも無い状態から復帰する場合は、こちらとは
    /// 別のapplicationShouldHandleReopen(_:hasVisibleWindows:)が担当するため、既定のまま
    /// 変更していない。そちらまでfalseにすると、ウインドウをすべて閉じたあとDockアイコンを
    /// クリックしても何も起きなくなってしまうため)
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Finderからファイルを渡してqooViewerを前面に呼び出す(再アクティブ化する)ときにも、
    /// AppKitは上のapplicationShouldOpenUntitledFileとは別の経路でウインドウの自動作成を
    /// 行うことがある(このアプリの既存ウインドウがすでに存在していても、再アクティブ化の
    /// タイミングによっては「表示中のウインドウが無い」と判定され、標準のWindowGroupが
    /// 新しい空ウインドウ=ウェルカム画面をもう1つ開いてしまうことがあった)。
    /// ここで既存ウインドウの有無を自前で確認し、1つでもあれば既定の自動オープンを
    /// 行わないようにする(既存ウインドウはこの後のapplication(_:open:)、または通常の
    /// 再アクティブ化そのものによって前面に来るので、それで十分)。
    /// ウインドウが本当に1つも無い場合(すべて閉じたあとDockアイコンをクリックした場合など)は
    /// 既定の動作(true)のままにし、新しいウインドウが開かれるようにする。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.windows.isEmpty
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard let primaryAppState = launchCoordinator?.primaryAppState else { return }

        // まだ本を表示していない(Welcome画面)場合は、環境設定に関わらず常にそのウインドウで
        // そのまま開く。既に本を表示している場合だけ、環境設定「Finderから開いたとき」に従う。
        guard primaryAppState.currentBook != nil else {
            primaryAppState.open(url: url)
            return
        }
        switch preferences?.finderOpenBehavior ?? .replaceCurrentBook {
        case .replaceCurrentBook:
            primaryAppState.open(url: url)
        case .newTab:
            // タブの追加先は、その時点でのNSApp.keyWindow(Finderから開いた直後は、まだ
            // 本来のウインドウがキーウインドウになっていないことがあり、不確実)ではなく、
            // 「本を開いていると確認したAppStateそのもの」が持つウインドウを明示的に渡す。
            openInNewWindowOrTab?(url, true, primaryAppState.hostWindow)
        case .newWindow:
            openInNewWindowOrTab?(url, false, primaryAppState.hostWindow)
        }
    }

    /// 環境設定の「すべてのウインドウを閉じたときにqooViewerを終了する」がONのときだけ、
    /// 最後のウインドウ(実寸表示や環境設定ウインドウも含む)が閉じられたタイミングで終了する。
    /// OFFのとき(既定)は、macOSの標準的な挙動どおりウインドウを閉じてもDockに常駐したままになる。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        preferences?.quitWhenLastWindowClosed ?? false
    }
}

/// Fileメニューの標準「閉じる」(Cmd+W)、およびウインドウ左上の赤い閉じるボタンの、
/// どちらでもウインドウ自体を閉じるようにするためのウインドウデリゲート。
/// 以前はCmd+W/「閉じる」実行時に本だけを閉じてWelcome画面に戻す(ウインドウ自体は閉じない)
/// 動作にしていたが、「Cmd+Wはウインドウを閉じるようにしてほしい」という要望を受けて、
/// 本が開いている場合はcloseBook()で読書状態を保存だけしてから、実際にウインドウを閉じる
/// (=trueを返す)ように変更した。
///
/// ウインドウ左上の赤い閉じるボタンは、標準では既定でperformClose:を呼び、これも
/// windowShouldCloseを経由するため、今はCmd+Wと同じ経路で問題なくウインドウを閉じられるが、
/// 以前「赤いボタンは常にウインドウを閉じる」という個別の要望に対応するために用意した
/// forceCloseWindow(_:)への差し替え(ViewerView.swiftのsetUpWindowObservers参照)は
/// そのまま残してある(windowShouldCloseを経由しない、より直接的な経路。動作に矛盾はない)。
///
/// SwiftUI/AppKitはWindowGroupが管理するウインドウに対して、タブ管理や状態復元などのために
/// 既に何らかのデリゲートを設定していることがある。それを丸ごと上書きしてしまうと、
/// それらの機能が壊れる可能性があるため、windowShouldClose以外のすべてのメソッド呼び出しは
/// (responds(to:)/forwardingTarget(for:)を使い)元のデリゲートへそのまま転送する。
@MainActor
final class BookClosingWindowDelegate: NSObject, NSWindowDelegate {
    weak var appState: AppState?
    weak var originalDelegate: NSWindowDelegate?
    /// 赤い閉じるボタンのforceCloseWindow(_:)から、直接閉じる対象のウインドウ。
    weak var window: NSWindow?
    /// 複数タブ確認ダイアログのON/OFF設定・表示言語を参照するため。
    weak var preferences: AppPreferences?

    /// Cmd+W(File>閉じる)・タブバー自身の×ボタンのどちらでも、この経路(performClose経由)
    /// を通る。AppKitからはどちらがきっかけかを区別できないため、ここでは複数タブの確認は
    /// 行わない(confirmCloseIfMultipleTabsのドキュメントコメント参照。確認したい場合は
    /// 赤い閉じるボタンか「ウインドウを閉じる」メニューを使う)。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 本が開いている場合は、ウインドウを閉じる前に読書状態(最後に表示していたページなど)
        // を保存しておく(closeBook()の副作用)。ウインドウ自体は常に閉じる(true)。
        if let appState, appState.currentBook != nil {
            appState.closeBook()
        }
        return originalDelegate?.windowShouldClose?(sender) ?? true
    }

    /// 赤い閉じるボタン、および「ウインドウを閉じる」メニュー項目(QooViewerApp.swiftの
    /// CommandGroup(before: .windowArrangement)参照)専用のアクション。windowShouldCloseを
    /// 経由せず、常にウインドウ自体を直接閉じる(複数タブの確認はここで行う)。
    ///
    /// 確認ダイアログの文言(「複数のタブが開いていますが、本当に閉じてもよろしいですか？」)は
    /// ウインドウ全体を閉じることを前提にしているため、window自身だけでなく、同じタブグループに
    /// 属する他のタブもすべて閉じる。window.tabGroup?.windows を先に配列として取り出してから
    /// 1つずつ閉じているのは、closeするたびにtabGroup.windowsの中身がその場で変化するため、
    /// 反復中に元の配列を直接ループするとタブを閉じ漏らす(あるいは配列が変化して不定な動作になる)
    /// おそれがあるのを避けるため。
    @objc func forceCloseWindow(_ sender: Any?) {
        guard let window else { return }
        guard confirmCloseIfMultipleTabs(for: window) else { return }
        let windowsToClose = window.tabGroup?.windows ?? [window]
        for windowToClose in windowsToClose {
            windowToClose.close()
        }
    }

    /// window(赤い閉じるボタンまたは「ウインドウを閉じる」メニューで閉じようとしているウインドウ)
    /// が複数のタブを開いているときは、環境設定の「複数のタブが開いているウインドウを閉じるときに
    /// 確認する」がONの場合に限り、本当に閉じてよいか確認するダイアログを表示する。設定がOFF、
    /// またはタブが1つ以下のときは確認なしでtrue(閉じてよい)を返す。
    ///
    /// Cmd+Wとタブバー自身の×ボタンは、AppKit上まったく同じ経路(NSWindow.performClose(_:)→
    /// windowShouldClose)で処理されるため、プログラム的に区別する確実な方法がない。そのため
    /// 確認ダイアログは、自分たちで直接呼び出しているforceCloseWindow(_:)の経路(赤い閉じる
    /// ボタン・「ウインドウを閉じる」メニュー)だけに絞っている。Cmd+Wやタブの×で複数タブの
    /// ウインドウを閉じても、この確認は出ない(意図的な仕様)。
    private func confirmCloseIfMultipleTabs(for window: NSWindow) -> Bool {
        guard preferences?.confirmBeforeClosingMultipleTabsWindow ?? true else { return true }
        let tabCount = window.tabGroup?.windows.count ?? 1
        guard tabCount > 1 else { return true }

        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Multiple Tabs Are Open", locale: locale)
        alert.informativeText = String(
            localized: "This window has multiple tabs open. Are you sure you want to close it?",
            locale: locale
        )
        alert.addButton(withTitle: String(localized: "Close Window", locale: locale))
        alert.addButton(withTitle: String(localized: "Cancel", locale: locale))
        return alert.runModal() == .alertFirstButtonReturn
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) {
            return nil
        }
        return originalDelegate
    }
}
