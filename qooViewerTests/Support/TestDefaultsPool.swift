import Foundation
import Synchronization
import Testing

/// テストが使う使い捨ての UserDefaults の領域(suite)を、**決まった少数の名前で使い回す**置き場(2026-09-22)。
///
/// ■ なぜ使い回すのか
/// 以前はテストのたびに `qooViewerTests.<label>.<UUID>` という新しい名前の領域を作り、最後に
/// `removePersistentDomain` で中身を消していた。ところが**設定ファイル自体はコンテナの Preferences フォルダに残る**
/// (cfprefsd が空のファイルを書き戻す。Web 上の複数の実測と一致)ので、Debug 版のコンテナには約 4 万個たまっていた。
/// 使い回せばファイルは増えない。
///
/// ■ 同時に借りる数の上限(2026-09-23)
/// 2026-09-21 夜と 09-23 朝に、テストの後で macOS の cfprefsd がすべてのアプリの設定の読み書きを断る状態になり、
/// Release 版が空の設定で起動した(再起動で直った)。09-22 の時点では「残ったファイルの数が引き金」と見ていたが、
/// それは裏付けの無い推測で、この置き場を入れた後に再発した。再起動後に測った事実(docs/02「テストと cfprefsd」):
/// - ユーザーごとの cfprefsd は開けるファイルが 512 まで(`/System/Library/LaunchAgents/com.apple.cfprefsd.xpc.agent.plist`)
/// - Swift Testing は既定で並行数に上限が無く、開始 2 秒で 127 のテストが走り出し、借りたまま返さない領域が約 490 に
///   なった。そのとき cfprefsd は Debug 版の設定フォルダを約 485 個開いていた(テストホストを止めると 9 に戻る)
/// - 上限に当たると「Too many open files」で読み書きが断られ、再起動まで戻らなかった(09-23 朝)
/// 領域 1 つにつき cfprefsd がフォルダを 1 つ開く仕組み自体は、公開資料では確かめられていない(数が一致するという実測だけ)。
/// そこで並行数をスキームの `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`(= 8。実測で開くのは最大 39)で絞り、
/// ここでも同時に借りる数を `maximumLeases` で止める。この変数は Swift Testing の「実験的」な設定なので、
/// 将来黙って効かなくなったとき、Mac 全体の設定を壊す前に**そのテストを失敗させて**知らせるための安全装置。
/// 上限を越えた分は新しい領域を作らず、共用の 1 つ(`overflowName`)を渡す ―― cfprefsd が開く数は増えず、
/// テストは失敗として記録されるので、中身が他のテストと混ざっても判定を誤らない。
/// テストホストを止める形(`precondition`)は、クラッシュ記録と「予期しない理由で終了」のダイアログが出るので
/// やめた(2026-09-23 ユーザー指示)。
/// 空くまで待たせないのは、`checkout()` が同期関数で、メインアクターのテストがそこで止まると抜けられないため。
///
/// ■ 使い方
/// `checkout()` で空の領域を 1 つ借り、終わったら `release(_:)` で返す。返すときに中身を消す。同時に借りられている数
/// ぶんの名前しか作らないので、ファイルの数はそれ以上に増えない。
/// 借りるときにも中身を消す(前の実行が落ちて返されなかった領域を、次の実行が使い回しても前の値が残らないように)。
nonisolated enum TestDefaultsPool {
    /// 貸し出しの記録(使っている番号)。
    private static let inUse = Mutex<Set<Int>>([])

    /// 同時に借りられる数の上限。並行 8 で全テストを回したとき、cfprefsd が Debug 版の設定フォルダを開いたのは最大 24(実測)。
    /// cfprefsd の 512 より十分少なく、
    /// 並行数の設定が効いているうちは届かない値にしてある(型コメント「同時に借りる数の上限」)。
    static let maximumLeases = 64

    static func name(ofSlot slot: Int) -> String { "qooViewerTests.pool.\(slot)" }

    /// 上限を越えたときに渡す共用の領域(型コメント「同時に借りる数の上限」)。
    static let overflowName = "qooViewerTests.pool.overflow"

    /// 空の領域を 1 つ借りる。返すのは `Lease.release()`(何度呼んでも 1 回だけ効く)か、`Lease` が解放されたとき。
    static func checkout() -> Lease {
        let slot = inUse.withLock { used -> Int? in
            var slot = 0
            while used.contains(slot) { slot += 1 }
            // 上限を越えたら新しい領域を作らない: 作り続ければ cfprefsd の上限まで開かせ、Mac 全体の設定の
            // 読み書きが再起動まで止まる。
            guard slot < maximumLeases else { return nil }
            used.insert(slot)
            return slot
        }
        guard let slot else {
            let message: String =
                "UserDefaults の領域を同時に \(maximumLeases) 個より多く借りようとした。テストの並行数の上限"
                    + "(スキームの SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH)が効いていない可能性がある。"
                    + "新しい領域を作り続けると cfprefsd が上限に達し、すべてのアプリの設定が読み書きできなくなる"
                    + "(TestDefaultsPool 参照)。このテストには共用の領域を渡した"
            Issue.record(Comment(rawValue: message))
            return Lease(slot: nil, name: overflowName, defaults: UserDefaults(suiteName: overflowName) ?? .standard)
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
        /// 共用の領域(上限越え)なら nil。
        private let slot: Int?
        private let released = Mutex(false)

        fileprivate init(slot: Int?, name: String, defaults: UserDefaults) {
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
            // 共用の領域は他のテストがまだ使っているので消さない(どのテストも失敗として記録済み)。
            guard !already, let slot else { return }
            UserDefaults().removePersistentDomain(forName: name)
            _ = TestDefaultsPool.inUse.withLock { $0.remove(slot) }
        }

        deinit { release() }
    }
}
