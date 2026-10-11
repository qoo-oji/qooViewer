import Foundation
import SwiftData

extension AppStores {
    /// AppStores が作るものの置き場所と、起動時につなぐ・始める仕事の選択(2026-10-11 の「GUI 無しで確かめる口」の点検)。
    ///
    /// ■ なぜ外から渡すのか
    /// 以前の `AppStores.init()` は `QooViewerApp.modelContainer.mainContext`・`FileSystemChangeCenter.shared`・`.standard` を直に読み、
    /// テストの中では `RuntimeEnvironment.isRunningTests` で配線ごと外していた。部品(BookRecordRelocator・ExternalMoveSweeper・
    /// FolderSettingBookmarks・MetadataGenerator …)はそれぞれテストされていても、**それらをつなぐ配線**(ファイルの変化が 11 の受け手へ
    /// 届くか、機能の ON/OFF が止めるべき仕事を止めるか)は一度も確かめられていなかった。置き場所と配線の選択を値にしておけば、
    /// テストは自分の ModelContext・suite・一時フォルダ・知らせの箱で AppStores を丸ごと組み立てられる。
    ///
    /// **アプリは `live()` だけを使う。** `live()` はテストホストとして起動したときの振る舞い(共有の状態に触らない)も含めて、
    /// 以前の `init()` と同じ値を返す。
    struct Dependencies {
        /// 保存データ(SwiftData)。5 つのストアとスマートライブラリが共有する 1 つ(CLAUDE.md)。
        var modelContext: ModelContext
        /// 環境設定・キーの割り当て・履歴・フォルダの許可・よく使う項目・自動リネーム・スマートライブラリの保存先。
        var defaults: UserDefaults
        /// シークレットフォルダの一覧の保存先(nil = 保存しない)。
        var secretFolderDefaults: UserDefaults?
        /// ファイル名からメタデータを作る規則(qooMeta)の settings.json。nil なら既定の場所(Application Support)。
        var metadataRulesURL: URL?
        /// 規則の以前の形の引き継ぎ元(nil = 引き継がない)。`metadataRulesURL` が nil のときは使わない(既定の引き継ぎ)。
        var metadataRulesLegacyDefaults: UserDefaults?
        /// コレクションの表紙・札の絵・表紙の元画像の置き場所(nil なら既定の場所)。
        var collectionCoverDirectory: URL?
        var collectionTileDirectory: URL?
        var coverSourceDirectory: URL?
        /// ファイルブラウザのアイコンの絵のディスクキャッシュ。
        var fileBrowserThumbnailDiskCache: FileBrowserThumbnailDiskCache
        /// 表紙の抽出が本を読むときのページ一覧のキャッシュ(nil = 読みも書きもしない)。
        var bookDiskCaches: BookDiskCaches?
        /// メタデータ生成の母体の記録(corpus.json。nil = 保存しない)と、スマートライブラリの前回の一覧(nil = 保存しない)。
        var metadataCorpusURL: URL?
        var smartLibraryCatalogURL: URL?
        /// アプリ自身がファイルを動かした知らせの箱。nil なら購読しない(テストホストとして起動したアプリ)。
        var changeCenter: FileSystemChangeCenter?
        /// 自動リネームが名前を変えるときに使うファイル操作(知らせは `changeCenter` へ届く組であること)。
        var fileOperations: FileOperationService
        /// アプリで 1 つの写しを書き換えてよいか(`MetadataGenerator.appWide`、規則とシークレットフォルダの一覧の写し、
        /// 起動前の予約された全削除、以前の保存物の引き継ぎ)。テストが組み立てるときは false。
        var isAppWide: Bool
        /// 起動時の掃除と追従(下書きの移行・読みだけの行の整理・アプリの外での移動の付け替え・本ではないフォルダの掃除・
        /// フォルダの設定の追従)。
        var runsLaunchSweeps: Bool
        /// 以前の下書き(drafts.json)。`runsLaunchSweeps` のときだけ DB へ移す。
        var metadataDraftStore: MetadataDraftStore?
        /// メタデータ生成を始める(母体の記録の購読を含む)。
        var startsMetadataGeneration: Bool
        /// 自動リネームと、動画のサムネイルの先回り(よく使う項目の中のファイルに触る裏の仕事)を始める。
        var startsBackgroundServices: Bool

        /// アプリ本体が使う値。テストホストとして起動したときは、共有の状態に触る配線を外す(以前の `init()` と同じ)。
        static func live() -> Dependencies {
            let isRunningTests = RuntimeEnvironment.isRunningTests
            return Dependencies(
                modelContext: QooViewerApp.modelContainer.mainContext,
                defaults: .standard,
                // テストの中で走る実物のアプリでは保存せず、以前の一覧の引き継ぎもしない(共有の状態に触らない)。
                secretFolderDefaults: isRunningTests ? nil : .standard,
                // テストの中で走る実物のアプリでは、利用者の規則のファイルを読み書きせず、以前の規則の引き継ぎもしない
                // (共有の状態に触らない。CLAUDE.md)。テストは自分の MetadataRulesStore を使い捨ての場所に作る。
                metadataRulesURL: isRunningTests
                    ? FileManager.default.temporaryDirectory
                        .appendingPathComponent("qooViewerTestHost.rules.\(UUID().uuidString)/settings.json")
                    : nil,
                metadataRulesLegacyDefaults: nil,
                collectionCoverDirectory: nil,
                collectionTileDirectory: nil,
                coverSourceDirectory: nil,
                fileBrowserThumbnailDiskCache: .shared,
                bookDiskCaches: .shared,
                // テストの中では記録を保存しない(共有の状態に触らない)。
                metadataCorpusURL: isRunningTests ? nil : MetadataCorpusStore.defaultURL,
                // 前回の一覧を保存して次の起動で先に出す。テストの中では保存しない(共有の状態に触らない)。
                smartLibraryCatalogURL: isRunningTests ? nil : SmartLibraryCatalog.defaultCacheURL,
                // テストの中で走る実物のアプリでは繋がない(テストの操作で、開発機の本物の保存データとよく使う項目を書き換えない)。
                changeCenter: isRunningTests ? nil : .shared,
                // 名前を変えたことをアプリ全体へ知らせるインスタンス(FileSystemChange の型コメント)。
                fileOperations: .shared,
                isAppWide: true,
                runsLaunchSweeps: !isRunningTests,
                metadataDraftStore: isRunningTests ? nil : MetadataDraftStore(),
                startsMetadataGeneration: !isRunningTests,
                // テストの中で走る実物のアプリでは動かさない(開発機の本物のよく使う項目を読み、名前を変え、本物のキャッシュに書くため)。
                startsBackgroundServices: !isRunningTests
            )
        }
    }
}
