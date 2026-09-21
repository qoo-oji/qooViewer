import AppKit
import SwiftUI

extension View {
    /// トラックパッドの左右フリックとマウスのサイドボタンで、ファイルブラウザの「戻る」「進む」を行う(ユーザー要望 2026-09-21)。
    /// 何をどちら向きに読むかは FileBrowserNavigationGesture.swift。ファイルブラウザのペインに 1 つ付ける。
    ///
    /// 操作は一覧のキー(⌘[ / ⌘])と同じ口(`FileBrowserEditResponding`)へ渡すので、戻り先が無いときは何も起きない。
    func fileBrowserNavigationGestures(appState: AppState, actions: FileBrowserActions) -> some View {
        modifier(FileBrowserNavigationGestures(appState: appState, actions: actions))
    }
}

private struct FileBrowserNavigationGestures: ViewModifier {
    let appState: AppState
    let actions: FileBrowserActions

    @State private var monitor = FileBrowserNavigationGestureMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.install(appState: appState, actions: actions) }
            .onDisappear { monitor.remove() }
    }
}

/// NSEventモニタの持ち主(モディファイアに直に持たせない理由は WelcomeGridPinch の MagnifyMonitor と同じ)。
///
/// ■ 受け取る範囲は「このウインドウ」
/// ローカルモニタにはアプリ全体のイベントが届くので、宛先が自分のウインドウのものだけを見る(タブは別の NSWindow)。
/// ペインが出ている間だけ取り付けてあるので、同じウインドウで本を開いている間や本棚の間は働かない。シートが出ている間も
/// 働かない(確認のシートの後ろでフォルダが変わらないように)。ウインドウの中での位置は問わない ―― Finder と同じく、
/// ツリーの上でも操作列の上でも効く。
///
/// ■ イベントは消費しない
/// 一覧のスクロールや、ほかのモニタ(FileBrowserNameClickRename の押し下げの監視)をそのまま働かせる。例外は、移動を
/// 起こしたフリックの**慣性のぶん**だけ ―― 通すと、移った先の一覧が勢いで横へ流れる。
@MainActor
final class FileBrowserNavigationGestureMonitor {
    /// deinitから外すためにnonisolated(unsafe)。触るのはメインスレッドだけ(MagnifyMonitor と同じ)。
    nonisolated(unsafe) private var token: Any?
    private var tracker = FileBrowserSwipeTracker()
    /// 移動を起こしたフリックの慣性を捨てている最中か。
    private var isSwallowingMomentum = false
    /// 押し下げを自分のウインドウで見たサイドボタン(離したときに同じボタンなら移動する)。
    private var pressedButton: Int?

    func install(appState: AppState, actions: FileBrowserActions) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .swipe, .otherMouseDown, .otherMouseUp]
        ) { [weak self, weak appState, weak actions] event in
            guard let self, let window = appState?.hostWindow, event.window === window,
                  window.attachedSheet == nil
            else { return event }
            return self.handle(event, in: window, responder: actions)
        }
    }

    func remove() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
        tracker = FileBrowserSwipeTracker()
        isSwallowingMomentum = false
        pressedButton = nil
    }

    // `.onDisappear`はウインドウを閉じたときに必ず来るとは限らない。取り外し損ねても、箱が解放されれば外れる。
    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }

    private func handle(
        _ event: NSEvent, in window: NSWindow, responder: FileBrowserEditResponding?
    ) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            if !event.phase.isEmpty { isSwallowingMomentum = false }
            if isSwallowingMomentum, !event.momentumPhase.isEmpty {
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    isSwallowingMomentum = false
                }
                return nil
            }
            let command = tracker.feed(
                phase: event.phase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                horizontalRoom: { Self.horizontalRoom(at: event.locationInWindow, in: window) }
            )
            if let command, responder?.canPerform(command) == true {
                responder?.perform(command)
                isSwallowingMomentum = true
            }
        case .swipe:
            // 「ページ間をスワイプ」が3本指/4本指のときの専用イベント。1 回のスワイプにつき 1 個届く。
            if let command = FileBrowserNavigationGesture.command(forSwipeDeltaX: event.deltaX) {
                responder?.perform(command)
            }
        case .otherMouseDown:
            pressedButton = event.buttonNumber
        case .otherMouseUp:
            defer { pressedButton = nil }
            if pressedButton == event.buttonNumber,
               let command = FileBrowserNavigationGesture.command(forMouseButton: event.buttonNumber) {
                responder?.perform(command)
            }
        default:
            break
        }
        return event
    }

    /// ポインタの下の一覧が、いま左・右へまだスクロールできるか(FileBrowserSwipeTracker のコメント)。
    private static func horizontalRoom(
        at locationInWindow: NSPoint, in window: NSWindow
    ) -> (towardLeft: Bool, towardRight: Bool) {
        var view = window.contentView?.hitTest(locationInWindow)
        while let current = view, !(current is NSScrollView) { view = current.superview }
        guard let scrollView = view as? NSScrollView, let document = scrollView.documentView else {
            return (false, false)
        }
        let visible = scrollView.documentVisibleRect
        // 0.5pt 未満の端数は「端にいる」とみなす。
        return (visible.minX > document.bounds.minX + 0.5, visible.maxX < document.bounds.maxX - 0.5)
    }
}
