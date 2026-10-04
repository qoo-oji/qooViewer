import Combine
import Foundation

// 取り消せる削除の 1 回分(DataUndoStep)。どれも「消す前に控えた値」をストアへ渡して書き戻す・もう一度消すだけで、
// 控えの取り方と書き戻し方はストアの側にある(BookmarkStore / RecentFilesStore / CollectionStore の「取り消せる削除」)。
// ストアは弱く持つ(ストアはアプリと同じだけ生きるが、テストのストアを積み場所が生かし続けないように)。

/// ブックマークの削除(1 件・見開きの 2 件・1 冊分)。
@MainActor
final class BookmarkDeletionUndo: DataUndoStep {
    private weak var store: BookmarkStore?
    private var snapshots: [Bookmark.Snapshot]
    let title: String
    /// 本の付け替えの知らせ(`followRelocation`)。
    private var relocationSubscription: AnyCancellable?

    init(store: BookmarkStore, snapshots: [Bookmark.Snapshot]) {
        self.store = store
        self.snapshots = snapshots
        title = String(localized: "Bookmark Deletion", language: AppLanguage.menuBarLocale)
        relocationSubscription = NotificationCenter.default.publisher(for: .booksDidRelocate)
            .sink { [weak self] notification in
                guard let notice = BookRelocationNotice(notification) else { return }
                MainActor.assumeIsolated { self?.followRelocation(notice) }
            }
    }

    /// 積んでいる間に本が付け替えられたら、控えも新しい bookID・ページの鍵へ移す(2026-10-04 の監査 BE-13)。以前は消した時点の値の
    /// まま書き戻し、その間に改名した本では古いパスに行ができた(左ペインに古い名前の行が現れ、開くと「見つかりません」)。
    /// 控えに `bookmarkData` があれば次の起動の外の移動の追従が拾ったが、編集ウインドウの＋・一括リネームの表紙のように持たない控えは
    /// そのまま残った。
    func followRelocation(_ notice: BookRelocationNotice) {
        snapshots = snapshots.map { snapshot in
            notice.newBookID(for: snapshot.bookID).map(snapshot.relocated(to:)) ?? snapshot
        }
    }

    func undo() -> Bool {
        guard let store else { return false }
        return !store.restore(snapshots).isEmpty
    }

    func redo() -> Bool {
        guard let store else { return false }
        store.delete(ids: Set(snapshots.map(\.id)), bookIDs: Set(snapshots.map(\.bookID)))
        return true
    }

    func discard() {}
}

/// 履歴の削除(1 件・選んだもの・すべて)。
@MainActor
final class HistoryRemovalUndo: DataUndoStep {
    private weak var store: RecentFilesStore?
    private let record: RecentFilesStore.RemovalRecord
    let title: String

    init(store: RecentFilesStore, record: RecentFilesStore.RemovalRecord) {
        self.store = store
        self.record = record
        title = String(localized: "History Deletion", language: AppLanguage.menuBarLocale)
    }

    func undo() -> Bool {
        guard let store else { return false }
        store.restore(record)
        return true
    }

    func redo() -> Bool {
        guard let store else { return false }
        store.reapply(record)
        return true
    }

    func discard() {}
}

/// コレクション・ライブラリの削除。表紙のファイルは、削除したまま積み場所から捨てられたときに消す(CollectionStore のコメント)。
@MainActor
final class CollectionDeletionUndo: DataUndoStep {
    private weak var store: CollectionStore?
    private let record: CollectionStore.CollectionDeletionRecord
    /// いま削除した状態か(取り消した後に捨てられたなら、表紙は消さない)。
    private var isDeleted = true
    let title: String

    init(store: CollectionStore, record: CollectionStore.CollectionDeletionRecord) {
        self.store = store
        self.record = record
        title = String(
            localized: record.library == nil ? "Collection Deletion" : "Library Deletion",
            language: AppLanguage.menuBarLocale
        )
    }

    func undo() -> Bool {
        guard let store, store.restore(record) else { return false }
        isDeleted = false
        return true
    }

    func redo() -> Bool {
        guard let store, store.reapply(record) else { return false }
        isDeleted = true
        return true
    }

    func discard() {
        guard isDeleted else { return }
        store?.finalizeDeletion(record)
    }
}

/// コレクションからの削除。表紙のファイルの扱いは CollectionDeletionUndo と同じ。
@MainActor
final class CollectionItemRemovalUndo: DataUndoStep {
    private weak var store: CollectionStore?
    private let record: CollectionStore.ItemRemovalRecord
    private var isRemoved = true
    let title: String

    init(store: CollectionStore, record: CollectionStore.ItemRemovalRecord) {
        self.store = store
        self.record = record
        title = String(localized: "Removal from Collection", language: AppLanguage.menuBarLocale)
    }

    func undo() -> Bool {
        guard let store, store.restore(record) else { return false }
        isRemoved = false
        return true
    }

    func redo() -> Bool {
        guard let store, store.reapply(record) else { return false }
        isRemoved = true
        return true
    }

    func discard() {
        guard isRemoved else { return }
        store?.finalizeRemoval(record)
    }
}

// MARK: - 呼ぶ側の口

extension DataUndoStack {
    /// ブックマークを消して積む(積み場所が無ければ消すだけ)。
    static func deleteBookmarks(_ bookmarks: [Bookmark], in store: BookmarkStore, recordingOn stack: DataUndoStack?) {
        let snapshots = store.deleteRecording(bookmarks)
        guard let stack, !snapshots.isEmpty else { return }
        stack.push(BookmarkDeletionUndo(store: store, snapshots: snapshots))
    }

    static func deleteAllBookmarks(forBookID bookID: String, in store: BookmarkStore, recordingOn stack: DataUndoStack?) {
        let snapshots = store.deleteAllBookmarksRecording(forBookID: bookID)
        guard let stack, !snapshots.isEmpty else { return }
        stack.push(BookmarkDeletionUndo(store: store, snapshots: snapshots))
    }

    static func removeHistory(_ entries: [RecentFilesStore.Entry], in store: RecentFilesStore, recordingOn stack: DataUndoStack?) {
        guard let record = store.removeRecording(entries), let stack else { return }
        stack.push(HistoryRemovalUndo(store: store, record: record))
    }

    static func removeAllHistory(in store: RecentFilesStore, recordingOn stack: DataUndoStack?) {
        guard let record = store.removeAllRecording(), let stack else { return }
        stack.push(HistoryRemovalUndo(store: store, record: record))
    }

    /// 積み場所が無いときは、今までどおり表紙のファイルまで消す(取り消せないので残す理由が無い)。
    static func deleteCollections(_ collections: [BookCollection], in store: CollectionStore, recordingOn stack: DataUndoStack?) {
        guard let stack else {
            store.delete(collections)
            return
        }
        guard let record = store.deleteRecording(collections) else { return }
        stack.push(CollectionDeletionUndo(store: store, record: record))
    }

    static func deleteLibrary(_ library: BookLibrary, in store: CollectionStore, recordingOn stack: DataUndoStack?) {
        guard let stack else {
            store.delete(library)
            return
        }
        guard let record = store.deleteRecording(library) else { return }
        stack.push(CollectionDeletionUndo(store: store, record: record))
    }

    static func removeItems(_ items: [CollectionItem], in store: CollectionStore, recordingOn stack: DataUndoStack?) {
        guard let stack else {
            store.remove(items)
            return
        }
        guard let record = store.removeRecording(items) else { return }
        stack.push(CollectionItemRemovalUndo(store: store, record: record))
    }
}
