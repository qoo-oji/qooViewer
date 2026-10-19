import Foundation
import Testing

@testable import qooViewer

/// StackNest の本の要求の同時数の門(StackNestRequestGate)。列ごとの上限・返した許可の引き継ぎ・待ちの取り消し・
/// 表示の列への移し替えを固定する。
struct StackNestRequestGateTests {
    @Test("背景は 4 件まで、合わせて 6 件まで。表示は背景が埋まっていても空きがあれば通る。返すと待っている人へ渡す")
    func limitsEachLane() async throws {
        let gate = StackNestRequestGate()
        var held: [StackNestRequestGate.Permit] = []
        for _ in 0..<StackNestRequestGate.backgroundLimit {
            held.append(try await gate.acquire(.background))
        }
        #expect(gate.inUseCount(.background) == StackNestRequestGate.backgroundLimit)
        let waiting = Task { try await gate.acquire(.background) }
        #expect(await Self.waitUntil { gate.waiterCount(.background) == 1 })
        // 表示の列は背景の列が埋まっていても通る。
        let display = try await gate.acquire(.display)
        #expect(display.lane == .display)
        held.removeFirst().release()
        let granted = try await waiting.value
        #expect(granted.lane == .background)
        // 引き継いだので数は変わらない。
        #expect(gate.inUseCount(.background) == StackNestRequestGate.backgroundLimit)
        granted.release()
        held.forEach { $0.release() }
        display.release()
        #expect(gate.inUseCount(.background) == 0)
        #expect(gate.inUseCount(.display) == 0)
    }

    @Test("合わせた上限に届いたら表示も待ち、空きが出たら待っている表示を背景より先に通す")
    func displayWaitersGoFirst() async throws {
        let gate = StackNestRequestGate()
        var held = try await (0..<StackNestRequestGate.totalLimit).asyncMap { _ in try await gate.acquire(.display) }
        let background = Task { try await gate.acquire(.background) }
        #expect(await Self.waitUntil { gate.waiterCount(.background) == 1 })
        let display = Task { try await gate.acquire(.display) }
        #expect(await Self.waitUntil { gate.waiterCount(.display) == 1 })
        held.removeFirst().release()
        let first = try await display.value
        #expect(first.lane == .display)
        #expect(gate.waiterCount(.background) == 1)
        held.removeFirst().release()
        let second = try await background.value
        #expect(second.lane == .background)
        first.release()
        second.release()
        held.forEach { $0.release() }
        #expect(gate.inUseCount(.display) == 0)
        #expect(gate.inUseCount(.background) == 0)
    }

    @Test("待っている間に取り消されたら CancellationError で抜け、許可を取らない(数が漏れない)")
    func cancelledWaiterLeavesNoPermit() async throws {
        let gate = StackNestRequestGate()
        let held = try await (0..<StackNestRequestGate.totalLimit).asyncMap { _ in try await gate.acquire(.display) }
        let waiting = Task { try await gate.acquire(.display) }
        #expect(await Self.waitUntil { gate.waiterCount(.display) == 1 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(gate.waiterCount(.display) == 0)
        held.forEach { $0.release() }
        #expect(gate.inUseCount(.display) == 0)
    }

    @Test("取り消された Task からは、待たずに CancellationError")
    func alreadyCancelledTaskDoesNotQueue() async {
        let gate = StackNestRequestGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await gate.acquire(.background)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(gate.inUseCount(.background) == 0)
    }

    @Test("背景の列で待っている読み込みに表示が追いついたら、表示の列へ移す(空いていればその場で通す)")
    func promotesAWaitingKeyToTheDisplayLane() async throws {
        let gate = StackNestRequestGate()
        let held = try await (0..<StackNestRequestGate.backgroundLimit).asyncMap { _ in try await gate.acquire(.background) }
        let waiting = Task { try await gate.acquire(.background, key: "page-7") }
        #expect(await Self.waitUntil { gate.waiterCount(.background) == 1 })
        gate.promote(key: "page-7")
        let granted = try await waiting.value
        #expect(granted.lane == .display)
        #expect(gate.waiterCount(.background) == 0)
        #expect(gate.inUseCount(.display) == 1)
        granted.release()
        held.forEach { $0.release() }
        #expect(gate.inUseCount(.display) == 0)
        #expect(gate.inUseCount(.background) == 0)
    }

    @Test("許可は 1 度だけ返る(release を 2 度呼んでも、手放しても数は 1 つだけ減る)")
    func permitReleasesOnce() async throws {
        let gate = StackNestRequestGate()
        var permit: StackNestRequestGate.Permit? = try await gate.acquire(.display)
        let other = try await gate.acquire(.display)
        permit?.release()
        permit?.release()
        permit = nil
        #expect(gate.inUseCount(.display) == 1)
        other.release()
        #expect(gate.inUseCount(.display) == 0)
    }

    /// 条件が成り立つまで(最長 5 秒)待つ。
    private static func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let limit = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= limit { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
