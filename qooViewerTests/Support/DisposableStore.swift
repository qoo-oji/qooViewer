import Foundation
import SwiftData

@testable import qooViewer

/// **ディスク上の使い捨てストア**。テスト1つぶんの一時フォルダに置いたSQLiteのストアを、
/// 好きなスキーマで何度でも開き直せる(2026-09-13)。
///
/// ■ なぜInMemoryLibraryだけでは足りなかったのか
/// メモリ内のストアは「保存 → 閉じる → 開き直す」を通らない。スキーマの移行も起きない。
/// 2026-09-11にコレクション表紙の3列が消えた事故は、まさにその2つ ―― **古いアプリが新しい
/// ストアを開いたときの移行**と、**開き直したときに何が残っているか** ―― の上で起きたので、
/// メモリ内のテストが何本あっても気づけなかった(StoreSchemaGuardの型コメント)。
///
/// 置き場所はTemporaryDirectory(サンドボックスではコンテナの`tmp/`)で、**利用者の本物の
/// ストアには触れない**。手放すとフォルダごと消える。
@MainActor
final class DisposableStore {
    private let directory: TemporaryDirectory
    let url: URL

    init(_ label: String) throws {
        directory = try TemporaryDirectory("store-\(label)")
        url = directory.file("default.store")
    }

    /// このストアを`types`のスキーマで開く。移行が要ればSwiftDataがここで行う。
    ///
    /// 開き直しを確かめるときは、**前のコンテナとその上のストア(LayoutStore等)を先に手放す**
    /// こと(`do { }`の中で使い切る)。
    func open(_ types: [any PersistentModel.Type]) throws -> ModelContainer {
        let schema = Schema(types)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
    }

    /// アプリと同じスキーマで開く。
    func openCurrent() throws -> ModelContainer {
        try open(QooViewerApp.modelTypes)
    }

    /// 同じフォルダの中のファイル(表紙の保管庫などを隣に置くため)。
    func file(_ name: String) -> URL {
        directory.file(name)
    }
}
