import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ファイルブラウザを表示している間の「移動」メニューの中身(改善要望7 段階4 の追加要望、2026-09-13)。
///
/// **Finder の「移動」メニューと同じ並び・同じキー**(この機の macOS 26.6 の Finder を AX で読んだもの)。
/// qooViewer に無い機能 ―― 最近の項目・最近使ったフォルダ・AirDrop・ネットワーク・iCloud Drive・共有・
/// サーバへ接続 ―― は置かない(ユーザー指示)。Finder で ⌥ / ⌃ を押すと現れる「内包しているフォルダ」の
/// 代替(新規ウインドウに表示など)も置かない。「ライブラリ」だけは Finder と同じく「ホーム」の ⌥ の代替。
///
/// 本を表示しているとき・本棚のときは、従来のページ移動の項目(QooViewerApp の CommandMenu("Go"))。
/// 切り替えは MenuCheckmarkState.fileBrowserNavigation の有無で決まる(値型の FocusedValue)。
///
/// 標準の場所を開いても、読む権限が無ければ右ペインに「アクセスを許可…」が出る(書類・デスクトップは
/// そのうえ TCC の確認が出る)。**開く前に触って確かめない**(触ること自体がダイアログの引き金になる)。
struct FileBrowserGoMenuItems: View {
    let navigation: FileBrowserMenuNavigation
    /// フォーカス中のウインドウのファイルブラウザ。**弱く持つ**(メニューバーの部品なので。HomeMenuItems.appState のコメント)。
    weak var browser: FileBrowserState?

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
/// **形は Finder の「フォルダへ移動」と同じ**(2026-10-24、ユーザー決定。実測: 幅 460pt・高さ 183pt、題もボタンも無く、上に入力欄と
/// 消去のボタン、下に打った名前で始まるフォルダの候補)。Return で移動、Esc で閉じる。以前は題・「キャンセル」「移動」のボタンの
/// 付いたシートで、「移動」がファイルの移動と同じ語だった。
///
/// 存在しない・フォルダでないときは**シートを閉じずにその場で知らせる**(移動してから右ペインで失敗するより
/// 打ち直しやすい ―― qooLibrary と同じ判断)。読む権限の有無は確かめない(移動した先で「アクセスを許可…」が出る。
/// 開く前に触ると TCC の確認の引き金になりうる)。`~` は**実際のホーム**に読み替える(`expandingTildeInPath` は
/// サンドボックスではコンテナを返す)。候補を読むのは、TCC で守られた場所とネットワークのボリュームの外だけ
/// (docs/15「サンドボックスと TCC の約束」 ―― 入っていないフォルダを読むことになるため)。
struct FileBrowserGoToFolderSheet: View {
    @ObservedObject var state: FileBrowserState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var path = ""
    @State private var errorKey: LocalizedStringKey?
    @State private var isChecking = false
    /// 確かめている Task。閉じたときとシートが消えたときに取り消す(2026-10-04 の監査 FBU-6)。
    @State private var checkTask: Task<Void, Never>?
    /// 打った名前で始まるフォルダ(Finder と同じく、欄の下に並べる)。
    @State private var suggestions: [URL] = []

    static let width: CGFloat = 460
    static let height: CGFloat = 183

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Path", text: $path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .onSubmit(go)
                    .onChange(of: path) { _, _ in errorKey = nil }
                if !path.isEmpty {
                    Button {
                        path = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                    .accessibilityLabel(Text("Clear"))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            Divider()
            Group {
                if let errorKey {
                    Text(errorKey)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(suggestions, id: \.self) { folder in
                                Button {
                                    path = folder.path
                                    go()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                        Text(verbatim: folder.lastPathComponent)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 24)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(folder.path)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: Self.width, height: Self.height)
        // ボタンは無いが、Esc で閉じる(Finder と同じ)。
        .background {
            Button("") {
                checkTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .hidden()
            // 読み上げの木に名前の無いボタンとして出さない(Esc のためだけのボタン)。
            .accessibilityHidden(true)
        }
        .onAppear {
            path = state.currentFolder?.path ?? ""
        }
        .task(id: path) { await updateSuggestions() }
        // ウインドウごと閉じた・シートが下りたら、確かめ終わっても移動しない(FBU-6)。
        .onDisappear { checkTask?.cancel() }
    }

    /// 打った名前で始まる、親のフォルダの中のフォルダ(最大 50)。打ち終えるまで少し待つ(1 文字ごとに読まない)。
    private func updateSuggestions() async {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let typed = path
        guard let target = Self.resolve(typed) else {
            suggestions = []
            return
        }
        let endsWithSlash = typed.hasSuffix("/")
        let parent = endsWithSlash ? target : target.deletingLastPathComponent()
        let prefix = endsWithSlash ? "" : target.lastPathComponent
        let found = await FileIO.perform { () -> [URL] in
            guard !DirectoryProbe.isPrivacyProtected(parent), !MountTable.current().isRemote(parent) else { return [] }
            guard let names = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
            ) else { return [] }
            return names.filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
                    && (prefix.isEmpty || url.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()))
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(50).map { $0 }
        }
        guard !Task.isCancelled, typed == path else { return }
        suggestions = found
    }

    private func go() {
        // 確かめている最中に Return をもう一度押しても 2 本目を走らせない(FBU-6 の検証での追加。以前は 2 本走り、2 回目の移動が
        // 同じ場所への移動になって選択を消した ―― FBU-7)。「移動」ボタンは淡色だが、欄の onSubmit は通る。
        guard !isChecking else { return }
        guard let target = Self.resolve(path) else {
            errorKey = "Enter a full path that starts with / or ~."
            return
        }
        isChecking = true
        checkTask = Task {
            // 移る先は**ディスク上の名前の書き方**に直す(2026-10-10。大小文字・正規化が違う書き方のままだと、同じフォルダの
            // ツリーの行と別物になる ―― `FileBrowserListing.onDiskSpelling` のコメント)。
            let folder = await FileIO.perform { () -> URL? in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue
                else { return nil }
                return FileBrowserListing.onDiskSpelling(of: target)
            }
            isChecking = false
            // 確かめている間に「キャンセル」された・シートが消えたら移動しない(2026-10-04 の監査 FBU-6。以前は取り消しも
            // シートの消滅も見ずに `navigate` していた)。
            guard !Task.isCancelled else { return }
            guard let folder else {
                errorKey = "The folder can’t be found."
                return
            }
            state.navigate(to: folder)
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
