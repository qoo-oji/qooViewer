import Foundation
import SwiftData
import AppKit
import Combine

/// お気に入り機能の件数・階層の上限。この2つの数値さえ変えれば、アプリ全体の挙動が
/// 追随するよう、ここ1箇所にまとめている(将来、環境設定からユーザーが変更できるようにする
/// 場合も、AppPreferences.maxTrackedBooksCountと同じパターンでここを置き換えるだけでよい)。
enum FavoritesLimits {
    /// 登録できるお気に入りの総数(全フォルダ合計)の上限。
    /// これ以上の規模は専用のカタログ管理ソフトで扱うべき、という判断による。
    static let maxFavoritesCount = 999
    /// フォルダの階層の深さの上限。ルート直下のフォルダを1階層目として数える。
    static let maxFolderDepth = 3
}

/// お気に入りの追加・フォルダ作成が上限に達していたときに投げるエラー。
/// 事前にボタンを無効化するのではなく、ユーザーが実際に操作を確定した時点でこれを検知し、
/// アラートで表示する(件数・階層のどちらの上限に引っかかったのかを明示する)。
enum FavoritesLimitError: LocalizedError {
    case favoritesLimitReached
    case folderDepthLimitReached

    // 件数・階層の数値を埋め込む部分は、Swiftの文字列補間(\(...))をString(localized:)へ
    // 直接渡す書き方だと、Xcodeの文字列カタログ抽出を経ないと正しいキーにならず翻訳が
    // 効かなくなるため、あえてString(format:)による昔ながらの%d置換にしている。これなら
    // Localizable.xcstrings側に"...%d..."という固定文字列のキーをそのまま追加でき、
    // 日本語訳も確実に反映される。
    var errorDescription: String? {
        switch self {
        case .favoritesLimitReached:
            return String(
                format: String(localized: "You can register up to %d favorites in total.", language: AppLanguage.currentLocale),
                FavoritesLimits.maxFavoritesCount
            )
        case .folderDepthLimitReached:
            return String(
                format: String(localized: "Favorite folders can be nested up to %d levels deep.", language: AppLanguage.currentLocale),
                FavoritesLimits.maxFolderDepth
            )
        }
    }
}

/// お気に入り一覧を1つの並びとして扱うための、フォルダ/お気に入りをまとめた列挙。
/// FavoritesStore.entries(in:)が返す。メニューバー・ツールバーのサブメニュー、
/// 「お気に入りの整理」ウインドウのどちらも、フォルダとお気に入りをそれぞれ別の見た目
/// (サブメニュー vs クリックで開く項目、フォルダアイコン vs 本アイコン)で表示する必要が
/// あるため、呼び出し側でswitchして分岐させる。
enum FavoriteListEntry: Identifiable {
    case folder(FavoriteFolder)
    case book(FavoriteBook)

    var id: UUID {
        switch self {
        case .folder(let folder): return folder.id
        case .book(let book): return book.id
        }
    }

    /// 並び替えの基準として使う名前(フォルダ名/本のタイトル)。
    fileprivate var sortName: String {
        switch self {
        case .folder(let folder): return folder.name
        case .book(let book): return book.title
        }
    }

    /// 並び替えの基準として使う「追加日時」(フォルダの作成日時/お気に入り登録日時)。
    fileprivate var dateAdded: Date {
        switch self {
        case .folder(let folder): return folder.createdAt
        case .book(let book): return book.addedAt
        }
    }

    /// 並び替えの基準として使う「更新日時」(フォルダ/お気に入りのupdatedAt)。
    fileprivate var dateUpdated: Date {
        switch self {
        case .folder(let folder): return folder.updatedAt
        case .book(let book): return book.updatedAt
        }
    }
}

/// 「登録しようとした本がすでにお気に入りに登録されている」ことを呼び出し側(UI層)へ知らせるための結果。
enum FavoriteAddOutcome {
    /// 新規に登録できた。
    case added(FavoriteBook)
    /// 登録先フォルダに既にあったため、内容を上書きした(ダイアログ不要)。
    case overwritten(FavoriteBook)
    /// 別のフォルダに既に登録されている。呼び出し側は、existingBreadcrumbを使って
    /// 「『(フォルダ名)』に既に登録されています。ここにも登録しますか?」という確認ダイアログを
    /// 出し、確認が取れたらforceAddFavorite(book:to:)を呼び直す。
    case needsDuplicateConfirmation(existingBreadcrumb: String)
    /// 件数上限(FavoritesLimits.maxFavoritesCount)に達しているため登録できなかった。
    case limitReached
    /// セキュリティスコープ付きブックマークの作成に失敗するなど、その他の理由で登録できなかった。
    case failed
}

/// お気に入り(階層フォルダ + 登録した本)の永続化・操作をまとめて担当する。
///
/// ブックマーク(Bookmark.swift、本の中のページの目印)とは異なり、お気に入りは「本を開いていない
/// 状態からでも後で開ける」必要があるため、本そのものへの参照はRecentFilesStore等と同じく
/// セキュリティスコープ付きブックマーク(bookmarkData)として保持する(詳細はFavoriteBook.swift参照)。
///
/// メニューバー(QooViewerApp.swiftの.commands)からも、各ウインドウのツールバー・
/// コンテキストメニューからも同じデータを参照する必要があるため、RecentFilesStoreと同様
/// アプリ全体で1つだけのインスタンスとして扱う(QooViewerAppの@StateObject)。
@MainActor
final class FavoritesStore: ObservableObject {
    /// MenuBarMenuGateへ登録する「メニューが閉じたら一覧を最新化する」処理の識別子。
    private static let menuGateKey = "FavoritesStore.reload"

    /// ルート直下のフォルダ一覧(親を持たないFavoriteFolder)。sortOptionの並び順。
    @Published private(set) var rootFolders: [FavoriteFolder] = []
    /// ルート直下に直接置かれているお気に入り(フォルダに属さないFavoriteBook)。sortOptionの並び順。
    @Published private(set) var rootBooks: [FavoriteBook] = []

    /// お気に入り一覧(このViewModelが公開するすべてのリスト)の並び順。変更すると即座に
    /// reload()し、「お気に入りの整理」ウインドウ・メニューバー/ツールバーのサブメニューの
    /// 両方に反映される(どちらもこのストアが公開するrootFolders/rootBooks、および
    /// subfolders(of:)/books(in:)経由でソート済みの結果を取得するだけのため、
    /// このプロパティ以外に変更箇所は不要)。
    @Published var sortOption: FavoritesSortOption {
        didSet {
            guard sortOption != oldValue else { return }
            UserDefaults.standard.set(sortOption.rawValue, forKey: Self.sortOptionDefaultsKey)
            reload()
        }
    }

    /// フォルダとお気に入りを、sortOptionの基準に関わらず常にフォルダを先に表示するか
    /// (既定はtrue。従来通り「フォルダ一覧の後にお気に入り一覧」という見た目になる)。
    /// falseにすると、フォルダ・お気に入りを区別せずsortOptionの基準(名前/追加日時/更新日時)
    /// だけで混在させて1つの並びにする(entries(in:)参照)。こちらはfetch結果自体は変わらないため
    /// reload()は不要で、@Publishedによる再描画だけで反映される。
    @Published var foldersAlwaysOnTop: Bool {
        didSet {
            guard foldersAlwaysOnTop != oldValue else { return }
            UserDefaults.standard.set(foldersAlwaysOnTop, forKey: Self.foldersAlwaysOnTopDefaultsKey)
        }
    }

    private static let sortOptionDefaultsKey = "qooViewer.pref.favoritesSortOption"
    private static let foldersAlwaysOnTopDefaultsKey = "qooViewer.pref.favoritesFoldersAlwaysOnTop"

    private let modelContext: ModelContext

    /// folder(withID:)/book(withID:)/existingFavorites(forBookID:)向けの、絞り込み無し全件
    /// フェッチ結果のキャッシュ。このストアがFavoriteFolder/FavoriteBookの唯一の書き込み口
    /// (modelContextはBookmarkStore/LayoutStore、およびContentView/ViewerViewModel側の
    /// `@Environment(\.modelContext)`とも同じ単一のModelContext(modelContainer.mainContext)を
    /// 共有しているが、FavoriteFolder/FavoriteBookへ書き込むのはこのストアだけ。
    /// LibraryImportExportServiceもこのストアのcreateFolder/forceAddFavorite経由でしか
    /// 書き込まない)であるため、insert/deleteのたびにinvalidateFavoritesLookupCaches()で
    /// 無効化しておけば、常にmodelContext.fetch()を直接呼んでいた場合と同じ結果になる。
    private var cachedFolders: [FavoriteFolder]?
    private var cachedBooks: [FavoriteBook]?

    /// メニューが開かれる直前に一覧を再読み込みするための監視トークン。
    /// (RecentFilesStoreと同じ理由: 整理画面や他のウインドウでの変更を、メニューを開くたびに
    /// 反映させるため)
    /// アプリがアクティブになったときに実体の存在確認をやり直すための監視トークン。
    private var activationObserver: NSObjectProtocol?
    /// ボリュームのマウント/アンマウントで存在確認をやり直すための監視トークン(NSWorkspaceの通知)。
    private var volumeObservers: [NSObjectProtocol] = []
    /// 非同期の存在確認(scheduleExistenceRefresh)が実行中かどうか。
    private var isRefreshingExistence = false
    /// 存在確認の実行中に、次の確認の要求が来たかどうか。要求を捨てずに1回ぶんだけ覚えておき、
    /// 実行中のものが終わってから走らせる。
    private var needsAnotherExistenceRefresh = false

    /// お気に入りの実体がまだ存在するかどうかのキャッシュ(FavoriteBook.id -> 存在するか)。
    ///
    /// バグ修正(ユーザー報告と同じ構図): 存在確認(fileExists(for:))はセキュリティスコープ付き
    /// ブックマークの解決を伴い、対象が未接続の外付け/ネットワークボリュームを指していると
    /// 秒単位ブロックしうる。以前はこれを
    ///   ・ウェルカム画面のbody評価中に全件ぶん(recentFavorites(limit:))
    ///   ・「お気に入りの整理」ウインドウの行ごとに.task(id:)で1件ずつ
    /// 同期実行していた。SwiftUIの.taskはビューと同じMainActor上で走るため、非同期にしても
    /// メインスレッドが止まることに変わりはなく、描画のもたつきの原因になっていた。
    /// 現在は、確認そのものをメインアクターの外へ出したうえでこのキャッシュへ集約し、
    /// 表示側はキャッシュを読むだけ(ファイルアクセスなし)にしている。
    @Published private(set) var existenceByFavoriteID: [UUID: Bool] = [:]

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        // didSetは(型自身のinit内で)ここで直接代入する分には呼ばれないため、reload()は
        // このあと明示的に1回呼ぶ必要がある。
        self.sortOption = FavoritesSortOption(
            rawValue: UserDefaults.standard.string(forKey: Self.sortOptionDefaultsKey) ?? ""
        ) ?? .nameAscending
        self.foldersAlwaysOnTop =
            UserDefaults.standard.object(forKey: Self.foldersAlwaysOnTopDefaultsKey) as? Bool ?? true
        reload()
        // RecentFilesStore.swiftの同様のオブザーバーと同じ書き方(queue: .mainを指定した
        // NotificationCenterのクロージャは実行時にはメインスレッドで呼ばれるため、
        // Task { @MainActor in ... }で包み直す必要はない。むしろ包むとSwift 6の
        // 厳格な並行性チェックで「Reference to captured var 'self' in concurrently-executing
        // code」という警告/エラーになった)。ただし素の呼び出しのままだと今度は
        // 「main actor-isolated instance method 'reload()' ... implicitly asynchronous」という
        // 警告が出るため、MainActor.assumeIsolatedで「実行時には既にMainActor上にいる」ことを
        // 伝える(Task化のような非同期ホップは発生させない。ViewerViewModel.swiftの同種の
        // コメント参照)。
        // メニューバーのメニューの内容(お気に入り/ブックマーク一覧)を最新に保つための再読み込み。
        // **開いた瞬間ではなく、閉じたあとに行う**。開いている最中に@Publishedを発火させると、
        // SwiftUIがトラッキング中のメインメニューを作り直し(NSMenu setItemArray:)、macOS 26では
        // 新しいメニュー実装(NSContextMenuImpl)が行高キャッシュの範囲外アクセスで
        // NSRangeExceptionを投げて落ちる(サムネイルグリッドを出したままメニューを開くと落ちる
        // 不具合と同じ系統)。
        //
        // NSMenu.didEndTrackingNotificationを自前で購読するのではなく、MenuBarMenuGateへ
        // 登録する。同じ通知をゲート自身も購読しているためオブザーバの呼び出し順が定まらず、
        // 自前で購読するとゲートより先に走った場合・後に走った場合で挙動が変わってしまう
        // (詳細はMenuBarMenuGate.onMenuBarMenuDidClose(_:_:)のコメント参照)。
        // publishOnlyWhenChangedにより、中身が変わったときだけ発火する点は従来どおり。
        MenuBarMenuGate.shared.onMenuBarMenuDidClose(Self.menuGateKey) { [weak self] in
            self?.reload(publishOnlyWhenChanged: true)
        }

        // 実体の存在確認は重いので、メニューや一覧の描画のたびではなく「古くなっている
        // 可能性が生まれたとき」にだけ非同期で行う(RecentFilesStoreと同じ考え方・同じ契機)。
        //   ・アプリがアクティブになったとき: 裏でFinderから削除・移動された場合
        //   ・ボリュームのマウント/アンマウント: 外付け・ネットワークドライブの抜き差し
        // お気に入りを新しく追加した直後は、cachedFileExists(for:)が既定でtrueを返すため
        // 確認を待たずに正しく表示される(いま開けたファイルなので存在するのは自明)。
        scheduleExistenceRefresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExistenceRefresh()
            }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleExistenceRefresh()
                }
            }
        }
    }

    /// 予防: RecentFilesStore.deinitと同じ理由(アプリ全体で1つのため現状は呼ばれないが、
    /// 購読の登録と解除を対にしておく)。
    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            workspaceCenter.removeObserver(observer)
        }
    }

    // MARK: - 実体の存在確認(非同期・キャッシュ)

    /// キャッシュ済みの存在確認結果を返す。**ファイルアクセスは一切行わない**ので、
    /// 一覧やメニューの描画から自由に呼んでよい。
    ///
    /// まだ確認できていない項目はtrue(存在する)として扱う。「まだ分からない」を「見つかりません」
    /// として描画すると、起動直後の一瞬すべてのお気に入りが失われたように見えてしまうため。
    func cachedFileExists(for favorite: FavoriteBook) -> Bool {
        existenceByFavoriteID[favorite.id] ?? true
    }

    /// 全お気に入りの実体確認を非同期に予約する。重い部分はメインアクターの外で走らせ、
    /// 結果の反映だけをメインアクターへ戻す。
    func scheduleExistenceRefresh() {
        guard !isRefreshingExistence else {
            // 走行中に来た要求は捨てずに覚えておき、完了後にもう一度走らせる
            // (理由はRecentFilesStore.scheduleRefresh()の同種のコメント参照)。
            needsAnotherExistenceRefresh = true
            return
        }
        isRefreshingExistence = true
        // ここで読むのはSwiftDataのモデルなので、メインアクターにいるうちに
        // 「Sendableな値(UUIDとData)」へ写し取ってから外へ渡す。
        let items = allFavoriteBooks().map { (id: $0.id, bookmark: $0.bookmarkData) }
        guard !items.isEmpty else {
            isRefreshingExistence = false
            if !existenceByFavoriteID.isEmpty { existenceByFavoriteID = [:] }
            return
        }
        // [weak self]で受けたselfを、awaitをまたぐ前にguard letで強参照へ変換しておく
        // (理由はRecentFilesStore.scheduleRefresh()の同種のコメント参照)。
        Task.detached(priority: .utility) { [weak self] in
            var result: [UUID: Bool] = [:]
            for item in items {
                result[item.id] = FavoritesStore.fileExists(bookmark: item.bookmark)
            }
            guard let self else { return }
            await self.finishExistenceRefresh(result)
        }
    }

    private func finishExistenceRefresh(_ result: [UUID: Bool]) {
        isRefreshingExistence = false
        defer {
            if needsAnotherExistenceRefresh {
                needsAnotherExistenceRefresh = false
                scheduleExistenceRefresh()
            }
        }
        // @Publishedは値が同じでも代入のたびに発火するため、変化したときだけ代入する。
        // さらに、この確認はアプリのアクティブ化・ボリュームの抜き差しで**利用者の操作とは
        // 無関係に**終わるため、メニューバーのメニューが開いている間は反映を保留する
        // (お気に入りメニューの各項目の見た目がここで変わる。詳細はMenuBarMenuGateの
        // 型コメント参照)。
        guard result != existenceByFavoriteID else { return }
        MenuBarMenuGate.shared.run("FavoritesStore.existence") { [weak self] in
            guard let self, result != self.existenceByFavoriteID else { return }
            self.existenceByFavoriteID = result
        }
    }

    /// ブックマークデータからURLを解決する。メインアクターの外から呼べるよう`nonisolated`を
    /// 明示している(このプロジェクトの既定のアクター隔離はMainActorのため。
    /// Services/ArchiveReading.swift冒頭のコメント参照)。
    nonisolated static func resolvedURL(fromBookmark data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// ブックマークデータが指す実体がまだ存在するかどうか。`nonisolated`の理由は上と同じ。
    nonisolated static func fileExists(bookmark data: Data) -> Bool {
        guard let url = resolvedURL(fromBookmark: data) else { return false }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// ルート直下のフォルダ・お気に入りを読み込み直す。フォルダの中身(children/books)は
    /// SwiftDataのリレーションシップ経由でその都度取得できるため、ここでは読み込まない。
    /// - Parameter publishOnlyWhenChanged: trueにすると、フェッチ結果が現在の値と同じときは
    ///   @Publishedへの代入自体を行わない。
    ///
    ///   バグ修正(ユーザー報告): @Publishedは値が同じでも代入のたびにobjectWillChangeを発火する。
    ///   このreload()はメニューバーの追跡開始のたびに呼ばれるため、既定のまま(=毎回発火)だと、
    ///   メニューが表示されている最中にSwiftUIがメニューバーを組み立て直すことになり、
    ///   AppKitのメニュー更新・検証パスと競合して未完成のメニューが表示される一因になっていた
    ///   (詳細はRecentFilesStore.init()のactivationObserverまわりのコメント、および
    ///   MenuBarMenuGateの型コメント参照)。
    ///
    ///   既定をfalseにしてあるのは、このreload()がお気に入りの追加・削除・並べ替えなど
    ///   「書き込んだ直後にUIを更新する」用途からも多数呼ばれているため。ルート直下の配列が
    ///   同一でも、その中身(フォルダの子要素など)が変わっているケースがあり、そこでは従来どおり
    ///   無条件に発火させる必要がある。
    func reload(publishOnlyWhenChanged: Bool = false) {
        // メニュートラッキング開始時の保険的な呼び出し(万一の取りこぼし対策)も含めて、
        // reload()が呼ばれたときは全件フェッチキャッシュも合わせて無効化しておく。
        invalidateFavoritesLookupCaches()

        let folderDescriptor = FetchDescriptor<FavoriteFolder>(
            predicate: #Predicate<FavoriteFolder> { $0.parent == nil }
        )
        let newRootFolders = sorted((try? modelContext.fetch(folderDescriptor)) ?? [])
        let bookDescriptor = FetchDescriptor<FavoriteBook>(
            predicate: #Predicate<FavoriteBook> { $0.folder == nil }
        )
        let newRootBooks = sorted((try? modelContext.fetch(bookDescriptor)) ?? [])

        // フェッチ自体は今すぐ行うが、@Publishedへの反映は**メニューバーのメニューが開いて
        // いる間は保留する**。この2つの配列はそのままメニューバーの「お気に入り」メニューの
        // 項目(FavoritesMenuContent)になるため、開いている最中に変わるとmacOS 26では
        // メニューの再構築でアプリが落ちる(詳細はMenuBarMenuGateの型コメント参照)。
        // お気に入りの追加・削除など利用者の操作による呼び出しでは、その操作の時点で
        // メニューは閉じているため、これまでどおり即座に反映される。
        MenuBarMenuGate.shared.run("FavoritesStore.roots") { [weak self] in
            guard let self else { return }
            if !publishOnlyWhenChanged || newRootFolders != self.rootFolders {
                self.rootFolders = newRootFolders
            }
            if !publishOnlyWhenChanged || newRootBooks != self.rootBooks {
                self.rootBooks = newRootBooks
            }
        }
    }

    /// 絞り込み無しの全FavoriteFolderを返す(キャッシュがあれば再利用)。
    private func allFavoriteFolders() -> [FavoriteFolder] {
        if let cachedFolders { return cachedFolders }
        let fetched = (try? modelContext.fetch(FetchDescriptor<FavoriteFolder>())) ?? []
        cachedFolders = fetched
        return fetched
    }

    /// 絞り込み無しの全FavoriteBookを返す(キャッシュがあれば再利用)。
    private func allFavoriteBooks() -> [FavoriteBook] {
        if let cachedBooks { return cachedBooks }
        let fetched = (try? modelContext.fetch(FetchDescriptor<FavoriteBook>())) ?? []
        cachedBooks = fetched
        return fetched
    }

    /// お気に入りに登録されている本のbookID一覧(フォルダ階層を無視したフラットな集合)。
    ///
    /// 「メタデータの編集」ウインドウが「このアプリが知っている本」を横断的に集める際に使う。
    /// CLAUDE.mdの方針どおり、お気に入りのデータへはこのストアの公開APIだけを経由して
    /// アクセスさせるため、呼び出し側がFavoriteBookを直接フェッチせずに済むよう用意している
    /// (フォルダ階層をたどるsubfolders(of:)/books(in:)の再帰では、この用途に対して
    /// 無駄が多いうえ階層構造への依存が生まれる)。
    func allRegisteredBookIDs() -> Set<String> {
        Set(allFavoriteBooks().map(\.bookID))
    }

    /// 指定した本がお気に入りに登録されている件数(複数フォルダへの重複登録がありうるため件数)。
    /// 「本ごとの保存データを削除」ウインドウのインジケータ表示に使う。
    func favoriteCount(forBookID bookID: String) -> Int {
        existingFavorites(forBookID: bookID).count
    }

    /// この本を指すセキュリティスコープ付きブックマークのうち、最初に見つかったもの
    /// (BookmarkStore.anyBookmarkData(forBookID:)と同じ用途)。
    func anyBookmarkData(forBookID bookID: String) -> Data? {
        existingFavorites(forBookID: bookID).first?.bookmarkData
    }

    /// FavoriteFolder/FavoriteBookをinsert/deleteするたびに直後で呼ぶ。
    private func invalidateFavoritesLookupCaches() {
        cachedFolders = nil
        cachedBooks = nil
    }

    /// 指定したフォルダの直下のサブフォルダ一覧(sortOptionの並び順)。nilを渡すとルート直下を返す。
    func subfolders(of folder: FavoriteFolder?) -> [FavoriteFolder] {
        guard let folder else { return rootFolders }
        return sorted(folder.children)
    }

    /// 指定したフォルダの直下のお気に入り一覧(sortOptionの並び順)。nilを渡すとルート直下を返す。
    func books(in folder: FavoriteFolder?) -> [FavoriteBook] {
        guard let folder else { return rootBooks }
        return sorted(folder.books)
    }

    /// 指定したフォルダ直下のサブフォルダ・お気に入りをまとめて1つの並びにしたもの。
    /// メニューバー・ツールバーのサブメニュー、「お気に入りの整理」ウインドウの詳細ペインは、
    /// どちらもこのメソッドの結果をそのまま描画するだけでよい(呼び出し側でswitchして
    /// フォルダ/お気に入りそれぞれの見た目を出し分ける)。
    ///
    /// foldersAlwaysOnTopがtrueの場合は「フォルダ一覧(sortOption順) → お気に入り一覧
    /// (sortOption順)」という従来通りの見た目に、falseの場合はフォルダ・お気に入りを
    /// 区別せずsortOptionの基準だけで混在させた1つの並びになる。
    func entries(in folder: FavoriteFolder?) -> [FavoriteListEntry] {
        let folders = subfolders(of: folder)
        let books = books(in: folder)
        if foldersAlwaysOnTop {
            return folders.map { .folder($0) } + books.map { .book($0) }
        }
        var entries: [FavoriteListEntry] = folders.map { .folder($0) } + books.map { .book($0) }
        switch sortOption {
        case .nameAscending:
            entries.sort { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
        case .nameDescending:
            entries.sort { $0.sortName.localizedStandardCompare($1.sortName) == .orderedDescending }
        case .dateAddedAscending:
            entries.sort { $0.dateAdded < $1.dateAdded }
        case .dateAddedDescending:
            entries.sort { $0.dateAdded > $1.dateAdded }
        case .dateUpdatedAscending:
            entries.sort { $0.dateUpdated < $1.dateUpdated }
        case .dateUpdatedDescending:
            entries.sort { $0.dateUpdated > $1.dateUpdated }
        }
        return entries
    }

    // MARK: - 並び順(sortOption)の適用

    /// フォルダ一覧を現在のsortOptionに従って並べ替える。
    /// ファイル名相当としてfolder.nameを、追加日時相当としてfolder.createdAtを使う
    /// (FavoriteBookのtitle/addedAtと対になる考え方)。
    private func sorted(_ folders: [FavoriteFolder]) -> [FavoriteFolder] {
        switch sortOption {
        case .nameAscending:
            return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateAddedAscending:
            return folders.sorted { $0.createdAt < $1.createdAt }
        case .dateAddedDescending:
            return folders.sorted { $0.createdAt > $1.createdAt }
        case .dateUpdatedAscending:
            return folders.sorted { $0.updatedAt < $1.updatedAt }
        case .dateUpdatedDescending:
            return folders.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// お気に入り一覧を現在のsortOptionに従って並べ替える。
    /// ファイル名の比較にはlocalizedStandardCompareを使う(数字を含む名前を「2, 10」のように
    /// 自然な順序で扱う、Finderのファイル名ソートと同じ挙動)。
    private func sorted(_ books: [FavoriteBook]) -> [FavoriteBook] {
        switch sortOption {
        case .nameAscending:
            return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .nameDescending:
            return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .dateAddedAscending:
            return books.sorted { $0.addedAt < $1.addedAt }
        case .dateAddedDescending:
            return books.sorted { $0.addedAt > $1.addedAt }
        case .dateUpdatedAscending:
            return books.sorted { $0.updatedAt < $1.updatedAt }
        case .dateUpdatedDescending:
            return books.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    // MARK: - 件数・階層の上限チェック

    func totalFavoritesCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<FavoriteBook>())) ?? 0
    }

    /// parentの直下に新しいフォルダを作ってよいか(階層の上限を超えないか)。
    func canCreateSubfolder(in parent: FavoriteFolder?) -> Bool {
        let parentDepth = parent?.depth ?? 0
        return parentDepth + 1 <= FavoritesLimits.maxFolderDepth
    }

    // MARK: - フォルダの作成・リネーム・削除・移動

    @discardableResult
    func createFolder(name: String, parent: FavoriteFolder?) -> Result<FavoriteFolder, FavoritesLimitError> {
        guard canCreateSubfolder(in: parent) else {
            return .failure(.folderDepthLimitReached)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let siblingCount = subfolders(of: parent).count
        let folder = FavoriteFolder(
            name: trimmed.isEmpty ? String(localized: "Untitled Folder", language: AppLanguage.currentLocale) : trimmed,
            parent: parent,
            sortOrder: siblingCount
        )
        modelContext.insert(folder)
        // 新しいサブフォルダが増えたぶん、親フォルダの中身が変わったとみなしupdatedAtを更新する
        // (並び替え基準「更新順」用。詳細はFavoriteFolder.updatedAtのコメント参照)。
        parent?.updatedAt = Date()
        try? modelContext.save()
        reload()
        return .success(folder)
    }

    func rename(_ folder: FavoriteFolder, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        try? modelContext.save()
        reload()
    }

    /// フォルダを削除する。配下のサブフォルダ・お気に入りも連鎖して削除される
    /// (FavoriteFolder.children/booksのdeleteRule: .cascade参照)。
    func delete(_ folder: FavoriteFolder) {
        // 削除後は親への参照が失われるため、削除前に控えておく。親フォルダの中身が
        // 減ったぶん、その親のupdatedAtを更新する(サブフォルダ自身のupdatedAtは、
        // 消えるだけなので更新する意味がなく触らない)。
        let parentFolder = folder.parent
        modelContext.delete(folder)
        parentFolder?.updatedAt = Date()
        try? modelContext.save()
        reload()
    }

    func delete(_ favorite: FavoriteBook) {
        // フォルダを削除する場合と同じ理由で、削除前に所属フォルダを控えておいてから
        // そのフォルダのupdatedAtを更新する。
        let parentFolder = favorite.folder
        modelContext.delete(favorite)
        parentFolder?.updatedAt = Date()
        try? modelContext.save()
        reload()
    }

    /// お気に入りの表示名(title)を変更する。既定ではファイルパスから取得したファイル名が
    /// そのままtitleとして保存されている(addFavorite/forceAddFavorite参照)ため、実体の
    /// ファイル名と切り離してユーザーが好きな名前を付けられるようにする(rename(_ folder:to:)、
    /// BookmarkStore.renameと同じ考え方・同じ実装パターン)。実体のファイル/フォルダ名や
    /// bookID(重複チェックに使う検索キー)には影響しない。
    func rename(_ favorite: FavoriteBook, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        favorite.title = trimmed
        favorite.updatedAt = Date()
        try? modelContext.save()
        reload()
    }

    /// お気に入りを別のフォルダへ移動する(整理画面でのドラッグ&ドロップから呼ぶ)。
    /// 移動元・移動先どちらのフォルダも中身が変わるためupdatedAtを更新する。移動した
    /// お気に入り自身のupdatedAtも更新するため、並び替え基準を「更新順(古い順)」にしていると
    /// 移動したお気に入りは(以前の登録順と同じく)そのフォルダの一番最後に来る。
    /// 同じフォルダへドロップした場合(実質的に移動していない場合)は何も更新しない。
    func move(_ favorite: FavoriteBook, to folder: FavoriteFolder?) {
        let oldFolder = favorite.folder
        let didMove = oldFolder?.id != folder?.id
        favorite.folder = folder
        favorite.sortOrder = books(in: folder).count
        if didMove {
            let now = Date()
            favorite.updatedAt = now
            oldFolder?.updatedAt = now
            folder?.updatedAt = now
        }
        try? modelContext.save()
        reload()
    }

    /// フォルダを別のフォルダへ移動する。移動先が自分自身・自分の子孫の場合(循環)、または
    /// 移動後に配下も含めて階層の上限を超えてしまう場合は何もせずfalseを返す。
    /// move(_ favorite:to:)と同じ理由で、移動元・移動先の親フォルダのupdatedAtを更新する
    /// (ただし移動されるフォルダ自身の中身は変わっていないため、そちらのupdatedAtは更新しない)。
    @discardableResult
    func move(_ folder: FavoriteFolder, to newParent: FavoriteFolder?) -> Bool {
        var candidate = newParent
        while let c = candidate {
            if c.id == folder.id { return false }
            candidate = c.parent
        }
        let newDepth = (newParent?.depth ?? 0) + 1
        let extraDepth = maxDepth(of: folder) - folder.depth
        guard newDepth + extraDepth <= FavoritesLimits.maxFolderDepth else { return false }

        let oldParent = folder.parent
        let didMove = oldParent?.id != newParent?.id
        folder.parent = newParent
        folder.sortOrder = subfolders(of: newParent).count
        if didMove {
            let now = Date()
            oldParent?.updatedAt = now
            newParent?.updatedAt = now
        }
        try? modelContext.save()
        reload()
        return true
    }

    /// folder自身、およびその配下(再帰的に)の中で一番深いフォルダの深さ。
    private func maxDepth(of folder: FavoriteFolder) -> Int {
        guard !folder.children.isEmpty else { return folder.depth }
        return folder.children.map { maxDepth(of: $0) }.max() ?? folder.depth
    }

    // MARK: - お気に入りの登録

    /// id(UUID)からフォルダを検索する。「お気に入りの整理」ウインドウでのドラッグ&ドロップ
    /// (ドラッグ元の識別子から実体を引き直す)に使う。
    ///
    /// 以前は#Predicate<FavoriteFolder> { $0.id == id }のようにSwiftData側の絞り込みフェッチに
    /// 任せていたが、キャプチャしたローカル変数名がモデル側プロパティ名と同名の場合に絞り込み
    /// フェッチが正しく機能しないことがある不具合が実機で確認された
    /// (LayoutStore.pageOverrides(forBookID:)のコメント参照)。同じ問題を避けるため、
    /// 絞り込み無しで全件取得してからSwift側でfilterする方式に統一する。
    func folder(withID id: UUID) -> FavoriteFolder? {
        allFavoriteFolders().first { $0.id == id }
    }

    /// id(UUID)からお気に入りを検索する(folder(withID:)と同じ用途・同じ理由で全件取得+filter)。
    func book(withID id: UUID) -> FavoriteBook? {
        allFavoriteBooks().first { $0.id == id }
    }

    /// 指定したbookIDで既に登録されているお気に入り一覧(全フォルダ横断)。同じ理由で
    /// 全件取得+filterに統一する。
    func existingFavorites(forBookID bookID: String) -> [FavoriteBook] {
        allFavoriteBooks().filter { $0.bookID == bookID }
    }

    /// ユーザー要望: JSONインポート時、bookID(パス)が食い違っていても同じファイル
    /// (iノード番号)なら「既に登録済み」と判定できるようにしたい(パスは参考情報として
    /// 残すが、インポート時の重複判定には使わないイメージ)。
    func existingFavorites(matching identifier: FileNodeIdentifier) -> [FavoriteBook] {
        allFavoriteBooks().filter { $0.fileNodeIdentifier == identifier }
    }

    /// ユーザー要望(後方互換性): ファイルノード識別子を持たない古いFavoriteBook行(この属性を
    /// 追加する前に作成されたもの)について、ファイルパス(bookID)なら実在が確認できている場合に、
    /// そのパスから改めて識別子を取得して補完する。BookmarkStore/LayoutStoreの同名メソッドと
    /// 同じ考え方(LibraryImportExportService.exportFavoritesが、書き出し対象の本のURLを
    /// 解決できたタイミングで呼ぶ)。
    func backfillFileNodeIdentifier(forBookID bookID: String, identifier: FileNodeIdentifier) {
        let targets = existingFavorites(forBookID: bookID).filter { $0.fileNodeIdentifier == nil }
        guard !targets.isEmpty else { return }
        for favorite in targets {
            favorite.inodeNumber = identifier.inodeNumber
            favorite.volumeDeviceNumber = identifier.volumeDeviceNumber
        }
        try? modelContext.save()
        cachedBooks = nil
    }

    /// 指定したbookIDが(どれか1つでも)お気に入りに登録されているかどうか。ツールバー・
    /// メニューバー・コンテキストメニューの「追加/削除」トグルボタンが、今どちらの見た目・
    /// 動作にすべきかを判定するために使う。
    func isFavorited(bookID: String) -> Bool {
        !existingFavorites(forBookID: bookID).isEmpty
    }

    /// ユーザー要望: お気に入りに登録済みの本が、同一ボリューム内で移動・リネームされた場合でも
    /// お気に入りを引き継げるようにしたい(ボリュームを跨いだ移動は諦める)。
    ///
    /// 現在のbookID(パス)で登録済みのお気に入りが1件でも見つかれば、移動していない(または
    /// 既に追従済み)とみなして何もしない。見つからない場合、この本のファイルノード識別子
    /// (iノード番号+デバイス番号)と一致するお気に入りを探し、見つかればそのbookIDを現在のパスへ
    /// 書き換える(表示名(title)はユーザーが独自にリネームしている可能性があるため触れない)。
    /// AppState.open(url:)から、本を開くたびに呼ばれる想定。
    func reconcileBookIDIfMoved(book: MangaBook) {
        guard existingFavorites(forBookID: book.id).isEmpty else { return }
        guard let identifier = FileNodeIdentifier.current(for: book.sourceURL) else { return }
        let candidates = allFavoriteBooks().filter { $0.bookID != book.id && $0.fileNodeIdentifier == identifier }
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            candidate.bookID = book.id
            candidate.updatedAt = Date()
        }
        try? modelContext.save()
        reload()
    }

    /// 指定したbookIDのお気に入りをすべて削除する(全フォルダ横断)。ツールバー・メニューバー・
    /// コンテキストメニュー・キーボードショートカットの「現在の本をお気に入りから削除」から呼ぶ。
    /// addFavoriteは別フォルダへの重複登録をユーザーが確認の上で許容する(.needsDuplicateConfirmation
    /// → forceAddFavorite)ため、同じ本が複数フォルダに登録されていることがありうる。「現在の本を
    /// お気に入りから削除」はどのフォルダに登録されているかをユーザーに問わない単純な操作として
    /// 用意しているため、該当するものをすべて削除する。
    func removeFavorites(forBookID bookID: String) {
        let favorites = existingFavorites(forBookID: bookID)
        guard !favorites.isEmpty else { return }
        // delete(_ favorite:)を1件ずつ呼ぶと、そのたびに同期save()+reload()が走ってしまう。
        // 同じ本が複数フォルダに登録されている場合、ここでは全件削除した上でsave()/reload()を
        // 1回にまとめる(delete(_ favorite:)と同じく、削除されたお気に入りが元々あった
        // フォルダのupdatedAtは更新する)。
        var touchedFolderIDs: Set<UUID> = []
        let now = Date()
        for favorite in favorites {
            if let parentFolder = favorite.folder, touchedFolderIDs.insert(parentFolder.id).inserted {
                parentFolder.updatedAt = now
            }
            modelContext.delete(favorite)
        }
        try? modelContext.save()
        reload()
    }

    /// お気に入りへの登録を試みる。
    /// - 登録先フォルダに既に同じ本がある場合は、確認なしで内容を上書きする。
    /// - 別のフォルダに既に同じ本がある場合は`.needsDuplicateConfirmation`を返すので、
    ///   呼び出し側でユーザーに確認した上で`forceAddFavorite`を呼び直す。
    /// - どこにも登録されていない場合は、件数上限を確認した上で新規登録する。
    @discardableResult
    func addFavorite(book: MangaBook, to folder: FavoriteFolder?) -> FavoriteAddOutcome {
        let existing = existingFavorites(forBookID: book.id)

        if let sameFolderEntry = existing.first(where: { $0.folder?.id == folder?.id }) {
            guard let bookmarkData = makeBookmarkData(for: book) else { return .failed }
            sameFolderEntry.bookmarkData = bookmarkData
            sameFolderEntry.title = book.title
            try? modelContext.save()
            reload()
            return .overwritten(sameFolderEntry)
        }

        if let otherEntry = existing.first {
            let breadcrumb = otherEntry.folder?.breadcrumb ?? String(localized: "Favorites (Top Level)", language: AppLanguage.currentLocale)
            return .needsDuplicateConfirmation(existingBreadcrumb: breadcrumb)
        }

        return forceAddFavorite(book: book, to: folder)
    }

    /// 別フォルダに既に登録済みであることをユーザーに確認した上で、それでも登録する場合に呼ぶ。
    /// (addFavoriteが`.needsDuplicateConfirmation`を返した後、確認ダイアログでユーザーが
    /// 「登録する」を選んだときに呼び出す)
    @discardableResult
    func forceAddFavorite(book: MangaBook, to folder: FavoriteFolder?) -> FavoriteAddOutcome {
        guard totalFavoritesCount() < FavoritesLimits.maxFavoritesCount else {
            return .limitReached
        }
        guard let bookmarkData = makeBookmarkData(for: book) else { return .failed }

        let favorite = FavoriteBook(
            bookID: book.id,
            bookmarkData: bookmarkData,
            title: book.title,
            folder: folder,
            sortOrder: books(in: folder).count,
            fileNodeIdentifier: FileNodeIdentifier.current(for: book.sourceURL)
        )
        modelContext.insert(favorite)
        // 新しいお気に入りが増えたぶん、登録先フォルダの中身が変わったとみなしupdatedAtを
        // 更新する(createFolderと同じ理由。ルート直下(folder == nil)の場合は対象となる
        // フォルダオブジェクトが存在しないため何もしない)。
        folder?.updatedAt = Date()
        try? modelContext.save()
        reload()
        return .added(favorite)
    }

    /// JSONインポート専用: 複数のお気に入りをまとめて登録する
    /// (LibraryImportExportService.applyFavorites参照)。
    struct BulkFavoriteRequest {
        let book: MangaBook
        let folder: FavoriteFolder?
    }

    /// forceAddFavoritesの1件ごとの結果。addFavorite/forceAddFavoriteのFavoriteAddOutcomeと
    /// 異なり、一括登録では「別フォルダへの重複確認」は発生しない(呼び出し側の
    /// LibraryImportExportServiceは常にforceAddFavorite相当=確認なしで登録する経路のみを使う
    /// ため)。
    enum BulkFavoriteOutcome {
        case added
        case limitReached
        case failed
    }

    /// forceAddFavoriteを本の件数ぶん個別に呼ぶと、そのたびに同期save()+reload()が走ってしまう
    /// (removeFavorites(forBookID:)のコメントと同じ理由。ユーザー報告: JSONインポートが非常に
    /// 遅く、Xcodeのコンソールを見る限りJSONを1行読むたびにSQLiteへの書き込みが起きているように
    /// 見える、との指摘を受けての対応)。件数上限チェック・ブックマークデータ生成・sortOrder割当
    /// (登録先フォルダ内の既存件数+このバッチ内で同じフォルダへ既に割り当てた件数)は1件ごとに
    /// 行うが、保存・再フェッチはこの一括登録全体を通して1回にまとめる。
    @discardableResult
    func forceAddFavorites(_ requests: [BulkFavoriteRequest]) -> [BulkFavoriteOutcome] {
        guard !requests.isEmpty else { return [] }
        var results: [BulkFavoriteOutcome] = []
        results.reserveCapacity(requests.count)
        var currentCount = totalFavoritesCount()
        // books(in:)はSwiftDataのリレーションシップ(folder.books)を参照するため、このバッチ内で
        // まだsave()していない新規insertを反映しない可能性がある。フォルダごとの次のsortOrderを
        // ローカルにキャッシュし、割り当てるたびにインクリメントすることで、
        // forceAddFavoriteを1件ずつ呼んだ場合と同じ連番になるようにする。
        var nextSortOrderByFolderID: [UUID?: Int] = [:]
        var touchedFolders: [ObjectIdentifier: FavoriteFolder] = [:]
        let now = Date()

        for request in requests {
            guard currentCount < FavoritesLimits.maxFavoritesCount else {
                results.append(.limitReached)
                continue
            }
            guard let bookmarkData = makeBookmarkData(for: request.book) else {
                results.append(.failed)
                continue
            }
            let folderKey = request.folder?.id
            let sortOrder = nextSortOrderByFolderID[folderKey] ?? books(in: request.folder).count
            nextSortOrderByFolderID[folderKey] = sortOrder + 1

            let favorite = FavoriteBook(
                bookID: request.book.id,
                bookmarkData: bookmarkData,
                title: request.book.title,
                folder: request.folder,
                sortOrder: sortOrder,
                fileNodeIdentifier: FileNodeIdentifier.current(for: request.book.sourceURL)
            )
            modelContext.insert(favorite)
            if let folder = request.folder {
                touchedFolders[ObjectIdentifier(folder)] = folder
            }
            currentCount += 1
            results.append(.added)
        }

        for folder in touchedFolders.values {
            folder.updatedAt = now
        }
        try? modelContext.save()
        reload()
        return results
    }

    private func makeBookmarkData(for book: MangaBook) -> Data? {
        try? book.sourceURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    // MARK: - 開く前のURL解決・存在確認

    /// 保存済みのブックマークからURLを解決する(実際にファイル/フォルダが存在するかまでは確認しない)。
    func resolvedURL(for favorite: FavoriteBook) -> URL? {
        Self.resolvedURL(fromBookmark: favorite.bookmarkData)
    }

    /// ユーザー要望: JSONインポート(LibraryImportExportService)時、ファイルパスが古くなって
    /// いても、ファイルノード識別子(iノード番号)を手がかりに、ローカルに既に保存されている
    /// セキュリティスコープ付きブックマークから現在の実際のURLを解決できるようにしたい。
    /// 一致する登録が複数ある場合は、実際に解決できた最初の1件を返す。
    func resolvedURL(matching identifier: FileNodeIdentifier) -> URL? {
        for favorite in allFavoriteBooks() where favorite.fileNodeIdentifier == identifier {
            if let url = resolvedURL(for: favorite) { return url }
        }
        return nil
    }

    /// 開く直前に使う便利メソッド。ブックマークの解決と存在確認の両方が成功した場合にのみURLを返す
    /// (要望5: 開く前の存在チェック)。呼び出し側(AppState.openFavorite、
    /// QooViewerApp.openFavorite(_:asTab:))は、これがnilを返した場合に
    /// 「見つかりません。お気に入りから削除しますか?」というアラートを表示する。
    func resolvedExistingURL(for favorite: FavoriteBook) -> URL? {
        guard let url = resolvedURL(for: favorite) else { return nil }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - 一括削除(環境設定「リセット」タブ)

    /// お気に入り(フォルダ・登録した本)をすべて削除する。JSONインポートで
    /// お気に入りに「上書き」を選んだときに、取り込みの前段として呼ばれる
    /// (LibraryImportExportService.applyFavorites参照。環境設定「リセット」タブの
    /// 「すべて削除」はここを通らず、ストアの実ファイルごと消す。ResetDataSettingsView参照)。
    ///
    /// バグ修正(2026-09-06、qooViewerTestsのメモリ内コンテナで発見): 以前は
    /// `try? modelContext.delete(model: FavoriteBook.self)`(述語なしの一括削除)を使っていたが、
    /// **FavoriteBook.folderがFavoriteFolder.books(deleteRule: .cascade)のmandatoryな逆リレーション
    /// であるため、SwiftDataのバッチ削除が全件ぶん失敗する**
    /// (`Constraint trigger violation: Batch delete failed due to mandatory OTO nullify inverse on
    /// FavoriteBook/folder`)。エラーはtry?で握り潰され、実際に消えていたのは続く
    /// FavoriteFolderの削除によるカスケード=**フォルダの中の本だけ**で、ルート直下
    /// (folder == nil)のお気に入りは残っていた。「上書きで取り込んだのに古い登録が残る」。
    ///
    /// 行をフェッチして1件ずつdelete(_:)すればこの制約には触れない。件数の上限は
    /// FavoritesLimits.maxFavoritesCount(999件)で、1回きりの操作でもあるため速度の心配は無い。
    func deleteAllFavorites() {
        for favorite in (try? modelContext.fetch(FetchDescriptor<FavoriteBook>())) ?? [] {
            modelContext.delete(favorite)
        }
        // 本を先に消してあるので、ここでのカスケードは実質フォルダの親子関係だけを辿る。
        for folder in (try? modelContext.fetch(FetchDescriptor<FavoriteFolder>())) ?? [] {
            modelContext.delete(folder)
        }
        try? modelContext.save()
        reload()
    }

    /// ウェルカム画面の「最近お気に入りに追加したファイル」用。登録日時が新しい順に、
    /// 実際に存在するものだけを最大limit件返す。
    /// バグ修正(ユーザー報告と同じ構図): これはウェルカム画面のbody評価中に呼ばれる。
    /// 以前はここで全お気に入りぶんのブックマーク解決と存在確認を同期実行しており、
    /// 外付け/ネットワークボリューム上のお気に入りがあるとウェルカム画面の描画が丸ごと
    /// 止まっていた。現在は、実体確認はキャッシュ(existenceByFavoriteID)を読むだけにし、
    /// 一覧の取得もキャッシュ済みのallFavoriteBooks()から行う(SwiftDataのfetchも起きない)。
    func recentFavorites(limit: Int) -> [FavoriteBook] {
        var result: [FavoriteBook] = []
        for favorite in allFavoriteBooks().sorted(by: { $0.addedAt > $1.addedAt })
        where cachedFileExists(for: favorite) {
            result.append(favorite)
            if result.count >= limit { break }
        }
        return result
    }
}
