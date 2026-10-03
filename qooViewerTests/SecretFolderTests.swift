import Foundation
import Testing

@testable import qooViewer

/// シークレットフォルダ(2026-10-03。SecretFolderStore、docs/plans/secret-folder-plan.md)。
///
/// アプリの一覧の写し(`SecretFolderStore.appWideFolders`)は共有の状態なので触らない。ここで作るストアは
/// どれも `isAppWide: false`(既定)で、写しへは書かない。
@MainActor
struct SecretFolderTests {
    @Test("中とサブフォルダの本が対象。似た名前の隣のフォルダは対象外")
    func containsBooksUnderTheFolder() {
        let store = SecretFolderStore(defaults: nil)
        store.add(URL(fileURLWithPath: "/架空/秘密", isDirectory: true))
        #expect(store.contains(path: "/架空/秘密"))
        #expect(store.contains(path: "/架空/秘密/本.zip"))
        #expect(store.contains(path: "/架空/秘密/下の階/本.zip"))
        #expect(!store.contains(path: "/架空/秘密ではない/本.zip"))
        #expect(!store.contains(path: "/架空/本.zip"))
        // 一覧にそのまま載っているのはフォルダそのものだけ(右クリックの「外す」)。
        #expect(store.isListed(URL(fileURLWithPath: "/架空/秘密", isDirectory: true)))
        #expect(!store.isListed(URL(fileURLWithPath: "/架空/秘密/下の階", isDirectory: true)))
        // 同じフォルダは 2 度入らない。
        store.add(URL(fileURLWithPath: "/架空/秘密/", isDirectory: true))
        #expect(store.folders == ["/架空/秘密"])
        store.remove("/架空/秘密")
        #expect(store.folders.isEmpty)
        #expect(!store.contains(path: "/架空/秘密/本.zip"))
    }

    @Test("/private/var と /var は同じ場所として比べる(standardizedFileURL は実在するときだけ /private を外す。CI で判明)")
    func privatePrefixIsIgnored() {
        let store = SecretFolderStore(defaults: nil)
        store.add(paths: ["/private/var/架空の一時/秘密"])
        #expect(store.contains(path: "/var/架空の一時/秘密/本.zip"))
        #expect(store.isListed(URL(fileURLWithPath: "/var/架空の一時/秘密", isDirectory: true)))
        // 綴りの違う同じ場所は 2 度入らず、どちらの綴りでも外せる。
        store.add(paths: ["/var/架空の一時/秘密"])
        #expect(store.folders.count == 1)
        store.remove("/var/架空の一時/秘密")
        #expect(store.folders.isEmpty)

        store.add(paths: ["/var/架空の一時/別"])
        #expect(store.contains(path: "/private/var/架空の一時/別/本.zip"))
    }

    @Test("保存して読み直しても残り、名前を変えたフォルダに付いていく")
    func persistsAndFollowsRenames() {
        let suite = TestDefaultsPool.checkout()
        defer { suite.release() }
        let store = SecretFolderStore(defaults: suite.defaults)
        store.add(URL(fileURLWithPath: "/架空/秘密", isDirectory: true))
        var change = FileSystemChange()
        change.relocations = [.init(from: URL(fileURLWithPath: "/架空/秘密"), to: URL(fileURLWithPath: "/架空/移した"))]
        store.relocate(using: change)
        #expect(store.folders == ["/架空/移した"])
        #expect(SecretFolderStore(defaults: suite.defaults).folders == ["/架空/移した"])
    }

    @Test("保存データの読み込みは足すだけ(上書きでも手元のシークレットフォルダを外さない)")
    func importOnlyAdds() {
        let store = SecretFolderStore(defaults: nil)
        store.add(URL(fileURLWithPath: "/架空/手元", isDirectory: true))
        #expect(store.importBackup(paths: ["/架空/持ち込み", "/架空/手元"], replacingExisting: false) == 1)
        #expect(store.folders == ["/架空/手元", "/架空/持ち込み"])
    }

    @Test("書き出しの「環境設定」に入り、読み込むと足される")
    func savedDataRoundTrip() async throws {
        let origin = try InMemoryLibrary(label: "secret-origin")
        defer { origin.close() }
        origin.secretFolders.add(URL(fileURLWithPath: "/架空/秘密", isDirectory: true))
        let (file, _) = await origin.buildExportFile(.everything)
        #expect(file.secretFolders == ["/架空/秘密"])

        let destination = try InMemoryLibrary(label: "secret-destination")
        defer { destination.close() }
        destination.secretFolders.add(URL(fileURLWithPath: "/架空/手元", isDirectory: true))
        // 環境設定のカテゴリを読まないなら足さない。
        await destination.apply(file, policies: LibraryImportExportService.ImportPolicies())
        #expect(destination.secretFolders.folders == ["/架空/手元"])
        let summary = await destination.apply(file, policies: LibraryImportExportService.ImportPolicies(settings: .overwrite))
        #expect(summary.importedSecretFolderCount == 1)
        #expect(destination.secretFolders.folders == ["/架空/手元", "/架空/秘密"])
    }

    @Test("「常にシークレットウインドウで開く」は、ON で、ノーマルの行き先で、シークレットフォルダの本のときだけ回す")
    func privateRoutingDecision() {
        let secret = BookOpenRequest(URL(fileURLWithPath: "/架空/秘密/本.zip"))
        let normal = BookOpenRequest(URL(fileURLWithPath: "/架空/普通/本.zip"))
        let isSecret: (URL) -> Bool = { SecretFolderStore.contains(path: $0.path, in: ["/架空/秘密"]) }
        #expect(BookWindowOpener.shouldOpenPrivately(secret, opensPrivately: false, isEnabled: true, isSecret: isSecret))
        // OFF・もともとシークレットの行き先・シークレットフォルダの外の本は回さない。
        #expect(!BookWindowOpener.shouldOpenPrivately(secret, opensPrivately: false, isEnabled: false, isSecret: isSecret))
        #expect(!BookWindowOpener.shouldOpenPrivately(secret, opensPrivately: true, isEnabled: true, isSecret: isSecret))
        #expect(!BookWindowOpener.shouldOpenPrivately(normal, opensPrivately: false, isEnabled: true, isSecret: isSecret))
        // テストの中では、実物の設定に関わらず回さない(AppPreferences.opensSecretFolderBooksPrivately)。
        #expect(!AppPreferences.opensSecretFolderBooksPrivately)
    }

    @Test("シークレットフォルダの本は保存データに何も残さない本で、ビューアは別の本として作り直す")
    func secretBooksLeaveNoRecord() {
        var book = MangaBook(id: "/架空/秘密/本.zip", title: "本", sourceURL: URL(fileURLWithPath: "/架空/秘密/本.zip"),
                             pages: [])
        #expect(!book.leavesNoRecord)
        let normalIdentity = ViewerHandoff.viewIdentity(of: book)
        book.isInSecretFolder = true
        #expect(book.leavesNoRecord)
        // isTransient(メニューの可否にも使う)は広げない。
        #expect(!book.isTransient)
        // 同じ本でも、シークレットフォルダかが変わった開き直しはビューモデルを作り直す(skipsPersistence は作るときに決まる)。
        #expect(ViewerHandoff.viewIdentity(of: book) != normalIdentity)
    }

    @Test("メタデータの記録(corpus)から、シークレットフォルダの本を外せる")
    func corpusDropsSecretBooks() {
        let corpus = MetadataCorpusStore(url: nil)
        corpus.recordCollectionBooks(["/架空/秘密/本.zip", "/架空/普通/本.zip"])
        corpus.recordSmartLibraryScan(roots: ["/架空"], bookIDs: ["/架空/秘密/別の本.zip", "/架空/普通/別の本.zip"],
                                      isTruncated: false)
        corpus.removeBooks(where: { SecretFolderStore.contains(path: $0, in: ["/架空/秘密"]) })
        #expect(corpus.collectionBookIDs == ["/架空/普通/本.zip"])
        #expect(corpus.smartLibraryBookIDs == ["/架空/普通/別の本.zip"])
    }
}
