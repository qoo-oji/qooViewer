import Foundation
import Testing

@testable import qooViewer

/// 後始末(`ViewerViewModel.releaseResources()`)をしたビューアが、保存先を手放した後に届いた知らせで DB に触れないこと。
///
/// CI(2026-10-10、Debug と macOS 27)で、`ReadingStateReplacementTests` の直後にテストホストが
/// 「This model instance was destroyed by calling ModelContext.reset」で落ちた(メインスレッド)。後始末をしたビューアが
/// まだ生きているうちに、保存先(メモリ内のコンテナ)が手放され、そこへほかのテストの LayoutStore が送った `.layoutDataDidChange`
/// が届くと、ビューアが読み直しを始め、消えたコンテナの `BookLayoutSettings` に触れて落ちる。
@MainActor
struct ViewerReleaseTests {
    @Test("後始末をしたビューアは、保存先を手放した後に届いたレイアウト・ブックマーク・メタデータの知らせで読み直さない")
    func aReleasedViewerIgnoresStoreNotifications() async throws {
        var harness: ViewerHarness? = try ViewerHarness(label: "released-viewer")
        let book = try await harness!.makeBook(pageCount: 4)
        // レイアウトの行(BookLayoutSettings)がある本にする ―― 読み直しがこの行に触れる。
        harness!.library.layouts.setPageLayoutState(for: book, pageKey: book.pages[0].sortKey, state: .single)
        let viewer = await harness!.open(book)

        harness!.close()
        // 保存先を手放す(テストの後始末でハーネスが解放されたときと同じ)。ビューアはまだ生きている。
        harness = nil

        // ほかのテスト・ウインドウの知らせ。並行して走るほかのテストのビューアを起こさないよう、この本の ID だけを付ける。
        let center = NotificationCenter.default
        let userInfo: [String: Any] = ["bookID": book.id]
        center.post(name: .layoutDataDidChange, object: nil, userInfo: userInfo)
        center.post(name: .bookmarksDidChange, object: nil, userInfo: userInfo)
        center.post(name: .bookMetadataDidChange, object: nil, userInfo: userInfo)
        // レイアウトの読み直しは約 1 フレームまとめてから走る(scheduleLayoutDataReload)。走ってしまえばここで落ちる。
        try await Task.sleep(for: .milliseconds(200))

        #expect(viewer.book.id == book.id)
    }
}
