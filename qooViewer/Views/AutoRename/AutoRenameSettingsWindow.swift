import AppKit
import SwiftUI

/// 「自動リネームの設定」ウインドウ(2026-09-15、ユーザー要望。docs/plans/auto-rename-study.md §3)。
///
/// 2 ペイン: 左に規則の一覧(チェックボックスで ON/OFF、ドラッグで並べ替え。**上から順にかける**)、右に選んだ規則の中身と対象フォルダの一覧。
/// 帯(上): 読み取り専用モードで止まっていること・今ある項目に掛ける前の確認・移動したと思われる対象。
/// ステータスバー(下): 規則と対象の件数。ツールバー: 実行ログ。
///
/// 何を書き換えてもその場で保存される(AutoRenameStore)。名前を変えるかどうかは実行役(AutoRenameService)が決める ――
/// 中身を変えた対象は、今ある項目に掛ける前に確認の一覧を通る(§8 の 2)。
struct AutoRenameSettingsWindow: View {
    static let windowID = "autoRenameSettings"

    @EnvironmentObject private var store: AutoRenameStore
    @EnvironmentObject private var service: AutoRenameService
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.locale) private var locale
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var selection: UUID?
    @State private var sheet: SheetKind?
    /// 「フォルダを追加…」で最後に足した対象(揃えたパス)と、パネルを閉じた時点で見ていた場所。規則の編集欄は規則ごとに
    /// 作り直す(`.id(selection)`)ので、ウインドウの側で持つ(AutoRenameRuleEditor.panelStartDirectory)。
    @State private var lastAddedTarget: AutoRenameRuleEditor.AddedTarget?

    enum SheetKind: String, Identifiable {
        case confirmation
        case moveSuggestions
        case activityLog

        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
                // ステータスバーは右ペインにだけ付ける。ウインドウ全体に付けると左の一覧の下の「+ −」の帯に重なって隠れた(2026-09-16 の実機)。
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ListWindowStatusBar {
                        statusText
                    }
                }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sheet = .activityLog
                } label: {
                    Label("Activity Log", systemImage: "list.bullet.rectangle")
                }
                .help(Text("Activity Log"))
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .sheet(item: $sheet) { kind in
            switch kind {
            case .confirmation:
                AutoRenameConfirmationSheet(targetIDs: service.targetsAwaitingConfirmation)
            case .moveSuggestions:
                AutoRenameMoveSuggestionsSheet()
            case .activityLog:
                AutoRenameActivityLogSheet()
            }
        }
        .onAppear {
            // 最初に開いたときは規則を 1 つ用意しておく(要望の「初期状態では自動リネーム 1 だけ」)。
            if store.rules.isEmpty { store.addRule() }
            consumeRequestedRule()
            if selection == nil { selection = store.rules.first?.id }
        }
        .onChange(of: service.requestedRuleID) { _, _ in consumeRequestedRule() }
        // 環境設定「ファイルブラウザを有効にする」が OFF の間は、このウインドウを出しておかない(2026-09-21 の監査の F1)。実行役は止まっていて
        // (AppStores.applyFileBrowserFeature)、ここで規則を変えても何も起きず、対象の状態も分からない。入り口はどれも OFF の間は消えるので、
        // 残るのは「OFF にした時点で開いていた」場合だけ ―― 出ているシートごと閉じる。`initial` は、何かの拍子に OFF のまま開いたときのため。
        .onChange(of: preferences.fileBrowserFeatureEnabled, initial: true) { _, isEnabled in
            if !isEnabled { dismissWindow(id: Self.windowID) }
        }
        // シーンの `.commandsRemoved()`(QooViewerApp.autoRenameSettingsScene ―― 「ウインドウ」メニューに常に並ぶ「開く」項目を落とす)は、
        // **開いている間の、メニュー下端の「開いているウインドウの一覧」からもこのウインドウを外してしまう**(2026-09-21 の実機。シーンの
        // 項目がその一覧の行を兼ねていた)。一覧に載るかどうかは NSWindow の側の指定なので、自分の載っているウインドウへ直に戻す。
        // 載るのは開いている間だけで、閉じれば消える(実機で確認)ので、ファイルブラウザ機能が OFF の間の入り口にはならない。
        .background(WindowAccessor { window in
            window?.isExcludedFromWindowsMenu = false
        })
        .onChange(of: store.rules.map(\.id)) { _, ids in
            if let selected = selection, !ids.contains(selected) { selection = ids.first }
        }
    }

    private func consumeRequestedRule() {
        guard let requested = service.requestedRuleID else { return }
        service.requestedRuleID = nil
        if store.rule(withID: requested) != nil { selection = requested }
    }

    // MARK: - 左

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(store.rules) { rule in
                AutoRenameRuleRow(rule: rule, hasProblem: hasProblem(rule))
                    .tag(rule.id)
            }
            .onMove { source, destination in
                store.moveRules(fromOffsets: source, toOffset: destination)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    if let rule = store.addRule() { selection = rule.id }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(!store.canAddRule)
                .help(Text("Add Rule"))
                Button {
                    guard let selected = selection else { return }
                    let index = store.rules.firstIndex { $0.id == selected } ?? 0
                    store.removeRule(id: selected)
                    selection = store.rules.indices.contains(index) ? store.rules[index].id : store.rules.last?.id
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help(Text("Delete Rule"))
                Spacer()
                Text("Applied from top to bottom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func hasProblem(_ rule: AutoRenameRule) -> Bool {
        rule.targets.contains { target in
            target.state == .disabledMissing
                || (target.state == .enabled && service.availability[target.id].map { $0 != .available } == true)
        }
    }

    // MARK: - 右

    @ViewBuilder
    private var detail: some View {
        Group {
            if let selection, store.rule(withID: selection) != nil {
                AutoRenameRuleEditor(ruleID: selection, lastAddedTarget: $lastAddedTarget)
                    .id(selection)
            } else {
                ContentUnavailableView {
                    Label("No Rule Selected", systemImage: "text.cursor")
                } description: {
                    Text("Add a rule with the + button, or select one on the left.")
                }
                .frame(maxHeight: .infinity)
            }
        }
        // 帯はフォームの上に差し込む(VStack で積むと、帯が 2 本出たときにウインドウの中身全体が上下にはみ出し、左の一覧まで見えなくなった。2026-09-16 の実機)。
        .safeAreaInset(edge: .top, spacing: 0) {
            banners
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if service.isPausedForReadOnly {
                AutoRenameBanner(systemImage: "pause.circle", tint: .secondary) {
                    Text("Auto rename is paused while the file browser is in read-only mode.")
                } action: {
                    Button("Turn Off Read-Only") { preferences.fileBrowserReadOnly = false }
                }
            }
            if !service.targetsAwaitingConfirmation.isEmpty {
                AutoRenameBanner(systemImage: "checkmark.circle", tint: .accentColor) {
                    Text("Some rules would rename items that are already in their folders. They won’t rename anything until you check the changes.")
                } action: {
                    Button("Review Changes…") { sheet = .confirmation }
                }
            }
            if !service.moveSuggestions.isEmpty {
                AutoRenameBanner(systemImage: "arrow.right.circle", tint: .orange) {
                    Text(String(
                        format: String(localized: "%lld target folders seem to have moved.", language: locale),
                        service.moveSuggestions.count
                    ))
                } action: {
                    Button("Review…") { sheet = .moveSuggestions }
                }
            }
        }
    }

    private var statusText: some View {
        let enabledRules = store.rules.filter(\.isEnabled).count
        let targets = store.rules.flatMap(\.targets)
        return HStack(spacing: 6) {
            Text(String(format: String(localized: "%1$lld of %2$lld rules on", language: locale), enabledRules, store.rules.count))
            ListWindowStatusSeparator()
            Text(String(format: String(localized: "%lld target folders", language: locale), targets.count))
            if service.isPausedForReadOnly {
                ListWindowStatusSeparator()
                Text("Paused (read-only mode)")
            }
        }
    }
}

/// 左の一覧の 1 行。
private struct AutoRenameRuleRow: View {
    @EnvironmentObject private var store: AutoRenameStore
    @Environment(\.locale) private var locale
    let rule: AutoRenameRule
    let hasProblem: Bool

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    guard var current = store.rule(withID: rule.id) else { return }
                    current.isEnabled = newValue
                    store.update(rule: current)
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            Text(verbatim: rule.displayName(locale: locale))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            Spacer(minLength: 0)
            if hasProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(Text("Some target folders can’t be used."))
            }
        }
    }
}

/// 帯 1 本。
private struct AutoRenameBanner<Message: View, Action: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder var message: Message
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            // 文の高さを自分で固定しない(`fixedSize(vertical:)` はボタンに幅を取られたときに縦へ伸び、ウインドウからはみ出した)。
            message
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            action
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 規則の中身

/// 右ペイン。規則の中身と対象フォルダの一覧。
private struct AutoRenameRuleEditor: View {
    @EnvironmentObject private var store: AutoRenameStore
    @EnvironmentObject private var service: AutoRenameService
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var favorites: FavoriteLocationStore
    @Environment(\.locale) private var locale
    let ruleID: UUID
    @Binding var lastAddedTarget: AddedTarget?

    @State private var addProblem: String?

    struct AddedTarget {
        /// 揃えたパス(`AutoRename.canonicalPath`)。
        let path: String
        let panelDirectory: URL
    }

    private var rule: AutoRenameRule {
        store.rule(withID: ruleID) ?? AutoRenameRule(id: ruleID)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AutoRenameRule, Value>) -> Binding<Value> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: { newValue in
                guard var current = store.rule(withID: ruleID) else { return }
                current[keyPath: keyPath] = newValue
                store.update(rule: current)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name), prompt: Text(verbatim: AutoRenameRule(
                    operation: rule.operation, find: rule.find, replaceWith: rule.replaceWith, replaceScope: rule.replaceScope,
                    addedText: rule.addedText, addPlacement: rule.addPlacement
                ).displayName(locale: locale)))
                Toggle("On", isOn: binding(\.isEnabled))
            } header: {
                Text("Rule")
            }

            Section {
                Picker("Rename By", selection: binding(\.operation)) {
                    Text("Replace Text").tag(AutoRenameRule.Operation.replaceText)
                    Text("Add Text").tag(AutoRenameRule.Operation.addText)
                }
                .pickerStyle(.segmented)
                switch rule.operation {
                case .replaceText:
                    Picker("Replace In", selection: binding(\.replaceScope)) {
                        Text("File Name").tag(AutoRenameRule.ReplaceScope.name)
                        Text("Extension").tag(AutoRenameRule.ReplaceScope.fileExtension)
                    }
                    .pickerStyle(.segmented)
                    // 欄の枠が見えない(グループのフォームの TextField は右寄せの文字だけ)ので、どこに打つかが分かる例を出す(2026-09-16 の実機)。
                    TextField("Find", text: binding(\.find), prompt: rule.replaceScope == .fileExtension ? Text(verbatim: "zip") : Text("Text to find"))
                    TextField("Replace With", text: binding(\.replaceWith), prompt: rule.replaceScope == .fileExtension ? Text(verbatim: "cbz") : Text("Leave empty to remove"))
                case .addText:
                    TextField("Text", text: binding(\.addedText), prompt: Text("Text to add"))
                    Picker("Add", selection: binding(\.addPlacement)) {
                        Text("Before Name").tag(BulkRename.Placement.beforeName)
                        Text("After Name").tag(BulkRename.Placement.afterName)
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Match Case", isOn: binding(\.isCaseSensitive))
                Toggle("Rename Folders Too", isOn: binding(\.includesFolders))
                    .disabled(!rule.canApplyToFolders)
            } header: {
                Text("How to Rename")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(operationHelp)
                    if !rule.hasEffect {
                        Label(emptyRuleMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                if rule.targets.isEmpty {
                    Text("No target folders yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rule.targets) { target in
                    AutoRenameTargetRow(ruleID: ruleID, target: target)
                }
                HStack {
                    Button {
                        chooseFolder()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .disabled(rule.targets.count >= AutoRename.maxTargetsPerRule)
                    Spacer()
                    Text(String(
                        format: String(localized: "%1$lld / %2$lld", language: locale),
                        rule.targets.count, AutoRename.maxTargetsPerRule
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let addProblem {
                    Label(addProblem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Target Folders")
            } footer: {
                Text("Only folders in Favorite Locations, or folders inside them, can be targets. Folders on network volumes can’t be used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var operationHelp: String {
        switch rule.operation {
        case .replaceText:
            switch rule.replaceScope {
            case .name:
                return String(localized: "Every match in the name is replaced. The extension is left as it is.", language: locale)
            case .fileExtension:
                return String(
                    localized: "The last extension is replaced only when it matches the text exactly (for example zip → cbz). Folders are never changed by this rule.",
                    language: locale
                )
            }
        case .addText:
            return String(
                localized: "The text is added before the name or before the extension. Names that already start or end with the text are left as they are.",
                language: locale
            )
        }
    }

    private var emptyRuleMessage: String {
        switch rule.operation {
        case .replaceText where rule.replaceScope == .fileExtension:
            String(localized: "Enter both extensions. This rule renames nothing until then.", language: locale)
        case .replaceText:
            String(localized: "Enter the text to find. This rule renames nothing until then.", language: locale)
        case .addText:
            String(localized: "Enter the text to add. This rule renames nothing until then.", language: locale)
        }
    }

    private func chooseFolder() {
        addProblem = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = panelStartDirectory()
        panel.prompt = String(localized: "Add", language: locale)
        panel.message = String(
            localized: "Choose a folder in Favorite Locations, or a folder inside one, to rename items in automatically.",
            language: locale
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let panelDirectory = panel.directoryURL ?? url.deletingLastPathComponent()
        Task {
            let result = await service.addTarget(folder: url, toRule: ruleID)
            addProblem = Self.message(for: result, locale: locale)
            // 次の「フォルダを追加…」は、よく使う項目の「＋」と同じく**パネルを閉じた時点で見ていた場所**から始める
            // (FileBrowserActions.addFavoriteLocation)。
            if result == .added {
                lastAddedTarget = AddedTarget(path: AutoRename.canonicalPath(of: url), panelDirectory: panelDirectory)
            }
        }
    }

    /// 「フォルダを追加…」のパネルをどこから始めるか。
    ///
    /// 以前は最後の対象フォルダそのもの(`rule.targets.last?.url`)から始めていたので、FolderA の中で FolderB を選んで足すと、
    /// 次のパネルが FolderB の**中に入った状態**で開いた(2026-09-17、ユーザー指摘。よく使う項目の「＋」で直したのと同じ症状)。
    /// - この規則の最後の対象が、このウインドウで直前に足したものなら、そのときパネルを閉じた場所。
    /// - そうでなければ(アプリを起動し直した・別の規則で足した・対象を消した)、最後の対象の親。対象が無ければ最初のよく使う項目。
    ///   **ウインドウを閉じて開き直しても記憶は残る**(`Window` シーンは閉じてもビューの状態を保つ。2026-09-17 の実機で確認)。
    private func panelStartDirectory() -> URL? {
        guard let last = rule.targets.last else { return favorites.items.first?.url }
        if let lastAddedTarget, lastAddedTarget.path == last.path {
            return lastAddedTarget.panelDirectory
        }
        return last.url.deletingLastPathComponent()
    }

    static func message(for result: AutoRenameService.AddTargetResult, locale: Locale) -> String? {
        switch result {
        case .added: nil
        case .alreadyAdded: String(localized: "That folder is already a target of this rule.", language: locale)
        case .limitReached: String(localized: "This rule already has as many target folders as it can.", language: locale)
        case .ineligible(.networkVolume): String(localized: "Folders on network volumes can’t be targets.", language: locale)
        case .ineligible: String(localized: "Choose a folder in Favorite Locations, or a folder inside one.", language: locale)
        }
    }
}

/// 対象フォルダの 1 行。
private struct AutoRenameTargetRow: View {
    @EnvironmentObject private var store: AutoRenameStore
    @EnvironmentObject private var service: AutoRenameService
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @Environment(\.locale) private var locale
    let ruleID: UUID
    let target: AutoRenameTarget

    private var problem: (message: String, isMissing: Bool)? {
        if target.state == .disabledMissing {
            return (String(localized: "Not found", language: locale), true)
        }
        switch service.availability[target.id] {
        case .outsideFavorites?: return (String(localized: "Not in Favorite Locations", language: locale), false)
        case .volumeNotConnected?: return (String(localized: "The volume isn’t connected", language: locale), false)
        case .networkVolume?: return (String(localized: "On a network volume", language: locale), false)
        case .noAccess?: return (String(localized: "No access", language: locale), false)
        case .missing?: return (String(localized: "Not found", language: locale), true)
        case .available?, nil: return nil
        }
    }

    var body: some View {
        let problem = problem
        let isDimmed = problem != nil || target.state != .enabled
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { target.state == .enabled },
                set: { store.setTarget(id: target.id, inRule: ruleID, enabled: $0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: target.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                    .help(Text(verbatim: target.path))
                if let problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(problem.isMissing ? .orange : .secondary)
                } else if service.targetsAwaitingConfirmation.contains(target.id) {
                    Label("Waiting for you to check the changes", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if service.availability[target.id] == .noAccess {
                Button("Grant Access…") { grantAccess() }
            }
            Toggle("Include Subfolders", isOn: Binding(
                get: { target.includesSubfolders },
                set: { newValue in
                    var updated = target
                    updated.includesSubfolders = newValue
                    store.update(target: updated, inRule: ruleID)
                }
            ))
            .toggleStyle(.checkbox)
            Button {
                store.removeTarget(id: target.id, fromRule: ruleID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(Text("Remove"))
        }
    }

    private func grantAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = target.url
        panel.prompt = String(localized: "Grant Access", language: locale)
        panel.message = String(localized: "To rename items in this folder automatically, please select and grant access to it.", language: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = folderAccess.add(url: url)
        service.refreshAvailability()
    }
}
