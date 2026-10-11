import AppKit

/// 入口が断ったことを利用者へ知らせる最小の合図(ビープ)。**`NSSound.beep()` を直に呼ばず、ここを通す**(2026-10-11)。
///
/// ■ なぜ 1 か所に集めるのか
/// CLAUDE.md の「断る・失敗する入口は少なくともビープで知らせる」は、これまでテストで確かめられなかった ―― ビープは音が鳴るだけで
/// 何も残らないので、「淡色にし損ねた項目を押したら黙って何もしない」のか「ビープした」のかを見分けられない。ここを通せば、テストは
/// `UserFeedback.$recorder.withValue(recorder) { … }` の中で入口を叩き、鳴った回数と場所を確かめられる。
///
/// 記録先は **TaskLocal** にしてある(テストは並行して走るので、アプリで 1 つの記録先だと他のテストのビープまで数えてしまう)。
/// 入口から同期で呼ばれるビープ、その中で作った `Task { }` のビープまでは届く(`Task.detached` には届かない)。
///
/// テストホストの中では、記録先が無ければ鳴らさない(テストの操作が音を出さない。ファイル操作の音と同じ。CLAUDE.md)。
nonisolated enum UserFeedback {
    /// 鳴ったビープの記録先(テストのための口)。
    @TaskLocal static var recorder: FeedbackRecorder?

    static func beep(fileID: StaticString = #fileID, line: UInt = #line) {
        if let recorder {
            recorder.record(FeedbackRecorder.Beep(fileID: "\(fileID)", line: line))
            return
        }
        guard !RuntimeEnvironment.isRunningTests else { return }
        NSSound.beep()
    }
}

/// `UserFeedback.recorder` に入れる記録(テストのための口)。どのスレッドから鳴っても数えられる。
nonisolated final class FeedbackRecorder: @unchecked Sendable {
    struct Beep: Equatable, Sendable {
        /// 鳴らした場所(`#fileID`、例 "qooViewer/AppState.swift")。
        let fileID: String
        let line: UInt
    }

    private let lock = NSLock()
    private var recorded: [Beep] = []

    init() {}

    func record(_ beep: Beep) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(beep)
    }

    var beeps: [Beep] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
