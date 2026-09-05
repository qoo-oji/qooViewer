import Foundation
import Testing

@testable import qooViewer

/// ストアの復旧と「すべてのデータを削除」(App/QooViewerApp.swift)。
///
/// どちらも**実際のアプリのストア・キャッシュ・環境設定**を消す処理なので、テストは必ず
/// 作業フォルダとその場限りの suite を渡す(既定のまま呼んではいけない)。
@MainActor
struct StoreRecoveryTests {

    // MARK: - 取り残された -wal / -shm

    @Test("ストア本体が無いときだけ、-wal と -shm を消す")
    func orphanedAuxiliaryFilesAreRemovedOnlyWithoutTheStore() throws {
        let temporary = try TemporaryDirectory("store")
        let store = temporary.file("default.store")
        let wal = temporary.file("default.store-wal")
        let shm = temporary.file("default.store-shm")

        // 本体があるときは何も消さない ―― 開いているストアの -wal/-shm を消すと壊れる。
        for url in [store, wal, shm] { try Data("x".utf8).write(to: url) }
        QooViewerApp.removeOrphanedAuxiliaryStoreFiles(at: store)
        #expect(FileManager.default.fileExists(atPath: wal.path))
        #expect(FileManager.default.fileExists(atPath: shm.path))

        // 本体だけ消えて -wal/-shm が取り残されると、次の起動でストアを開けない。
        try FileManager.default.removeItem(at: store)
        QooViewerApp.removeOrphanedAuxiliaryStoreFiles(at: store)
        #expect(FileManager.default.fileExists(atPath: wal.path) == false)
        #expect(FileManager.default.fileExists(atPath: shm.path) == false)
    }

    @Test("ストアの削除は本体と -wal / -shm の3つを消す")
    func deletingTheStoreRemovesAllThreeFiles() throws {
        let temporary = try TemporaryDirectory("store")
        let store = temporary.file("default.store")
        for suffix in ["", "-wal", "-shm"] {
            try Data("x".utf8).write(to: temporary.file("default.store\(suffix)"))
        }

        QooViewerApp.deleteStoreFiles(at: store)

        for suffix in ["", "-wal", "-shm"] {
            #expect(FileManager.default.fileExists(atPath: temporary.file("default.store\(suffix)").path) == false)
        }
    }

    // MARK: - 予約された削除

    @Test("予約が無ければ、何も消さない")
    func nothingHappensWithoutAReservation() throws {
        let temporary = try TemporaryDirectory("store")
        let suite = PreferencesSuite(label: "reset")
        let store = temporary.file("default.store")
        try Data("x".utf8).write(to: store)
        suite.defaults.set("keep", forKey: "qooViewer.pref.appAppearance")

        QooViewerApp.performPendingStoreResetIfNeeded(
            defaults: suite.defaults, storeURL: store, domainName: suite.name,
            cacheDirectories: []
        )

        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(suite.storedDomain["qooViewer.pref.appAppearance"] as? String == "keep")
    }

    @Test("ストアだけの削除は、環境設定に手を付けない")
    func aStoreOnlyResetKeepsThePreferences() throws {
        let temporary = try TemporaryDirectory("store")
        let suite = PreferencesSuite(label: "reset")
        let store = temporary.file("default.store")
        try Data("x".utf8).write(to: store)
        suite.defaults.set("keep", forKey: "qooViewer.pref.appAppearance")
        suite.defaults.set(true, forKey: QooViewerApp.pendingStoreResetDefaultsKey)

        QooViewerApp.performPendingStoreResetIfNeeded(
            defaults: suite.defaults, storeURL: store, domainName: suite.name,
            cacheDirectories: []
        )

        #expect(FileManager.default.fileExists(atPath: store.path) == false)
        #expect(suite.storedDomain["qooViewer.pref.appAppearance"] as? String == "keep")
        // 予約は取り下げる(次の起動でもう一度消さない)。
        #expect(suite.defaults.bool(forKey: QooViewerApp.pendingStoreResetDefaultsKey) == false)
    }

    @Test("すべてのデータの削除は、キャッシュも環境設定も消し、フォルダのアクセス権だけ残す")
    func aFullResetKeepsOnlyTheGrantedFolders() throws {
        let temporary = try TemporaryDirectory("store")
        let suite = PreferencesSuite(label: "reset")
        let store = temporary.file("default.store")
        try Data("x".utf8).write(to: store)
        let cache = try temporary.directory("cache")
        try Data("x".utf8).write(to: cache.appendingPathComponent("thumbnail"))

        suite.defaults.set("gone", forKey: "qooViewer.pref.appAppearance")
        suite.defaults.set([Data([0x01])], forKey: FolderAccessStore.defaultsKey)
        suite.defaults.set(true, forKey: QooViewerApp.pendingStoreResetDefaultsKey)
        suite.defaults.set(true, forKey: QooViewerApp.pendingFullResetDefaultsKey)

        QooViewerApp.performPendingStoreResetIfNeeded(
            defaults: suite.defaults, storeURL: store, domainName: suite.name,
            cacheDirectories: [cache]
        )

        #expect(FileManager.default.fileExists(atPath: store.path) == false)
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
        // ドメインごと消える(環境設定・割り当て・履歴・ウインドウの位置・予約のキー自身も)。
        #expect(suite.storedDomain["qooViewer.pref.appAppearance"] == nil)
        #expect(suite.defaults.bool(forKey: QooViewerApp.pendingFullResetDefaultsKey) == false)
        // フォルダのアクセス権だけは控えて書き戻す(ユーザーの指示)。
        #expect((suite.storedDomain[FolderAccessStore.defaultsKey] as? [Data])?.count == 1)
    }
}
