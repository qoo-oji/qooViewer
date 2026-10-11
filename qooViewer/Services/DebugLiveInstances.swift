import Foundation
import Synchronization

/// 生きているインスタンスの数(Debug ビルドだけが数える。2026-10-11)。
///
/// 本のウインドウを閉じた後に AppState・ViewerViewModel・PageLoader が残るリーク(docs/12「閉じたウインドウのリーク」)は、
/// これまで `heap` の出力を人が読んで確かめていた。数を持っておけば、Debug の制御口(DebugControlPort の `state`)から読めるので、
/// 開いて閉じる操作をスクリプトで繰り返し、数が戻るかで回帰を判定できる。Release では呼び出しごと消える(`#if DEBUG`)。
nonisolated enum DebugLiveInstances {
    private static let counts = Mutex<[String: Int]>([:])

    static func didCreate(_ type: String) {
        counts.withLock { $0[type, default: 0] += 1 }
    }

    static func didRelease(_ type: String) {
        counts.withLock { $0[type, default: 0] -= 1 }
    }

    static var snapshot: [String: Int] {
        counts.withLock { $0 }
    }
}
