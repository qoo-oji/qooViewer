import Foundation

/// プロセスの実行環境の判定を 1 箇所に集める(2026-09-13。qooLibrary の同名の型と同じ考え方)。
nonisolated enum RuntimeEnvironment {
    /// テストホストとして動いているか。**テストは TEST_HOST = 実物のアプリの中で走る**ので、アプリの起動処理も
    /// ウインドウも本物が動く。そこで開発機の共有の状態に触れる・利用者の目に付く動きを止めるために使う:
    /// - `SystemSoundPlayer` … 音を鳴らさない(テストのたびにゴミ箱の音が鳴る)
    /// - `ContentView` … ウェルカム画面を本棚で始める(ファイルブラウザで始めると実際のホームを読みに行く)
    ///
    /// テストランナーは XCTest の設定ファイルを環境変数で渡す(Swift Testing でも xcodebuild の実行では同じ)。
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
