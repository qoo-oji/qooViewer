#if DEBUG
import AppKit

/// **Debug ビルドだけの制御口**(2026-10-11、「GUI 無しで確かめる口」の点検)。起動中のアプリを、画面を操作せずにスクリプトから
/// 動かし、何が出ているかを読むためのもの。Release ビルドには含まれない(ファイルごと `#if DEBUG`)。
///
/// ■ なぜ要るのか
/// 実機での検証の多くは見た目ではなく「どの窓に何が出ているか・メニューが淡色か」という状態の読み取りなのに、読む手段が
/// アクセシビリティ(AX)しか無かった。AX は名前が古い(作り直したメニュー)・値が遅れる・SwiftUI のボタンに名前が無い、の 3 つの
/// 問題があり、キー入力は最前面のアプリへ届くので送れない(docs/12)。ここは既存の入口(`AppState.open`・`selectMode`・メニューの項目
/// そのもの)を通して動かし、状態は値で書き出す。
///
/// ■ 口の形(scripts/dev/qoo-debug-control.py が使う)
/// - 置き場所: 環境変数 `QOO_DEBUG_CONTROL_DIR`、無ければ `NSTemporaryDirectory()/qooViewer-debug-control`(サンドボックスの中では
///   コンテナの `tmp/`)。起動すると `ready.json`(pid・bundle id・版)を書く。
/// - 頼む側は `inbox/<id>.json`(`{"id", "command", "arguments"}`)を**一時ファイルから rename で**置く。アプリは処理して
///   `outbox/<id>.json`(`{"id", "ok", "result" | "error"}`)を書き、inbox のファイルを消す。
/// - 監視はフォルダの書き込みの知らせ(`DispatchSource`)。サンドボックスの中でもアプリ自身のコンテナなので許可は要らない。
/// - ファイルの読み書きはすべて FileIO の上(メインで I/O しない約束。CLAUDE.md)。返事のファイル名は頼みのファイル名から作り、
///   頼みの中の `id` は使わない(`../` を含む id で outbox の外へ書かせない。2026-10-11 のレビュー)。
///
/// テストホストの中では始めない(テストは入口を直に叩く)。
@MainActor
final class DebugControlPort {
    private(set) static var shared: DebugControlPort?

    nonisolated let directory: URL
    private nonisolated var inbox: URL { directory.appendingPathComponent("inbox", isDirectory: true) }
    private nonisolated var outbox: URL { directory.appendingPathComponent("outbox", isDirectory: true) }
    private let stores: AppStores
    /// 外から本を渡す経路(Finder の「開く」と同じ。AppDelegate が起動の終わりに自分を入れる)。
    weak var appDelegate: AppDelegate?
    private var source: DispatchSourceFileSystemObject?
    private var processing: Set<String> = []
    /// 読み取りの最中か・その間にまた知らせが来たか(読み取りは 1 本ずつ。2 本が同じファイルを見て、後の 1 本が消えた後の
    /// ファイルを読んで「JSON ではない」と答えていた ―― CI で実測、2026-10-11)。
    private var isScanning = false
    private var needsRescan = false

    static func startIfNeeded(stores: AppStores) {
        guard shared == nil, !RuntimeEnvironment.isRunningTests else { return }
        let directory = ProcessInfo.processInfo.environment["QOO_DEBUG_CONTROL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("qooViewer-debug-control", isDirectory: true)
        let port = DebugControlPort(directory: directory, stores: stores)
        shared = port
        Task { await port.start() }
    }

    /// 作るだけで聞き始めない(`start` しない)。テストは `perform(_:arguments:)` を直に呼ぶ。
    init(directory: URL, stores: AppStores) {
        self.directory = directory
        self.stores = stores
    }

    private func start() async {
        let inbox = inbox, outbox = outbox, directory = directory
        let descriptor = await FileIO.perform(qos: .utility) { () -> Int32 in
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
                try manager.createDirectory(at: outbox, withIntermediateDirectories: true)
            } catch {
                NSLog("DebugControlPort: could not create %@: %@", directory.path, String(describing: error))
                return -1
            }
            // 前の起動の残りは捨てる(古い頼みを今の状態で実行しない)。
            for stale in (try? manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [] {
                try? manager.removeItem(at: stale)
            }
            return Darwin.open(inbox.path, O_EVTONLY)
        }
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scanInbox() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
        await Self.write(["pid": ProcessInfo.processInfo.processIdentifier,
                          "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                          "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""],
                         to: directory.appendingPathComponent("ready.json"))
        NSLog("DebugControlPort: listening at %@", directory.path)
        // 聞き始める前に置かれていた頼み。
        scanInbox()
    }

    // MARK: - 受け取り

    private func scanInbox() {
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        let inbox = inbox
        Task { @MainActor in
            // 頼みを読み、inbox から消す(読めたものだけ)。読み書きは FileIO の上。
            let requests = await FileIO.perform(qos: .userInitiated) { () -> [(name: String, data: Data)] in
                let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
                return files.filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .compactMap { file in
                        guard let data = try? Data(contentsOf: file) else { return nil }
                        try? FileManager.default.removeItem(at: file)
                        return (file.deletingPathExtension().lastPathComponent, data)
                    }
            }
            for request in requests where self.processing.insert(request.name).inserted {
                await self.handle(data: request.data, replyName: request.name)
                self.processing.remove(request.name)
            }
            self.isScanning = false
            if self.needsRescan {
                self.needsRescan = false
                self.scanInbox()
            }
        }
    }

    /// 返事のファイル名にしてよい名前(頼みのファイル名。英数字と `-` `_` `.` だけ、`.` で始まらない)。
    nonisolated static func isSafeReplyName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), name.count <= 128 else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
            && name.unicodeScalars.allSatisfy(\.isASCII)
    }

    private func handle(data: Data?, replyName: String) async {
        guard Self.isSafeReplyName(replyName) else { return }
        let replyURL = outbox.appendingPathComponent("\(replyName).json")
        guard let data, let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            await Self.write(["id": replyName, "ok": false, "error": "the request is not a JSON object"], to: replyURL)
            return
        }
        // `id` は返事の中に写すだけ(ファイル名には使わない)。
        let id = request["id"] as? String ?? replyName
        let command = request["command"] as? String ?? ""
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        let reply: [String: Any]
        do {
            reply = ["id": id, "ok": true, "result": try await perform(command, arguments: arguments)]
        } catch {
            reply = ["id": id, "ok": false, "error": String(describing: error)]
        }
        await Self.write(reply, to: replyURL)
    }

    /// 読む側が書きかけを読まないよう、一時ファイルから置き換える(FileIO の上で)。
    private static func write(_ object: [String: Any], to url: URL) async {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        ) else { return }
        await FileIO.perform(qos: .utility) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: - 頼み

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// 頼みを 1 つ実行する(テストからも呼べる)。
    func perform(_ command: String, arguments: [String: Any]) async throws -> Any {
        switch command {
        case "ping":
            return ["pid": ProcessInfo.processInfo.processIdentifier]
        case "state":
            return DebugStateDump.state(stores: stores)
        case "menu":
            return DebugStateDump.menuTree(NSApp.mainMenu)
        case "open":
            return try open(arguments)
        case "closeBook":
            try frontmost().closeBook()
            return [:] as [String: Any]
        case "perform":
            guard let raw = arguments["action"] as? String, let action = ViewerAction(rawValue: raw) else {
                throw Failure("unknown viewer action: \(arguments["action"] ?? "nil")")
            }
            guard let performer = try frontmost().performViewerAction else { throw Failure("no viewer is shown") }
            performer(action)
            return [:] as [String: Any]
        case "jumpToPage":
            guard let index = arguments["index"] as? Int else { throw Failure("missing index") }
            guard let jump = try frontmost().jumpToPageIndex else { throw Failure("no viewer is shown") }
            jump(index)
            return [:] as [String: Any]
        case "selectHomeMode":
            guard let raw = arguments["mode"] as? String, let mode = WelcomeMode(rawValue: raw) else {
                throw Failure("unknown mode: \(arguments["mode"] ?? "nil")")
            }
            guard let library = try frontmost().welcomeLibrary else { throw Failure("Home is not shown") }
            library.selectMode(mode)
            return ["mode": library.mode.rawValue]
        case "setPreference":
            return try setPreference(arguments)
        case "performMenuItem":
            return try performMenuItem(arguments)
        case "newWindow":
            guard let opener = appDelegate?.openNewWindowFromDock else { throw Failure("the app delegate is not ready") }
            opener(arguments["private"] as? Bool ?? false)
            return [:] as [String: Any]
        case "focusWindow":
            // 窓を前に出してキーにする(実機の検証で、合成した入力をその窓へ届けるため)。
            guard let number = arguments["windowNumber"] as? Int,
                  let window = NSApp.windows.first(where: { $0.windowNumber == number })
            else { throw Failure("no window \(arguments["windowNumber"] ?? "nil")") }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return ["isKey": window.isKeyWindow]
        case "closeWindow":
            guard let number = arguments["windowNumber"] as? Int,
                  let window = NSApp.windows.first(where: { $0.windowNumber == number })
            else { throw Failure("no window \(arguments["windowNumber"] ?? "nil")") }
            window.performClose(nil)
            return [:] as [String: Any]
        case "nudge":
            // 何もしないイベントを流し、窓を描き直させる。SwiftUI・AppKit の後始末(閉じた本のビューの解放など)は次のイベント・
            // 次の描画まで遅れることがある(docs/12「閉じた直後に数えない」。実機ではカーソルを動かして待っていた)ので、数える前に送る。
            if let event = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, subtype: 0, data1: 0, data2: 0
            ) {
                NSApp.postEvent(event, atStart: false)
            }
            for window in NSApp.windows where window.isVisible {
                if let moved = NSEvent.mouseEvent(
                    with: .mouseMoved, location: NSPoint(x: 1, y: 1), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
                ) {
                    NSApp.postEvent(moved, atStart: false)
                }
                window.contentView?.needsLayout = true
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
            return [:] as [String: Any]
        case "quit":
            // 返事を書いてから終える(待っている側が時間切れにならない)。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return [:] as [String: Any]
        default:
            throw Failure("unknown command: \(command)")
        }
    }

    /// 頼みの相手(いちばん前の、本を出す窓)。開いている本・ホームに対する操作なので、プライバシーで選び直さない(開く頼みは `open` を参照)。
    private func frontmost() throws -> AppState {
        guard let state = stores.launchCoordinator.frontmostContentAppState() else { throw Failure("no content window") }
        return state
    }

    /// 本を開く。`via: "finder"` は Finder から渡したのと同じ経路(環境設定の「Finder から」の開き方に従う)、
    /// `via: "windowNumber"` は `windowNumber` の窓で開く。既定はいちばん前の
    /// 窓のうち、焦点の外から開くときの相手(`frontmostContentAppStateForUnfocusedOpen`)で開く。
    private func open(_ arguments: [String: Any]) throws -> Any {
        guard let path = arguments["path"] as? String else { throw Failure("missing path") }
        let url = URL(fileURLWithPath: path)
        switch arguments["via"] as? String ?? "window" {
        case "finder":
            guard let delegate = appDelegate else { throw Failure("the app delegate is not ready") }
            delegate.application(NSApp, open: [url])
        case "windowNumber":
            // 窓を名指しで(実機の検証で、シークレットの窓にだけ本を開くため)。
            guard let number = arguments["windowNumber"] as? Int,
                  let state = stores.launchCoordinator.allOpenAppStates.first(where: { $0.hostWindow?.windowNumber == number })
            else { throw Failure("no content window \(arguments["windowNumber"] ?? "nil")") }
            state.open(url: url)
        default:
            // 外からの頼みなので、メニューが焦点の外から開くときと同じ相手(シークレットかどうかを新しい窓と揃える。CLAUDE.md)。
            guard let state = stores.launchCoordinator.frontmostContentAppStateForUnfocusedOpen() else {
                throw Failure("no content window")
            }
            state.open(url: url)
        }
        return ["path": url.path]
    }

    /// 実行中に切り替えてよい設定(機能の ON/OFF と読み取り専用)。設定の画面と同じ `@Published` を書くので、購読している側
    /// (AppStores.applyLibraryFeature など)まで同じ経路で届く。
    private func setPreference(_ arguments: [String: Any]) throws -> Any {
        guard let key = arguments["key"] as? String, let value = arguments["value"] as? Bool else {
            throw Failure("setPreference needs key and a Bool value")
        }
        let preferences = stores.preferences
        switch key {
        case "libraryFeatureEnabled": preferences.libraryFeatureEnabled = value
        case "fileBrowserFeatureEnabled": preferences.fileBrowserFeatureEnabled = value
        case "smartLibraryFeatureEnabled": preferences.smartLibraryFeatureEnabled = value
        case "fileBrowserReadOnly": preferences.fileBrowserReadOnly = value
        default: throw Failure("not a switchable preference: \(key)")
        }
        return [key: value]
    }

    /// メニューバーの項目を押す(`path` は題の並び。例 ["File", "Close Window"]、表示言語の題でもよい)。押す前に項目を検証し、
    /// 淡色なら押さずに断る(利用者が押せない項目を押した形にしない)。
    private func performMenuItem(_ arguments: [String: Any]) throws -> Any {
        guard let path = arguments["path"] as? [String], !path.isEmpty, var menu = NSApp.mainMenu else {
            throw Failure("missing path")
        }
        for (depth, title) in path.enumerated() {
            menu.update()
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                throw Failure("no menu item “\(title)” in \(path.prefix(depth))")
            }
            let item = menu.items[index]
            if depth == path.count - 1 {
                guard item.isEnabled, !item.isHidden else { throw Failure("the menu item “\(title)” is disabled") }
                menu.performActionForItem(at: index)
                return ["performed": path]
            }
            guard let submenu = item.submenu else { throw Failure("“\(title)” has no submenu") }
            menu = submenu
        }
        throw Failure("missing path")
    }
}

/// 状態の書き出し(DebugControlPort の `state` と `menu`)。値はすべて JSON にできる型。
@MainActor
enum DebugStateDump {
    static func state(stores: AppStores) -> [String: Any] {
        let coordinator = stores.launchCoordinator
        let appStates = coordinator.allOpenAppStates
        let frontmost = coordinator.frontmostContentAppState()
        // 見えている窓と、本を出す窓(アプリを隠して起動したときは見えていなくても数える)。
        let windows: [[String: Any]] = NSApp.windows.filter { window in
            window.isVisible || appStates.contains { $0.hostWindow === window }
        }.map { window in
            var entry: [String: Any] = [
                "windowNumber": window.windowNumber,
                "isVisible": window.isVisible,
                "title": window.title,
                "frame": frame(window.frame),
                "isKey": window.isKeyWindow,
                "isMain": window.isMainWindow,
                "isSheet": window.isSheet,
                "attachedSheet": window.attachedSheet.map { $0.title } ?? NSNull(),
                "tabbingIdentifier": window.tabbingIdentifier,
                "tabbedWindows": window.tabbedWindows?.map(\.windowNumber) ?? [],
                "className": NSStringFromClass(type(of: window)),
            ]
            if let appState = appStates.first(where: { $0.hostWindow === window }) {
                entry["content"] = content(appState, isFrontmost: appState === frontmost)
            }
            return entry
        }
        let preferences = stores.preferences
        return [
            "isAppActive": NSApp.isActive,
            "isAppHidden": NSApp.isHidden,
            "windows": windows,
            "contentWindowCount": appStates.count,
            "openBookIDs": ViewerViewModel.openBookIDs.sorted(),
            "hasRunningWork": RunningWorkRegistry.forCurrentProcess?.hasRunningWork ?? false,
            "liveInstances": DebugLiveInstances.snapshot,
            "features": [
                "library": preferences.libraryFeatureEnabled,
                "fileBrowser": preferences.fileBrowserFeatureEnabled,
                "smartLibrary": preferences.smartLibraryFeatureEnabled,
                "fileBrowserReadOnly": preferences.fileBrowserReadOnly,
            ],
        ]
    }

    private static func content(_ state: AppState, isFrontmost: Bool) -> [String: Any] {
        var entry: [String: Any] = [
            "isFrontmost": isFrontmost,
            "isPrivateWindow": state.isPrivateWindow,
            "isWaitingToOpen": state.isWaitingToOpen,
            "isLoading": state.loadingProgress != nil,
            "errorMessage": state.errorMessage ?? NSNull(),
            "homeMode": state.currentBook == nil ? (state.welcomeLibrary?.mode.rawValue ?? NSNull()) : NSNull(),
            "fileBrowserFolder": state.fileBrowser?.currentFolder?.path ?? NSNull(),
            "isSidePanelRevealed": state.isSidePanelRevealed,
            "hideToolbar": state.hideToolbar,
            "hideProgressBar": state.hideProgressBar,
            "hideSidePanel": state.hideSidePanel,
        ]
        if let book = state.currentBook {
            entry["book"] = [
                "id": book.id,
                "title": book.title,
                // 読み込んだ本のページ数(除外の前)と、ビューアが並べているページ数(ビューアが出るまでは 0)。
                "pageCount": book.pages.count,
                "shownPageCount": state.currentBookPages.count,
                "currentPageIndex": state.currentPageIndex,
                "partnerPageIndex": state.currentPartnerPageIndex ?? NSNull(),
                "isSpreadMode": state.isSpreadMode,
                "isRightToLeft": state.isRightToLeft,
                "scalingMode": state.currentScalingMode.rawValue,
                "isSlideshowActive": state.isSlideshowActive,
                "isLoupeActive": state.isLoupeActive,
                "isPinchZoomed": state.isPinchZoomed,
                "bookmarkCount": state.currentBookmarks.count,
                "leavesNoRecord": book.leavesNoRecord,
            ] as [String: Any]
        }
        return entry
    }

    /// メニューバーの木(題・淡色・隠し・キー)。各メニューを `update()` してから読む(押せるかは利用者が開いたときと同じ判定)。
    static func menuTree(_ menu: NSMenu?) -> [[String: Any]] {
        guard let menu else { return [] }
        menu.update()
        return menu.items.map { item in
            var entry: [String: Any] = [
                "title": item.title,
                "isEnabled": item.isEnabled,
                "isHidden": item.isHidden,
                "isSeparator": item.isSeparatorItem,
                "state": item.state == .on ? "on" : (item.state == .mixed ? "mixed" : "off"),
            ]
            if !item.keyEquivalent.isEmpty {
                entry["keyEquivalent"] = item.keyEquivalent
                entry["keyEquivalentModifiers"] = Int(item.keyEquivalentModifierMask.rawValue)
            }
            if item.isAlternate { entry["isAlternate"] = true }
            if let submenu = item.submenu { entry["items"] = menuTree(submenu) }
            return entry
        }
    }

    private static func frame(_ rect: NSRect) -> [String: Double] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
    }
}
#endif
