import SwiftUI

/// 描画では読まない(参照を渡す・操作の中で使うだけの)アプリで 1 つのストアを、**購読せずに**渡す口(2026-10-05 の効率の監査 B9)。
///
/// `@EnvironmentObject` で持つと、そのストアが知らせるたびに持っているビューの body が評価し直される。ContentView・ViewerView・
/// FileBrowserPane は大きな body を持つのに、いくつかのストアを参照を配るためだけに `@EnvironmentObject` で持っていて、表紙を
/// 1 冊抽出するたび(CollectionStore)・メタデータを 500 件書くたび(BookMetadataStore)・本を開くたびの履歴の記録(RecentFilesStore)
/// などで、本を開いている全ウインドウのこれらが組み直されていた。`CollectionAddingContext` と同じ考え方。
///
/// QooViewerApp が本のウインドウの中身(`contentWindow`)に入れる。ストアはアプリの終わりまで生きるので弱い参照で持ち、
/// 読む側は必ずある前提で取り出す(入れ忘れは `@EnvironmentObject` の入れ忘れと同じく、すぐ分かる形で落ちる)。
/// **描画で値を読むストアはここから取らない**(変わっても描き直されない)。
struct UnobservedStores: Equatable {
    weak var collectionStore: CollectionStore?
    weak var coverExtractor: CollectionCoverExtractor?
    weak var bookmarkStore: BookmarkStore?
    weak var layoutStore: LayoutStore?
    weak var metadataStore: BookMetadataStore?
    weak var recentFiles: RecentFilesStore?
    weak var folderAccess: FolderAccessStore?
    weak var launchCoordinator: LaunchCoordinator?
    weak var autoRenameStore: AutoRenameStore?
    weak var autoRenameService: AutoRenameService?
    weak var smartLibraryStore: SmartLibraryStore?
    weak var secretFolderStore: SecretFolderStore?

    /// 同じストアを指していれば同じ(App の body が組み直されるたびに作り直されても、読む側を描き直させない)。
    static func == (lhs: UnobservedStores, rhs: UnobservedStores) -> Bool {
        lhs.collectionStore === rhs.collectionStore && lhs.coverExtractor === rhs.coverExtractor
            && lhs.bookmarkStore === rhs.bookmarkStore && lhs.layoutStore === rhs.layoutStore
            && lhs.metadataStore === rhs.metadataStore && lhs.recentFiles === rhs.recentFiles
            && lhs.folderAccess === rhs.folderAccess && lhs.launchCoordinator === rhs.launchCoordinator
            && lhs.autoRenameStore === rhs.autoRenameStore && lhs.autoRenameService === rhs.autoRenameService
            && lhs.smartLibraryStore === rhs.smartLibraryStore && lhs.secretFolderStore === rhs.secretFolderStore
    }

    /// 必ずある前提で取り出す(型コメント)。
    static func required<Store: AnyObject>(_ store: Store?, _ name: StaticString = #function) -> Store {
        guard let store else { fatalError("UnobservedStores: \(name) が入っていない(QooViewerApp.contentWindow)") }
        return store
    }
}

extension EnvironmentValues {
    @Entry var unobservedStores = UnobservedStores()
}
