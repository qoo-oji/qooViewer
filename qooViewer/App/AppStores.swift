import Combine
import SwiftData
import SwiftUI

/// QooViewerAppが起動時に1度だけ生成して持ち続ける、アプリ全体で共有するストア一式。
///
/// ■ なぜ「入れ物」にまとめるのか(メニュー描画崩れの根本対策)
/// 以前はQooViewerAppがこれらを1つずつ@StateObjectとして持っていた。@StateObjectは
/// objectWillChangeを購読するため、**どれか1つの@Publishedが発火するたびにApp全体のbody
/// (全Scene+.commands)が再評価され、AppKitのメニューが作り直されていた** ―― メニューが
/// その値をまったく読んでいなくても、である(実測: リソースモニタの毎秒の計測値の発火だけで、
/// 開いている「表示」メニューが毎秒作り直されていた。ProcessResourceSampler参照)。
/// メニューバーのメニューを開いている最中の作り直しは、macOS 26のメニュー実装では
/// 描画崩れ/NSRangeExceptionクラッシュの条件になる(MenuBarMenuGateの型コメント参照)。
///
/// この型は**何もpublishしない**。ObservableObjectに適合しているのは、@StateObjectとして
/// 保持してもらうことで生成を1回に固定するためだけで、@Publishedプロパティを持たず、
/// objectWillChangeを流す口も無い。そのため個々のストアの発火がAppのbodyへ直接届くことは
/// なくなり、メニューの再構築はMenuBarMenuRefresher(下記)がMenuBarMenuGate経由で流す
/// 1本に束ねられる。
///
/// **新しい共有ストアを追加するときは、@StateObjectをQooViewerAppへ足すのではなく、
/// 必ずここへ足し、allObjectWillChangePublishersにも並べること。** Appへ@StateObjectとして
/// 足すと、そのストアの発火がこの仕組みを素通りして、開いている最中のメニューを作り直して
/// しまう(publishersへの並べ忘れは逆に「メニューの表示が古いまま残る」という目に見える
/// 形で現れるので、壊れ方としては安全側)。
///
/// 各ウインドウ内のビューはこれまでどおり.environmentObjectで個々のストアを購読するため、
/// パネルや一覧の再描画のされ方・タイミングは何も変わらない。
@MainActor
final class AppStores: ObservableObject {
    let preferences: AppPreferences
    let keyBindingStore: KeyBindingStore
    let recentFiles: RecentFilesStore
    let folderAccess: FolderAccessStore
    /// サイドパネルのリソースモニタの計測役。CPU・メモリ・ディスクI/Oはプロセスの値なので
    /// アプリで1つ(ProcessResourceSamplerのコメント参照)。
    let resourceSampler: ProcessResourceSampler
    /// ファイル名からメタデータを作る規則(qooMeta)の設定。2026-09-21 に `MetadataFormatStore`(3 種の正規表現の規則)
    /// から置き換えた。`@Observable` なので `allObjectWillChangePublishers` には入らない(メニューは規則を読まない)。
    let metadataRulesStore: MetadataRulesStore
    /// 複数ウインドウ/タブに対応するための調整役。詳細はLaunchCoordinator.swiftのコメント参照。
    let launchCoordinator: LaunchCoordinator
    /// お気に入り(階層フォルダ + 登録した本)。RecentFilesStore等と違いSwiftDataで永続化するため、
    /// modelContainerから作ったModelContextを渡して生成する(以下の3つも同じ)。
    let favoritesStore: FavoritesStore
    /// ブックマーク(すべての本を横断)。
    let bookmarkStore: BookmarkStore
    /// ページレイアウト設定(すべての本を横断)。
    let layoutStore: LayoutStore
    /// 書誌メタデータ(著者・タイトル・シリーズ・巻数。すべての本を横断)。
    let metadataStore: BookMetadataStore
    /// 本のタイトルを求める役(登録済みならDBの値、未登録ならファイル名からの推測値)。
    /// コレクションの並び順「タイトル」とカバー下のキャプションが**同じ1つ**を見る必要が
    /// あるため、ここで作って配る(BookTitleResolverの型コメント参照)。
    ///
    /// **allObjectWillChangePublishersには足さない** ―― 何もpublishしない(読まれたその場で
    /// 自分のキャッシュの古さを確かめるだけの)入れ物である。
    let bookTitleResolver: BookTitleResolver
    /// コレクションのカバー画像(ディスク上のJPEG)。CollectionStore/CollectionCoverExtractorの
    /// 両方が同じ1つを見る必要があるため、ここで作って配る。
    let collectionCoverStore: CollectionCoverStore
    /// 焼いた札の絵(コレクションのタイル1枚を1枚のJPEGとして持っておくキャッシュ)。
    /// CollectionStoreが捨てる側、札(CollectionTile)が読む側なので、ここで作って配る。
    let collectionTileImageStore: CollectionTileImageStore
    /// ライブラリ・コレクション・その中の本(改善要望5)。
    ///
    /// **allObjectWillChangePublishersには意図的に足していない。** 表紙の抽出や存在確認のたびに
    /// publishするので、つなぐと名前が変わっていなくてもメニュー全体が作り直される(お気に入りの
    /// publishがメニュー全体を作り直していた轍を踏まない。型コメント参照)。2026-09-15から
    /// 「ホーム」メニューに名前が出るが、それは下のhomeMenuDirectoryが値の写しで受け持つ。
    let collectionStore: CollectionStore
    /// メニューバーの「ホーム」メニューが読む、ライブラリとコレクションの名前の写し(2026-09-15)。
    /// collectionStoreの代わりに**こちらを**allObjectWillChangePublishersへ並べる ―― 名前・並び・所属が
    /// 変わったときだけpublishする(HomeMenuDirectoryStoreの型コメント)。
    let homeMenuDirectory: HomeMenuDirectoryStore
    /// カバー抽出の待ち行列。ウインドウをまたいで1本にするためここが持つ(同上の理由で
    /// allObjectWillChangePublishersには足さない)。
    let collectionCoverExtractor: CollectionCoverExtractor
    /// 自動登録フォルダの走査役(ユーザー要望 2026-09-09)。カバー抽出と同じく、ウインドウを
    /// またいで1つ ―― 同じフォルダを何枚もの画面が同時に走査する意味が無い(同上の理由で
    /// allObjectWillChangePublishersには足さない)。
    let collectionAutoFolderScanner: CollectionAutoFolderScanner
    /// ファイルブラウザの「よく使う項目」(改善要望7 段階3)。メニューバーに現れないので
    /// allObjectWillChangePublishersには足さない(CollectionStoreと同じ理由)。
    let favoriteLocations: FavoriteLocationStore
    /// スマートライブラリで保存するもの(スマートシェルフ・対象フォルダ。2026-09-21)。メニューバーは読まないので
    /// allObjectWillChangePublishers には足さない。
    let smartLibraryStore: SmartLibraryStore
    /// スマートライブラリに並べる本を集める役(画面が出ている間だけ働く)。同じく allObjectWillChangePublishers には足さない。
    let smartLibraryCatalog: SmartLibraryCatalog
    /// ファイルブラウザのアイコン表示の絵(改善要望7 段階 7a)。メモリの絵と作る仕事の待ち行列をウインドウをまたいで
    /// 1 つにする。メニューバーに現れないので allObjectWillChangePublishers には足さない。
    let fileBrowserThumbnails: FileBrowserThumbnailProvider
    /// よく使う項目の中の動画の絵を裏で先に作る役(段階 7b)。ウインドウに配らない(誰も直接は読まない)。
    let fileBrowserVideoThumbnailWarmer: FileBrowserVideoThumbnailWarmer
    /// ファイルブラウザの自動リネーム(2026-09-15)。規則・実行ログ・実行役。メニューバーに現れないので
    /// allObjectWillChangePublishers には足さない。
    let autoRenameStore: AutoRenameStore
    let autoRenameLog: AutoRenameActivityLog
    let autoRenameService: AutoRenameService
    /// アプリ自身が移した本の保存データの付け替え役(BookRecordRelocator)。
    let bookRecordRelocator: BookRecordRelocator
    /// テキストの欄を編集しているか(編集メニューの「取り消す」「やり直す」の淡色。TextEditingMenuState の型コメント)。
    let textEditingMenuState = TextEditingMenuState()
    /// アプリ自身がファイルを動かした知らせの購読(`handleFileSystemChange`)。
    private var fileSystemChangeSubscription: AnyCancellable?
    /// 環境設定「ライブラリを有効にする」の購読(`applyLibraryFeature`)。
    private var libraryFeatureSubscription: AnyCancellable?
    /// 環境設定「ファイルブラウザを有効にする」の購読(`applyFileBrowserFeature`)。
    private var fileBrowserFeatureSubscription: AnyCancellable?
    private var smartLibraryFeatureSubscription: AnyCancellable?
    /// 規則の変更の購読(ロックしていないメタデータの行を読み直す。`reparseUnlockedMetadata`)。
    private var metadataRulesSubscription: AnyCancellable?
    private var metadataReparseTask: Task<Void, Never>?
    /// 起動時の掃除(行の無い表紙・元画像・札の絵)を済ませたか。ライブラリ機能がOFFで起動したら、最初にONになるまで先送りする。
    private var didSweepLibraryOrphans = false

    init() {
        // 予約された「すべてのデータを削除」の残り(終了前に落ちた場合)は、**どのストアよりも
        // 先に**片付ける(監査で指摘 2026-09-13)。以前はmodelContainerの初期化の中でだけ
        // 行っていたが、そこへ届くのは下の4つ(環境設定・キーの割り当て・履歴・フォルダの
        // アクセス権)がUserDefaultsを読み終えた後だった。消した直後にそれらのdidSetが古い値を
        // 書き戻すので、この経路の全削除では環境設定が生き残っていた。modelContainerの中の
        // 呼び出しはそのまま残す(予約はここで取り下げられているので、あちらは何もしない)。
        QooViewerApp.performPendingStoreResetIfNeeded()
        // 生成の順序は、QooViewerAppが@StateObjectを個別に持っていた頃の
        // 「宣言時デフォルト値(宣言順)→ init()内のSwiftData系4つ」の順をそのまま保つ。
        preferences = AppPreferences()
        keyBindingStore = KeyBindingStore()
        recentFiles = RecentFilesStore()
        folderAccess = FolderAccessStore()
        resourceSampler = ProcessResourceSampler()
        // テストの中で走る実物のアプリでは、利用者の規則のファイルを読み書きせず、以前の規則の引き継ぎもしない
        // (共有の状態に触らない。CLAUDE.md)。テストは自分の MetadataRulesStore を使い捨ての場所に作る。
        metadataRulesStore = RuntimeEnvironment.isRunningTests
            ? MetadataRulesStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("qooViewerTestHost.rules.\(UUID().uuidString)/settings.json"),
                legacyDefaults: nil, isAppWide: true)
            : MetadataRulesStore(isAppWide: true)
        // 英単語の辞書(約 24 万語)を画面の外で読んでおく(メタデータの編集ウインドウを初めて開いたときに待たない)。
        MetadataRulesStore.warmUp()
        launchCoordinator = LaunchCoordinator()
        favoriteLocations = FavoriteLocationStore()
        let context = QooViewerApp.modelContainer.mainContext
        favoritesStore = FavoritesStore(modelContext: context)
        bookmarkStore = BookmarkStore(modelContext: context)
        layoutStore = LayoutStore(modelContext: context)
        metadataStore = BookMetadataStore(modelContext: context)
        bookTitleResolver = BookTitleResolver(
            metadataStore: metadataStore, rulesStore: metadataRulesStore
        )
        collectionCoverStore = CollectionCoverStore()
        collectionTileImageStore = CollectionTileImageStore(coverStore: collectionCoverStore)
        // ライブラリ機能がOFFなら、ライブラリのためだけの仕事を**起動の時点から**始めない(applyLibraryFeature のコメント)。
        let isLibraryEnabled = preferences.libraryFeatureEnabled
        collectionStore = CollectionStore(
            modelContext: context, coverStore: collectionCoverStore,
            tileStore: collectionTileImageStore, titleResolver: bookTitleResolver,
            isLibraryFeatureEnabled: isLibraryEnabled
        )
        homeMenuDirectory = HomeMenuDirectoryStore(collectionStore: collectionStore, isLibraryFeatureEnabled: isLibraryEnabled)
        collectionCoverExtractor = CollectionCoverExtractor(
            collectionStore: collectionStore, coverStore: collectionCoverStore,
            layoutStore: layoutStore, isLibraryFeatureEnabled: isLibraryEnabled
        )
        fileBrowserThumbnails = FileBrowserThumbnailProvider(
            collectionStore: collectionStore, coverStore: collectionCoverStore, layoutStore: layoutStore
        )
        fileBrowserThumbnails.connect(preferences: preferences)
        fileBrowserThumbnails.setLibraryFeatureEnabled(isLibraryEnabled)
        fileBrowserVideoThumbnailWarmer = FileBrowserVideoThumbnailWarmer(dependencies: .live())
        // テストの中で走る実物のアプリでは動かさない(開発機の本物のよく使う項目を読み、本物のキャッシュに書くため)。
        if !RuntimeEnvironment.isRunningTests {
            fileBrowserVideoThumbnailWarmer.connect(favorites: favoriteLocations, preferences: preferences)
        }
        autoRenameStore = AutoRenameStore()
        autoRenameLog = AutoRenameActivityLog()
        let folderAccessForAutoRename = folderAccess
        let launchCoordinatorForAutoRename = launchCoordinator
        autoRenameService = AutoRenameService(
            store: autoRenameStore, log: autoRenameLog, favorites: favoriteLocations, preferences: preferences,
            // 名前を変えたことをアプリ全体へ知らせるインスタンス(FileSystemChange の型コメント)。
            fileOps: .shared,
            hasAccess: { [weak folderAccessForAutoRename] url in folderAccessForAutoRename?.isPathCovered(url) ?? false },
            inUsePaths: { [weak launchCoordinatorForAutoRename] in
                launchCoordinatorForAutoRename?.allOpenAppStates.compactMap { $0.currentBook?.sourceURL.path } ?? []
            },
            locale: { [weak preferences] in preferences?.effectiveLocale ?? AppLanguage.currentLocale }
        )
        // テストの中で走る実物のアプリでは動かさない(開発機の本物のよく使う項目の中の名前を変えてしまう)。
        // ファイルブラウザ機能がOFFなら始めない(applyFileBrowserFeature のコメント)。
        // (init の途中なので `startAutoRename()` は呼べない ―― 同じ中身を直に書く。)
        if !RuntimeEnvironment.isRunningTests, preferences.fileBrowserFeatureEnabled {
            autoRenameService.start(folderAccessChanges: folderAccess.objectWillChange.map { _ in () }.eraseToAnyPublisher())
        }
        smartLibraryStore = SmartLibraryStore()
        smartLibraryCatalog = SmartLibraryCatalog(
            metadataStore: metadataStore, store: smartLibraryStore, rulesStore: metadataRulesStore, modelContext: context,
            // 前回の一覧を保存して次の起動で先に出す。テストの中では保存しない(共有の状態に触らない)。
            cacheURL: RuntimeEnvironment.isRunningTests ? nil : SmartLibraryCatalog.defaultCacheURL
        )
        if !RuntimeEnvironment.isRunningTests { SmartLibraryCatalog.removeLegacyCache() }
        smartLibraryCatalog.setFeatureEnabled(preferences.smartLibraryFeatureEnabled)
        collectionAutoFolderScanner = CollectionAutoFolderScanner(
            collectionStore: collectionStore, coverExtractor: collectionCoverExtractor,
            folderAccess: folderAccess, preferences: preferences
        )
        collectionAutoFolderScanner.setLibraryFeatureEnabled(isLibraryEnabled)

        bookRecordRelocator = BookRecordRelocator(
            favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
            metadataStore: metadataStore, collectionStore: collectionStore, modelContext: context,
            coverExtractor: collectionCoverExtractor
        )
        // テストの中で走る実物のアプリでは繋がない(テストの操作で、開発機の本物の保存データとよく使う項目を書き換えない)。
        if !RuntimeEnvironment.isRunningTests {
            fileSystemChangeSubscription = FileSystemChangeCenter.shared.changes.sink { [weak self] change in
                MainActor.assumeIsolated { self?.handleFileSystemChange(change) }
            }
        }
        // 解析した本はすべて DB に登録する(利用者の指示 2026-09-22。BookMetadataRecord の型コメント)。以前の下書き
        // (drafts.json)を DB へ移し、規則が変わったらロックしていない行を読み直す。テストの中では動かさない(本物の
        // drafts.json を読んで消すため。テストは自分のストアで確かめる)。
        if !RuntimeEnvironment.isRunningTests {
            MetadataDraftStore().migrate(into: metadataStore, rules: metadataRulesStore.rules)
            pruneParsedOnlyMetadata()
            metadataRulesSubscription = NotificationCenter.default
                .publisher(for: MetadataRulesStore.rulesDidChange, object: metadataRulesStore)
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.reparseUnlockedMetadata() } }
        }
        // 起動時の掃除(CollectionCoverExtractorのinitの移行の**後**であること。sweepLibraryOrphansIfNeeded のコメント)。
        if isLibraryEnabled { sweepLibraryOrphansIfNeeded() }
        // `@Published`の投影はwillSetで飛ぶので、届いた値のほうを使う。起動時の値は上で渡し済み。
        fileBrowserFeatureSubscription = preferences.$fileBrowserFeatureEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated { self?.applyFileBrowserFeature(isEnabled) }
            }
        // 「スマートライブラリを有効にする」(2026-09-22)。OFF で止まるものと止まらないものは SmartLibraryCatalog の型コメント
        // 「OFF にしたとき」。画面・「ホーム」メニューの項目・メタデータの編集ウインドウの対象フォルダは、それぞれが設定を読む。
        smartLibraryFeatureSubscription = preferences.$smartLibraryFeatureEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated { self?.smartLibraryCatalog.setFeatureEnabled(isEnabled) }
            }
        libraryFeatureSubscription = preferences.$libraryFeatureEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated { self?.applyLibraryFeature(isEnabled) }
            }
    }

    /// 環境設定「ライブラリを有効にする」(AppPreferences.libraryFeatureEnabled。2026-09-21、ユーザー要望)を、アプリで 1 つの仕事へ伝える。
    ///
    /// ■ OFFの間に止まるもの(ライブラリのためだけの仕事)
    /// - 登録した本の実体の存在確認(`CollectionStore.scheduleExistenceRefresh` ―― 起動・アクティブ化・ボリュームの着脱・アプリ自身の
    ///   ファイル操作のたびに、全冊のブックマーク解決と stat)
    /// - 表紙の抽出と、その起動時の下ごしらえ(`CollectionCoverExtractor`)
    /// - 自動登録フォルダの走査と FSEvents の監視(`CollectionAutoFolderScanner`)
    /// - 起動時の掃除(行の無い表紙・元画像・札の絵。`sweepLibraryOrphansIfNeeded`)
    /// - 「ホーム」メニューの名前の写し(`HomeMenuDirectoryStore`)
    /// - ファイルブラウザのアイコンの表紙の照会(FileBrowserThumbnailProvider)、起動時の「見つからない本」の確認(ContentView)
    /// どれも登録した本の全件フェッチを伴う。OFFの間は、下の「止めないもの」のどれかが要るまで、その行はメモリに載らない。
    ///
    /// ■ 止めないもの(保存データを正しく保つための仕事)
    /// - アプリ自身が移した・名前を変えた本の付け替え(`BookRecordRelocator`)。別のボリュームへ移した本は、ここで付け替えないと
    ///   ONへ戻したときに「見つからない本」になる(同じボリュームの中ならブックマークが追うが、ボリュームをまたぐと追えない)
    /// - 本を開いたときの、Finder で移した・名前を変えた本への追従と識別子の補完(AppState.open の `reconcileBookIDIfMoved` /
    ///   `backfillFileNodeIdentifier`)。お気に入り・ブックマーク・レイアウト・メタデータと**5つ揃えて**付け替える ―― コレクションの行だけ
    ///   古いパスに残すと、その行から`bookID`で引く表紙の指定とメタデータが外れる(いったんは止めていた。2026-09-21 の監査の D2)
    /// - 保存データの書き出し・読み込み・削除(コレクションも対象のまま)
    /// - 「このアプリが知っている本」の一覧と、本の実体へ届くための最後の手がかり(`KnownBooks.collect`・
    ///   `CollectionStore.allRegisteredBookIDs` / `anyBookmarkData(forBookID:)` ―― 「メタデータの編集」「本の書き出し」「保存データの
    ///   削除」「コレクション表紙の読み込み」)。コレクションにしか無い本も編集・書き出しの対象で、権限もそこにしか無いことがある
    /// これらは登録した本の全件フェッチを伴う(1回引けばキャッシュに残る)。**止めるのは「ライブラリのためだけの仕事」で、
    /// 「`CollectionItem`に触るもの全部」ではない**(2026-09-21 の監査 docs/plans/feature-toggle-audit.md の D1)。
    ///
    /// ■ データは消さない
    /// ONへ戻せば棚は元のまま。止めていた仕事はその場で動き出す(存在確認 → 表紙の待ち行列の組み直し → 自動登録フォルダの走査)。
    /// OFFの間に表紙の指定が変わった本は、ONへ戻ったときに作り直す(CollectionCoverExtractor.isLibraryFeatureEnabled のコメント)。
    private func applyLibraryFeature(_ isEnabled: Bool) {
        collectionStore.setLibraryFeatureEnabled(isEnabled)
        homeMenuDirectory.setLibraryFeatureEnabled(isEnabled)
        collectionCoverExtractor.setLibraryFeatureEnabled(isEnabled)
        collectionAutoFolderScanner.setLibraryFeatureEnabled(isEnabled)
        fileBrowserThumbnails.setLibraryFeatureEnabled(isEnabled)
        if isEnabled { sweepLibraryOrphansIfNeeded() }
    }

    /// 環境設定「ファイルブラウザを有効にする」(AppPreferences.fileBrowserFeatureEnabled。2026-09-21、ユーザー要望)を、アプリで 1 つの仕事へ伝える。
    ///
    /// ■ OFFの間に止まるもの(ファイルブラウザのためだけの仕事)
    /// - **自動リネーム**(`AutoRenameService`): よく使う項目の下の監視(FSEvents)・走査・名前の変更。規則を作る・止める入り口
    ///   (右クリックの「自動リネーム」・「ホーム」メニューと環境設定「ファイルブラウザ」の「自動リネームの設定…」)は、OFFの間は
    ///   どれも消える・押せなくなり、開いていた設定ウインドウも自分で閉じる(AutoRenameSettingsWindow。「ウインドウ」メニューの
    ///   自動の項目は `.commandsRemoved()` で落としてある)ので、画面が無い間に裏で名前を変え続けない。止まっている間は
    ///   実行役の口(`refreshAvailability`・`handle`)も何もしない(`AutoRenameService.stop` のコメント。2026-09-21 の監査の F1・F2)。
    ///   規則とログは残り、ONへ戻すとその時点の中身を読み直して動き出す(`start` が全部を走査する)
    /// - よく使う項目の中の動画のサムネイルの先回り(`FileBrowserVideoThumbnailWarmer`。設定を自分で購読している)
    /// - ウインドウごとの一覧の読み込み・監視・サムネイル作り: ペインが画面に出ないので始まらない(`FileBrowserState.activate` は
    ///   ペインの onAppear、`FileBrowserThumbnailProvider` は頼まれたぶんだけ作る)。ここから伝えるものは無い
    ///
    /// ■ 止めないもの
    /// - 置き換えの退避の復旧(`ReplaceBackupRecovery`。起動時)―― 前回の操作が途中で落ちていたら、利用者のファイルを元へ戻す
    /// - アプリ自身がファイルを動かした知らせ(`FileSystemChangeCenter`)とよく使う項目の付け替え ―― サイドパネルのフォルダブラウザも使う
    /// - サムネイルのディスクキャッシュ・よく使う項目・規則などの保存したものは消さない
    private func applyFileBrowserFeature(_ isEnabled: Bool) {
        guard !RuntimeEnvironment.isRunningTests else { return }
        if isEnabled { startAutoRename() } else { autoRenameService.stop() }
    }

    private func startAutoRename() {
        autoRenameService.start(folderAccessChanges: folderAccess.objectWillChange.map { _ in () }.eraseToAnyPublisher())
    }

    /// 起動時の掃除(1回だけ。`didSweepLibraryOrphans`のコメント)。
    private func sweepLibraryOrphansIfNeeded() {
        guard !didSweepLibraryOrphans else { return }
        didSweepLibraryOrphans = true
        // 行の無いカバー画像(前回の起動が落ちた・ストアを作り直した等)を起動時に1度だけ掃除する。
        collectionStore.sweepOrphanedCovers()
        // コレクション表紙の元画像も同じく(CollectionCoverExtractorのinitが分離の移行で
        // 複製を作るので、**その後で**掃除すること)。
        layoutStore.sweepOrphanedShelfCoverImages()
        // 焼いた札の絵も同じく(こちらは容量の刈り込みも兼ねる)。
        collectionStore.sweepOrphanedTileImages()
    }

    /// 起動時に、ほかに覚えている理由の無いファイル名の読みだけのメタデータの行を消す(`BookMetadataStore.pruneParsedOnlyRows`)。
    /// ライブラリ機能が OFF の間もコレクションの本は数える(「このアプリが知っている本」の一覧は止めない仕事。
    /// `applyLibraryFeature` のコメント)。
    private func pruneParsedOnlyMetadata() {
        let known = KnownBooks.collect(from: KnownBooks.Sources(
            metadataStore: metadataStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
            favoritesStore: favoritesStore, collectionStore: collectionStore,
            modelContext: QooViewerApp.modelContainer.mainContext
        ), includingMetadata: false)
        metadataStore.pruneParsedOnlyRows(keeping: known, keepingFolders: smartLibraryStore.folders.map(\.path))
    }

    /// ロックしていないメタデータの行を、いまの規則で読み直す(前の読み直しは取り消す)。
    private func reparseUnlockedMetadata() {
        metadataReparseTask?.cancel()
        let previous = metadataReparseTask
        metadataReparseTask = Task { [metadataStore, metadataRulesStore] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await metadataStore.reparseUnlockedRows(rules: metadataRulesStore.rules)
        }
    }

    /// アプリ自身がファイルを動かした(ファイルブラウザの操作・取り消し・やり直し・自動リネーム。`FileSystemChange` の型コメント)。
    /// ウインドウごとの一覧(ファイルブラウザ・サイドパネル)は自分で受ける。ここはアプリで 1 つのもの:
    /// よく使う項目と保存データを新しいパスへ付け替え、それが済んでから棚・履歴・お気に入りの「実体があるか」を確かめ直す
    /// (以前の契機は起動・アクティブ化・ボリュームの着脱だけで、アプリの中で本を移しても消しても表示が変わらなかった)。
    private func handleFileSystemChange(_ change: FileSystemChange) {
        favoriteLocations.relocate(using: change)
        smartLibraryStore.relocate(using: change)
        metadataRulesStore.relocate(using: change)
        smartLibraryCatalog.handleFileSystemChange(change)
        let relocation = bookRecordRelocator.apply(change)
        Task { @MainActor [weak self] in
            await relocation.value
            guard let self else { return }
            // ライブラリ機能がOFFの間は、ストアの側で何もしない(CollectionStore.isLibraryFeatureEnabled)。
            self.collectionStore.scheduleExistenceRefresh()
            self.recentFiles.scheduleRefresh()
            self.favoritesStore.scheduleExistenceRefresh()
        }
    }

    /// MenuBarMenuRefresherが購読する、全ストアのobjectWillChange。
    /// ストアを増やしたら必ずここにも足すこと(型コメント参照)。
    var allObjectWillChangePublishers: [ObservableObjectPublisher] {
        [
            preferences.objectWillChange,
            keyBindingStore.objectWillChange,
            recentFiles.objectWillChange,
            folderAccess.objectWillChange,
            resourceSampler.objectWillChange,
            launchCoordinator.objectWillChange,
            favoritesStore.objectWillChange,
            bookmarkStore.objectWillChange,
            layoutStore.objectWillChange,
            metadataStore.objectWillChange,
            homeMenuDirectory.objectWillChange,
            textEditingMenuState.objectWillChange,
        ]
    }
}

/// ストアのどれかが変わったことを、**メニューバーが安全なタイミングでだけ**Appのbodyへ
/// 伝える中継役。QooViewerAppが@StateObjectとして観測する唯一のオブジェクト。
///
/// AppStores内の全ストアのobjectWillChangeを購読し、
/// 1. 同じランループターン内の連続した発火を1回にまとめ、
/// 2. MenuBarMenuGate経由でrevisionを進める ―― メニューバーのメニューが開いている間は
///    閉じるまで保留され、閉じた1ランループ後に1回だけ反映される。
///
/// これにより「メニューの内容に影響しうる発火を、メニューを開いている最中にAppのbodyへ
/// 届けない」というMenuBarMenuGateの原則が、個々のストアの実装に頼らず**構造として**
/// 保証される。ストア側が自分の発火タイミングを気にする必要はもう無い(既存のストア内の
/// ゲート経由の発火はそのまま残してある ―― ウインドウ内の一覧の描き替えまで保留したい、
/// というそれぞれの理由が別にあるため。各ストアのコメント参照)。
///
/// revisionの値そのものは誰も読まない。@Publishedの発火だけが目的で、発火を受けた
/// SwiftUIがAppのbodyを再評価し、.commandsが各ストアの**その時点の最新値**を読み直す。
///
/// なおAppのbodyの再評価要因はこれで全てではなく、FocusedValues(qooViewerAppState /
/// qooViewerMenuCheckmarkState)の変化でも再評価される。そちらはAppState側で
/// ゲート経由の値だけを公開することで同じ原則を守っている(MenuCheckmarkStateのコメント参照)。
@MainActor
final class MenuBarMenuRefresher: ObservableObject {
    /// 「どれかのストアが変わった」ことだけを表す通し番号。値は読まれない(型コメント参照)。
    @Published private(set) var revision: UInt64 = 0
    private var subscriptions: [AnyCancellable] = []
    /// 次のランループターンでのrevision更新を予約済みか(同一ターン内の発火をまとめる)。
    private var isBumpScheduled = false

    init(observing stores: AppStores) {
        for publisher in stores.allObjectWillChangePublishers {
            publisher
                .sink { [weak self] _ in
                    // 全ストアが@MainActorなので発火は常にメインスレッド
                    // (違反していればここで即座に落ちて気付ける)。
                    MainActor.assumeIsolated {
                        self?.scheduleBump()
                    }
                }
                .store(in: &subscriptions)
        }
    }

    private func scheduleBump() {
        guard !isBumpScheduled else { return }
        isBumpScheduled = true
        // objectWillChangeは値が変わる**前**に飛ぶため、1ランループ跨いでから進める。
        // これでbodyの再評価は必ず変更後の値を読み、かつ同じターン内の複数ストアの発火が
        // 1回の再評価にまとまる。
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isBumpScheduled = false
                MenuBarMenuGate.shared.run("MenuBarMenuRefresher.revision") { [weak self] in
                    self?.revision &+= 1
                }
            }
        }
    }
}
