import Foundation
import SwiftData
import AppKit
import Combine

/// 「ブックマークの編集」ウインドウの左ペインに表示する、1冊分のまとめ。
///
/// Equatableに準拠させているのは、BookmarkStore.rebuildGroups(publishOnlyWhenChanged:)で
/// 「本当に中身が変わったときだけ@Publishedへ代入する」判定に使うため。
struct BookmarkBookGroup: Identifiable, Equatable {
    let bookID: String
    /// この本に付いているブックマークの件数(左ペインの行に表示する)。
    let count: Int
    /// 並び替え基準「追加日時」に使う。この本に属するブックマークのうちもっとも古いcreatedAt
    /// (=この本に最初にブックマークを付けた日時)。BookmarkStore.bookSortOption参照。
    let earliestCreatedAt: Date
    /// 並び替え基準「更新日時」に使う。この本に属するブックマークのうちもっとも新しいupdatedAt
    /// (=この本のブックマークの中で、直近に追加・リネームがあった日時)。
    /// BookmarkStore.bookSortOption参照。
    let latestUpdatedAt: Date

    /// 表示用の本の名前。Bookmarkにはタイトルが保存されておらず、bookID(パス)しか
    /// 持たないため、パスの最後の部分から生成する(RecentFilesStore.Entry.displayNameと
    /// 同じ考え方。実体のファイル/フォルダが後からリネームされていた場合、この表示名は
    /// リネーム前のままになりうるが、お気に入りと違い「開く」機能を持たないブックマーク編集では
    /// これで十分と判断した)。
    ///
    /// 以前は計算プロパティとして参照のたびに生成していたが、この値は左ペインの並べ替え
    /// (sortedGroups)の比較関数の中から読まれるため、1回のソートでO(N log N)回ぶんの
    /// URL構築+パス操作が発生していた(sampleによる実測で判明)。行を作る時点で1回だけ
    /// 計算して保持する。
    let displayName: String

    var id: String { bookID }

    init(bookID: String, count: Int, earliestCreatedAt: Date, latestUpdatedAt: Date) {
        self.bookID = bookID
        self.count = count
        self.earliestCreatedAt = earliestCreatedAt
        self.latestUpdatedAt = latestUpdatedAt
        self.displayName = URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent
    }
}

/// ブックマーク(Bookmark.swift)の永続化・操作を、特定の本に限らず横断的に担当する。
///
/// 以前はブックマークの一覧・編集は「今開いている本」のものだけをViewerViewModel経由で
/// 扱っていたが、「ブックマークの編集」ウインドウをお気に入りの編集ウインドウと同じ2ペイン構成
/// (左: 本の一覧、右: 選択中の本のブックマーク一覧)にする際、すべての本を横断して編集できる
/// 必要が生じたため、FavoritesStoreと同じ考え方でこのストアを新設した。
///
/// 開いている本のViewerViewModelも同じSwiftData ModelContext(modelContainer.mainContext。
/// QooViewerApp.init()参照)を介して同じBookmarkを参照するため、一方の変更をもう一方にも
/// 伝える必要がある。これは個別のクロージャではなくNotification.Name.bookmarksDidChangeの
/// 送受信で行う(詳細はBookmark.swiftのコメント参照。「今読んでいる本」を1つに絞れる
/// FavoritesStoreの「現在の本を追加」ボタンと違い、こちらは開いているすべての本の
/// ViewerViewModelと同期を取る必要があるため、AppState経由の個別のクロージャではなく通知の
/// 形にしている。なお、ModelContextを単一に統一した後も、このObservableObjectが持つ
/// キャッシュ(groups/cachedBookmarks)自体はSwiftDataが自動的に再フェッチしてくれるわけでは
/// ないため、この通知ベースのreload()の仕組みは引き続き必要)。
@MainActor
final class BookmarkStore: ObservableObject {
    /// 本ごとにグループ化した一覧。bookSortOptionに従って並べる(既定は表示名の自然順=
    /// Finderと同じ)。
    @Published private(set) var groups: [BookmarkBookGroup] = []

    /// 選択中の本のブックマーク一覧を並べる基準。FavoritesSortOptionをそのまま流用する
    /// (名前・追加日時・更新日時の3種類、それぞれ昇順・降順。詳細はFavoritesSortOption.swift
    /// のコメント参照。以前あった「ページ番号」ソートは、お気に入りの編集画面と表記・挙動を
    /// 完全に揃えるため廃止した)。
    ///
    /// 左ペイン(本一覧)の並び替え基準はbookSortOptionとして別に持つ(要望: 左ペインも右ペインと
    /// 同じルールでソートしたいが、「本を選び替えるたびにブックマークの並びまで変わる」体験は
    /// 避けたいため、2つのペインで独立に切り替えられるようにした)。
    @Published var sortOption: FavoritesSortOption {
        didSet {
            guard sortOption != oldValue else { return }
            UserDefaults.standard.set(sortOption.rawValue, forKey: Self.sortOptionDefaultsKey)
            // groups自体の並びには関与しないためreload()は不要。bookmarks(forBookID:)は
            // 呼び出しの都度この値を見て並べ替えるだけなので、@Publishedによる再描画だけで
            // 画面には反映される(FavoritesStore.foldersAlwaysOnTopと同じ考え方)。
        }
    }

    /// 左ペイン(本一覧)を並べる基準。sortOptionと同じFavoritesSortOptionを使うが、値は独立に
    /// 保持・永続化する(上記sortOptionのコメント参照)。
    @Published var bookSortOption: FavoritesSortOption {
        didSet {
            guard bookSortOption != oldValue else { return }
            UserDefaults.standard.set(bookSortOption.rawValue, forKey: Self.bookSortOptionDefaultsKey)
            // 以前はここでgroups自体も並べ替え直していた(groupsは既にearliestCreatedAt/
            // latestUpdatedAtを持っているため再フェッチは不要、という理由)。しかしgroupsの
            // 並び順を利用している箇所は実際には無く(左ペインのBookmarkEditorView.mergedRowsは
            // bookIDをキーにした辞書へ詰め替えたうえでfilteredSortedRows側で並べ直す。
            // EPUB/PDF出力ウインドウとJSON書き出しはいずれもbookIDの集合としてしか使わない)、
            // ここでの並べ替えは表示に何ら影響しないまま、@Publishedの発火(=このストアを
            // 参照している画面の再評価)を1回余計に起こしていただけだった。
            // 並び替えのドロップダウンを操作するたびに、この余計な更新と左ペイン自身の
            // 並べ替えとで2回ぶんの更新が走る形になっていたため、こちらは取りやめる。
        }
    }

    private static let sortOptionDefaultsKey = "qooViewer.pref.bookmarkSortOption"
    private static let bookSortOptionDefaultsKey = "qooViewer.pref.bookmarkBookSortOption"

    private let modelContext: ModelContext

    /// Bookmarkの絞り込み無し全件フェッチ結果を、bookIDで引ける形にしたキャッシュ。
    /// bookmarks(forBookID:)等が呼ばれるたびにmodelContext.fetch()をやり直さずに済むようにする。
    /// nilは「キャッシュ未構築(次回読み取り時にフェッチが必要)」を表す。
    ///
    /// このストア自身の書き込み(add/rename/delete等)は、フェッチし直すのではなくこのキャッシュへ
    /// 直接差分を反映する。一方、開いている本のViewerViewModelが同じModelContext経由で直接
    /// 書き込んだ場合は、その変更をこのストアは知らないため、bookmarksDidChange通知を受けた
    /// reload()が実フェッチでキャッシュごと作り直す(reload()のコメント参照)。
    ///
    /// 経緯: 以前は`[Bookmark]`の平坦な配列で持ち、書き込みのたびにreload()で全件フェッチ+
    /// 全体の再グループ化をやり直していた。ブックマークを1件追加するだけでもBookmarkテーブル
    /// 全体のフェッチとSwiftDataオブジェクトの再生成が起きるため、ブックマークを持つ本が増える
    /// ほど1回の操作が重くなっていく。書き込んだぶんだけをキャッシュへ反映し、groupsは
    /// フェッチ無しでこのキャッシュから組み直す形に変えた(rebuildGroups()参照)。
    private var cachedBookmarksByBookID: [String: [Bookmark]]?

    /// 他のウインドウ(開いている本、または別の「ブックマークの編集」ウインドウ)での変更を
    /// 都度反映するための監視トークン。
    private var changeObserver: NSObjectProtocol?
    /// メニューが開かれる直前にも念のため再読み込みする(FavoritesStore/RecentFilesStoreと
    /// 同じ理由の保険。通常はbookmarksDidChangeの送受信だけで同期が取れるはずだが、
    /// 万一取りこぼした場合の保険として残しておく)。
    private var menuTrackingObserver: NSObjectProtocol?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.sortOption = FavoritesSortOption(
            rawValue: UserDefaults.standard.string(forKey: Self.sortOptionDefaultsKey) ?? ""
        ) ?? .nameAscending
        self.bookSortOption = FavoritesSortOption(
            rawValue: UserDefaults.standard.string(forKey: Self.bookSortOptionDefaultsKey) ?? ""
        ) ?? .nameAscending
        reload()

        // queue: .mainを指定しているため実行時には必ずMainActor上で呼ばれるが、クロージャ自体の
        // 型はMainActorに分離されていないため、コンパイラは静的にそれを保証できない
        // (「main actor-isolated instance method 'reload()' ... implicitly asynchronous」という
        // 警告になる)。Task { @MainActor in ... }で包み直すと今度はselfのキャプチャに関する
        // 別の警告/エラーになるため、MainActor.assumeIsolatedで「実行時には既にMainActor上に
        // いる」ことを伝える(ViewerViewModel.swiftの同種のコメント参照)。
        changeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 自分自身が投げた通知は無視する。このストアの書き込みメソッドは、投げる前に
                // 既にキャッシュとgroupsを更新し終えているため、ここで受け取って更に
                // reload()(全件フェッチ)まで走らせると、1回の書き込みにつき2回リロードして
                // いることになる(通知はobject: selfで投げているのに、購読側はobject: nil=
                // 送信元を問わずすべて受け取っていたため)。他の送信元(開いている本の
                // ViewerViewModel)からの通知は従来どおり実フェッチで取り込む必要がある。
                guard (notification.object as AnyObject?) !== self else { return }
                self.reload()
            }
        }
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                // メニューバーのメニュー以外(ウインドウ内のPicker/Menuのドロップダウンなど)では
                // 何もしない。詳細はMenuBarTracking.isMainMenu(_:)のコメント参照。
                guard MenuBarTracking.isMainMenu(notification) else { return }
                // メニューバーを開くたびに走る経路なので、中身が変わったときだけ@Publishedを
                // 発火させる(理由はrebuildGroups(publishOnlyWhenChanged:)のコメント参照)。
                self?.reload(publishOnlyWhenChanged: true)
            }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        if let menuTrackingObserver {
            NotificationCenter.default.removeObserver(menuTrackingObserver)
        }
    }

    /// すべてのブックマークをbookIDごとにグループ化し直す。
    ///
    /// 以前は、EPUBの目次/PDFのアウトラインから自動的に取り込んだブックマーク
    /// (Bookmark.isEpubDerived == true)をこのストアの一覧から除外していた(「ブックマーク・
    /// レイアウトの編集」ウインドウにはユーザーが明示的に作成したものだけを出すべき、という
    /// 当時のご要望による)。ユーザー要望による方針転換で、EPUB/PDFの情報は初回オープン時に
    /// DBへ取り込み、以降はDB上の情報に従う(=取り込み後はユーザー作成のものと同等に扱う)
    /// 扱いへ変更したため、この除外は廃止した。
    /// isEpubDerived属性そのものは、自動取り込みが1冊につき1回で済んでいるかの判別材料として
    /// 残してある(Bookmark.swiftのコメント参照)。
    func reload(publishOnlyWhenChanged: Bool = false) {
        // このストアの外(開いている本のViewerViewModelが同じModelContext経由で直接書き込んだ
        // 場合)での変更を取り込むための経路。そちらの変更はこのストアのキャッシュに反映され
        // ようがないため、ここは必ず実フェッチでキャッシュごと作り直す(キャッシュを鵜呑みに
        // しない)。このストア自身の書き込みは、フェッチ不要のrebuildGroups()の側を使う。
        cachedBookmarksByBookID = nil
        _ = bookmarksByBookID()
        rebuildGroups(publishOnlyWhenChanged: publishOnlyWhenChanged)
    }

    /// bookID → その本のBookmark(順不同、EPUB自動取り込み分も含む)。
    private func bookmarksByBookID() -> [String: [Bookmark]] {
        if let cachedBookmarksByBookID { return cachedBookmarksByBookID }
        let fetched = (try? modelContext.fetch(FetchDescriptor<Bookmark>())) ?? []
        let grouped = Dictionary(grouping: fetched, by: \.bookID)
        cachedBookmarksByBookID = grouped
        return grouped
    }

    /// 左ペインの一覧(groups)を、SwiftDataへ問い合わせずキャッシュだけから組み直す。
    /// このストア自身の書き込みメソッドが、キャッシュへ差分を反映した後に呼ぶ。
    private func rebuildGroups(publishOnlyWhenChanged: Bool = false) {
        let unsorted = bookmarksByBookID().compactMap { bookID, bookmarks -> BookmarkBookGroup? in
            let visible = bookmarks
            guard !visible.isEmpty else { return nil }
            // 「追加日時」はこの本に最初にブックマークを付けた日時(=最小のcreatedAt)、
            // 「更新日時」はこの本のブックマークの中で直近に変更があった日時(=最大のupdatedAt)
            // として扱う(BookmarkBookGroupのコメント参照)。visibleが1件以上あることは上で
            // 確認済みのためmin()/max()がnilになることはないが、念のためDate()にフォールバック
            // しておく。
            return BookmarkBookGroup(
                bookID: bookID,
                count: visible.count,
                earliestCreatedAt: visible.map(\.createdAt).min() ?? Date(),
                latestUpdatedAt: visible.map(\.updatedAt).max() ?? Date()
            )
        }
        let newGroups = Self.sortedGroups(unsorted, by: bookSortOption)
        // バグ修正(ユーザー報告): @Publishedは値が同じでも代入のたびにobjectWillChangeを
        // 発火する。メニューバーの追跡開始のたびに発火させると、メニューが表示されている最中に
        // SwiftUIがメニューバーを組み立て直すことになり、AppKitのメニュー更新・検証パスと
        // 競合して未完成のメニューが表示される一因になっていた(詳細はRecentFilesStore.init()の
        // menuTrackingObserverのコメント参照)。既定をfalseにしてあるのは、ブックマークの
        // 追加・削除・リネーム直後のUI更新にもこの経路が使われているため。
        if !publishOnlyWhenChanged || newGroups != groups {
            groups = newGroups
        }
    }

    /// 絞り込み無しの全Bookmark(順不同)。特定のbookIDに閉じない横断的な検索(ファイルノード
    /// 識別子での照合など)にだけ使う。bookIDが分かっている場合はbookmarksByBookID()を使うこと。
    private func allBookmarks() -> [Bookmark] {
        bookmarksByBookID().values.flatMap { $0 }
    }

    /// 新規insertしたBookmarkをキャッシュへ反映する(キャッシュ未構築なら何もしない。次回の
    /// 読み取り時にフェッチで拾われるため)。
    private func cacheInsertedBookmarks(_ inserted: [Bookmark], forBookID bookID: String) {
        guard cachedBookmarksByBookID != nil, !inserted.isEmpty else { return }
        cachedBookmarksByBookID?[bookID, default: []].append(contentsOf: inserted)
    }

    /// deleteしたBookmarkをキャッシュから取り除く。
    private func cacheRemovedBookmarks(_ removed: [Bookmark], forBookID bookID: String) {
        guard cachedBookmarksByBookID != nil, !removed.isEmpty else { return }
        let removedIdentities = Set(removed.map { ObjectIdentifier($0) })
        let remaining = (cachedBookmarksByBookID?[bookID] ?? []).filter {
            !removedIdentities.contains(ObjectIdentifier($0))
        }
        cachedBookmarksByBookID?[bookID] = remaining.isEmpty ? nil : remaining
    }

    /// 左ペインの本一覧を、指定したbookSortOptionに従って並べ替える。bookmarks(forBookID:)の
    /// switch文と同じ基準・同じ考え方だが、対象がBookmark個々ではなくBookmarkBookGroup
    /// (本単位に集約した日時)である点が異なる。
    private static func sortedGroups(
        _ groups: [BookmarkBookGroup], by option: FavoritesSortOption
    ) -> [BookmarkBookGroup] {
        switch option {
        case .nameAscending:
            return groups.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .nameDescending:
            return groups.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending }
        case .dateAddedAscending:
            return groups.sorted { $0.earliestCreatedAt < $1.earliestCreatedAt }
        case .dateAddedDescending:
            return groups.sorted { $0.earliestCreatedAt > $1.earliestCreatedAt }
        case .dateUpdatedAscending:
            return groups.sorted { $0.latestUpdatedAt < $1.latestUpdatedAt }
        case .dateUpdatedDescending:
            return groups.sorted { $0.latestUpdatedAt > $1.latestUpdatedAt }
        }
    }

    /// bookIDに紐づくいずれかのBookmark.bookmarkDataからURLを解決する(生パスへのフォールバックは
    /// 行わない。LayoutStore.resolvedURL(forBookID:)と組み合わせて使う想定で、そちらが生パスへの
    /// フォールバックを持つため、ここで重複して持たせる必要が無い)。
    /// JSON書き出し(6節)で、ブックマークを持つ本のページを読み込む(pageIndex→pageKey変換)ために
    /// 使う(詳細はLibraryImportExportService.resolveURL参照)。
    func resolvedURLFromBookmarkData(forBookID bookID: String) -> URL? {
        for candidate in bookmarks(forBookID: bookID) {
            guard let data = candidate.bookmarkData else { continue }
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
        return nil
    }

    /// ユーザー要望: ブックマークが付いている本が、同一ボリューム内で移動・リネームされた場合
    /// でもブックマークを引き継げるようにしたい(ボリュームを跨いだ移動は諦める)。
    ///
    /// 現在のbookID(パス)のブックマークが1件でも見つかれば、移動していない(または既に
    /// 追従済み)とみなして何もしない。見つからない場合、この本のファイルノード識別子
    /// (登録済みのBookmark.inodeNumber/volumeDeviceNumber)と一致するブックマークを探し、
    /// 見つかればそれらすべてのbookIDを現在のパスへ書き換える。AppState.open(url:)から、
    /// 本を開くたびに呼ばれる想定。
    func reconcileBookIDIfMoved(book: MangaBook) {
        guard (bookmarksByBookID()[book.id] ?? []).isEmpty else { return }
        guard let identifier = FileNodeIdentifier.current(for: book.sourceURL) else { return }
        let candidates = allBookmarks().filter { $0.bookID != book.id && $0.fileNodeIdentifier == identifier }
        guard !candidates.isEmpty else { return }
        // 同じiノードを指すブックマークが、過去の複数のパスに分かれて残っていることもありうる。
        // 書き換えでbookIDを失う前に、現在のbookIDごとに仕分けておく(キャッシュ辞書のキーは
        // bookIDそのものなので、旧キーから正しく取り除くために必要)。
        let candidatesByOldBookID = Dictionary(grouping: candidates, by: \.bookID)
        // 通知に載せる「元のパス」。候補が複数ある場合にどれを載せるかは元々一意に決まらないが、
        // 全件フェッチ結果の先頭に依存していた従来と違い、辞書化で順序が不定になったため
        // 明示的に決め打ちする。
        let oldBookID = candidatesByOldBookID.keys.sorted().first ?? candidates[0].bookID
        for bookmark in candidates {
            bookmark.bookID = book.id
        }
        try? modelContext.save()
        // bookIDはキャッシュ辞書のキーそのものなので、書き換えたぶんを旧キーから新キーへ移す
        // (行の追加・削除と違い、ここだけはキーの引っ越しになる)。candidatesは旧bookIDの行
        // すべてとは限らない(fileNodeIdentifierが一致するものだけ)ため、残りは旧キーに残す。
        for (previousBookID, moved) in candidatesByOldBookID {
            cacheRemovedBookmarks(moved, forBookID: previousBookID)
        }
        cacheInsertedBookmarks(candidates, forBookID: book.id)
        rebuildGroups()
        NotificationCenter.default.post(
            name: .bookmarksDidChange, object: self, userInfo: ["bookID": book.id, "oldBookID": oldBookID]
        )
    }

    /// ユーザー要望: JSONインポート(LibraryImportExportService)時、ファイルパスが古くなって
    /// いても、ファイルノード識別子(iノード番号)を手がかりに、ローカルに既に保存されている
    /// セキュリティスコープ付きブックマークから現在の実際のURLを解決できるようにしたい。
    func resolvedURL(matching identifier: FileNodeIdentifier) -> URL? {
        for bookmark in allBookmarks() where bookmark.fileNodeIdentifier == identifier {
            guard let data = bookmark.bookmarkData else { continue }
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// ユーザー要望(後方互換性): ファイルノード識別子を持たない古いブックマーク行(この属性を
    /// 追加する前に作成されたもの、またはaddBookmark/addBookmarksがfileNodeIdentifierを渡されずに
    /// 作成したもの)について、ファイルパス(bookID)なら実在が確認できている場合に、そのパスから
    /// 改めて識別子を取得して補完する。
    ///
    /// LibraryImportExportService.exportBookmarksが、書き出し対象の本を実際に読み込めた
    /// (=URLを解決できた)タイミングで、その本のブックマークにまだ識別子が無ければここを呼ぶ
    /// (エクスポートしたJSONに毎回inodeが含まれるようにするための、地道な取りこぼし救済)。
    /// 対象が無ければ何もしない(呼び出しコストを抑えるため、呼び出し前にidentifierが必要な
    /// 行があるかどうかは呼び出し側で判定する)。
    func backfillFileNodeIdentifier(forBookID bookID: String, identifier: FileNodeIdentifier) {
        let targets = (bookmarksByBookID()[bookID] ?? []).filter { $0.fileNodeIdentifier == nil }
        guard !targets.isEmpty else { return }
        for bookmark in targets {
            bookmark.inodeNumber = identifier.inodeNumber
            bookmark.volumeDeviceNumber = identifier.volumeDeviceNumber
        }
        try? modelContext.save()
        // キャッシュが保持しているのはこれらのBookmark自身(同じ参照)なので、フィールドを
        // 書き換えただけのここではキャッシュ側に手を入れる必要は無い(行の増減もbookIDの変化も
        // 無い)。表示上の並び・件数にも影響しないため、通知(bookmarksDidChange)も投げない
        // (この変更を他のウインドウが今すぐ知る必要のある可視の変化ではないため)。
    }

    /// 指定したbookIDのブックマークを、現在のsortOptionに従って並べ替えて返す。
    /// (次/前のブックマークへジャンプする操作(ViewerViewModel.jumpToNextBookmark等)は
    /// 常にページ番号順で判定する必要があるため、そちらは影響を受けないViewerViewModel.bookmarks
    /// を直接使い続けている。ここで返す並びはあくまでこの編集画面の表示専用)。
    /// #Predicateで直接bookIDを絞り込むのではなく、reload()と同じく絞り込み無しで全件取得して
    /// からSwift側でfilterしている。SwiftDataの#Predicateクロージャ内でキャプチャしたローカル
    /// 変数名が、比較対象のモデル側プロパティ名($0.bookID)と同名(bookID)だと、絞り込みフェッチが
    /// 正しく機能しないことがある不具合が実機で確認された(LayoutStore.pageOverrides(forBookID:)の
    /// コメント参照)ため、同じ理由でここも合わせて統一しておく。
    /// この本のブックマークが持つセキュリティスコープ付きブックマークデータを、並べ替えずに
    /// すべて返す。
    ///
    /// bookmarks(forBookID:)は呼ばれるたびにこの本のブックマーク全件を並べ替える(既定の
    /// 名前順ではlocalizedStandardCompareというロケール照合を使う)。実在確認のように
    /// 順序が結果に一切影響しない用途で、登録済みの本すべてに対して回すと、その並べ替えが
    /// 丸ごと無駄なコストになるため、こちらを使うこと(EPUB/PDF出力ウインドウの対象一覧の
    /// 絞り込み。BookURLResolver参照)。
    func bookmarkDataList(forBookID bookID: String) -> [Data] {
        (bookmarksByBookID()[bookID] ?? []).compactMap(\.bookmarkData)
    }

    func bookmarks(forBookID bookID: String) -> [Bookmark] {
        let fetched = bookmarksByBookID()[bookID] ?? []
        switch sortOption {
        case .nameAscending:
            return fetched.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return fetched.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateAddedAscending:
            return fetched.sorted { $0.createdAt < $1.createdAt }
        case .dateAddedDescending:
            return fetched.sorted { $0.createdAt > $1.createdAt }
        case .dateUpdatedAscending:
            return fetched.sorted { $0.updatedAt < $1.updatedAt }
        case .dateUpdatedDescending:
            return fetched.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// 指定したbookID・ページ番号に、直接ブックマークを追加する。5節の一括リネームウインドウの
    /// 「表紙の固定割り当て」で、先頭ページにブックマークが無い場合に使う。ViewerViewModel.
    /// addBookmarkと異なり、その本を今開いているウインドウ/タブが無くても動作する
    /// (bookmarkDataは付与しない。この機能で新規作成するブックマークはbookIDの素のパスへの
    /// フォールバックで十分実用に足りるため。詳細はBookmark.bookmarkDataのコメント参照)。
    /// 同じページに既にブックマークがある場合は何もしない(ViewerViewModel.addBookmarkと同じ
    /// 重複防止)。
    /// 戻り値: 実際に新規追加したらtrue、既存の重複により何もしなかったらfalse
    /// (呼び出し側が「追加できたかどうか」を、before/after件数比較で二重にフェッチし直さずに
    /// 済むようにするため。LibraryImportExportService.applyBookmarks参照)。
    ///
    /// - Parameter fileNodeIdentifier: 呼び出し側がこの本のURLを解決済みであれば渡す
    ///   (FileNodeIdentifier.current(for:)で計算したもの)。ViewerViewModel.addBookmark(atIndex:)と
    ///   異なり、この関数は本を開いていない状態でも呼ばれる(BookmarkListView「+」ボタン、
    ///   一括リネームウインドウの表紙自動追加)ため、呼び出し元でURLを解決できた場合にだけ
    ///   渡してもらう(解決できなければnilのままでよく、従来通りinode無しで作成される。
    ///   FileNodeIdentifierのコメント参照: 致命的な問題にはならない)。
    @discardableResult
    func addBookmark(bookID: String, pageIndex: Int, name: String, fileNodeIdentifier: FileNodeIdentifier? = nil) -> Bool {
        guard !bookmarks(forBookID: bookID).contains(where: { $0.pageIndex == pageIndex }) else { return false }
        let bookmark = Bookmark(bookID: bookID, pageIndex: pageIndex, name: name, fileNodeIdentifier: fileNodeIdentifier)
        modelContext.insert(bookmark)
        try? modelContext.save()
        cacheInsertedBookmarks([bookmark], forBookID: bookID)
        rebuildGroups()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
        return true
    }

    /// JSONインポート専用: 指定した本に複数のブックマークをまとめて追加する
    /// (LibraryImportExportService.applyBookmarks参照)。
    ///
    /// 経緯(ユーザー報告): JSONインポートが非常に遅い。Xcodeのコンソールを見ると、ブックマークを
    /// 1件読み込むたびにSwiftData(内部はSQLite)への書き込みが起きているように見える、との指摘。
    /// 実際、addBookmark(bookID:pageIndex:name:)をブックマークの件数ぶんループで個別に呼ぶと、
    /// そのたびに(1) modelContext.save()(SQLiteへの同期コミット)、(2) reload()
    /// (Bookmarkテーブルの絞り込み無し全件フェッチ+並べ替え)、(3) NotificationCenter.post
    /// (bookmarksDidChangeを購読している開いている本のViewerViewModelの再読み込み)が発生する。
    /// 本1冊で数百件のブックマークを持つことも珍しくなく、これがJSONインポートを遅くしていた
    /// 主要因の1つだった。
    ///
    /// 対応: 対象の本1冊ぶんの既存ブックマーク(ページ番号の集合)を最初に1回だけ取得し、
    /// 以降はメモリ上で重複判定・insertだけを行った上で、最後に保存・再フェッチ・通知を
    /// この本につき1回にまとめる(addBookmarkと同じ「同じページに既存のブックマークがあれば
    /// 何もしない」重複防止は維持する。渡されたentries内で同じpageIndexが複数あった場合も、
    /// 先頭のものだけが採用される=addBookmarkを順番に呼んだ場合と同じ結果になる)。
    ///
    /// - Parameter fileNodeIdentifier: このbookIDについて解決済みのファイルノード識別子
    /// (addBookmarkのfileNodeIdentifierパラメータ参照)。JSONインポート(LibraryImportExportService.
    /// applyBookmarks)では、この呼び出しの直前に本を実際に読み込んでURLを解決済みのため、
    /// そこで得たbook.sourceURLから計算した最新の識別子を渡す(JSON側の古いinodeをそのまま
    /// 信用せず、実際に解決できたファイルから再取得する。qooViewer改善要望.mdの「ファイルパス
    /// ならば実在する場合、inodeをDB上のinodeはそのファイルパスから再取得してinodeで設定する」
    /// 要件に対応)。
    @discardableResult
    func addBookmarks(
        bookID: String, entries: [(pageIndex: Int, name: String)], fileNodeIdentifier: FileNodeIdentifier? = nil
    ) -> Int {
        guard !entries.isEmpty else { return 0 }
        var existingPageIndices = Set(bookmarks(forBookID: bookID).map(\.pageIndex))
        var inserted: [Bookmark] = []
        for entry in entries {
            guard !existingPageIndices.contains(entry.pageIndex) else { continue }
            let bookmark = Bookmark(
                bookID: bookID, pageIndex: entry.pageIndex, name: entry.name, fileNodeIdentifier: fileNodeIdentifier
            )
            modelContext.insert(bookmark)
            existingPageIndices.insert(entry.pageIndex)
            inserted.append(bookmark)
        }
        guard !inserted.isEmpty else { return 0 }
        try? modelContext.save()
        cacheInsertedBookmarks(inserted, forBookID: bookID)
        rebuildGroups()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
        return inserted.count
    }

    /// ブックマークをリネームする。本が今開いているかどうかに関わらず直接SwiftDataを操作し、
    /// bookmarksDidChangeを投げてViewerViewModel側(その本が今開いていれば)にも反映させる。
    func rename(_ bookmark: Bookmark, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bookID = bookmark.bookID
        bookmark.name = trimmed
        bookmark.updatedAt = Date()
        try? modelContext.save()
        // 行の増減は無いためキャッシュはそのままでよいが、groupsのlatestUpdatedAt(並び替えに
        // 使う)が変わるため組み直す。
        rebuildGroups()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
    }

    /// JSONインポート・ページ並べ替えと同じ理由で見つかった、もう1つの「1件ごとにSQLiteへ
    /// コミット」の箇所への対応。BulkRenameBookmarksWindow.applyRenaming参照。
    ///
    /// 経緯(ユーザー報告): 他にも同様の箇所がないか確認してほしい、との依頼を受けて調査した
    /// ところ、「ブックマークの一括リネーム」ウインドウの実行処理(4.4節/5節)が、対象の本の
    /// 全ブックマークをrename(_:to:)でループしながら1件ずつ呼んでいた。renameは呼び出しの
    /// たびにsave()+reload()+通知を行うため、ブックマークを数百件持つ本で「一括リネーム」を
    /// 実行すると、それだけの回数SQLiteへコミットしていたことになる。
    ///
    /// 対応: 対象の本1冊分のリネームをまとめて受け取り、保存・再フェッチ・通知をこの本1冊に
    /// つき1回にまとめる(空文字列だけのnewNameは無視する。rename(_:to:)と同じ挙動)。
    /// 戻り値: 実際にリネームできた件数。
    @discardableResult
    func renameBookmarks(bookID: String, renames: [(bookmark: Bookmark, newName: String)]) -> Int {
        guard !renames.isEmpty else { return 0 }
        let now = Date()
        var changedCount = 0
        for (bookmark, newName) in renames {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            bookmark.name = trimmed
            bookmark.updatedAt = now
            changedCount += 1
        }
        guard changedCount > 0 else { return 0 }
        try? modelContext.save()
        rebuildGroups()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
        return changedCount
    }

    /// ページの並べ替え(4.3節: BookLayoutEditorViewModel.movePages/movePageUp/movePageDown)で、
    /// 既存のブックマークが元のページ番号(スロット)ではなく、元々ブックマークしていたページ
    /// (ファイル)に追従するように、影響を受けたブックマークのpageIndexを一括で書き換える
    /// (ユーザー報告: 「ブックマークがあるページの順番を入れ替えると、ブックマークが追従しない
    /// (画像は入れ替わったのに元のページ順に居座る)。ブックマークはあくまでファイルに紐づく
    /// ものなので、順番が入れ替わった際はファイルに追従してほしい」)。
    ///
    /// oldIndexToNewIndexは「並べ替え前のpageIndex → 並べ替え後のpageIndex」の対応
    /// (BookLayoutEditorViewModel.migrateBookmarkIndices参照。movePages/movePageUp/
    /// movePageDownはページの除外/表示状態の集合自体を変えない純粋な並べ替えのため、この対応は
    /// 1対1の置換になる)。対応が無いpageIndexのブックマーク(この本のうち動かなかったページに
    /// 付いているもの)には触れない。リネーム(名前・updatedAt)とは異なる機械的な位置補正のため、
    /// updatedAtは更新しない(「更新順」の並び替えに影響させないため)。
    func updatePageIndices(forBookID bookID: String, oldIndexToNewIndex: [Int: Int]) {
        guard !oldIndexToNewIndex.isEmpty else { return }
        let matched = bookmarksByBookID()[bookID] ?? []
        guard !matched.isEmpty else { return }
        var didChange = false
        for bookmark in matched {
            if let newIndex = oldIndexToNewIndex[bookmark.pageIndex], newIndex != bookmark.pageIndex {
                bookmark.pageIndex = newIndex
                didChange = true
            }
        }
        guard didChange else { return }
        try? modelContext.save()
        // 件数もupdatedAtも変えない機械的な位置補正のためgroupsの内容は変わらないが、
        // 他の書き込みメソッドと足並みを揃えて組み直しておく(キャッシュだけを見る処理のため
        // フェッチは発生しない)。
        rebuildGroups()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
    }

    /// ブックマークを削除する。rename(_:to:)と同じく、本が今開いているかどうかに関わらず
    /// 直接SwiftDataを操作する。
    func delete(_ bookmark: Bookmark) {
        let bookID = bookmark.bookID
        modelContext.delete(bookmark)
        try? modelContext.save()
        cacheRemovedBookmarks([bookmark], forBookID: bookID)
        rebuildGroups()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
    }

    /// 指定した1冊分のブックマークをすべて削除する。「ブックマーク・レイアウトの編集」
    /// ウインドウの4.4節「ブックマークを全削除」から呼ぶ(1冊分のみを対象にする点が
    /// deleteAllBookmarks()と異なる)。
    func deleteAllBookmarks(forBookID bookID: String) {
        let matched = bookmarksByBookID()[bookID] ?? []
        guard !matched.isEmpty else { return }
        for bookmark in matched {
            modelContext.delete(bookmark)
        }
        try? modelContext.save()
        cacheRemovedBookmarks(matched, forBookID: bookID)
        rebuildGroups()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
    }

    /// この本を指すセキュリティスコープ付きブックマークのうち、最初に見つかったもの。
    /// resolvedURLFromBookmarkData(forBookID:)と違い、ファイルの実在確認は行わずデータ自体を返す
    /// (「本ごとの保存データを削除」ウインドウが、実在するかどうかを自分で判定するために使う)。
    func anyBookmarkData(forBookID bookID: String) -> Data? {
        (bookmarksByBookID()[bookID] ?? []).compactMap(\.bookmarkData).first
    }

    /// すべてのブックマークを削除する。環境設定「リセット」タブの「すべてのお気に入り・
    /// ブックマーク・読書履歴を削除」から呼ばれる、緊急時向けの強力な操作
    /// (ResetDataSettingsView参照)。
    ///
    /// userInfoに"bookID"を含めずに通知することで、「特定の本の変更」ではなく「全件リセット」で
    /// あることを示す。ViewerViewModel側は、userInfoに"bookID"が無い通知を「自分の本に
    /// 関わらず読み直す」信号として扱う(詳細はViewerViewModelのbookmarksChangeObserver参照)。
    func deleteAllBookmarks() {
        try? modelContext.delete(model: Bookmark.self)
        try? modelContext.save()
        // delete(model:)はSwiftDataにまとめて消させるため、どの行が消えたかを個別に追えない。
        // キャッシュは「空」として作り直す(LayoutStore.deleteAllLayoutDataと同じ考え方)。
        cachedBookmarksByBookID = [:]
        rebuildGroups()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: nil)
    }
}
