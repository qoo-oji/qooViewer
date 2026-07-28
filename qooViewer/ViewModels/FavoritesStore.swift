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
                format: String(localized: "You can register up to %d favorites in total."),
                FavoritesLimits.maxFavoritesCount
            )
        case .folderDepthLimitReached:
            return String(
                format: String(localized: "Favorite folders can be nested up to %d levels deep."),
                FavoritesLimits.maxFolderDepth
            )
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
    /// ルート直下のフォルダ一覧(親を持たないFavoriteFolder)。sortOrder順。
    @Published private(set) var rootFolders: [FavoriteFolder] = []
    /// ルート直下に直接置かれているお気に入り(フォルダに属さないFavoriteBook)。sortOrder順。
    @Published private(set) var rootBooks: [FavoriteBook] = []

    private let modelContext: ModelContext
    /// メニューが開かれる直前に一覧を再読み込みするための監視トークン。
    /// (RecentFilesStoreと同じ理由: 整理画面や他のウインドウでの変更を、メニューを開くたびに
    /// 反映させるため)
    private var menuTrackingObserver: NSObjectProtocol?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        reload()
        // RecentFilesStore.swiftの同様のオブザーバーと同じ書き方(queue: .mainを指定した
        // NotificationCenterのクロージャは実行時にはメインスレッドで呼ばれるため、
        // Task { @MainActor in ... }で包み直す必要はない。むしろ包むとSwift 6の
        // 厳格な並行性チェックで「Reference to captured var 'self' in concurrently-executing
        // code」という警告/エラーになった)。
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    /// ルート直下のフォルダ・お気に入りを読み込み直す。フォルダの中身(children/books)は
    /// SwiftDataのリレーションシップ経由でその都度取得できるため、ここでは読み込まない。
    func reload() {
        var folderDescriptor = FetchDescriptor<FavoriteFolder>(
            predicate: #Predicate<FavoriteFolder> { $0.parent == nil }
        )
        folderDescriptor.sortBy = [SortDescriptor(\.sortOrder)]
        rootFolders = (try? modelContext.fetch(folderDescriptor)) ?? []

        var bookDescriptor = FetchDescriptor<FavoriteBook>(
            predicate: #Predicate<FavoriteBook> { $0.folder == nil }
        )
        bookDescriptor.sortBy = [SortDescriptor(\.sortOrder)]
        rootBooks = (try? modelContext.fetch(bookDescriptor)) ?? []
    }

    /// 指定したフォルダの直下のサブフォルダ一覧(sortOrder順)。nilを渡すとルート直下を返す。
    func subfolders(of folder: FavoriteFolder?) -> [FavoriteFolder] {
        guard let folder else { return rootFolders }
        return folder.children.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 指定したフォルダの直下のお気に入り一覧(sortOrder順)。nilを渡すとルート直下を返す。
    func books(in folder: FavoriteFolder?) -> [FavoriteBook] {
        guard let folder else { return rootBooks }
        return folder.books.sorted { $0.sortOrder < $1.sortOrder }
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
            name: trimmed.isEmpty ? String(localized: "Untitled Folder") : trimmed,
            parent: parent,
            sortOrder: siblingCount
        )
        modelContext.insert(folder)
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
        modelContext.delete(folder)
        try? modelContext.save()
        reload()
    }

    func delete(_ favorite: FavoriteBook) {
        modelContext.delete(favorite)
        try? modelContext.save()
        reload()
    }

    /// お気に入りを別のフォルダへ移動する(整理画面でのドラッグ&ドロップから呼ぶ)。
    func move(_ favorite: FavoriteBook, to folder: FavoriteFolder?) {
        favorite.folder = folder
        favorite.sortOrder = books(in: folder).count
        try? modelContext.save()
        reload()
    }

    /// フォルダを別のフォルダへ移動する。移動先が自分自身・自分の子孫の場合(循環)、または
    /// 移動後に配下も含めて階層の上限を超えてしまう場合は何もせずfalseを返す。
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

        folder.parent = newParent
        folder.sortOrder = subfolders(of: newParent).count
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
    func folder(withID id: UUID) -> FavoriteFolder? {
        var descriptor = FetchDescriptor<FavoriteFolder>(predicate: #Predicate<FavoriteFolder> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// id(UUID)からお気に入りを検索する(folder(withID:)と同じ用途)。
    func book(withID id: UUID) -> FavoriteBook? {
        var descriptor = FetchDescriptor<FavoriteBook>(predicate: #Predicate<FavoriteBook> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// 指定したbookIDで既に登録されているお気に入り一覧(全フォルダ横断)。
    func existingFavorites(forBookID bookID: String) -> [FavoriteBook] {
        let descriptor = FetchDescriptor<FavoriteBook>(
            predicate: #Predicate<FavoriteBook> { $0.bookID == bookID }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
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
            let breadcrumb = otherEntry.folder?.breadcrumb ?? String(localized: "Favorites (Top Level)")
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
            sortOrder: books(in: folder).count
        )
        modelContext.insert(favorite)
        try? modelContext.save()
        reload()
        return .added(favorite)
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
        var isStale = false
        return try? URL(
            resolvingBookmarkData: favorite.bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// お気に入りが指すファイル/フォルダが、実際にまだ存在するかどうか。
    /// (RecentFilesStore.fileStillExistsと同じロジック)
    func fileExists(for favorite: FavoriteBook) -> Bool {
        guard let url = resolvedURL(for: favorite) else { return false }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return FileManager.default.fileExists(atPath: url.path)
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

    /// ウェルカム画面の「最近お気に入りに追加したファイル」用。登録日時が新しい順に、
    /// 実際に存在するものだけを最大limit件返す。
    func recentFavorites(limit: Int) -> [FavoriteBook] {
        let descriptor = FetchDescriptor<FavoriteBook>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        var result: [FavoriteBook] = []
        for favorite in all {
            if fileExists(for: favorite) {
                result.append(favorite)
                if result.count >= limit { break }
            }
        }
        return result
    }
}
