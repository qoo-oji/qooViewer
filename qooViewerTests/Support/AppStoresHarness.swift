import Combine
import Foundation
import SwiftData

@testable import qooViewer

/// アプリ全体の入れ物(`AppStores`)を、**テスト 1 つぶんの置き場所と知らせの箱**で丸ごと組み立てる。
///
/// アプリの `AppStores()` は `Dependencies.live()`(実物の SwiftData・`.standard`・`FileSystemChangeCenter.shared`)で作られる。
/// ここでは `AppStores(dependencies:)` に、メモリ内のコンテナ・借りた suite・作業フォルダ・このテストの箱を渡す。
/// アプリで 1 つの写し(`MetadataGenerator.appWide`・シークレットフォルダや規則の写し)には触らない(`isAppWide: false`)。
///
/// 配線そのもの(ファイルの変化が受け手へ届くか、機能の ON/OFF が仕事を止めるか)を確かめるための入口。ストア単体の振る舞いは
/// `InMemoryLibrary` で確かめる。**`close()` を必ず呼ぶこと**(購読を外してから suite とフォルダを返す)。
@MainActor
final class AppStoresHarness {
    let temporary: TemporaryDirectory
    let container: ModelContainer
    let changeCenter = FileSystemChangeCenter()
    let fileOperations: FileOperationService
    let stores: AppStores
    private let suite: TestDefaultsPool.Lease

    /// - Parameter configure: 既定の選択(知らせの箱は購読する。起動時の掃除・メタデータ生成・裏の仕事は始めない)を変える。
    init(
        label: String = "app-stores",
        configure: (inout AppStores.Dependencies) -> Void = { _ in }
    ) throws {
        temporary = try TemporaryDirectory(label)
        let configuration = ModelConfiguration(schema: QooViewerApp.modelSchema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: QooViewerApp.modelSchema, configurations: [configuration])
        suite = TestDefaultsPool.checkout()
        let changeCenter = changeCenter
        fileOperations = FileOperationService(
            environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")),
            changeObserver: { changeCenter.report($0) }
        )
        var dependencies = AppStores.Dependencies(
            modelContext: container.mainContext,
            defaults: suite.defaults,
            secretFolderDefaults: nil,
            metadataRulesURL: temporary.file("rules/settings.json"),
            metadataRulesLegacyDefaults: nil,
            collectionCoverDirectory: temporary.file("covers"),
            collectionTileDirectory: temporary.file("tiles"),
            coverSourceDirectory: temporary.file("cover-sources"),
            fileBrowserThumbnailDiskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("file-browser-thumbnails")),
            bookDiskCaches: BookDiskCaches(directory: temporary.file("book-caches")),
            metadataCorpusURL: temporary.file("corpus.json"),
            smartLibraryCatalogURL: nil,
            changeCenter: changeCenter,
            fileOperations: fileOperations,
            isAppWide: false,
            runsLaunchSweeps: false,
            metadataDraftStore: nil,
            startsMetadataGeneration: false,
            startsBackgroundServices: false
        )
        configure(&dependencies)
        stores = AppStores(dependencies: dependencies)
    }

    var context: ModelContext { container.mainContext }

    /// 知らせを箱へ入れ、まとめる間隔(`FileSystemChangeCenter.coalescingInterval`)の後に受け手へ届くのを待つ。
    func report(_ change: FileSystemChange) async {
        let delivered = OneShotSignal()
        let subscription = changeCenter.changes.sink { _ in delivered.fire() }
        changeCenter.report(change)
        _ = await delivered.wait()
        subscription.cancel()
        // 受け手(AppStores.handleFileSystemChange)は同じ知らせの購読者で、こちらより先に繋いである。届いた時点で走り終えている。
    }

    /// 購読と裏の仕事を畳む。借りた suite は**ここでは返さない**(ストアはまだ suite を持っていて、畳んだ後に残った書き込み ――
    /// 待ち行列の Task・deinit の中の didSet ―― が、返した後に別のテストへ貸された suite に落ちうる。2026-10-11 のレビュー)。
    /// 返すのはハーネスが手放されるとき(deinit)。
    func close() {
        stores.releaseResources()
    }

    deinit {
        suite.release()
    }
}
