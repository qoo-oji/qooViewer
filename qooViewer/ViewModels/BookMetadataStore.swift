import Foundation
import SwiftData
import Combine

/// 書誌メタデータ(BookMetadata)の永続化・操作を、特定の本に限らず横断的に担当する。
/// LayoutStore/BookmarkStoreと同じ設計(SwiftDataを直接操作し、変更を
/// Notification.Name.bookMetadataDidChange経由で他のウインドウ/ViewerViewModelへ伝える)を
/// 踏襲する。
///
/// このクラス自体は「本を開いているかどうか」を意識しない。今開いている本のツールバー表示への
/// 反映は、ViewerViewModel側がbookMetadataDidChangeを購読して行う。
///
/// ModelContextはFavoritesStore/BookmarkStore/LayoutStoreと同じ、アプリ全体で1つだけの
/// `QooViewerApp.modelContainer.mainContext`を共有する(CLAUDE.md / QooViewerApp.init()の
/// コメント参照。コンテキストを分けると、一方のコンテキストのオブジェクトに対する更新・削除が
/// もう一方に反映されず静かに失敗する)。
@MainActor
final class BookMetadataStore: ObservableObject {
    private let modelContext: ModelContext

    /// メタデータが登録されている本のbookID一覧。「メタデータの編集」ウインドウの行の
    /// 色分け、およびEPUB/PDF出力ウインドウの対象判定・インジケータ表示に使う。
    ///
    /// LayoutStore.layoutBookIDsと同じく、このストアがBookMetadataの唯一の書き込み口である
    /// ことを前提に、各更新メソッドの最後で(saveAndNotify経由で)更新する。
    @Published private(set) var registeredBookIDs: Set<String> = []

    /// 全件フェッチ結果をbookIDで引ける形にしてキャッシュしたもの。nilは「キャッシュ未構築」。
    /// LayoutStore.cachedSettingsByBookIDと同じ考え方・同じ理由(絞り込みフェッチではなく
    /// 全件フェッチ+Swift側での仕分け、かつinsert/deleteのたびに差分だけをキャッシュへ反映)。
    private var cachedByBookID: [String: BookMetadata]?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        registeredBookIDs = Set(metadataByBookID().keys)
    }

    // MARK: - 読み取り

    /// 指定したbookIDの登録済みメタデータ(未登録ならnil)。
    private func metadataByBookID() -> [String: BookMetadata] {
        if let cachedByBookID { return cachedByBookID }
        let fetched = (try? modelContext.fetch(FetchDescriptor<BookMetadata>())) ?? []
        var byBookID: [String: BookMetadata] = [:]
        byBookID.reserveCapacity(fetched.count)
        // 同じbookIDの行が万一複数あった場合は、フェッチ順で最初の1件を採用する
        // (LayoutStore.settingsByBookIDと同じ扱い)。
        for metadata in fetched where byBookID[metadata.bookID] == nil {
            byBookID[metadata.bookID] = metadata
        }
        cachedByBookID = byBookID
        return byBookID
    }

    func metadata(forBookID bookID: String) -> BookMetadata? {
        metadataByBookID()[bookID]
    }

    /// 登録済みのメタデータ全件(順不同)。JSONエクスポートなど、横断的に扱う経路でのみ使う。
    func allMetadata() -> [BookMetadata] {
        Array(metadataByBookID().values)
    }

    /// この本にメタデータが登録されているか。
    func isRegistered(bookID: String) -> Bool {
        registeredBookIDs.contains(bookID)
    }

    // MARK: - 書き込み

    /// メタデータを登録(既に登録済みなら上書き)する。
    ///
    /// 4項目すべてが空の内容で登録しようとした場合は、行を作らず(既にあれば削除して)
    /// 未登録状態へ戻す。「登録済みだが中身が何も無い」行は、一覧の色分け上は登録済みに
    /// 見えるのに実際には何の情報も持たないという分かりにくい状態になるため。
    ///
    /// - Parameter sourceURL: 分かる場合は本の実URL。セキュリティスコープ付きブックマークと
    ///   ファイルノード識別子の生成に使う(今この本を開けている=このURLへのアクセス権を
    ///   持っている、という前提。LayoutStore.existingOrNewSettingsと同じ考え方)。
    ///   一覧から登録する場合など、URLが手元に無い場合はnilでよい。
    @discardableResult
    func upsert(
        bookID: String,
        author: String,
        title: String,
        series: String,
        seriesIndex: String,
        sourceURL: URL? = nil
    ) -> BookMetadata? {
        let author = author.trimmingCharacters(in: .whitespaces)
        let title = title.trimmingCharacters(in: .whitespaces)
        let series = series.trimmingCharacters(in: .whitespaces)
        let seriesIndex = seriesIndex.trimmingCharacters(in: .whitespaces)

        guard !(author.isEmpty && title.isEmpty && series.isEmpty && seriesIndex.isEmpty) else {
            delete(forBookID: bookID)
            return nil
        }

        if let existing = metadata(forBookID: bookID) {
            existing.author = author
            existing.title = title
            existing.series = series
            existing.seriesIndex = seriesIndex
            existing.updatedAt = Date()
            // 識別子・ブックマークは、これまで取れていなかった場合にだけ補完する
            // (既存の値を、解決できないかもしれない新しい値で上書きしない)。
            if let sourceURL {
                if existing.bookmarkData == nil {
                    existing.bookmarkData = Self.makeBookmarkData(for: sourceURL)
                }
                if existing.fileNodeIdentifier == nil, let identifier = FileNodeIdentifier.current(for: sourceURL) {
                    existing.inodeNumber = identifier.inodeNumber
                    existing.volumeDeviceNumber = identifier.volumeDeviceNumber
                }
            }
            saveAndNotify(bookID: bookID)
            return existing
        }

        let created = BookMetadata(
            bookID: bookID,
            author: author,
            title: title,
            series: series,
            seriesIndex: seriesIndex,
            bookmarkData: sourceURL.flatMap(Self.makeBookmarkData(for:)),
            fileNodeIdentifier: sourceURL.flatMap(FileNodeIdentifier.current(for:))
        )
        modelContext.insert(created)
        cachedByBookID?[bookID] = created
        saveAndNotify(bookID: bookID)
        return created
    }

    /// 登録を解除する(未登録なら何もしない)。
    func delete(forBookID bookID: String) {
        guard let existing = metadata(forBookID: bookID) else { return }
        modelContext.delete(existing)
        cachedByBookID?[bookID] = nil
        saveAndNotify(bookID: bookID)
    }

    /// 全件削除(環境設定「リセット」タブ、およびJSONインポートの「置き換え」用)。
    func deleteAllMetadata() {
        do {
            try modelContext.delete(model: BookMetadata.self)
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("deleteAllMetadata() failed: \(error)")
        }
        // 一括削除はどの行が消えたかを個別に追えないため、キャッシュは「空」として作り直す
        // (LayoutStore.deleteAllLayoutDataと同じ理由)。
        cachedByBookID = [:]
        registeredBookIDs = []
        NotificationCenter.default.post(name: .bookMetadataDidChange, object: self, userInfo: nil)
    }

    // MARK: - bookIDの追従・URL解決

    /// ユーザー要望(他のモデルと同様): メタデータが付いている本が、同一ボリューム内で移動・
    /// リネームされた場合でも登録内容を引き継げるようにする(ボリュームを跨いだ移動は諦める)。
    /// LayoutStore.reconcileBookIDIfMoved(book:)と同じ考え方。AppState.open(url:)から、本を
    /// 開くたびに呼ばれる想定。
    func reconcileBookIDIfMoved(book: MangaBook) {
        guard metadata(forBookID: book.id) == nil else { return }
        guard let identifier = FileNodeIdentifier.current(for: book.sourceURL) else { return }
        // 同じiノードを指す行が過去のパスぶん複数残っている場合に備えて、最後に更新された
        // 行を選ぶ(LayoutStoreと同じ基準)。
        guard let matched = allMetadata()
            .filter({ $0.bookID != book.id && $0.fileNodeIdentifier == identifier })
            .max(by: { $0.updatedAt < $1.updatedAt })
        else { return }

        let oldBookID = matched.bookID
        matched.bookID = book.id
        matched.updatedAt = Date()
        // bookIDはキャッシュ辞書のキーそのものなので、旧キーから新キーへ移す。
        cachedByBookID?[oldBookID] = nil
        cachedByBookID?[book.id] = matched
        registeredBookIDs.remove(oldBookID)
        saveAndNotify(bookID: book.id)
    }

    /// bookIDからこの本の実URLを解決する(LayoutStore.resolvedURLと同じ考え方)。
    /// セキュリティスコープ付きブックマークが無い/解決できない場合は素のパスへフォールバックし、
    /// どちらでもファイルが見つからなければnilを返す。
    func resolvedURL(forBookID bookID: String) -> URL? {
        if let data = metadata(forBookID: bookID)?.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallbackURL = URL(fileURLWithPath: bookID)
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }
        return fallbackURL
    }

    /// ファイルノード識別子・セキュリティスコープ付きブックマークを持たない行について、
    /// 本を開けた(=アクセス権を持っている)タイミングで補完する。
    /// LayoutStore.backfillFileNodeIdentifierと同じ考え方。
    func backfillIdentifiers(forBookID bookID: String, sourceURL: URL) {
        guard let metadata = metadata(forBookID: bookID) else { return }
        var didChange = false
        if metadata.fileNodeIdentifier == nil, let identifier = FileNodeIdentifier.current(for: sourceURL) {
            metadata.inodeNumber = identifier.inodeNumber
            metadata.volumeDeviceNumber = identifier.volumeDeviceNumber
            didChange = true
        }
        if metadata.bookmarkData == nil, let data = Self.makeBookmarkData(for: sourceURL) {
            metadata.bookmarkData = data
            didChange = true
        }
        guard didChange else { return }
        // 行の増減もbookIDの変化も無いため、キャッシュには手を入れなくてよい
        // (キャッシュが保持しているのはこのmetadata自身と同じ参照)。
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("backfillIdentifiers() failed for bookID=\(bookID): \(error)")
        }
    }

    // MARK: - 内部処理

    /// 直近のsave()が失敗した場合のエラーメッセージ(デバッグ用)。
    /// LayoutStore.lastSaveErrorMessageと同じ目的(try?で握りつぶさず、Console.appから
    /// 追えるようにしておく)。
    private(set) var lastSaveErrorMessage: String?

    private static func makeBookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func saveAndNotify(bookID: String) {
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("save() failed for bookID=\(bookID): \(error)")
        }
        if metadataByBookID()[bookID] != nil {
            registeredBookIDs.insert(bookID)
        } else {
            registeredBookIDs.remove(bookID)
        }
        NotificationCenter.default.post(
            name: .bookMetadataDidChange, object: self, userInfo: ["bookID": bookID]
        )
    }

    private func logSaveFailure(_ detail: String) {
        let message = "qooViewer: BookMetadataStore.\(detail)"
        lastSaveErrorMessage = message
        #if DEBUG
        print(message)
        #endif
        NSLog("%@", message)
    }
}
