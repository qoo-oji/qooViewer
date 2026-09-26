import Foundation

/// 途中で終了すると切れてしまう、利用者が始めた作業(ファイルブラウザの操作・本と表紙と保存データの書き出し・保存データの
/// 読み込み)を数える(2026-09-26)。⌘Q(と、環境設定で最後のウインドウを閉じたときの終了)で、走っている作業があれば確認を
/// 出すため(`AppDelegate.applicationShouldTerminate`)。以前は確認なしで終わり、コピー・圧縮・書き出しが途中で切れた
/// (macOS の標準では、走っている作業があれば終了の前に尋ねる)。
///
/// 数えるのは利用者が始めて、終わりを待っているものだけ。自動リネーム・表紙の抽出・スマートライブラリの集め直しのような裏の
/// 仕事は数えない(次の起動で続きからやり直せる)。
///
/// **テストはこれに触れない**(アプリ全体で 1 つの状態のため)。数える側は `forCurrentProcess` を持ち、テストでは nil になる。
@MainActor
final class RunningWorkRegistry {
    static let shared = RunningWorkRegistry()

    /// 数える側が持つ既定値。テストでは共有の状態に触れないよう nil。
    static var forCurrentProcess: RunningWorkRegistry? {
        RuntimeEnvironment.isRunningTests ? nil : shared
    }

    private var running: Set<UUID> = []

    /// 走っている作業があるか。
    var hasRunningWork: Bool { !running.isEmpty }

    /// 作業を始めたときに呼び、返った印を終わったときに `end` へ渡す。
    func begin() -> UUID {
        let token = UUID()
        running.insert(token)
        return token
    }

    func end(_ token: UUID) {
        running.remove(token)
    }
}
