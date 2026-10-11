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
    @EnvironmentObject private var secretFolderStore: SecretFolderStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var loadedFile: QooLibraryExportFile?
    @State private var sourceFileName: String?
    /// カテゴリごとの取り込み方針(ピッカー)。開き直すたびに既定から始める(`resetForNextOpen`)。
    @State private var policies = Self.defaultPolicies
    @State private var isImporting = false
    /// 直前の読み込みの結果と、そのとき**実際に使った**ファイル・方針(下の `ImportOutcome`)。
    @State private var outcome: ImportOutcome?
    @State private var loadErrorMessage: String?
    @State private var hasPromptedForFile = false
    /// 閉じたときに読み込みの途中だったので、次に開いたときに捨てる(`handlePresence`)。
    @State private var resetsWhenIdle = false

    /// 方針の既定。
    /// 改善要望5でお気に入りを無効化した間は、ファイルに`favorites`があっても取り込まない
    /// (取り込んでもどこにも見えないため。FavoritesFeature参照)。読み込みの経路自体は
    /// 壊さずに残してあるので、復活させれば過去の書き出しファイルからそのまま取り込める。
    /// 規則(qooMeta。以前はフォーマット定義)は「取り込む=自分の設定を丸ごと置き換える」操作になるため、既定は無視。
    /// マージという選択肢自体が無い(ImportPolicies.metadataRulesのコメント参照)。
    /// 2026-09-23 に足した環境設定も規則と同じく「置き換えるか取り込まないか」の2択で、既定は無視。
    /// ほかは ImportPolicies の既定(マージ)のまま。
    private static var defaultPolicies: LibraryImportExportService.ImportPolicies {
        LibraryImportExportService.ImportPolicies(
            favorites: FavoritesFeature.isEnabled ? .merge : .ignore,
            metadataRules: .ignore,
            settings: .ignore
        )
    }

    /// 結果の欄に出すもの。**読み込んだ時点の**ファイルと方針を控える(2026-10-04 の監査 TW-9)。以前は結果の各行を「いまのピッカー」と
    /// 「いまのファイル」で出し分けていたので、読み込んだ後で方針を変える・別のファイルを選ぶと、結果の欄が実際にしたことと違う
    /// ことを言った(「無視」に変えた行が消える、取り込んでいないファイルのカテゴリの行が出る)。
    private struct ImportOutcome {
        let summary: LibraryImportExportService.ImportSummary
        let file: QooLibraryExportFile
        let policies: LibraryImportExportService.ImportPolicies
    }

    /// ファイルに含まれているカテゴリかどうか(ユーザー要望: 方針ピッカーは、ファイルを
    /// 選ぶ前も含めて常に表示し続け、対象カテゴリが無い/ファイル未選択の間だけ無効化する
    /// ことで、選んだ瞬間にピッカーが増減してレイアウトが変わらないようにしたい)。
    private var categories: FileCategories { FileCategories(loadedFile) }

    /// ファイルが持っているカテゴリ。ピッカーの淡色は選んでいるファイルで、結果の欄は読み込んだときのファイル(`ImportOutcome.file`)で決める。
    private struct FileCategories {
        let hasFavorites: Bool
        let hasCollections: Bool
        let hasBookmarks: Bool
        let hasLayouts: Bool
        let hasMetadata: Bool
        /// 規則(新しい形の `metadataRules` か、以前の形の `metadataFormats`)を含むか。
        let hasMetadataRules: Bool
        let hasReadingStates: Bool
        let hasSmartLibrary: Bool
        let hasFileBrowser: Bool
        let hasSettings: Bool

        init(_ file: QooLibraryExportFile?) {
            hasFavorites = file?.favorites != nil
            hasCollections = file?.libraries?.isEmpty == false
            hasBookmarks = file?.bookmarks?.isEmpty == false
            hasLayouts = file?.layouts?.isEmpty == false
            hasMetadata = file?.metadata?.isEmpty == false
            hasMetadataRules = file?.metadataRules != nil || file?.metadataFormats != nil
            hasReadingStates = file?.readingStates?.isEmpty == false
            hasSmartLibrary = file?.smartLibrary != nil
            hasFileBrowser = file?.fileBrowser != nil
            hasSettings = file?.settings?.values.isEmpty == false || file?.secretFolders?.isEmpty == false
        }
    }

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
                    // 読み込みの途中でファイルを替えると、結果の欄が読み込んでいないファイルのものに見える(TW-9)。
                    .disabled(isImporting)
                }

                // ユーザー要望: お気に入り/ブックマーク/ページレイアウトの取り込み方針は、
                // ファイルを選ぶ前も常に表示したまま(隠さない)にし、対象カテゴリが無い間は
                // 触れないようグレーアウトするだけにしたい。
                Section {
                    if FavoritesFeature.isEnabled {
                        policyPicker("Favorites", selection: $policies.favorites)
                            .disabled(!categories.hasFavorites || isImporting)
                    }
                    policyPicker("Collections", selection: $policies.collections)
                        .disabled(!categories.hasCollections || isImporting)
                    policyPicker("Bookmarks", selection: $policies.bookmarks)
                        .disabled(!categories.hasBookmarks || isImporting)
                    // ユーザー要望: 「ページレイアウトの設定」から「の設定」を省き、
                    // お気に入り・ブックマークの見出しと同じ体裁の「ページレイアウト」にしたい。
                    policyPicker("Page Layout", selection: $policies.layouts)
                        .disabled(!categories.hasLayouts || isImporting)
                    policyPicker("Metadata", selection: $policies.metadata)
                        .disabled(!categories.hasMetadata || isImporting)
                    // フォーマット定義は本ごとのデータではなくアプリ全体の設定のため、
                    // 「マージ」を選べるようにしても意味のある結果にならない。
                    // 置き換えるか取り込まないかの2択だけを出す。
                    Picker("Metadata Rules", selection: $policies.metadataRules) {
                        Text(LibraryImportExportService.ImportPolicy.overwrite.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.overwrite)
                        Text(LibraryImportExportService.ImportPolicy.ignore.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.ignore)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!categories.hasMetadataRules || isImporting)
                    // 2026-09-23 に足したカテゴリ。
                    policyPicker("Reading Positions", selection: $policies.readingStates)
                        .disabled(!categories.hasReadingStates || isImporting)
                    policyPicker("Smart Library", selection: $policies.smartLibrary)
                        .disabled(!categories.hasSmartLibrary || isImporting)
                    policyPicker("File Browser", selection: $policies.fileBrowser)
                        .disabled(!categories.hasFileBrowser || isImporting)
                    // 環境設定もアプリ全体の設定なので、規則と同じく2択(ImportPolicies.settings)。
                    Picker("Settings", selection: $policies.settings) {
                        Text(LibraryImportExportService.ImportPolicy.overwrite.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.overwrite)
                        Text(LibraryImportExportService.ImportPolicy.ignore.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.ignore)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!categories.hasSettings || isImporting)
                } footer: {
                    Text("Overwrite replaces existing data for the books mentioned in the file. Merge only adds what's missing, without changing anything that already exists. Ignore skips that category entirely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let outcome {
                    Section("Result") {
                        importSummaryView(outcome)
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
        // 出た・閉じた(補助ウインドウの共通の決まり。View.auxiliaryWindowPresence のコメント)。
        .auxiliaryWindowPresence { handlePresence($0) }
    }

    /// 出たら(最初に開いたときと、まっさらに戻した後に開き直したとき)ファイル選択のパネルを出す。閉じたら、読み込んだファイル・
    /// 方針・結果・パネルの番人を捨てる(2026-10-04 の監査 TW-8)。
    ///
    /// この窓は `Window` シーンで、閉じても `@State` が残る。以前は開き直すと、前回のファイル名・結果・方針(「上書き」を含む)が
    /// そのまま出て、パネルも出なかった ―― 別のバックアップを読み込むつもりで開いて「保存データを読み込む」を押すと、メモリに
    /// 持っている前回のファイルの中身で、前回の方針のまま今のデータを書き換えた。
    /// 読み込みの途中で閉じたときは(閉じても処理は続く)、終わるまで消さず、次に開いたときに捨てる。
    private func handlePresence(_ presented: Bool) {
        if presented {
            if resetsWhenIdle, !isImporting { resetForNextOpen() }
            resetsWhenIdle = false
            guard !hasPromptedForFile else { return }
            hasPromptedForFile = true
            chooseFileButtonTapped()
        } else if isImporting {
            resetsWhenIdle = true
        } else {
            resetForNextOpen()
        }
    }

    private func resetForNextOpen() {
        loadedFile = nil
        sourceFileName = nil
        policies = Self.defaultPolicies
        outcome = nil
        loadErrorMessage = nil
        hasPromptedForFile = false
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
                // 実行中は止められない(読み込みは途中で切ると保存データが半分だけ書き換わる)。以前は「キャンセル」が押せて、
                // 窓を閉じるだけで処理は最後まで続いていた(2026-10-04 の監査 TW-12)。淡色にして、閉じても続くことを言葉で示す。
                Text("Importing saved data… It continues even if you close this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isImporting)

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
    private func metadataSummaryRows(_ outcome: ImportOutcome) -> some View {
        let summary = outcome.summary
        let categories = FileCategories(outcome.file)
        let policies = outcome.policies
        if categories.hasMetadata, policies.metadata != .ignore {
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
    private func importSummaryView(_ outcome: ImportOutcome) -> some View {
        let summary = outcome.summary
        let categories = FileCategories(outcome.file)
        let policies = outcome.policies
        if categories.hasFavorites, policies.favorites != .ignore {
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
        if categories.hasCollections, policies.collections != .ignore {
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
        if categories.hasBookmarks, policies.bookmarks != .ignore {
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
        if categories.hasLayouts, policies.layouts != .ignore {
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
        metadataSummaryRows(outcome)
        backupSummaryRows(outcome)
    }

    /// 2026-09-23 に足したカテゴリの結果(同じく子の数の上限のため別のメソッド)。
    @ViewBuilder
    private func backupSummaryRows(_ outcome: ImportOutcome) -> some View {
        let summary = outcome.summary
        let categories = FileCategories(outcome.file)
        let policies = outcome.policies
        let locale = preferences.effectiveLocale
        if categories.hasReadingStates, policies.readingStates != .ignore {
            Text(String(format: String(localized: "Reading Positions: %d book(s) imported.", language: locale),
                        summary.readingStatesImportedBooks))
                .font(.caption)
        }
        if categories.hasSmartLibrary, policies.smartLibrary != .ignore {
            Text(String(format: String(localized: "Smart Library: %d smart collection(s), %d target folder(s) imported.",
                                       language: locale),
                        summary.smartLibraryImportedShelves, summary.smartLibraryImportedFolders))
                .font(.caption)
        }
        if categories.hasFileBrowser, policies.fileBrowser != .ignore {
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
        if categories.hasSettings, policies.settings != .ignore {
            Text(String(format: String(localized: "Settings: %d setting(s) imported.", language: locale),
                        summary.importedSettingsCount))
                .font(.caption)
            if summary.importedSecretFolderCount > 0 {
                Text(String(format: String(localized: "Secret Folders: %d folder(s) added.", language: locale),
                            summary.importedSecretFolderCount))
                    .font(.caption)
            }
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
        WindowSheet.beginChoosing(panel) { urls in
            guard let url = urls?.first, !isImporting else { return }
            LastUsedFolderMemory.libraryIO.remember(url.deletingLastPathComponent())

            do {
                let file = try LibraryImportExportService.read(from: url)
                loadedFile = file
                sourceFileName = url.lastPathComponent
                outcome = nil
                loadErrorMessage = nil
            } catch {
                // 読めなかったら前のファイルも手放す(2026-10-04 の監査 TW-9)。以前は前のファイルを持ったままで、エラーの下で
                // 「保存データを読み込む」が押せ、押すと前のファイルが読み込まれた。
                loadedFile = nil
                sourceFileName = nil
                outcome = nil
                loadErrorMessage = String(
                    format: String(localized: "This file couldn't be read: %@", language: locale),
                    error.localizedDescription
                )
            }
        }
    }

    private func importButtonTapped() {
        guard let loadedFile else { return }
        isImporting = true
        // ⌘Q の確認のために数える(RunningWorkRegistry。途中で切れると保存データが半分だけ書き換わる)。
        let workToken = RunningWorkRegistry.forCurrentProcess?.begin()
        // 押した時点の方針を控える(結果の欄はこれで描く。ImportOutcome のコメント)。
        let appliedPolicies = policies
        Task {
            defer { if let workToken { RunningWorkRegistry.forCurrentProcess?.end(workToken) } }
            // シーンが `.modelContext` を注入し忘れると、既定の空のコンテキストへ書いて何も残らない(高 2)。
            assert(modelContext.container === QooViewerApp.modelContainer, "libraryImport のシーンに .modelContext が無い")
            let summary = await LibraryImportExportService.apply(
                loadedFile, policies: appliedPolicies,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                metadataStore: metadataStore, metadataRulesStore: metadataRulesStore,
                collectionStore: collectionStore,
                backupStores: LibraryImportExportService.BackupStores(
                    modelContext: modelContext, smartLibrary: smartLibraryStore,
                    favoriteLocations: favoriteLocations, autoRename: autoRenameStore,
                    preferences: preferences, keyBindings: keyBindingStore, secretFolders: secretFolderStore
                )
            )
            outcome = ImportOutcome(summary: summary, file: loadedFile, policies: appliedPolicies)
            // 取り込んだ本のカバーはpendingのまま置いてある(applyCollections参照)。
            // ここで待ち行列へ入れておくと、ウェルカム画面を開いた時点で埋まり始める。
            collectionCoverExtractor.refill()
            isImporting = false
        }
    }
}
