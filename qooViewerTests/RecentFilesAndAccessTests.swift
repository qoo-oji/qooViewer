import Foundation
import Testing

@testable import qooViewer

/// 「最近開いたファイル」(ViewModels/RecentFilesStore.swift)と、フォルダのアクセス権
/// (ViewModels/FolderAccessStore.swift)。
///
/// どちらも保存先が `UserDefaults` で、`init(defaults:)` でその場限りの suite へ向ける。
@MainActor
struct RecentFilesAndAccessTests {

    // MARK: - 最近開いたファイル

    @Test("記録は新しい順に並び、同じパスは重複しない")
    func historyKeepsTheNewestFirstWithoutDuplicates() throws {
        let suite = PreferencesSuite(label: "recent")
        let temporary = try TemporaryDirectory("recent")
        let store = RecentFilesStore(defaults: suite.defaults)

        let first = temporary.file("first.cbz")
        let second = temporary.file("second.cbz")
        try Data().write(to: first)
        try Data().write(to: second)

        store.record(url: first)
        store.record(url: second)
        #expect(store.entries.map(\.path) == [second.path, first.path])

        // 同じ本をもう一度開いたら、増やさずに先頭へ持ち上げる。
        store.record(url: first)
        #expect(store.entries.map(\.path) == [first.path, second.path])
    }

    @Test("保持件数を超えたぶんは古い順に落ちる")
    func historyIsCappedAtTheConfiguredLimit() throws {
        let suite = PreferencesSuite(label: "recent")
        let temporary = try TemporaryDirectory("recent")
        // 件数の上限は環境設定の値を UserDefaults から直接読む(このストアは AppPreferences を
        // 参照しない)。同じ suite に書いておけば効く。
        suite.defaults.set(10.0, forKey: AppPreferences.recentFilesLimitDefaultsKey)
        let store = RecentFilesStore(defaults: suite.defaults)

        for index in 1...12 {
            let url = temporary.file(String(format: "book%02d.cbz", index))
            try Data().write(to: url)
            store.record(url: url)
        }

        #expect(store.entries.count == 10)
        #expect(store.entries.first?.path == temporary.file("book12.cbz").path)
        #expect(store.entries.contains { $0.path.hasSuffix("book01.cbz") } == false)
    }

    @Test("記録は新旧2つの形式へ書く(古いバージョンへ戻しても履歴が消えないように)")
    func recordingWritesBothStorageFormats() throws {
        let suite = PreferencesSuite(label: "recent")
        let temporary = try TemporaryDirectory("recent")
        let store = RecentFilesStore(defaults: suite.defaults)
        let url = temporary.file("book.cbz")
        try Data().write(to: url)

        store.record(url: url)

        #expect(suite.storedDomain["recentBookEntries"] != nil)
        #expect((suite.storedDomain["recentBookBookmarks"] as? [Data])?.count == 1)
    }

    @Test("一覧が空でも、保存済みの履歴は「すべて削除」で消える")
    func removeAllClearsStoredDataEvenWhenTheListLooksEmpty() throws {
        let suite = PreferencesSuite(label: "recent")
        // 旧形式(ブックマークの配列)だけがある状態。移行直後はパスが未解決なので、
        // 表示用の一覧には出てこない。
        suite.defaults.set([Data([0x01, 0x02])], forKey: "recentBookBookmarks")
        let store = RecentFilesStore(defaults: suite.defaults)
        #expect(store.entries.isEmpty)

        store.removeAll()

        // 一覧の空を見て打ち切ると、「消したはずの履歴が次回起動で復活する」。
        #expect(suite.storedDomain["recentBookBookmarks"] == nil)
        #expect(suite.storedDomain["recentBookEntries"] == nil)
    }

    @Test("1件だけの削除は、保存済みのデータからも消える")
    func removingOneEntryClearsItFromStorage() throws {
        let suite = PreferencesSuite(label: "recent")
        let temporary = try TemporaryDirectory("recent")
        let store = RecentFilesStore(defaults: suite.defaults)
        let keep = temporary.file("keep.cbz")
        let drop = temporary.file("drop.cbz")
        try Data().write(to: keep)
        try Data().write(to: drop)
        store.record(url: keep)
        store.record(url: drop)

        let target = try #require(store.entries.first { $0.path == drop.path })
        store.remove(target)

        #expect(store.entries.map(\.path) == [keep.path])
        #expect(RecentFilesStore(defaults: suite.defaults).entries.map(\.path) == [keep.path])
    }

    // MARK: - フォルダのアクセス権

    @Test("許可したフォルダは保存され、開き直しても残る")
    func grantedFoldersArePersisted() throws {
        let suite = PreferencesSuite(label: "access")
        let temporary = try TemporaryDirectory("access")
        let folder = try temporary.directory("granted")
        let store = FolderAccessStore(defaults: suite.defaults)

        #expect(store.add(url: folder))
        #expect(store.entries.map(\.url.path) == [folder.path])
        #expect(suite.storedDomain[FolderAccessStore.defaultsKey] != nil)

        let reopened = FolderAccessStore(defaults: suite.defaults)
        #expect(reopened.entries.map(\.url.path) == [folder.path])

        let entry = try #require(reopened.entries.first)
        reopened.remove(entry)
        #expect(reopened.entries.isEmpty)
    }

    @Test("既に許可済みのフォルダの配下は、重ねて許可しない")
    func aDescendantOfAGrantedFolderIsNotAddedAgain() throws {
        let suite = PreferencesSuite(label: "access")
        let temporary = try TemporaryDirectory("access")
        let parent = try temporary.directory("parent")
        let child = try temporary.directory("parent/child")
        let store = FolderAccessStore(defaults: suite.defaults)

        #expect(store.add(url: parent))
        // サンドボックスのアクセス許可は配下すべてに及ぶので、追加の処理は要らない。
        #expect(store.add(url: child))
        #expect(store.entries.map(\.url.path) == [parent.path])
        #expect(store.isPathCovered(child.appendingPathComponent("book.cbz")))
    }

    @Test("新しく許可したフォルダの配下にあたる既存の許可は、冗長なので取り除く")
    func grantingAnAncestorRemovesTheRedundantChildren() throws {
        let suite = PreferencesSuite(label: "access")
        let temporary = try TemporaryDirectory("access")
        let parent = try temporary.directory("parent")
        let child = try temporary.directory("parent/child")
        let store = FolderAccessStore(defaults: suite.defaults)

        #expect(store.add(url: child))
        #expect(store.add(url: parent))
        #expect(store.entries.map(\.url.path) == [parent.path])
    }

    @Test("配下かどうかは、パスの区切りの単位で比べる")
    func coverageIsComparedComponentWise() throws {
        let suite = PreferencesSuite(label: "access")
        let temporary = try TemporaryDirectory("access")
        let granted = try temporary.directory("cover")
        let sibling = try temporary.directory("coverage")
        let store = FolderAccessStore(defaults: suite.defaults)

        #expect(store.add(url: granted))
        // 単純な前方一致だと "…/cover" が "…/coverage" にも一致してしまう。
        #expect(store.isPathCovered(granted.appendingPathComponent("book.cbz")))
        #expect(store.isPathCovered(sibling.appendingPathComponent("book.cbz")) == false)
        // フォルダ自身も「配下」に含む(改めて許可し直す必要は無い)。
        #expect(store.isPathCovered(granted))
    }
}
