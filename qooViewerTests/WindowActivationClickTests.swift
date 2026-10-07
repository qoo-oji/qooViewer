import AppKit
import Testing

@testable import qooViewer

/// ウインドウを前に出すクリックの見分け方(WindowActivationClick)。捨てる・前に出す動きそのものは実機で確認する。
struct WindowActivationClickTests {
    private func check(
        _ type: NSEvent.EventType = .leftMouseDown, control: Bool = false, at time: TimeInterval, key: Bool,
        activatedAt: TimeInterval, deactivatedAt: TimeInterval = 10
    ) -> Bool {
        WindowActivationClick.isActivationClick(
            eventType: type, isControlClick: control, eventTimestamp: time, windowAppearsActive: key,
            activatedAt: activatedAt, deactivatedAt: deactivatedAt)
    }

    @Test("まだメインでないウインドウへの押し下げは、前に出すクリック")
    func clickOnNonKeyWindow() {
        #expect(check(at: 100, key: false, activatedAt: 50))
    }

    @Test("メインになった・アプリが前面になったのが押し下げより後なら、前に出すクリック")
    func keyChangedAfterTheClick() {
        #expect(check(at: 100, key: true, activatedAt: 100.2))
    }

    @Test("メインで前面でも、後ろへ回った後に前に出た知らせがまだ来ていなければ、前に出すクリック")
    func activationNoticeNotYetArrived() {
        #expect(check(at: 100, key: true, activatedAt: 50, deactivatedAt: 80))
    }

    @Test("メインのウインドウでのふつうのクリックは通す")
    func ordinaryClick() {
        #expect(!check(at: 100, key: true, activatedAt: 50))
    }

    @Test("右クリック・⌃クリック・中ボタン・キー入力は対象外")
    func otherEventsPass() {
        #expect(!check(.rightMouseDown, at: 100, key: false, activatedAt: 50))
        #expect(!check(control: true, at: 100, key: false, activatedAt: 50))
        #expect(!check(.otherMouseDown, at: 100, key: false, activatedAt: 50))
        #expect(!check(.keyDown, at: 100, key: true, activatedAt: 100.2))
    }
}
