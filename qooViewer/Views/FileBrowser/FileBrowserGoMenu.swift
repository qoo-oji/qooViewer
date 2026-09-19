import AppKit
import SwiftUI

/// ファイルブラウザを表示している間の「移動」メニューの中身(改善要望7 段階4 の追加要望、2026-09-13)。
///
/// **Finder の「移動」メニューと同じ並び・同じキー**(この機の macOS 26.6 の Finder を AX で読んだもの)。
/// qooViewer に無い機能 ―― 最近の項目・最近使ったフォルダ・AirDrop・ネットワーク・iCloud Drive・共有・
/// サーバへ接続 ―― は置かない(ユーザー指示)。Finder で ⌥ / ⌃ を押すと現れる「内包しているフォルダ」の
/// 代替(新規ウインドウに表示など)も置かない。「ライブラリ」だけは Finder と同じく「ホーム」の ⌥ の代替。
///
/// 本を表示しているとき・本棚のときは、従来のページ移動の項目(QooViewerApp の CommandMenu("Move"))。
/// 切り替えは MenuCheckmarkState.fileBrowserNavigation の有無で決まる(値型の FocusedValue)。
///
/// 標準の場所を開いても、読む権限が無ければ右ペインに「アクセスを許可…」が出る(書類・デスクトップは
/// そのうえ TCC の確認が出る)。**開く前に触って確かめない**(触ること自体がダイアログの引き金になる)。
struct FileBrowserGoMenuItems: View {
    let navigation: FileBrowserMenuNavigation
    let browser: FileBrowserState?

    var body: some View {
        Button("Back") { browser?.goBack() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!navigation.canGoBack)
        Button("Forward") { browser?.goForward() }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!navigation.canGoForward)
        // ⌘↑・⇧⌘↑ はテキストの欄では「先頭へ」なので、欄を編集中のキーは欄へ返す(HomeMenuKeyRouting.shouldPerformNavigation)。
        Button("Enclosing Folder") {
            guard HomeMenuKeyRouting.shouldPerformNavigation(
                forwardingTextAction: #selector(NSResponder.moveToBeginningOfDocument(_:))
            ) else { return }
            browser?.goUp()
        }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!navigation.canGoUp)
        Button("Select Startup Disk") {
            guard HomeMenuKeyRouting.shouldPerformNavigation(
                forwardingTextAction: #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:))
            ) else { return }
            // コンピュータへ移って起動ディスクを選ぶ(Finder と同じ)。
            browser?.reveal(URL(fileURLWithPath: "/", isDirectory: true))
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .shift])

        Divider()

        item("Documents", .documents, key: "o", modifiers: [.command, .shift])
        item("Desktop", .desktop, key: "d", modifiers: [.command, .shift])
        item("Downloads", .downloads, key: "l", modifiers: [.command, .option])
        item("Home Folder", .home, key: "h", modifiers: [.command, .shift])
            .modifierKeyAlternate(.option) {
                Button("Library Folder") { open(.library) }
            }
        Button("Computer") { browser?.navigate(to: nil) }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        item("Applications", .applications, key: "a", modifiers: [.command, .shift])
        item("Utilities", .utilities, key: "u", modifiers: [.command, .shift])

        Divider()

        Button("Go to Folder…") { browser?.isShowingGoToFolder = true }
            .keyboardShortcut("g", modifiers: [.command, .shift])
    }

    private func item(
        _ title: LocalizedStringKey, _ location: FileBrowserStandardLocation, key: KeyEquivalent, modifiers: EventModifiers
    ) -> some View {
        Button(title) { open(location) }
            .keyboardShortcut(key, modifiers: modifiers)
    }

    private func open(_ location: FileBrowserStandardLocation) {
        browser?.navigate(to: location.url)
    }
}

/// メニューバーへ渡す、ファイルブラウザの移動の可否(値型。MenuCheckmarkState の中)。
struct FileBrowserMenuNavigation: Equatable {
    var canGoBack = false
    var canGoForward = false
    var canGoUp = false
}

/// 「移動」メニューの標準の場所。ホームは**実際のホーム**(サンドボックスのコンテナではない ――
/// FileBrowserListing.realHomeDirectory)。
nonisolated enum FileBrowserStandardLocation: CaseIterable {
    case documents, desktop, downloads, home, library, applications, utilities

    var url: URL {
        let home = FileBrowserListing.realHomeDirectory()
        return switch self {
        case .documents: home.appendingPathComponent("Documents", isDirectory: true)
        case .desktop: home.appendingPathComponent("Desktop", isDirectory: true)
        case .downloads: home.appendingPathComponent("Downloads", isDirectory: true)
        case .home: home
        case .library: home.appendingPathComponent("Library", isDirectory: true)
        case .applications: URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .utilities: URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true)
        }
    }
}

/// 「フォルダへ移動…」(⇧⌘G)。パスを打って移動する。
///
/// 存在しない・フォルダでないときは**シートを閉じずにその場で知らせる**(移動してから右ペインで失敗するより
/// 打ち直しやすい ―― qooLibrary と同じ判断)。読む権限の有無は確かめない(移動した先で「アクセスを許可…」が出る。
/// 開く前に触ると TCC の確認の引き金になりうる)。`~` は**実際のホーム**に読み替える(`expandingTildeInPath` は
/// サンドボックスではコンテナを返す)。
struct FileBrowserGoToFolderSheet: View {
    @ObservedObject var state: FileBrowserState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var path = ""
    @State private var errorKey: LocalizedStringKey?
    @State private var isChecking = false

    var body: some View {
        // **ボタンの幅は揃える**(「キャンセル」と「移動」で大きさが違うのは美しくない ―― ユーザー指摘 2026-09-13)。
        // 幅はボタンではなくラベルに与える(CollectionNameSheet と同じ。`Button.frame(width:)` はベゼルに効かない)。
        let labelWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [String(localized: "Cancel", language: locale), String(localized: "Go", language: locale)],
            minWidth: 60,
            chrome: 0
        )
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder")
                .font(.headline)
            // 欄と知らせは 1 つの塊にし、知らせの高さを予約する(出たときにシートの高さが跳ねない)。
            VStack(alignment: .leading, spacing: 4) {
                // **欄は面の幅いっぱいに伸ばし、面の幅はシート側で決める。** 以前は欄だけを 380pt に固定していたので、
                // シートがそれより広くなると欄の右にだけ余白が残り、左右の余白が揃わなかった(ユーザー指摘 2026-09-13)。
                TextField("Path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit(go)
                Group {
                    if let errorKey {
                        Text(errorKey).foregroundStyle(.red)
                    } else {
                        Text(verbatim: " ")
                    }
                }
                .font(.caption)
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Text("Cancel").frame(width: labelWidth)
                }
                .keyboardShortcut(.cancelAction)
                Button(action: go) {
                    Text("Go").frame(width: labelWidth)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            path = state.currentFolder?.path ?? ""
        }
    }

    private func go() {
        guard let target = Self.resolve(path) else {
            errorKey = "Enter a full path that starts with / or ~."
            return
        }
        isChecking = true
        Task {
            let isFolder = await FileIO.perform { () -> Bool in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            isChecking = false
            guard isFolder else {
                errorKey = "The folder can’t be found."
                return
            }
            state.navigate(to: target)
            dismiss()
        }
    }

    /// 入力をフォルダの URL にする。`/` か `~` で始まらなければ nil(相対パスは受け付けない)。
    nonisolated static func resolve(_ raw: String, home: URL = FileBrowserListing.realHomeDirectory()) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return URL(fileURLWithPath: home.path + String(trimmed.dropFirst()), isDirectory: true).standardizedFileURL
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
    }
}
