import Foundation
import SwiftData
import AppKit
import Combine

/// 「ブックマークの編集」ウインドウの左ペインに表示する、1冊分のまとめ。
struct BookmarkBookGroup: Identifiable {
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

    var id: String { bookID }

    /// 表示用の本の名前。Bookmarkにはタイトルが保存されておらず、bookID(パス)しか
    /// 持たないため、パスの最後の部分から都度生成する(RecentFilesStore.Entry.displayNameと
    /// 同じ考え方。実体のファイル/フォルダが後からリネームされていた場合、この表示名は
    /// リネーム前のままになりうるが、お気に入りと違い「開く」機能を持たないブックマーク編集では
    /// これで十分と判断した)。
    var displayName: String {
        URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent
    }
}

/// ブックマーク(Bookmark.swift)の永続化・操作を、特定の本に限らず横断的に担当する。
///
/// 以前はブックマークの一覧・編集は「今開いている本」のものだけをViewerViewModel経由で
/// 扱っていたが、「ブックマークの編集」ウインドウをお気に入りの編集ウインドウと同じ2ペイン構成
/// (左: 本の一覧、右: 選択中の本のブックマーク一覧)にする際、すべての本を横断して編集できる
/// 必要が生じたため、FavoritesStoreと同じ考え方でこのストアを新設した。
///
/// 開いている本のViewerViewModelも同じSwiftData ModelContextを介して同じBookmarkを参照しうるため、
/// 一方の変更をもう一方にも伝える必要がある。これは個別のクロージャではなく
/// Notification.Name.bookmarksDidChangeの送受信で行う(詳細はBookmark.swiftのコメント参照。
/// 「今読んでいる本」を1つに絞れるFavoritesStoreの「現在の本を追加」ボタンと違い、こちらは
/// 開いているすべての本のViewerViewModelと同期を取る必要があるため、AppState経由の個別の
/// クロージャではなく通知の形にしている)。
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
            // groupsは既にearliestCreatedAt/latestUpdatedAtを持っているため、再フェッチ
            // (reload())せずその場で並べ替えるだけでよい。
            groups = Self.sortedGroups(groups, by: bookSortOption)
        }
    }

    private static let sortOptionDefaultsKey = "qooViewer.pref.bookmarkSortOption"
    private static let bookSortOptionDefaultsKey = "qooViewer.pref.bookmarkBookSortOption"

    private let modelContext: ModelContext
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

        changeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
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
    func reload() {
        let all = (try? modelContext.fetch(FetchDescriptor<Bookmark>())) ?? []
        let grouped = Dictionary(grouping: all, by: \.bookID)
        let unsorted = grouped.map { bookID, bookmarks -> BookmarkBookGroup in
            // 「追加日時」はこの本に最初にブックマークを付けた日時(=最小のcreatedAt)、
            // 「更新日時」はこの本のブックマークの中で直近に変更があった日時(=最大のupdatedAt)
            // として扱う(BookmarkBookGroupのコメント参照)。bookmarksは同じbookIDでグループ化した
            // 直後のため必ず1件以上あり、min()/max()がnilになることはないが、念のためDate()に
            // フォールバックしておく。
            BookmarkBookGroup(
                bookID: bookID,
                count: bookmarks.count,
                earliestCreatedAt: bookmarks.map(\.createdAt).min() ?? Date(),
                latestUpdatedAt: bookmarks.map(\.updatedAt).max() ?? Date()
            )
        }
        groups = Self.sortedGroups(unsorted, by: bookSortOption)
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

    /// 指定したbookIDのブックマークを、現在のsortOptionに従って並べ替えて返す。
    /// (次/前のブックマークへジャンプする操作(ViewerViewModel.jumpToNextBookmark等)は
    /// 常にページ番号順で判定する必要があるため、そちらは影響を受けないViewerViewModel.bookmarks
    /// を直接使い続けている。ここで返す並びはあくまでこの編集画面の表示専用)。
    func bookmarks(forBookID bookID: String) -> [Bookmark] {
        let descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate<Bookmark> { $0.bookID == bookID }
        )
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
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

    /// ブックマークをリネームする。本が今開いているかどうかに関わらず直接SwiftDataを操作し、
    /// bookmarksDidChangeを投げてViewerViewModel側(その本が今開いていれば)にも反映させる。
    func rename(_ bookmark: Bookmark, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bookID = bookmark.bookID
        bookmark.name = trimmed
        bookmark.updatedAt = Date()
        try? modelContext.save()
        reload()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
    }

    /// ブックマークを削除する。rename(_:to:)と同じく、本が今開いているかどうかに関わらず
    /// 直接SwiftDataを操作する。
    func delete(_ bookmark: Bookmark) {
        let bookID = bookmark.bookID
        modelContext.delete(bookmark)
        try? modelContext.save()
        reload()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: ["bookID": bookID])
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
        reload()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: self, userInfo: nil)
    }
}
