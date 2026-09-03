import SwiftUI
import AppKit

/// 環境設定ウインドウの「レイアウト」画面(ユーザー要望)。
///
/// ■ この画面が受け持つこと
/// 1. レイアウトの保存データを持っていない本を開いたときに、本全体を自動レイアウトするか
/// 2. 形式(EPUB / PDF / CBZ)ごとの、書き出しの保存先・オプションの既定値・
///    書き出し終わった本の後始末
/// 3. 右クリックから書き出したあと、次に何をするか
///
/// ■ なぜ1枚に同居しているのか
/// ユーザーが繰り返したい作業が「新しい本を開く(自動でレイアウトされる)→ 右クリックから
/// 書き出す → そのまま次の本を開く」という**一続きの流れ**だから。1〜3はその流れの
/// 3つの区切りに1対1で対応していて、どれか1つだけ設定しても流れは完成しない。
///
/// ■ 形式ごとのセクションに分けてある理由
/// 形式ごとに5〜7行ある。設定ごとに「EPUB/PDF/CBZ」の3行を並べる形にすると、同じ形式の
/// 設定が画面のあちこちに散る。実際にユーザーが決めるのは「EPUBで書き出すときはこうする」
/// という**形式単位のまとまり**なので、セクションを形式で切って、1つの形式の設定が必ず
/// 隣り合って見えるようにしている。
///
/// セクションの中の並びは、書き出しの時間順にしてある: どこへ(保存先)→ 何を書くか
/// (オプション)→ そのあと元の本をどうするか(保存データ・履歴)。
struct LayoutSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences

    /// 固定の保存先フォルダの表示を描き直させるための世代番号。
    ///
    /// 保存先フォルダはセキュリティスコープ付きブックマークなので`AppPreferences`ではなく
    /// `LastUsedFolderMemory`(UserDefaultsを直接読む)が持っており、`@Published`ではない。
    /// フォルダを選び直しても、そのままでは画面が描き直されないため、この値を進める
    /// (RecentFilesStore等と違い、この記憶を見るのはこの画面と書き出しの実行時だけなので、
    /// 専用のObservableObjectを1つ増やすより軽い)。
    @State private var fixedFolderGeneration = 0

    var body: some View {
        SettingsPaneContainer {
            // 1. レイアウトの保存データを持っていない本を開いたとき
            Section {
                SettingsPicker(
                    "Auto-Layout",
                    selection: $preferences.missingLayoutAutoLayout,
                    help: "Lays out the whole book the same way “Auto-Layout Based on Current View” does, using the first page as the starting point. Books that already have layout data — including EPUB and PDF, whose layout is imported the first time you open them — are left alone."
                )
            } header: {
                Text("Opening a Book Without Layout Data")
            }

            // 2. 形式ごとの書き出し
            ForEach(BookExportFormat.allCases) { format in
                Section {
                    SettingsPicker(
                        "Destination",
                        selection: destinationModeBinding(for: format),
                        help: "Once a folder is chosen, exporting from the right-click menu asks nothing and writes straight to it."
                    )
                    if preferences.bookExportDestinationMode(for: format) == .fixedFolder {
                        fixedFolderRow(for: format)
                    }
                    // 書き出しオプションの既定値(ユーザー要望)。ここで決めた値が、書き出し
                    // ウインドウの「書き出しオプション…」と右クリックの書き出しシートの
                    // 開いた直後の値になる(AppPreferences.bookExportRenumbersImages参照)。
                    // どの項目を出すかは形式が決める(BookExportFormat.supportsImageRenumbering)。
                    if format.supportsImageRenumbering {
                        SettingsToggle(
                            "Renumber Image Files Sequentially",
                            isOn: preferences.bookExportRenumbersImagesBinding(for: format),
                            help: format == .cbz
                                ? "CBZ files have no page-order metadata, so readers sort by file name. Turn this off only if you want to keep the original file names."
                                : nil
                        )
                    }
                    SettingsToggle(
                        "Include Excluded Pages",
                        isOn: preferences.bookExportIncludesExcludedPagesBinding(for: format)
                    )
                    if format.supportsComicInfoVolumeElement {
                        SettingsToggle(
                            "Also Write the Volume Number to ComicInfo\u{2019}s Volume Element",
                            isOn: $preferences.bookExportWritesVolumeElement,
                            help: "Kavita reads Volume as the volume number, but Komga appends it to the series name, which can split a series into one series per volume."
                        )
                    }
                    SettingsPicker(
                        "Saved Data",
                        selection: preferences.bookExportDataCleanupBinding(for: format),
                        help: "Deletes this book's page layout, bookmarks, metadata and reading position once it has been exported. Favorites are kept. This can't be undone."
                    )
                    SettingsPicker(
                        "History",
                        selection: preferences.bookExportHistoryCleanupBinding(for: format),
                        help: "Removes this book from the history list once it has been exported. The book itself is not touched."
                    )
                } header: {
                    // 形式名は固有名詞なので翻訳しない(BookExportFormat.displayName参照)。
                    Text(verbatim: format.displayName)
                }
            }

            // 3. 書き出したあとの動作
            Section {
                // 行のラベルはセクション見出しの言い換えにしない(SettingsControlsの3層の方針)。
                // 見出しが「いつの話か」を言い切っているので、ここは「そのあと何を決めるのか」
                // だけでよい。
                SettingsPicker(
                    "Afterwards",
                    selection: $preferences.bookExportCompletionBehavior,
                    help: "“Close Book” closes this tab (the window too, if it is the only tab). “Return to Welcome Screen” keeps the window open."
                )
            } header: {
                Text("Exporting the Book You Are Reading")
            }

            SettingsResetSection(
                help: "Restores every setting on this page, including the fixed destination folders. Other pages, and your favorites, bookmarks and reading history, are not affected."
            ) {
                preferences.resetToDefaults(.layout)
                fixedFolderGeneration &+= 1
            }
        }
    }

    // MARK: - 固定の保存先

    /// 保存先の決め方のBinding。「保存先を設定」を選んだその場でフォルダを選ばせる
    /// (ユーザー要望)。フォルダを選ばずに閉じられた場合、保存先の分からない「保存先を設定」が
    /// 残ってしまうので「毎回確認」へ戻す ―― 既に一度設定したフォルダがあるなら、それを
    /// 選び直さなかっただけなのでそのまま残す。
    private func destinationModeBinding(for format: BookExportFormat) -> Binding<BookExportDestinationMode> {
        let stored = preferences.bookExportDestinationModeBinding(for: format)
        return Binding(
            get: { stored.wrappedValue },
            set: { newValue in
                stored.wrappedValue = newValue
                guard newValue == .fixedFolder else { return }
                // フォルダ選択パネルは、この場(ポップアップの選択が反映されている最中)では
                // 開かない。NSOpenPanel.runModal()はモーダルループを回すので、SwiftUIの
                // 更新の途中で呼ぶと再入することになる。値の反映を終わらせてから開く。
                Task { @MainActor in
                    guard !chooseFixedFolder(for: format),
                          format.fixedFolder.lastFolderPath() == nil
                    else { return }
                    // 一度も設定されていないのにフォルダを選ばずに閉じられた。保存先の
                    // 分からない「保存先を設定」が残ってしまうので「毎回確認」へ戻す。
                    stored.wrappedValue = .askEachTime
                }
            }
        )
    }

    /// いま設定されている保存先フォルダを見せる行。パスは`remember`した時点のもので、
    /// フォルダを開くのには使えない(`LastUsedFolderMemory.lastFolderPath()`参照)。
    private func fixedFolderRow(for format: BookExportFormat) -> some View {
        // fixedFolderGenerationをここで読むことで、フォルダを選び直したときにこの行が
        // 描き直される(@Stateのコメント参照)。
        let path = { _ = fixedFolderGeneration; return format.fixedFolder.lastFolderPath() }()
        return SettingRow("Folder") {
            HStack(spacing: 8) {
                // フォルダ名だけだと、書き出し先を形式名で分けている人には
                // 「保存先」ではなく「形式」に見える(ExportDestinationLabel参照)。
                ExportDestinationLabel(path: path)
                Button("Change…") {
                    _ = chooseFixedFolder(for: format)
                }
            }
        }
    }

    /// 保存先フォルダを選ばせる。選ばれたらtrue。
    @discardableResult
    private func chooseFixedFolder(for format: BookExportFormat) -> Bool {
        let locale = preferences.effectiveLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", language: locale)
        panel.message = String(
            localized: "Choose the folder to always export to.", language: locale
        )
        if let current = format.fixedFolder.lastFolder() ?? format.lastUsedFolder.lastFolder() {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        format.fixedFolder.remember(folder)
        fixedFolderGeneration &+= 1
        return true
    }
}
