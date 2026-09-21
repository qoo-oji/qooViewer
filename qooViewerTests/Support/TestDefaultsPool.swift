import Foundation
import Synchronization

/// テストが使う使い捨ての UserDefaults の領域(suite)を、**決まった少数の名前で使い回す**置き場(2026-09-22)。
///
/// ■ なぜ使い回すのか
/// 以前はテストのたびに `qooViewerTests.<label>.<UUID>` という新しい名前の領域を作り、最後に
/// `removePersistentDomain` で中身を消していた。ところが**設定ファイル自体はコンテナの Preferences フォルダに残る**
/// ので、テストを流すたびに数百個ずつ増え、Debug 版のコンテナには約 4 万個たまっていた。2026-09-21 の夜、テストを
/// 何度も流した後に macOS の cfprefsd が「Path not accessible」ですべてのアプリの設定の読み書きを断る状態になり、
/// Release 版が空の設定で起動した(再起動で直った。docs/02「テスト」)。直接の原因は macOS 側だが、引き金はこの
/// 大量の領域だった見込みが高い。
///
/// ■ 使い方
/// `checkout()` で空の領域を 1 つ借り、終わったら `release(_:)` で返す。返すときに中身を消す。同時に借りられている数
/// (= 並列に走るテストの数)ぶんの名前しか作らないので、ファイルの数はそれ以上に増えない。
/// 借りるときにも中身を消す(前の実行が落ちて返されなかった領域を、次の実行が使い回しても前の値が残らないように)。
nonisolated enum TestDefaultsPool {
    /// 貸し出しの記録(使っている番号)。
    private static let inUse = Mutex<Set<Int>>([])

    static func name(ofSlot slot: Int) -> String { "qooViewerTests.pool.\(slot)" }

    /// 空の領域を 1 つ借りる。返すのは `Lease.release()`(何度呼んでも 1 回だけ効く)か、`Lease` が解放されたとき。
    static func checkout() -> Lease {
        let slot = inUse.withLock { used -> Int in
            var slot = 0
            while used.contains(slot) { slot += 1 }
            used.insert(slot)
            return slot
        }
        let name = name(ofSlot: slot)
        UserDefaults().removePersistentDomain(forName: name)
        return Lease(slot: slot, name: name, defaults: UserDefaults(suiteName: name) ?? .standard)
    }

    /// 借りた領域 1 つ。**返すのは 1 回だけ**(返した番号はすぐ別のテストが借りうるので、2 回目の後始末が
    /// よその領域を消さないように)。
    final class Lease: @unchecked Sendable {
        let name: String
        let defaults: UserDefaults
        private let slot: Int
        private let released = Mutex(false)

        fileprivate init(slot: Int, name: String, defaults: UserDefaults) {
            self.slot = slot
            self.name = name
            self.defaults = defaults
        }

        /// 中身を消して返す。
        func release() {
            let already = released.withLock { value -> Bool in
                defer { value = true }
                return value
            }
            guard !already else { return }
            UserDefaults().removePersistentDomain(forName: name)
            _ = TestDefaultsPool.inUse.withLock { $0.remove(slot) }
        }

        deinit { release() }
    }
}
