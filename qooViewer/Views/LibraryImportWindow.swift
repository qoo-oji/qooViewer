import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// 設計コンセプト6.2節: インポート用の独立ウインドウ。NSOpenPanelでJSONファイルを選び、
/// ファイルに含まれているカテゴリ(お気に入り/ブックマーク/ページレイアウト設定)ごとに
/// 上書き/マージ/無視を選んでから取り込む。
///
/// ユーザー要望: 以前は、ファイルに含まれていないカテゴリのピッカーや、ファイルを選ぶ前の
/// 「インポート」ボタン自体を非表示にしていたが、ファイルを選んだ瞬間にウインドウの中身が
/// 増減してレイアウトが変わるのが分かりづらいという指摘があった。方針ピッカー・
/// 「ライブラリデータをインポート」ボタンはどちらも常に表示したままにし、対象カテゴリが無い/
/// ファイル未選択の間は無効化(グレーアウト)するだけにする。
struct LibraryImportWindow: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @Environment(MetadataRulesStore.self) private var metadataRulesStore
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var collectionCoverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var preferences: AppPreferences
    // 2026-09-23: 本ごとのデータ以外(読書位置・スマートライブラリ・ファイルブラウザ・環境設定)。
    @EnvironmentObject private var smartLibraryStore: SmartLibraryStore
    @EnvironmentObject private var favoriteLocations: FavoriteLocationStore
    @EnvironmentObject private var autoRenameStore: AutoRenameStore
    @EnvironmentObject private var keyBindingStore: KeyBindingStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var loadedFile: QooLibraryExportFile?
    @State private var sourceFileName: String?
    // 改善要望5でお気に入りを無効化した間は、ファイルに`favorites`があっても取り込まない
    // (取り込んでもどこにも見えないため。FavoritesFeature参照)。読み込みの経路自体は
    // 壊さずに残してあるので、復活させれば過去の書き出しファイルからそのまま取り込める。
    @State private var favoritesPolicy: LibraryImportExportService.ImportPolicy =
        FavoritesFeature.isEnabled ? .merge : .ignore
    @State private var collectionsPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var bookmarksPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var layoutsPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var metadataPolicy: LibraryImportExportService.ImportPolicy = .merge
    /// 規則(qooMeta。以前はフォーマット定義)は「取り込む=自分の設定を丸ごと置き換える」操作になるため、既定は無視。
    /// マージという選択肢自体が無い(ImportPolicies.metadataRulesのコメント参照)。
    @State private var metadataRulesPolicy: LibraryImportExportService.ImportPolicy = .ignore
    /// 2026-09-23 に足したカテゴリ。環境設定は規則と同じく「置き換えるか取り込まないか」の2択で、既定は無視。
    @State private var readingStatesPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var smartLibraryPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var fileBrowserPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var settingsPolicy: LibraryImportExportService.ImportPolicy = .ignore
    @State private var isImporting = false
    @State private var summary: LibraryImportExportService.ImportSummary?
    @State private var loadErrorMessage: String?
    @State private var hasPromptedForFile = false

    /// ファイルに含まれているカテゴリかどうか(ユーザー要望: 方針ピッカーは、ファイルを
    /// 選ぶ前も含めて常に表示し続け、対象カテゴリが無い/ファイル未選択の間だけ無効化する
    /// ことで、選んだ瞬間にピッカーが増減してレイアウトが変わらないようにしたい)。
    private var hasFavorites: Bool { loadedFile?.favorites != nil }
    private var hasCollections: Bool { loadedFile?.libraries?.isEmpty == false }
    private var hasBookmarks: Bool { loadedFile?.bookmarks?.isEmpty == false }
    private var hasLayouts: Bool { loadedFile?.layouts?.isEmpty == false }
    private var hasMetadata: Bool { loadedFile?.metadata?.isEmpty == false }
    /// 規則(新しい形の `metadataRules` か、以前の形の `metadataFormats`)を含むか。
    private var hasMetadataRules: Bool { loadedFile?.metadataRules != nil || loadedFile?.metadataFormats != nil }
    private var hasReadingStates: Bool { loadedFile?.readingStates?.isEmpty == false }
    private var hasSmartLibrary: Bool { loadedFile?.smartLibrary != nil }
    private var hasFileBrowser: Bool { loadedFile?.fileBrowser != nil }
    private var hasSettings: Bool { loadedFile?.settings?.values.isEmpty == false }

    // バグ修正(ユーザー報告): LibraryExportWindowと同じ理由(コメント参照)で、ボタン行を
    // Form(スクロール領域)の外側、VStack(spacing: 0)の中でDivider()の下に独立させ、
    // EPUB出力ウインドウと同じ「区切り線+右下配置」の見た目・ウインドウの縦サイズが内容に
    // 自然に収まる挙動に揃えた。
    var body: some View {
        VStack(spacing: 0) {
            Form {
                // ユーザー要望: ファイル未選択時は「ファイルが選択されていません」、選択後は
                // ファイル名を表示するが、両方とも1行ぶんの高さだけの同じ領域にすることで、
                // ファイルを選んだ瞬間にレイアウトが縦にジャンプしないようにしたい。
                // 「ファイルを選ぶ」ボタンと「別のファイルを選ぶ」ボタンも、状態に関わらず
                // 同じ1個のボタン(ラベルだけ切り替え)にすることで、常に同じ位置に表示される
                // ようにする。
                Section {
                    Group {
                        if let sourceFileName {
                            Text(sourceFileName)
                                .font(.headline)
                        } else {
                            Text("No File Selected")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)

                    if let loadErrorMessage {
                        Text(loadErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button(loadedFile == nil ? "Choose File…" : "Choose a Different File…") {
                        chooseFileButtonTapped()
                    }
                }

                // ユーザー要望: お気に入り/ブックマーク/ページレイアウトの取り込み方針は、
                // ファイルを選ぶ前も常に表示したまま(隠さない)にし、対象カテゴリが無い間は
                // 触れないようグレーアウトするだけにしたい。
                Section {
                    if FavoritesFeature.isEnabled {
                        policyPicker("Favorites", selection: $favoritesPolicy)
                            .disabled(!hasFavorites)
                    }
                    policyPicker("Collections", selection: $collectionsPolicy)
                        .disabled(!hasCollections)
                    policyPicker("Bookmarks", selection: $bookmarksPolicy)
                        .disabled(!hasBookmarks)
                    // ユーザー要望: 「ページレイアウトの設定」から「の設定」を省き、
                    // お気に入り・ブックマークの見出しと同じ体裁の「ページレイアウト」にしたい。
                    policyPicker("Page Layout", selection: $layoutsPolicy)
                        .disabled(!hasLayouts)
                    policyPicker("Metadata", selection: $metadataPolicy)
                        .disabled(!hasMetadata)
                    // フォーマット定義は本ごとのデータではなくアプリ全体の設定のため、
                    // 「マージ」を選べるようにしても意味のある結果にならない。
                    // 置き換えるか取り込まないかの2択だけを出す。
                    Picker("Metadata Rules", selection: $metadataRulesPolicy) {
                        Text(LibraryImportExportService.ImportPolicy.overwrite.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.overwrite)
                        Text(LibraryImportExportService.ImportPolicy.ignore.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.ignore)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!hasMetadataRules)
                    // 2026-09-23 に足したカテゴリ。
                    policyPicker("Reading Positions", selection: $readingStatesPolicy)
                        .disabled(!hasReadingStates)
                    policyPicker("Smart Library", selection: $smartLibraryPolicy)
                        .disabled(!hasSmartLibrary)
                    policyPicker("File Browser", selection: $fileBrowserPolicy)
                        .disabled(!hasFileBrowser)
                    // 環境設定もアプリ全体の設定なので、規則と同じく2択(ImportPolicies.settings)。
                    Picker("Settings", selection: $settingsPolicy) {
                        Text(LibraryImportExportService.ImportPolicy.overwrite.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.overwrite)
                        Text(LibraryImportExportService.ImportPolicy.ignore.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.ignore)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!hasSettings)
                } footer: {
                    Text("Overwrite replaces existing data for the books mentioned in the file. Merge only adds what's missing, without changing anything that already exists. Ignore skips that category entirely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let summary {
                    Section("Result") {
                        importSummaryView(summary)
                    }
                }
            }
            // ユーザー報告: LibraryExportWindowと同じ理由(コメント参照)で、素のForm
            // (既定スタイル)に変更したところトグル・ピッカーの見た目が.formStyle(.grouped)から
            // 変わってしまった、との指摘を受け.formStyle(.grouped)に戻した。中身とボタン行の
            // 間の大きな空白は.fixedSize(horizontal: false, vertical: true)だけで解消する
            // (見た目を保ったまま、縦方向だけ中身の実サイズに合わせる)。
            //
            // ユーザー報告(左右の余白・不要なスクロールバー): LibraryExportWindowと同じ理由
            // (コメント参照)。.formStyle(.grouped)の内容幅600pt頭打ち中央寄せの仕様により、
            // ウインドウの既定幅が実際に必要な幅より広いと左右に余白として見えてしまうため、
            // idealWidth/maxWidthを明示してウインドウが不必要に広く開かないようにした。
            // スクロールバーは.scrollIndicators(.hidden)で非表示にする(.fixedSize(vertical:
            // true)により実際にスクロールが発生することは無いため、隠しても操作性への影響は
            // 無い)。
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.hidden)

            Divider()
            bottomSection
        }
        .frame(minWidth: 460, idealWidth: 460, maxWidth: 540)
        .onAppear {
            guard !hasPromptedForFile else { return }
            hasPromptedForFile = true
            chooseFileButtonTapped()
        }
    }

    /// ユーザー要望: 「ライブラリデータをインポート」ボタンは、ファイルを選ぶ前も
    /// 常にウインドウ右下に表示し、選ぶまでは無効化するだけにしたい。左に
    /// 「キャンセル」ボタンを追加し、EPUB出力ウインドウの「EPUB出力を開始」ボタンと
    /// 同じアクセントカラー(既定ボタン=.keyboardShortcut(.defaultAction))に揃える。
    @ViewBuilder
    private var bottomSection: some View {
        HStack {
            Spacer()
            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Import Saved Data") {
                importButtonTapped()
            }
            .disabled(loadedFile == nil || isImporting)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    @ViewBuilder
    private func policyPicker(
        _ titleKey: LocalizedStringKey, selection: Binding<LibraryImportExportService.ImportPolicy>
    ) -> some View {
        Picker(titleKey, selection: selection) {
            ForEach(LibraryImportExportService.ImportPolicy.allCases) { policy in
                Text(policy.titleKey).tag(policy)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func metadataSummaryRows(_ summary: LibraryImportExportService.ImportSummary) -> some View {
        if hasMetadata, metadataPolicy != .ignore {
            Text(
                String(
                    format: String(localized: "Metadata: %d book(s) imported.", language: preferences.effectiveLocale),
                    summary.metadataImportedBooks
                )
            )
            .font(.caption)
        }
        if summary.didImportMetadataRules {
            Text("Metadata rules were replaced with the ones in the file.")
                .font(.caption)
        }
        if !summary.metadataRuleErrors.isEmpty {
            Text(String(format: String(localized: "The metadata rules in the file could not be read, so they were not imported: %@",
                                       language: preferences.effectiveLocale),
                        summary.metadataRuleErrors.joined(separator: " / ")))
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func importSummaryView(_ summary: LibraryImportExportService.ImportSummary) -> some View {
        if loadedFile?.favorites != nil, favoritesPolicy != .ignore {
            Text(
                String(
                    format: String(localized: "Favorites: %d folder(s), %d book(s) imported.", language: preferences.effectiveLocale),
                    summary.favoritesImportedFolders, summary.favoritesImportedBooks
                )
            )
            .font(.caption)
            if summary.favoritesSkippedForLimit > 0 {
                Text(
                    String(
                        format: String(localized: "%d favorite(s) were skipped because the total limit was reached.", language: preferences.effectiveLocale),
                        summary.favoritesSkippedForLimit
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        if hasCollections, collectionsPolicy != .ignore {
            Text(
                String(
                    format: String(localized: "Collections: %d library(ies), %d collection(s), %d book(s) imported.", language: preferences.effectiveLocale),
                    summary.collectionsImportedLibraries, summary.collectionsImportedCollections,
                    summary.collectionsImportedBooks
                )
            )
            .font(.caption)
            if !summary.collectionsSkippedBookIDs.isEmpty {
                Text(
                    String(
                        format: String(localized: "%d book(s) were skipped because their files couldn't be found.", language: preferences.effectiveLocale),
                        summary.collectionsSkippedBookIDs.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        if loadedFile?.bookmarks?.isEmpty == false, bookmarksPolicy != .ignore {
            Text(
                String(
                    format: String(localized: "Bookmarks: %d bookmark(s) across %d book(s) imported.", language: preferences.effectiveLocale),
                    summary.bookmarksImportedEntries, summary.bookmarksImportedBooks
                )
            )
            .font(.caption)
            if !summary.bookmarksSkippedBookIDs.isEmpty {
                Text(
                    String(
                        format: String(localized: "%d book(s) were skipped because their files couldn't be found.", language: preferences.effectiveLocale),
                        summary.bookmarksSkippedBookIDs.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        if loadedFile?.layouts?.isEmpty == false, layoutsPolicy != .ignore {
            Text(
                String(
                    format: String(localized: "Page Layout Settings: %d book(s) imported.", language: preferences.effectiveLocale),
                    summary.layoutsImportedBooks
                )
            )
            .font(.caption)
            if !summary.layoutsSkippedBookIDs.isEmpty {
                Text(
                    String(
                        format: String(localized: "%d book(s) were skipped because their files couldn't be found.", language: preferences.effectiveLocale),
                        summary.layoutsSkippedBookIDs.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        // メタデータ関連の行は、ViewBuilderが1つのビュー本体で扱える子の数の上限
        // (10個)を超えないよう、別のメソッドへ切り出してある。
        metadataSummaryRows(summary)
        backupSummaryRows(summary)
    }

    /// 2026-09-23 に足したカテゴリの結果(同じく子の数の上限のため別のメソッド)。
    @ViewBuilder
    private func backupSummaryRows(_ summary: LibraryImportExportService.ImportSummary) -> some View {
        let locale = preferences.effectiveLocale
        if hasReadingStates, readingStatesPolicy != .ignore {
            Text(String(format: String(localized: "Reading Positions: %d book(s) imported.", language: locale),
                        summary.readingStatesImportedBooks))
                .font(.caption)
        }
        if hasSmartLibrary, smartLibraryPolicy != .ignore {
            Text(String(format: String(localized: "Smart Library: %d smart collection(s), %d target folder(s) imported.",
                                       language: locale),
                        summary.smartLibraryImportedShelves, summary.smartLibraryImportedFolders))
                .font(.caption)
        }
        if hasFileBrowser, fileBrowserPolicy != .ignore {
            Text(String(format: String(localized: "File Browser: %d favorite location(s), %d auto rename rule(s) imported.",
                                       language: locale),
                        summary.fileBrowserImportedLocations, summary.fileBrowserImportedAutoRenameRules))
                .font(.caption)
            // 対象フォルダの確認の印は持ち込まない(AutoRenameStore.importBackup)。黙って何も
            // 起きないと「壊れている」と見えるので、そのことを書いておく。
            if summary.fileBrowserImportedAutoRenameRules > 0 {
                Text("Auto rename won't touch the imported folders until you confirm their contents again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if hasSettings, settingsPolicy != .ignore {
            Text(String(format: String(localized: "Settings: %d setting(s) imported.", language: locale),
                        summary.importedSettingsCount))
                .font(.caption)
            // メニューバーと表示言語は起動し直すまで切り替わらない(AppLanguage の型コメント)。
            Text("The menu bar follows the imported display language from the next launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFileButtonTapped() {
        let locale = preferences.effectiveLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Choose a JSON file exported from qooViewer.", language: locale)
        if let lastFolder = LastUsedFolderMemory.libraryIO.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LastUsedFolderMemory.libraryIO.remember(url.deletingLastPathComponent())

        do {
            let file = try LibraryImportExportService.read(from: url)
            loadedFile = file
            sourceFileName = url.lastPathComponent
            summary = nil
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = String(
                format: String(localized: "This file couldn't be read: %@", language: locale),
                error.localizedDescription
            )
        }
    }

    private func importButtonTapped() {
        guard let loadedFile else { return }
        isImporting = true
        // ⌘Q の確認のために数える(RunningWorkRegistry。途中で切れると保存データが半分だけ書き換わる)。
        let workToken = RunningWorkRegistry.forCurrentProcess?.begin()
        Task {
            defer { if let workToken { RunningWorkRegistry.forCurrentProcess?.end(workToken) } }
            let policies = LibraryImportExportService.ImportPolicies(
                favorites: favoritesPolicy, bookmarks: bookmarksPolicy, layouts: layoutsPolicy,
                metadata: metadataPolicy, metadataRules: metadataRulesPolicy,
                collections: collectionsPolicy, readingStates: readingStatesPolicy,
                smartLibrary: smartLibraryPolicy, fileBrowser: fileBrowserPolicy,
                settings: settingsPolicy
            )
            // シーンが `.modelContext` を注入し忘れると、既定の空のコンテキストへ書いて何も残らない(高 2)。
            assert(modelContext.container === QooViewerApp.modelContainer, "libraryImport のシーンに .modelContext が無い")
            summary = await LibraryImportExportService.apply(
                loadedFile, policies: policies,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                metadataStore: metadataStore, metadataRulesStore: metadataRulesStore,
                collectionStore: collectionStore,
                backupStores: LibraryImportExportService.BackupStores(
                    modelContext: modelContext, smartLibrary: smartLibraryStore,
                    favoriteLocations: favoriteLocations, autoRename: autoRenameStore,
                    preferences: preferences, keyBindings: keyBindingStore
                )
            )
            // 取り込んだ本のカバーはpendingのまま置いてある(applyCollections参照)。
            // ここで待ち行列へ入れておくと、ウェルカム画面を開いた時点で埋まり始める。
            collectionCoverExtractor.refill()
            isImporting = false
        }
    }
}
