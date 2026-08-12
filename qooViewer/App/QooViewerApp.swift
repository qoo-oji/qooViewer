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
    /// ブックマーク(すべての本を横断)。favoritesStoreと同じ理由でModelContextを明示的に
    /// 渡す必要があるため、下のinit()で組み立てる。
    @StateObject private var bookmarkStore: BookmarkStore
    /// ページレイアウト設定(すべての本を横断)。bookmarkStoreと同じ理由でModelContextを
    /// 明示的に渡す必要があるため、下のinit()で組み立てる。
    @StateObject private var layoutStore: LayoutStore
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

    /// お気に入り・ブックマーク・読書履歴(BookReadingState)・ページレイアウト設定のスキーマ。
    /// BookLayoutSettings/PageLayoutOverrideは、フォルダ・zip/cbz・rar/cbr・7z/cb7・PDFに対して
    /// EPUBのpackage document相当のレイアウト情報をqooViewer自身が保持するための新規モデル
    /// (設計コンセプト2章参照)。追加のみのライトウェイトマイグレーションのため、
    /// 既存ユーザーのストアにも問題なく追加される。
    private static let modelSchema = Schema([
        BookReadingState.self, Bookmark.self, FavoriteFolder.self, FavoriteBook.self,
        BookLayoutSettings.self, PageLayoutOverride.self
    ])

    /// スキーマの移行に失敗した場合に、ストアファイルを削除して作り直せるよう、URLを
    /// 参照できる明示的なModelConfigurationを介して構築する(`ModelContainer(for:)`の
    /// 簡易版だと、失敗時に削除すべきファイルのURLを得る手段が無い)。
    /// ResetDataSettingsView(環境設定「リセット」タブ)からもストアの実ファイルを直接削除できる
    /// よう、privateではなく通常のアクセスレベルにしてある(詳細はdeleteStoreFilesのコメント参照)。
    static let modelConfiguration = ModelConfiguration(schema: modelSchema)

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
    ///
    /// 過去に一度、FavoriteBook/FavoriteFolderへ非Optionalな属性(updatedAt)を追加した際、
    /// 既存ユーザーの端末で「Validation error missing attribute values on mandatory destination
    /// attribute」という移行エラーが発生し、fatalErrorで即座にアプリが起動できなくなったことが
    /// あった(そのときはinit時の`= Date()`というデフォルト値追加で解決したが、根本的には
    /// 「移行に失敗したら二度と起動できない」という設計上の弱点が残っていた)。
    ///
    /// 今後同様に移行エラーが起きた場合に備え、ここで一度だけ失敗をキャッチし、ユーザーに
    /// 確認した上でストアファイルを削除・再作成することで、アプリが起動できなくなる事態を防ぐ。
    /// この時点ではSwiftUIのウインドウはまだ何も表示されていないため、通常のSwiftUIの
    /// `.alert`ではなく、AppKitのNSAlertを同期的(モーダル)に表示する。
    /// (環境設定の「リセット」タブ(ResetDataSettingsView)は、この状況を待たずにユーザーが
    /// 自分の意思で同じことを手動で行うための機能で、こちらは正常に起動できている場合のみ
    /// 使える。両方を用意することで、「起動できる場合」「起動できない場合」のどちらでも
    /// リセットできるようにしている)
    private static let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: modelSchema, configurations: [modelConfiguration])
        } catch {
            NSLog("qooViewer: ModelContainer creation failed, will ask the user whether to reset the store: \(error)")

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "qooViewer Can't Open Your Saved Data")
            alert.informativeText = String(
                localized: """
                Your favorites, bookmarks, and reading history couldn't be loaded, possibly because they're incompatible with this version of qooViewer.

                If you continue, all of this data will be permanently deleted and qooViewer will start fresh. If you don't want to lose this data, quit now without deleting it (for example, to try an older version of qooViewer, or to ask for help).
                """
            )
            alert.addButton(withTitle: String(localized: "Delete and Continue"))
            alert.addButton(withTitle: String(localized: "Quit Without Deleting"))
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                // この時点ではSwiftUIのRunLoop/NSApplicationのイベントループがまだ本格的に
                // 始まっていないため、NSApplication.terminate(_:)に頼らずexit(0)で確実に
                // その場でプロセスを終了させる。
                exit(0)
            }

            deleteStoreFiles(at: modelConfiguration.url)
            do {
                return try ModelContainer(for: modelSchema, configurations: [modelConfiguration])
            } catch {
                let failureAlert = NSAlert()
                failureAlert.alertStyle = .critical
                failureAlert.messageText = String(localized: "qooViewer Could Not Start")
                failureAlert.informativeText = String(
                    localized: "qooViewer couldn't start even after resetting its saved data. Please contact support."
                )
                failureAlert.runModal()
                fatalError("Failed to create ModelContainer even after resetting the store: \(error)")
            }
        }
    }()

    /// SwiftDataのストア本体、および付随するWAL/SHMファイル(SQLiteの補助ファイル)を削除する。
    /// これらが残っていると、ストア本体だけ削除してもデータの一部が復元されてしまうことがある。
    ///
    /// ResetDataSettingsView(環境設定「リセット」タブ)からも同じ実装を使い回すため、privateでは
    /// なくしてある。以前はそちらのリセットボタンはModelContext経由で各モデルの行を個別に
    /// delete()するだけだったが、それだとストア自体のスキーマ・リレーションが壊れている場合
    /// (実際に、Bundle Identifierが同じ古いビルドが同じストアファイルを開いてしまい、
    /// リレーションが壊れたと見られる事例が報告された)、削除操作自体が正しいデータを対象に
    /// できているとは限らない。ここでのファイル自体の削除であれば、ストアの内容がどれだけ
    /// 壊れていても関係なく、次回起動時に完全にまっさらな状態のストアを新規作成させられる。
    static func deleteStoreFiles(at url: URL) {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let candidate = directory.appendingPathComponent(baseName + suffix)
            try? fileManager.removeItem(at: candidate)
        }
    }

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
    ///
    /// FavoritesStore/BookmarkStore/LayoutStoreには、いずれも`QooViewerApp.modelContainer.mainContext`
    /// (メインスレッド用の既定ModelContext。`.modelContainer(modelContainer)`経由でContentView/
    /// ResetDataSettingsView/ViewerViewModel側の`@Environment(\.modelContext)`にも同じインスタンスが
    /// 注入される)をそのまま渡し、アプリ全体で単一のModelContextに統一している。
    ///
    /// 以前はFavoritesStore/BookmarkStore/LayoutStoreそれぞれに`ModelContext(modelContainer)`で
    /// 専用の(互いに素の)ModelContextを個別に作っていた。この構成では、例えば「編集ウインドウ
    /// (BookmarkStore)で削除したBookmarkを、ビューア側(ViewerViewModel。環境経由のmainContext)の
    /// 一覧が持つ古い参照へ渡してもSwiftData的には削除できない(別コンテキストのオブジェクトの
    /// ため)」といった、コンテキストが分裂していること自体に起因する取り扱い分けが複数の箇所
    /// (ViewerView.toggleCurrentPageBookmark等)で必要になっていた。単一のmainContextに統一する
    /// ことで、同じ行を指すBookmark/FavoriteBook/BookLayoutSettings等はどこから取得しても同一の
    /// オブジェクトになり、この種の「別コンテキストのオブジェクトを渡すと静かに何も起きない」
    /// クラスの問題が構造的に起きなくなる。またAppState.open(url:)が本を開くたびに呼ぶ
    /// favoritesStore/layoutStore/bookmarkStoreそれぞれのreconcileBookIDIfMoved(book:)も、
    /// 同じmainContextに対する変更として扱われるようになる。
    ///
    /// なお、一時期(このコメントの旧バージョン当時)「あるページのレイアウトをinsert()して
    /// save()した直後、他の経路から読み直すと消えて見える」という不具合(ユーザー報告)の原因では
    /// ないかと疑い、一度すべてのStoreをcontainerが持つ単一の共有mainContextへ統一したことが
    /// あったが、その時点では実際には無関係と判断して専用ModelContextに分ける構成へ戻した
    /// 経緯がある(真の原因はPageLayoutOverride.compositeKey/BookLayoutSettings.bookIDに
    /// 付けていた@Attribute(.unique)側にあった。詳細はPageLayoutOverride.swift/
    /// BookLayoutSettings.swiftのコメント参照)。今回はその調査の副産物としてではなく、上記の
    /// 「コンテキスト分裂に起因する取り扱い分けの解消」を目的として改めて単一ModelContextへ
    /// 統一している。真因だった@Attribute(.unique)は既に両モデルから外してあり、ModelContextを
    /// 統一したこと自体がその不具合クラスを再発させるわけではないが、将来的に一意制約
    /// (@Attribute(.unique))を再導入する場合は、同一ModelContextに短時間で連続してinsert()+save()
    /// するパターンを避けるよう注意すること(PageLayoutOverride.swiftのコメント参照。単一
    /// ModelContextへ統一した今の構成では、複数ストアの書き込みが同じコンテキストに集約される分、
    /// この条件に該当しうる操作の密度はむしろ従来より上がる)。
    @MainActor
    init() {
        _favoritesStore = StateObject(
            wrappedValue: FavoritesStore(modelContext: QooViewerApp.modelContainer.mainContext)
        )
        _bookmarkStore = StateObject(
            wrappedValue: BookmarkStore(modelContext: QooViewerApp.modelContainer.mainContext)
        )
        _layoutStore = StateObject(
            wrappedValue: LayoutStore(modelContext: QooViewerApp.modelContainer.mainContext)
        )
    }

    var body: some Scene {
        // 表示言語のLocaleは全Sceneで共通の値なので、bodyの評価ごとに1回だけ解決して使い回す
        // (以前は各Sceneの`.environment(\.locale, currentLocale)`が9箇所に分散しており、bodyが
        // 再評価されるたびにcurrentLocaleの解決が9回走っていた。値は常に同一なので結果は不変)。
        let locale = currentLocale
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(preferences)
                .environmentObject(keyBindingStore)
                .environmentObject(recentFiles)
                .environmentObject(folderAccess)
                .environmentObject(favoritesStore)
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
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
        // バグ修正(ユーザー報告): ウインドウをすべて閉じた状態から外部アプリ等で再アクティブ化
        // すると、macOSの標準ウインドウ状態復元の仕組みが「前回のmainウインドウを復元する」
        // つもりで空のウインドウを自動生成することがあり、これが閉じたはずの古いNSWindow
        // オブジェクトを再利用してしまい、中身(SwiftUIのコンテンツ)が正しく描画されない
        // (何も表示されない壊れたウインドウになる)不具合が実機で確認された。また、この状態復元の
        // 仕組みのせいで、ウインドウを閉じてもその中身(@StateObjectのappState)がすぐには
        // 解放されないという副作用もあった(LaunchCoordinator.primaryAppStateのコメント参照)。
        // "main"ウインドウグループの状態復元を無効化することで、どちらも解消される
        // (本を開いていた場合の「前回の本を自動的に開く」機能は、この仕組みには頼っておらず
        // 独自のLastActiveBookStore/launchOpensLastBook設定で行っているため、影響を受けない。
        // ウインドウの位置・サイズの記憶も、ContentView側の自前のUserDefaultsベースの仕組み
        // 〈restoreMainWindowFrameIfNeeded〉によるもので、こちらも影響を受けない)。
        .restorationBehavior(.disabled)
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
                            // タイトルは拡張子を除いた名前のため、同名のcbz/epubなど拡張子違いの
                            // 同じ本が同じフォルダに並ぶと見分けがつかない(ユーザー報告)。
                            // Favoritesメニュー(FavoritesMenuContent/FavoritesNSMenuBridge)と
                            // 同様に、拡張子バッジのプレーンテキスト版を末尾に付けて区別できるようにする。
                            Button(
                                FormatBadgeView.plainTextTitle(
                                    baseName: url.deletingPathExtension().lastPathComponent, bookID: url.path
                                )
                            ) {
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

                // ユーザー要望: 現在の本(ファイルまたはフォルダ)をFinderで開く。
                // 「同じフォルダのファイルを開く」と同じ「今の本の場所」に関するグループの
                // 一員として、間に区切り線を挟まずすぐ下に置く。
                Button("Show in Finder") {
                    focusedAppState?.revealCurrentBookInFinder()
                }
                .disabled(focusedAppState?.currentBook == nil)

                Divider()

                // グループ4: 開いた履歴から選んで開く
                Menu("Open Recent") {
                    if recentFiles.entries.isEmpty {
                        Text("(None)")
                    } else {
                        ForEach(recentFiles.entries) { entry in
                            // entry.displayNameは拡張子を除いた名前(RecentFilesStore.Entry参照)。
                            // 同名のcbz/epubなど拡張子違いの同じ本を開いた履歴が並ぶと見分けが
                            // つかない(ユーザー報告)ため、上の「同じフォルダのファイルを開く」と
                            // 同様に拡張子バッジのプレーンテキスト版を末尾に付ける。
                            Button(
                                FormatBadgeView.plainTextTitle(baseName: entry.displayName, bookID: entry.url.path)
                            ) {
                                _ = entry.url.startAccessingSecurityScopedResource()
                                focusedAppState?.open(url: entry.url)
                            }
                        }
                    }
                }
            }

            // 6.2節: 「インポート・エクスポート」グループ。Fileメニューの標準「閉じる」
            // (Cmd+W)の直前(=上のグループ2〜4を含むnewItemグループの直後)に置く。
            // 「ブックマーク・レイアウトの編集」ウインドウ(editBookmarks)と同じく、本を今開いて
            // いなくても・複数開いていても常に1つの独立ウインドウとして開く(openWindow(id:)は
            // 既に開いていれば前面に出すだけで、新しく作り直しはしない)。
            CommandGroup(after: .newItem) {
                Divider()
                Button("Import…") {
                    openWindow(id: "libraryImport")
                }
                Button("Export…") {
                    openWindow(id: "libraryExport")
                }

                Divider()
                // 画像のエクスポート機能(要望)。データベースのインポート・エクスポートの
                // グループと、EPUBのエクスポートのグループの間に配置する。本を開いていないと
                // 実行しようがないため無効化する(EPUB出力・DBインポート/エクスポートと異なり
                // hasBook不問にはしない)。見開き表示中で、かつ実際に2ページとも表示されている
                // (hasPartnerPageDisplayed)ときだけ左右2件+結合の3件を、それ以外(単一ページ表示、
                // または見開き表示中でも横長画像の自動単ページ化等で実際には1枚しか表示されて
                // いない場合)は「このページをエクスポート」の1件のみを出す(ViewerView.
                // contextMenuContentのExport Imageサブメニューと同じ判定基準)。
                Menu("Export Image") {
                    if menuCheckmarkState?.isSpreadMode == true, menuCheckmarkState?.hasPartnerPageDisplayed == true {
                        Button("Export Right Page…") {
                            focusedAppState?.performImageExport?(.rightPage)
                        }
                        Button("Export Left Page…") {
                            focusedAppState?.performImageExport?(.leftPage)
                        }
                        Button("Combine Spread and Export…") {
                            focusedAppState?.performImageExport?(.mergedSpread)
                        }
                    } else {
                        Button("Export This Page…") {
                            focusedAppState?.performImageExport?(.currentPage)
                        }
                    }
                }
                .disabled(focusedAppState?.currentBook == nil)

                Divider()
                // 8.1節「epub出力」グループ。本を開いていなくても有効(hasBook不問、
                // 「ブックマーク・レイアウトの編集」ウインドウと同じ考え方)。
                Button("Export as EPUB…") {
                    openWindow(id: "epubExport")
                }
                // PDF出力(ユーザー要望: EPUB出力と同様、ブックマーク・タイトル・著者名を
                // 埋め込んだPDFを書き出せるようにしたい)。EPUB出力の直下に配置する。
                Button("Export as PDF…") {
                    openWindow(id: "pdfExport")
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

            // 要望: 標準の「編集」(Edit)メニューは、SwiftUIが自動的に追加する既定の内容
            // (取り消す/やり直す/カット/コピー/ペースト/削除/すべてを選択)のままだと、
            // このアプリにはテキスト編集機能自体が無いため、どの項目も実際には機能しない
            // 見せかけのメニューになっていた。CommandGroup(replacing: .undoRedo)/
            // CommandGroup(replacing: .pasteboard)をどちらも空の内容で登録することで、
            // 既定の項目をすべて取り除く。
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .pasteboard) { }

            // 「編集」(Edit)メニューの実際の内容。以前はそれぞれ「お気に入り」「レイアウト」と
            // いう独立したトップレベルメニュー(CommandMenu)だったが、上記の通り既定では
            // 何も機能しない「編集」メニューをそのまま空けておくのはもったいないという指摘から、
            // この「編集」メニューへ統合した(要望)。CommandGroup(after: .pasteboard)は、
            // 上で空にした「ペースト」グループの直後(=編集メニューの先頭)に項目を挿入する。
            // 3つのグループ(お気に入り→ブックマーク→レイアウト)の並び順、および各グループ内の
            // 並び順は、以前の「お気に入り」「レイアウト」メニューのときからユーザーの指示により
            // 変えていない。ブックマーク(本を開いている間だけ有効な、ページ位置の目印)と
            // お気に入り(本そのものを、階層フォルダで整理して保存する)は別の仕組みのため、
            // Dividerでグループを分けて並べる。追加・削除は別々の項目ではなく、現在の本/ページの
            // 登録状態に応じて文言・動作が切り替わる1つのトグル項目にまとめている
            // (ツールバー・コンテキストメニューと同じ考え方)。「編集」の文言も「ブックマークの
            // 編集…」と表現をそろえ、以前の「お気に入りを整理…」から「お気に入りの編集…」に
            // 変更した(ViewerAction.showFavoritesOrganizer、Window("Edit Favorites", ...)も
            // 同様に変更済み)。
            CommandGroup(after: .pasteboard) {
                let hasBook = focusedAppState?.currentBook != nil
                let isLayoutLocked = !hasBook || (menuCheckmarkState?.hasAuthoritativeSourceLayout ?? false)

                // グループ1: お気に入り(追加/削除→編集→一覧の順)
                Button(
                    menuCheckmarkState?.isCurrentBookFavorited == true
                        ? "Remove This Book from Favorites" : "Add This Book to Favorites…"
                ) {
                    focusedAppState?.performViewerAction?(.toggleFavorite)
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

                // グループ2: ブックマーク(追加/削除→編集→一覧の順)
                Button(
                    menuCheckmarkState?.isCurrentPageBookmarked == true
                        ? "Remove This Page from Bookmarks" : "Add This Page to Bookmarks"
                ) {
                    focusedAppState?.performViewerAction?(.toggleBookmark)
                }
                .disabled(!hasBook)

                // 「Edit Favorites…」と同じく、performViewerAction(ViewerViewが表示されている
                // 間だけ登録されるクロージャ)には頼らず、直接openWindowで開く。以前は
                // focusedAppState?.performViewerAction?(.showBookmarkList)経由だったが、
                // 「ブックマークの編集」がすべての本を横断する構成になった今、この操作は
                // 特定の本が focusedAppState として存在すること自体に依存する理由が無い。
                // それどころか、.id(book.id)によってViewerViewが本の切り替えのたびに
                // 作り直される(ContentView.swift参照)関係で、短時間に連続して本を切り替えた
                // 直後はperformViewerActionの登録が一時的に外れている可能性があり、
                // 「メニューからブックマーク編集を選んでもウインドウが開かない」不具合の
                // 原因になっていた。
                Button("Edit Bookmarks…") {
                    launchCoordinator.pendingEditorInitialFocus = .bookmarks
                    openWindow(id: "editBookmarks")
                }

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

                Divider()

                // グループ3: ページレイアウト制御(設計コンセプト8.2節)。ここではこのビュー自身の
                // @StateObjectであるViewerViewModelへ直接アクセスできないため、「移動」「上の
                // お気に入り/ブックマーク」グループと同じFocusedValueブリッジ
                // (focusedAppState.performLayoutStateChange/performLayoutClear/
                // performAutoLayout)を経由する。項目の有効/無効・件数構成はmenuCheckmarkState
                // (値型。AppState.swiftのコメント参照)の現在値で判定する。
                Button("Auto-Layout Based on Current View") {
                    focusedAppState?.performAutoLayout?()
                }
                .disabled(isLayoutLocked)

                // ユーザー要望: 「自動でレイアウトする」の下、および下の「レイアウトの編集…」の
                // 上にあった区切り線は削除した(このグループ内は1つの塊として見せる)。

                if menuCheckmarkState?.hasPartnerPageDisplayed == true {
                    // 見開き表示中に実際に2ページとも表示されている場合は、8.2節の通り
                    // 左右それぞれのページ用に5項目ずつ(計10項目)並べる。設計doc本文は
                    // フラットな10項目を想定しているが、視認性のためLeft Page/Right Pageの
                    // サブメニューにまとめている(ViewerView.contextMenuContentのLayoutサブメニューと
                    // 同じ考え方)。
                    Menu("Left Page") {
                        layoutMenuItems(
                            target: menuCheckmarkState?.isRightToLeft == true ? .partner : .current,
                            hasOverride: menuCheckmarkState?.isRightToLeft == true
                                ? (menuCheckmarkState?.hasPartnerPageLayoutOverride ?? false)
                                : (menuCheckmarkState?.hasCurrentPageLayoutOverride ?? false)
                        )
                    }
                    .disabled(isLayoutLocked)

                    Menu("Right Page") {
                        layoutMenuItems(
                            target: menuCheckmarkState?.isRightToLeft == true ? .current : .partner,
                            hasOverride: menuCheckmarkState?.isRightToLeft == true
                                ? (menuCheckmarkState?.hasCurrentPageLayoutOverride ?? false)
                                : (menuCheckmarkState?.hasPartnerPageLayoutOverride ?? false)
                        )
                    }
                    .disabled(isLayoutLocked)
                } else {
                    layoutMenuItems(target: .current, hasOverride: menuCheckmarkState?.hasCurrentPageLayoutOverride ?? false)
                        .disabled(isLayoutLocked)
                }

                // 「レイアウトの編集…」(8.2節)。4節の「ブックマーク・レイアウトの編集」
                // ウインドウを、4.5節の「レイアウトの編集」用フィルタで開く。本を開いていなくても
                // 有効(hasBook不問。上の「Edit Bookmarks…」と同じ)。
                Button("Edit Layout…") {
                    launchCoordinator.pendingEditorInitialFocus = .layout
                    openWindow(id: "editBookmarks")
                }
            }
        }
        .environment(\.locale, locale)

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
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
                .environmentObject(launchCoordinator)
        }
        .windowResizability(.contentSize)
        .modelContainer(QooViewerApp.modelContainer)
        .environment(\.locale, locale)

        Settings {
            SettingsView()
                .environmentObject(preferences)
                .environmentObject(keyBindingStore)
                .environmentObject(folderAccess)
                // 「リセット」タブ(ResetDataSettingsView)がfavoritesStore/bookmarkStoreの
                // 一括削除メソッド、および@Environment(\.modelContext)経由でBookReadingStateを
                // 直接操作する必要があるため、他のScene(WindowGroup)と同様にここでも
                // favoritesStore/bookmarkStore/modelContainerを渡す。
                .environmentObject(favoritesStore)
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
                .modelContainer(QooViewerApp.modelContainer)
                .environment(\.locale, locale)
        }

        // 「お気に入りの編集」ウインドウ(要望3。以前は「お気に入りの整理」という表現だったが、
        // 「ブックマークの編集」と表現をそろえるため「編集」に変更した)。Settingsと同様、
        // 本を開いているウインドウとは独立した単独のウインドウとして、
        // openWindow(id: "favoritesOrganizer")で開く。
        // launchCoordinatorは、ツールバーの「現在の本を追加」ボタン(FavoritesOrganizerView参照)が
        // 「今読んでいる本」(launchCoordinator.activeBookAppState)を特定するために必要。
        // preferencesは、詳細ペインでお気に入りをダブルクリックして開いたときに、環境設定
        // 「お気に入りを開くとき」(favoriteOpenBehavior)を判定するために必要
        // (FavoritesOrganizerView.openFavoriteAccordingToPreference参照)。
        Window("Edit Favorites", id: "favoritesOrganizer") {
            FavoritesOrganizerView(favoritesStore: favoritesStore)
                .environmentObject(launchCoordinator)
                .environmentObject(preferences)
                .environment(\.locale, locale)
        }
        .windowResizability(.contentSize)

        // 「ブックマーク・レイアウトの編集」ウインドウ(独立ウインドウ、設計コンセプト4節)。
        // 以前は本を表示しているウインドウのシートで、かつ「今開いている本」のブックマークだけを
        // 扱っていたが、「お気に入りの編集」ウインドウと見た目・操作感を完全に揃えるため、
        // すべての本を横断して編集できる2ペイン構成に変更した。さらに4節により、ページ
        // レイアウト制御(BookLayoutSettings/PageLayoutOverride)の編集も同じウインドウへ統合した。
        // データの実体はbookmarkStore/layoutStore(FavoritesStoreと同じくmodelContainer.mainContextを
        // 共有する単一のModelContextを持つ)が持ち、launchCoordinatorは選択中の本が今開いているかの
        // 判定・呼び出し元別の初期
        // フィルタ(4.5節)の橋渡しに使う(BookmarkListView.swift参照)。preferencesは、右ペインの
        // ページ一覧読み込み(BookLayoutEditorViewModel)が横長画像ヒューリスティックの閾値
        // (preferences.singlePageAspectRatioThreshold)を参照するために必要。
        Window("Edit Bookmarks & Layout", id: "editBookmarks") {
            BookmarkEditorWindow()
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
                .environmentObject(launchCoordinator)
                .environmentObject(preferences)
                .environment(\.locale, locale)
        }
        .windowResizability(.contentSize)

        // 5節: ブックマーク一括リネームウインドウ(新設)。4.4節の「一括リネーム」ボタンから、
        // launchCoordinator.pendingBulkRenameBookIDへ対象bookIDをセットしたうえで
        // openWindow(id: "bulkRenameBookmarks")を呼んで開く(単一インスタンスのWindowシーンは
        // for:による値のパラメータ化ができないため、pendingEditorInitialFocusと同じ橋渡し方式)。
        Window("Bulk Rename Bookmarks", id: "bulkRenameBookmarks") {
            BulkRenameBookmarksWindow()
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
                .environmentObject(launchCoordinator)
                .environmentObject(preferences)
                .environment(\.locale, locale)
        }
        .windowResizability(.contentSize)

        // 6節: JSONエクスポート/インポート用の独立ウインドウ。「ブックマーク・レイアウトの編集」と
        // 同じく、favoritesStore/bookmarkStore/layoutStoreはすべてmodelContainer.mainContextを
        // 共有する、アプリ全体で1つだけのインスタンスをそのまま渡す。
        Window("Export Library Data", id: "libraryExport") {
            LibraryExportWindow()
                .environmentObject(favoritesStore)
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
                .environmentObject(preferences)
                .environment(\.locale, locale)
        }
        .windowResizability(.contentSize)

        Window("Import Library Data", id: "libraryImport") {
            LibraryImportWindow()
                .environmentObject(favoritesStore)
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
                .environmentObject(preferences)
                .environment(\.locale, locale)
        }
        .windowResizability(.contentSize)

        // 7節: EPUB出力専用ウインドウ。favoritesStoreは不要(お気に入りはEPUB出力の対象外)。
        Window("Export as EPUB", id: "epubExport") {
            EpubExportWindow()
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
                .environmentObject(preferences)
                .environment(\.locale, locale)
        }
        .windowResizability(.contentSize)

        // PDF出力専用ウインドウ。EPUB出力ウインドウと同じ構成(favoritesStoreは不要)。
        Window("Export as PDF", id: "pdfExport") {
            PDFExportWindow()
                .environmentObject(bookmarkStore)
                .environmentObject(layoutStore)
                .environmentObject(preferences)
                .environment(\.locale, locale)
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

    /// 「編集」(Edit)メニュー内のレイアウトグループの、1ページ分の項目群(設計コンセプト3.2節)。
    /// ViewerView.layoutStateMenuItems(forPageIndex:)と同じ構成だが、こちらは
    /// ViewerViewModelへ直接アクセスできないため、focusedAppState経由のクロージャを呼ぶ。
    /// 「レイアウト情報を削除する」は、hasOverride(menuCheckmarkState由来の現在値)が
    /// trueの場合のみ表示する。
    @ViewBuilder
    private func layoutMenuItems(target: LayoutMenuTarget, hasOverride: Bool) -> some View {
        Button("Set as Single Page") {
            focusedAppState?.performLayoutStateChange?(target, .single)
        }
        Button("Set as Spread Right Page") {
            focusedAppState?.performLayoutStateChange?(target, .spreadRight)
        }
        Button("Set as Spread Left Page") {
            focusedAppState?.performLayoutStateChange?(target, .spreadLeft)
        }
        Button("Set as Excluded (Hidden)") {
            focusedAppState?.performLayoutStateChange?(target, .excluded)
        }
        if hasOverride {
            Divider()
            Button("Delete Layout Info") {
                focusedAppState?.performLayoutClear?(target)
            }
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
    ///
    /// 要望: 「編集」メニューの末尾にmacOS自身が自動的に挿入する「自動入力」「音声入力を
    /// 開始」「絵文字と記号」(および、それらの手前の区切り線)を消してほしい。このアプリには
    /// テキスト編集機能自体が無いため、これらは常に無関係かつ不要。
    /// 「音声入力を開始」「絵文字と記号」の2つは、AppKitが参照する非公開のUserDefaultsキー
    /// (NSDisabledDictationMenuItem/NSDisabledCharacterPaletteMenuItem)にtrueを登録する
    /// ことで抑制できる(NSInitialToolTipDelayと同じ理由で、ここ=起動の最も早いタイミングで
    /// 登録する)。
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 200,
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
    }

    /// 上のNSDisabledDictationMenuItem/NSDisabledCharacterPaletteMenuItemとは異なり、
    /// 「自動入力」(AutoFill)の抑制には対応するUserDefaultsキーが存在しない(非公開APIとしても
    /// 見つからない)。そのため、自前で「編集」メニューの末尾の余分な項目を取り除く。
    ///
    /// バグ修正(ユーザー報告): 当初はNSMenu.didBeginTrackingNotification(メニューを開こうと
    /// した瞬間に飛ぶ通知)だけで毎回取り除く実装にしていたが、実機で確認したところ
    /// 「自動入力」が消えなかった。macOSがこれを挿入するタイミングは非公開で、
    /// didBeginTrackingより後(メニューが実際に画面に描画される直前など)である可能性が高いと
    /// 考えられる。そのため、次の3段構えにした。
    /// 1. cleanUpEditMenu()を起動直後(applicationDidFinishLaunching、AppKit自身がこれらの
    ///    項目を挿入し終えているはずのタイミング)に1回、即座に呼ぶ。
    /// 2. 念のため、SwiftUIによるメニューバー構築がまだ完了していない場合に備えて、
    ///    Task { @MainActor in ... }で次のRunLoopに回してからもう1回呼ぶ。
    /// 3. さらに、メニューを開こうとするたびに毎回(NSMenu.didBeginTrackingNotification)、
    ///    同じくTask { @MainActor in ... }で「その通知の処理がすべて終わった直後」まで遅らせて
    ///    呼ぶことで、macOSが同じタイミングで後から追加してくる場合にも対応する
    ///    (継続的なセーフティネット)。
    ///
    /// 「編集」メニューかどうかは、タイトル(ローカライズにより"Edit"/"編集"と変わる)ではなく、
    /// このアプリが「編集」メニューの最後の項目として必ず配置している「レイアウトの編集…」
    /// (英語なら"Edit Layout…")の有無で判定する(QooViewerApp.swiftの
    /// CommandGroup(after: .pasteboard)参照。このアプリが対応する言語はAppLanguage.swift
    /// の通り日本語・英語の2つのみのため、この2パターンだけを見れば十分)。その項目より後ろに
    /// 残っている項目(=macOSが自動的に追加したもの)をすべて削除する。
    private static let editMenuLastOwnItemTitles: Set<String> = ["Edit Layout…", "レイアウトの編集…"]
    private var editMenuTrackingObserver: NSObjectProtocol?

    /// NSApp.mainMenuの直下から、上のeditMenuLastOwnItemTitlesのいずれかを含むサブメニュー
    /// (=「編集」メニュー)を探し出し、見つかれば末尾の余分な項目を取り除く。見つからなければ
    /// (メニューバーがまだ構築されていない等)何もしない。
    /// 明示的に@MainActorを付けている理由はQooViewerApp構造体本体のコメントと同じ
    /// (NSApp/NSMenuなどAppKitのAPIはメインアクター隔離のため、Task { @MainActor in ... }
    /// のような非同期コンテキストから呼んでもコンパイルエラーにならないようにするため)。
    @MainActor
    private func cleanUpEditMenu() {
        guard let topLevelItems = NSApp.mainMenu?.items else { return }
        for topLevelItem in topLevelItems {
            guard let menu = topLevelItem.submenu else { continue }
            guard let lastOwnIndex = menu.items.firstIndex(where: {
                AppDelegate.editMenuLastOwnItemTitles.contains($0.title)
            }) else { continue }
            while menu.items.count > lastOwnIndex + 1 {
                menu.removeItem(at: menu.items.count - 1)
            }
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        cleanUpEditMenu()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cleanUpEditMenu()
        }

        // バグ修正(ビルド時の警告): [weak self]でキャプチャしたselfをそのままネストした
        // Task { @MainActor in ... }の中で再び参照すると、「弱参照(var相当)を並行実行される
        // コードの中で参照している」という警告(Swift 6言語モードではエラーになる)が出る。
        // 外側のクロージャに入った直後にguard let selfで弱参照を1回だけ強参照(let、値が
        // 変わらないことが保証される)に変換し、その強参照だけを内側のTaskへ渡すようにする。
        editMenuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.cleanUpEditMenu()
            }
        }
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
        // バグ修正(ユーザー報告): primaryAppStateそのものの有無だけでなく、
        // その`hostWindow`が今も実際に存在するかも確認する。SwiftUIのWindowGroup(id:)の
        // 標準の状態復元は、ウインドウを閉じてもその中身(@StateObjectのappState)をすぐには
        // 解放しないことがあり、primaryAppState(weak var)が閉じられたウインドウを指したまま
        // 残ることがあった(この副作用は"main" WindowGroupで状態復元を無効化
        // 〈.restorationBehavior(.disabled)〉したことで解消済みだが、念のためhostWindowの
        // 有無でも確認しておく)。この状態で外部アプリ等からファイルが渡されると、以前は
        // ここでそのゾンビ状態のprimaryAppStateへ本を読み込んでしまい、読み込み自体は成功して
        // 履歴にも記録されるのに、それを表示するウインドウがどこにも無い(=ユーザーには
        // 何も起きなかったように見える)という不具合があった。
        if let primaryAppState = launchCoordinator?.primaryAppState, primaryAppState.hostWindow != nil {
            openInPrimaryWindow(url, primaryAppState: primaryAppState)
            return
        }

        // 再利用できる既存のmainウインドウが無い状態。「新しいウインドウ/タブで開く」と同じ経路
        // (openInNewWindowOrTab、実体はopenURLInNewWindow)で、自前で新しい「book」ウインドウを
        // 開く。
        openInNewWindowOrTab?(url, false, nil)

        // バグ修正(ユーザー報告): "main" WindowGroupの状態復元を無効化した後も、この直後に
        // AppKit/SwiftUIが既定動作として空のmainウインドウを自動生成すること自体は実機で
        // 依然として起こりうる(以前と違い中身は正しく描画されるが、こちらが開いたbookウインドウ
        // とは別に本を表示しない空ウインドウが残ってしまう)。この時点では「再利用できる
        // mainウインドウが無かった」ことが確定しているため、bookウインドウで本の表示が
        // 落ち着いた後もなお空のprimaryAppStateが残っていれば、それはこの一連の処理の中で
        // AppKitが勝手に作った余分なウインドウだと判断してよい。ただし、本の読み込みに時間が
        // かかっている場合に唯一残っているウインドウまで閉じてしまわないよう、閉じる前に他に
        // 表示中のウインドウが実在することを確認する。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            guard let suspect = self.launchCoordinator?.primaryAppState,
                  suspect.currentBook == nil,
                  let suspectWindow = suspect.hostWindow else { return }
            guard NSApp.windows.contains(where: { $0 !== suspectWindow && $0.isVisible }) else { return }
            suspectWindow.close()
        }
    }

    /// application(_:open:)から、実際に存在が確認できているprimaryAppStateへURLを開く処理。
    private func openInPrimaryWindow(_ url: URL, primaryAppState: AppState) {
        // ウインドウがDockに最小化された状態のままFinderから本を開くと、以前はウインドウの
        // 中身(表示中の本)だけが差し替わり、ウインドウ自体はDockに最小化されたまま
        // ユーザーの目に触れない、という不具合があった。Finderからの「開く」はOS側が
        // アプリ自体をアクティブにしてくれるが、最小化されたウインドウはアプリのアクティブ化
        // だけでは自動的に元に戻らない(Dockのアイコンをクリックしたときと同様、明示的な
        // 復元操作が必要)。対象ウインドウが最小化されている場合は、ここでdeminiaturize(_:)を
        // 呼んで明示的に復元する(Dockアイコンをクリックしたときと同じAPIのため、復元後に
        // そのウインドウが前面・キーウインドウになる挙動もあわせて期待できる)。
        if let hostWindow = primaryAppState.hostWindow, hostWindow.isMiniaturized {
            hostWindow.deminiaturize(nil)
        }

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
