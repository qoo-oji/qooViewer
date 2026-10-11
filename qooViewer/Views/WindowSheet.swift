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

    /// テストホストの中で、答える役(SheetScripting.responder)が無いのに出す先を省かれたら出さずにキャンセル扱いにする。
    /// 省いたときの出す先はキーウインドウ ―― テストホストのアプリのウインドウで、そこへ付けたシートは誰も閉じない(以後のシートが
    /// すべて「既に出ている」になる)。アプリモーダルは `runModal` がテストを止めたままにする。ウインドウを自分で渡すテスト
    /// (WindowSheetTests)は、そのウインドウへ本当に出す。
    private static func refusesInTestHost(_ window: NSWindow?) -> Bool {
        window == nil && RuntimeEnvironment.isRunningTests
    }

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

    /// 出す先を決めたときに辿ったウインドウ(渡されたウインドウ、またはキーウインドウから、いちばん上のシートまで)。
    private static func chain(from window: NSWindow?) -> [NSWindow] {
        guard var current = window ?? NSApp.keyWindow else { return [] }
        var windows = [current]
        while let sheet = current.attachedSheet {
            windows.append(sheet)
            current = sheet
        }
        return windows
    }

    /// **シートを出したまま、その下のウインドウが閉じられたら、シートを Cancel で終わらせる**(2026-09-27 の監査)。
    ///
    /// シートの付いたウインドウに`close()`を呼ぶと、AppKit はシートの完了ハンドラを**呼ばない**(保存パネル・アラートとも、
    /// 単体の AppKit で実測。macOS 27)。`run`の continuation が再開せず、待っている側 ―― ファイル操作の列(終了の確認に
    /// 数える`RunningWorkRegistry`も)、書き出しの Task ―― が止まったままになっていた。`close()`はシートを確かめない経路から
    /// 呼ばれる: タブ 1 枚のウインドウの赤い閉じるボタン(独自の target を付けているので、シートの間も押せる。
    /// BookClosingWindowDelegate のコメント)、裏のタブも閉じる「ウインドウを閉じる」、スライドショーの終わりの「タブを閉じる」。
    /// `willClose`の中で`endSheet`すれば完了ハンドラが Cancel で呼ばれることを実測した。閉じる経路ごとに断るより、ここで
    /// 一度に塞ぐ(新しい閉じる経路が増えても漏れない)。見張るのは、出す先を決めるときに辿ったウインドウすべて(SwiftUI の
    /// シートの上に重ねたときは、その下の本のウインドウが閉じても知らせはシートのウインドウには来ない)。
    @MainActor
    private final class CloseWatch {
        private weak var sheet: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        init(sheet: NSWindow, windows: [NSWindow]) {
            self.sheet = sheet
            tokens = windows.map { window in
                // queue: nil ―― 閉じる処理の中で(ウインドウが消える前に)同期して受ける。
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: nil
                ) { [self] _ in
                    MainActor.assumeIsolated { endSheet() }
                }
            }
        }

        private func endSheet() {
            guard let sheet, let parent = sheet.sheetParent else { return }
            parent.endSheet(sheet, returnCode: .cancel)
        }

        /// 完了ハンドラから呼ぶ(見張りを外す)。
        func stop() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
        }
    }

    // MARK: 保存パネル・開くパネル

    /// パネルを出し、閉じたら`completion`を呼ぶ。出す先は呼んだ時点で決める(同期の呼び出し元から使う)。
    ///
    /// **選ばれた場所を読むなら `beginChoosing` / `chooseURLs` を使う**(テストが答えを差し込めるのは、そちらの戻り値だけ ――
    /// `panel.urls` は読み取り専用で、出さずに埋められない)。
    static func begin(
        _ panel: NSSavePanel, for window: NSWindow? = nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let responder = SheetScripting.responder {
            completion(responder.reply(to: .init(panel: panel)).modalResponse)
            return
        }
        guard !refusesInTestHost(window) else { return completion(.cancel) }
        switch placement(for: window) {
        case .sheet(let host):
            let watch = CloseWatch(sheet: panel, windows: chain(from: window))
            panel.beginSheetModal(for: host) { response in
                MainActor.assumeIsolated { watch.stop() }
                afterSheetIsGone { completion(response) }
            }
        case .appModal:
            // テストホストの中で、答える役の無いアプリモーダルは出さない(runModal はテストを止めたままにする)。
            guard !RuntimeEnvironment.isRunningTests else { return completion(.cancel) }
            completion(panel.runModal())
        case .busy:
            UserFeedback.beep()
            completion(.cancel)
        }
    }

    /// `begin(_:for:completion:)`の async 版。
    static func run(_ panel: NSSavePanel, for window: NSWindow? = nil) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin(panel, for: window) { continuation.resume(returning: $0) }
        }
    }

    /// パネルを出し、選ばれた場所(開くパネルなら選ばれたすべて、保存パネルなら保存先)を返す。キャンセルなら nil。
    static func beginChoosing(
        _ panel: NSSavePanel, for window: NSWindow? = nil, completion: @escaping ([URL]?) -> Void
    ) {
        if let responder = SheetScripting.responder {
            completion(responder.reply(to: .init(panel: panel)).chosenURLs)
            return
        }
        begin(panel, for: window) { response in
            guard response == .OK else { return completion(nil) }
            let urls = (panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] } ?? []
            completion(urls.isEmpty ? nil : urls)
        }
    }

    /// `beginChoosing(_:for:completion:)`の async 版。
    static func chooseURLs(_ panel: NSSavePanel, for window: NSWindow? = nil) async -> [URL]? {
        await withCheckedContinuation { continuation in
            beginChoosing(panel, for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: アラート

    static func begin(
        _ alert: NSAlert, for window: NSWindow? = nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let responder = SheetScripting.responder {
            completion(responder.reply(to: .init(alert: alert)).modalResponse)
            return
        }
        guard !refusesInTestHost(window) else { return completion(.cancel) }
        guard case .sheet(let host) = placement(for: window) else {
            // テストホストの中で、答える役の無いアプリモーダルは出さない(runModal はテストを止めたままにする)。
            guard !RuntimeEnvironment.isRunningTests else { return completion(.cancel) }
            completion(alert.runModal())
            return
        }
        let alertWindow = ObjectIdentifier(alert.window)
        presentedAlertWindows.insert(alertWindow)
        let watch = CloseWatch(sheet: alert.window, windows: chain(from: window))
        alert.beginSheetModal(for: host) { response in
            MainActor.assumeIsolated {
                watch.stop()
                _ = presentedAlertWindows.remove(alertWindow)
            }
            afterSheetIsGone { completion(response) }
        }
    }

    static func run(_ alert: NSAlert, for window: NSWindow? = nil) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin(alert, for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: 自前のシートのウインドウ

    /// 自前で組んだシートのウインドウ(一括リネームの`BulkRenamePanel`)を出し、閉じたら応答を返す
    /// (2026-10-04 の監査 FBA-2)。
    ///
    /// 以前の一括リネームは`host.beginSheet`を直に呼んでいて(リポジトリでここだけ)、`CloseWatch`が無かった。シートを出したまま
    /// 「すべてを閉じる」などの`close()`でウインドウが閉じると完了ハンドラが呼ばれず、ファイル操作の列が永久に止まり、
    /// 以後の終了のたびに「作業の途中」と尋ねられた(実測。赤ボタンはシートの間は閉じない)。既にシートがあるときに
    /// アプリモーダルへ落ちる点も、ほかのパネルの「いちばん上に重ねる」と食い違っていた。
    ///
    /// シートの側は、閉じるときに`sheetParent?.endSheet(_:returnCode:)`(シートのとき)か`NSApp.stopModal(withCode:)`
    /// (アプリモーダルのとき)を呼ぶこと。同じウインドウでパネル・アラートが既に出ていれば、保存パネルと同じくビープして
    /// キャンセル扱い(上に重ねない)。出している間は「ここで出したもの」に数え、上にパネル・アラートを重ねさせない。
    static func run(sheetWindow sheet: NSWindow, for window: NSWindow? = nil) async -> NSApplication.ModalResponse {
        if let responder = SheetScripting.responder {
            return responder.reply(to: .init(sheetWindow: sheet)).modalResponse
        }
        guard !refusesInTestHost(window) else { return .cancel }
        switch placement(for: window) {
        case .sheet(let host):
            let sheetID = ObjectIdentifier(sheet)
            presentedAlertWindows.insert(sheetID)
            let watch = CloseWatch(sheet: sheet, windows: chain(from: window))
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                host.beginSheet(sheet) { response in
                    MainActor.assumeIsolated {
                        watch.stop()
                        _ = presentedAlertWindows.remove(sheetID)
                    }
                    afterSheetIsGone { continuation.resume(returning: response) }
                }
            }
            return response
        case .appModal:
            // テストホストの中で、答える役の無いアプリモーダルは出さない(runModal はテストを止めたままにする)。
            guard !RuntimeEnvironment.isRunningTests else { return .cancel }
            sheet.center()
            let response = NSApp.runModal(for: sheet)
            sheet.orderOut(nil)
            return response
        case .busy:
            UserFeedback.beep()
            return .cancel
        }
    }
}

// MARK: - テストのための口

/// WindowSheet が出すものに、出す代わりに答える役の置き場所(2026-10-11、「GUI 無しで確かめる口」の点検)。
///
/// 以前は、確認のアラートや「開く…」のパネルの先にある処理(選んだ本を開く・フォルダの許可を足す・確認の答えで分かれる処理)を
/// テストが通せなかった ―― 答えるには本物のシートを押すしかない。テストは `SheetScripting.$responder.withValue(responder) { … }` の
/// 中で入口を叩き、`ScriptedSheetResponder` が順に答えを返す(出したもの ―― 文言・ボタン・パネルの設定 ―― は記録に残る)。
/// TaskLocal にしてあるのは UserFeedback.recorder と同じ理由(並行して走るテストの間で混ざらない)。
nonisolated enum SheetScripting {
    @TaskLocal static var responder: ScriptedSheetResponder?
}

@MainActor
final class ScriptedSheetResponder {
    /// 出されたもの(記録)。
    struct Presentation: Equatable {
        enum Kind: Equatable { case alert, openPanel, savePanel, sheetWindow }
        let kind: Kind
        /// アラートの見出しと説明。パネルは `message`、自前のシートは題。
        let messageText: String
        let informativeText: String
        /// アラートのボタンの題(並び順のまま。最初のものが既定のボタン)。
        let buttonTitles: [String]
        /// パネルの「開く」ボタンの題と、最初に出す場所。
        let prompt: String?
        let directoryURL: URL?

        init(alert: NSAlert) {
            kind = .alert
            messageText = alert.messageText
            informativeText = alert.informativeText
            buttonTitles = alert.buttons.map(\.title)
            prompt = nil
            directoryURL = nil
        }

        init(panel: NSSavePanel) {
            kind = panel is NSOpenPanel ? .openPanel : .savePanel
            messageText = panel.message
            informativeText = ""
            buttonTitles = []
            prompt = panel.prompt
            directoryURL = panel.directoryURL
        }

        init(sheetWindow: NSWindow) {
            kind = .sheetWindow
            messageText = sheetWindow.title
            informativeText = ""
            buttonTitles = []
            prompt = nil
            directoryURL = nil
        }
    }

    /// 返す答え。答えが尽きたら `.cancel`。
    enum Reply: Equatable {
        /// アラートの n 番目(0 始まり)のボタン。
        case button(Int)
        /// パネルで、これらを選んで「開く」/「保存」。
        case choose([URL])
        /// そのままの応答(自前のシートなど)。
        case response(NSApplication.ModalResponse)
        case cancel

        var modalResponse: NSApplication.ModalResponse {
            switch self {
            case .button(let index):
                NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
            case .choose: .OK
            case .response(let response): response
            case .cancel: .cancel
            }
        }

        var chosenURLs: [URL]? {
            if case .choose(let urls) = self, !urls.isEmpty { return urls }
            return nil
        }
    }

    private(set) var presentations: [Presentation] = []
    private var replies: [Reply]

    init(replies: [Reply] = []) {
        self.replies = replies
    }

    /// 次の答えを積む。
    func enqueue(_ reply: Reply) {
        replies.append(reply)
    }

    func reply(to presentation: Presentation) -> Reply {
        presentations.append(presentation)
        return replies.isEmpty ? .cancel : replies.removeFirst()
    }
}
