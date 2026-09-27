import AppKit

/// 保存パネル・フォルダ選択・確認のアラートを、**ウインドウに付くシート**として出す(2026-09-27、
/// docs/plans/macos-conventions-audit-2026-09-26.md の 10)。
///
/// 以前は約 40 か所が`runModal()`で、パネルが出ている間はアプリ全体が止まっていた(別のウインドウで本を読み進めることも
/// できない)。macOS の標準では、あるウインドウでの操作から出る確認・保存先の選択はそのウインドウのシートで、ほかの
/// ウインドウは使えるまま。アプリ全体に関わるもの(起動時の保存データの警告、終了の確認、起動時の置き換えの復旧)は
/// これを通さず`runModal()`のまま。
///
/// **出す先**: 渡されたウインドウ(省けば、その時点のキーウインドウ ―― ボタン・右クリック・メニューバーの操作では、
/// 操作されたウインドウがキー)。そのウインドウに既にシートが付いていれば、いちばん上のシートに重ねる。`beginSheet`は
/// シートの付いたウインドウへ出すと**前のシートが閉じるまで待たせる**(NSWindow.h)ので、SwiftUI の`.sheet`の中のボタンから
/// 親のウインドウへ出すと、そのシートを閉じるまで出てこない。シートの上のシートは AppKit が扱う(NSWindow.h の`sheets`の
/// 「nested/sub-sheets」)。
///
/// **シートにしないとき**:
/// - 出す先が無い(ウインドウが 1 枚も無い)、見えていない・しまってある、ポップオーバー → 以前どおりアプリモーダル
///   (ファイルブラウザの圧縮・展開がこの形の最初の例だった。FileBrowserOperationViews)。
/// - いちばん上が既に保存パネルかここで出したアラート(同じウインドウで 2 つ目を頼まれた ―― メニューバーの項目はシートが
///   出ていても押せる)→ パネルは**出さずにビープしてキャンセル扱い**(パネルの上にアプリモーダルのパネルを重ねない)。
///   アラートは知らせを失わないようアプリモーダルで出す。
///
/// シートの間はほかのウインドウが動くので、**パネルが閉じた後に続く処理は、その間に変わりうるもの(機能の ON/OFF・
/// 読み取り専用・開いている本)を確かめ直すこと**(CLAUDE.md「re-check the flag after every await」と同じ理由)。
@MainActor
enum WindowSheet {
    enum Placement: Equatable {
        case sheet(NSWindow)
        case appModal
        /// 同じウインドウでパネルかアラートが既に出ている。
        case busy
    }

    /// ここで出しているアラートのウインドウ。上に重ねない。
    private static var presentedAlertWindows: Set<ObjectIdentifier> = []

    /// どこへ出すか。
    static func placement(for window: NSWindow?) -> Placement {
        guard var host = window ?? NSApp.keyWindow else { return .appModal }
        while let sheet = host.attachedSheet { host = sheet }
        if host is NSSavePanel || presentedAlertWindows.contains(ObjectIdentifier(host)) { return .busy }
        guard host.isVisible, !host.isMiniaturized, !isPopoverWindow(host) else { return .appModal }
        return .sheet(host)
    }

    /// ポップオーバーの中のボタン(表紙を選ぶ画面・コレクションの設定)から頼まれたとき、キーウインドウはポップオーバーの
    /// ウインドウ(`_NSPopoverWindow`)。そこへシートは付けられないので、以前どおりアプリモーダルで出す。公開の型が無いので名前で見る。
    private static func isPopoverWindow(_ window: NSWindow) -> Bool {
        NSStringFromClass(type(of: window)).contains("Popover")
    }

    /// シートの完了ハンドラの中では、シートはまだウインドウに付いている(AppKit は完了ハンドラが返ってから下ろす。10.9 の
    /// AppKit リリースノート)。そこでウインドウを閉じると`performClose`が断られる(2026-09-27、実機: 複数タブを閉じる確認で
    /// 「ウインドウを閉じる」を押しても、シートの付いたタブだけが残った)。続きはシートが下りた後の回へ回す。
    private static func afterSheetIsGone(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    // MARK: 保存パネル・開くパネル

    /// パネルを出し、閉じたら`completion`を呼ぶ。出す先は呼んだ時点で決める(同期の呼び出し元から使う)。
    static func begin(
        _ panel: NSSavePanel, for window: NSWindow? = nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        switch placement(for: window) {
        case .sheet(let host):
            panel.beginSheetModal(for: host) { response in afterSheetIsGone { completion(response) } }
        case .appModal:
            completion(panel.runModal())
        case .busy:
            NSSound.beep()
            completion(.cancel)
        }
    }

    /// `begin(_:for:completion:)`の async 版。
    static func run(_ panel: NSSavePanel, for window: NSWindow? = nil) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin(panel, for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: アラート

    static func begin(
        _ alert: NSAlert, for window: NSWindow? = nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard case .sheet(let host) = placement(for: window) else {
            completion(alert.runModal())
            return
        }
        let alertWindow = ObjectIdentifier(alert.window)
        presentedAlertWindows.insert(alertWindow)
        alert.beginSheetModal(for: host) { response in
            MainActor.assumeIsolated { _ = presentedAlertWindows.remove(alertWindow) }
            afterSheetIsGone { completion(response) }
        }
    }

    static func run(_ alert: NSAlert, for window: NSWindow? = nil) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin(alert, for: window) { continuation.resume(returning: $0) }
        }
    }
}
