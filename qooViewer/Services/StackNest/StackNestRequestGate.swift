import Foundation

/// StackNest の要求の同時数を絞る門(スレッドを塞がずに待つ)。接続先(StackNest の 127.0.0.1 のポート)ごとに 1 つで、同じ StackNest の
/// 本どうしは共有する(StackNestSessions.Book.gate)。
///
/// ■ なぜ要るか(2026-10-18 のレビュー)
/// 以前はページの取り寄せのたびに `FileIO` のスレッドを 1 本借り、部品の同期の口(`StackNestBlockingReader`)で応答を待っていた。
/// 取り寄せはデコードの枠の外なので、ページ一覧のセル・先読み・寸法の下調べが頼んだ数だけ同時にスレッドが塞がり(1 本最長 25 秒×
/// 最大 3 回)、StackNest が応答しないと数ウインドウでプロセスのスレッドの上限(512)に届いて、ほかの本やファイルブラウザの
/// 読み書きまで止まりえた。StackNest が応答していても、受け取ったバイト列が枠の数を超えて同時にメモリに載った。また、接続先
/// 1 つに同時 6 本までしかつながらないので、後ろに並んだ要求は待ちの時間切れ(部品は並んでいる間も数える)で失敗しえた ―― 先読みの
/// 後ろに並んだ表示のページも。
///
/// 今は部品の async の口で待ち(スレッドを使わない)、その前にこの門で同時数を絞る:
/// - 合わせて `totalLimit`(接続先 1 つの同時の接続数と同じ 6)まで。
/// - 先読み・サムネイル・寸法(`background`)は、そのうち `backgroundLimit`(4)まで。残り(少なくとも 2)は表示が使える。
/// - 表示(`display`)は空いていればいくつでも使える(応答の止まった表示のページが 2 つあっても、3 つ目の表示は通る)。
/// - 空きが出たら、待っている表示を先に通す。
/// PageLoader は許可をデコードが終わるまで持つので、取り寄せたまま枠を待つバイト列も門の数で頭打ちになる。
///
/// 背景の列で待っている読み込みに表示の要求が合流したら(PageLoader の先読みに表示が追いついた)、`promote(key:)` でその待ちを
/// 表示の列へ移す(PageLoader の `promoteDecodeWaiter` と同じ考え)。
///
/// 待っている間に取り消されたら `CancellationError` で抜ける(許可は取らない)。
nonisolated final class StackNestRequestGate: @unchecked Sendable {
    enum Lane: Sendable {
        /// いま表示するページ・利用者の操作(書き出し・情報など)。
        case display
        /// 先読み・サムネイル・寸法の下調べ。
        case background
    }

    /// 合わせた同時数。接続先 1 つの同時の接続数(URLSession の既定の 6。StackNestConnector はこれに manifest と書き戻しの分の
    /// 余りを足した `StackNestConnectorPolicy.maxConnectionsPerHost`)。
    static let totalLimit = 6
    /// そのうち、先読み・サムネイル・寸法が使える数。残りは表示のために空けておく。
    static let backgroundLimit = 4

    /// 許可 1 つ。`release()` を呼ぶか、手放したときに返る(返すのは 1 度だけ)。
    final class Permit: @unchecked Sendable {
        private weak var gate: StackNestRequestGate?
        /// どちらの列の許可か(背景の列で並んでいて表示の列へ移ったものは表示の列)。
        let lane: Lane
        private let lock = NSLock()
        private var isReleased = false

        fileprivate init(gate: StackNestRequestGate, lane: Lane) {
            self.gate = gate
            self.lane = lane
        }

        func release() {
            let releases = lock.withLock { () -> Bool in
                guard !isReleased else { return false }
                isReleased = true
                return true
            }
            if releases { gate?.release(lane) }
        }

        deinit { release() }
    }

    private struct Waiter {
        let id: UInt64
        let key: String?
        let continuation: CheckedContinuation<Lane, any Error>
    }

    /// 待ちの札の状態。札は、並ぶ前に取り消された・並んでいる、の間だけ `waitStates` にある。
    private enum WaitState { case allocated, queued(Lane), cancelledEarly }

    private let lock = NSLock()
    /// 以下は `lock` の中でだけ読み書きする。
    private var totalInUse = 0
    private var backgroundInUse = 0
    private var waiters: [Lane: [Waiter]] = [.display: [], .background: []]
    private var waitStates: [UInt64: WaitState] = [:]
    private var nextWaiterID: UInt64 = 0

    init() {}

    /// 許可を取る(空くまで待つ)。取り消されたら `CancellationError`。
    /// - Parameter key: `promote(key:)` で表示の列へ移すための鍵(PageLoader の inFlightKey)。
    func acquire(_ lane: Lane, key: String? = nil) async throws -> Permit {
        try Task.checkCancellation()
        let id: UInt64? = lock.withLock {
            // 待っている表示を追い越さない(表示の待ちがあれば、背景は並ぶ)。
            if canGrantLocked(lane), lane == .display || (waiters[.display]?.isEmpty ?? true) {
                grantLocked(lane)
                return nil
            }
            nextWaiterID += 1
            waitStates[nextWaiterID] = .allocated
            return nextWaiterID
        }
        guard let id else { return Permit(gate: self, lane: lane) }
        let granted = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lane, any Error>) in
                let ready: [(Waiter, Lane)]? = lock.withLock {
                    // 取り消しの閉包が先に走っていたら(並ぶ前の取り消し)、並ばない。
                    if case .cancelledEarly? = waitStates[id] {
                        waitStates[id] = nil
                        return nil
                    }
                    waitStates[id] = .queued(lane)
                    waiters[lane, default: []].append(Waiter(id: id, key: key, continuation: continuation))
                    // 札を作ってから並ぶまでの間に空いていれば、ここで通す。
                    return pumpLocked()
                }
                guard let ready else { return continuation.resume(throwing: CancellationError()) }
                Self.resume(ready)
            }
        } onCancel: {
            let waiter: Waiter? = lock.withLock {
                switch waitStates[id] {
                case .queued(let queuedLane)?:
                    waitStates[id] = nil
                    guard let index = waiters[queuedLane]?.firstIndex(where: { $0.id == id }) else { return nil }
                    return waiters[queuedLane]?.remove(at: index)
                case .allocated?:
                    // まだ並んでいない(継続を作る前)。並ぶ側が見て抜ける。
                    waitStates[id] = .cancelledEarly
                    return nil
                case .cancelledEarly?, nil:
                    // もう許可を受け取った(pump が渡した)。取り消しは、許可を持った呼び出し側が見る。
                    return nil
                }
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
        // 並んでいた人は、渡した側(`pumpLocked`)が数え済み。
        return Permit(gate: self, lane: granted)
    }

    /// 背景の列で `key` の待ちがあれば表示の列へ移す(空いていればその場で許可を渡す)。
    func promote(key: String) {
        let ready: [(Waiter, Lane)] = lock.withLock {
            // 同じ鍵が 2 つ並ぶときは新しい方(後ろ)。前の方は取り消した読み込みの古い待ちでありうる(PageLoader.promoteDecodeWaiter)。
            guard let index = waiters[.background]?.lastIndex(where: { $0.key == key }),
                  let waiter = waiters[.background]?.remove(at: index)
            else { return [] }
            waitStates[waiter.id] = .queued(.display)
            waiters[.display, default: []].append(waiter)
            return pumpLocked()
        }
        Self.resume(ready)
    }

    /// いま使っている数(試験用)。
    func inUseCount(_ lane: Lane) -> Int {
        lock.withLock { lane == .background ? backgroundInUse : totalInUse - backgroundInUse }
    }

    /// 待っている数(試験用)。
    func waiterCount(_ lane: Lane) -> Int { lock.withLock { waiters[lane]?.count ?? 0 } }

    private func canGrantLocked(_ lane: Lane) -> Bool {
        guard totalInUse < Self.totalLimit else { return false }
        return lane == .display || backgroundInUse < Self.backgroundLimit
    }

    private func grantLocked(_ lane: Lane) {
        totalInUse += 1
        if lane == .background { backgroundInUse += 1 }
    }

    /// 空きのぶん、待っている人へ許可を渡す(表示が先)。渡した人とその列を返す(再開はロックの外で)。
    private func pumpLocked() -> [(Waiter, Lane)] {
        var ready: [(Waiter, Lane)] = []
        for lane in [Lane.display, .background] {
            while canGrantLocked(lane), var queue = waiters[lane], !queue.isEmpty {
                let next = queue.removeFirst()
                waiters[lane] = queue
                waitStates[next.id] = nil
                grantLocked(lane)
                ready.append((next, lane))
            }
        }
        return ready
    }

    private static func resume(_ ready: [(Waiter, Lane)]) {
        for (waiter, lane) in ready { waiter.continuation.resume(returning: lane) }
    }

    /// 許可を返し、空いたぶんを待っている人へ渡す。
    fileprivate func release(_ lane: Lane) {
        let ready: [(Waiter, Lane)] = lock.withLock {
            totalInUse = max(totalInUse - 1, 0)
            if lane == .background { backgroundInUse = max(backgroundInUse - 1, 0) }
            return pumpLocked()
        }
        Self.resume(ready)
    }
}
