import SwiftUI
import AppKit

/// 環境設定「レイアウト」から進む、書き出しの形式1つ分の子ページ。
///
/// 「レイアウト」の形式の一覧(LayoutSettingsView.formatsSection)の行を押して開く。
/// ウインドウのタイトルは形式名になり、ツールバーの「戻る」で一覧へ戻る
/// (2階層にした理由はLayoutSettingsView冒頭参照)。
///
/// ■ 載っているもの
/// この形式で本を1冊まるごと書き出すときの既定値。並びは**書き出しの時間順**にしてある:
/// どこへ(保存先)→ 何を書くか(オプション)→ そのあと元の本をどうするか(保存データ・履歴)。
/// 以前この画面が「レイアウト」の中の1セクションだったときと同じ並びで、行そのものも
/// 変えていない ―― 分けたのは探しやすさのためだけなので、中身の意味は動かさない。
///
/// どの行を出すかは形式が決める(`BookExportFormat.supportsImageRenumbering` /
/// `supportsComicInfoVolumeElement`)。形式ごとに`if`を書き分けないのは、書き出し
/// ウインドウ側のオプションと判定を共有して「片方にだけ項目が出る」食い違いを作らないため
/// (BookExportFormatのコメント参照)。
///
/// ■ 「初期設定に戻す」は置かない
/// 「レイアウト」の一覧ページ末尾のものが、全形式のページの設定ごと戻す
/// (理由はPanelSurfaceSettingsViewの同じ項参照)。
struct BookExportFormatSettingsView: View {
    let format: BookExportFormat

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
            Section {
                SettingsPicker(
                    "Destination",
                    selection: destinationModeBinding,
                    help: "Once a folder is chosen, exporting from the right-click menu asks nothing and writes straight to it."
                )
                if preferences.bookExportDestinationMode(for: format) == .fixedFolder {
                    fixedFolderRow
                }
                // 書き出しオプションの既定値(ユーザー要望)。ここで決めた値が、書き出し
                // ウインドウの「書き出しオプション…」と右クリックの書き出しシートの
                // 開いた直後の値になる(AppPreferences.bookExportRenumbersImages参照)。
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
                // 見出しに形式名を入れてある。この画面に来るまでの経路(一覧の行/タイトルバー)
                // でも形式は分かるが、**セクションが1つしか無いので見出しが「書き出しの設定だ」と
                // 言わないと、タイトルの「CBZ」だけでは何の設定なのかが分からない**。
                // 隣の「レイアウト」の2つの見出しと同じ「〜とき」の形に揃えてある。
                Text("When Exporting as \(format.displayName)")
            }
        }
        // 子ページの間はウインドウのタイトルを形式名にする(一覧では「レイアウト」)。
        // 形式名は固有名詞で翻訳の対象にならないため、`SettingsPane`/`PanelSurface`の
        // タイトルと違って表示言語で引く必要がない(BookExportFormat.displayName参照)。
        .navigationTitle(format.displayName)
    }

    // MARK: - 固定の保存先

    /// 保存先の決め方のBinding。「保存先を設定」を選んだその場でフォルダを選ばせる
    /// (ユーザー要望)。フォルダを選ばずに閉じられた場合、保存先の分からない「保存先を設定」が
    /// 残ってしまうので「毎回確認」へ戻す ―― 既に一度設定したフォルダがあるなら、それを
    /// 選び直さなかっただけなのでそのまま残す。
    private var destinationModeBinding: Binding<BookExportDestinationMode> {
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
                    guard !chooseFixedFolder(),
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
    private var fixedFolderRow: some View {
        // fixedFolderGenerationをここで読むことで、フォルダを選び直したときにこの行が
        // 描き直される(@Stateのコメント参照)。
        let path = { _ = fixedFolderGeneration; return format.fixedFolder.lastFolderPath() }()
        return SettingRow("Folder") {
            HStack(spacing: 8) {
                // フォルダ名だけだと、書き出し先を形式名で分けている人には
                // 「保存先」ではなく「形式」に見える(ExportDestinationLabel参照)。
                ExportDestinationLabel(path: path)
                Button("Change…") {
                    _ = chooseFixedFolder()
                }
            }
        }
    }

    /// 保存先フォルダを選ばせる。選ばれたらtrue。
    @discardableResult
    private func chooseFixedFolder() -> Bool {
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
