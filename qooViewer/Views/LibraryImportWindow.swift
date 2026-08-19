import SwiftUI
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
    @EnvironmentObject private var metadataFormatStore: MetadataFormatStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var loadedFile: QooLibraryExportFile?
    @State private var sourceFileName: String?
    @State private var favoritesPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var bookmarksPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var layoutsPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var metadataPolicy: LibraryImportExportService.ImportPolicy = .merge
    /// フォーマット定義は「取り込む=自分の設定を丸ごと置き換える」操作になるため、既定は無視。
    /// マージという選択肢自体が無い(ImportPolicies.metadataFormatsのコメント参照)。
    @State private var metadataFormatsPolicy: LibraryImportExportService.ImportPolicy = .ignore
    @State private var isImporting = false
    @State private var summary: LibraryImportExportService.ImportSummary?
    @State private var loadErrorMessage: String?
    @State private var hasPromptedForFile = false

    /// ファイルに含まれているカテゴリかどうか(ユーザー要望: 方針ピッカーは、ファイルを
    /// 選ぶ前も含めて常に表示し続け、対象カテゴリが無い/ファイル未選択の間だけ無効化する
    /// ことで、選んだ瞬間にピッカーが増減してレイアウトが変わらないようにしたい)。
    private var hasFavorites: Bool { loadedFile?.favorites != nil }
    private var hasBookmarks: Bool { loadedFile?.bookmarks?.isEmpty == false }
    private var hasLayouts: Bool { loadedFile?.layouts?.isEmpty == false }
    private var hasMetadata: Bool { loadedFile?.metadata?.isEmpty == false }
    private var hasMetadataFormats: Bool { loadedFile?.metadataFormats != nil }

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
                    policyPicker("Favorites", selection: $favoritesPolicy)
                        .disabled(!hasFavorites)
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
                    Picker("Metadata Formats", selection: $metadataFormatsPolicy) {
                        Text(LibraryImportExportService.ImportPolicy.overwrite.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.overwrite)
                        Text(LibraryImportExportService.ImportPolicy.ignore.titleKey)
                            .tag(LibraryImportExportService.ImportPolicy.ignore)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!hasMetadataFormats)
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

            Button("Import Library Data") {
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
                    format: String(localized: "Metadata: %d book(s) imported."),
                    summary.metadataImportedBooks
                )
            )
            .font(.caption)
        }
        if summary.didImportMetadataFormats {
            Text("Metadata formats were replaced with the ones in the file.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func importSummaryView(_ summary: LibraryImportExportService.ImportSummary) -> some View {
        if loadedFile?.favorites != nil, favoritesPolicy != .ignore {
            Text(
                String(
                    format: String(localized: "Favorites: %d folder(s), %d book(s) imported."),
                    summary.favoritesImportedFolders, summary.favoritesImportedBooks
                )
            )
            .font(.caption)
            if summary.favoritesSkippedForLimit > 0 {
                Text(
                    String(
                        format: String(localized: "%d favorite(s) were skipped because the total limit was reached."),
                        summary.favoritesSkippedForLimit
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        if loadedFile?.bookmarks?.isEmpty == false, bookmarksPolicy != .ignore {
            Text(
                String(
                    format: String(localized: "Bookmarks: %d bookmark(s) across %d book(s) imported."),
                    summary.bookmarksImportedEntries, summary.bookmarksImportedBooks
                )
            )
            .font(.caption)
            if !summary.bookmarksSkippedBookIDs.isEmpty {
                Text(
                    String(
                        format: String(localized: "%d book(s) were skipped because their files couldn't be found."),
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
                    format: String(localized: "Page Layout Settings: %d book(s) imported."),
                    summary.layoutsImportedBooks
                )
            )
            .font(.caption)
            if !summary.layoutsSkippedBookIDs.isEmpty {
                Text(
                    String(
                        format: String(localized: "%d book(s) were skipped because their files couldn't be found."),
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
    }

    private func chooseFileButtonTapped() {
        let locale = preferences.effectiveLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Choose a JSON file exported from qooViewer.", locale: locale)
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
                format: String(localized: "This file couldn't be read: %@", locale: locale),
                error.localizedDescription
            )
        }
    }

    private func importButtonTapped() {
        guard let loadedFile else { return }
        isImporting = true
        Task {
            let policies = LibraryImportExportService.ImportPolicies(
                favorites: favoritesPolicy, bookmarks: bookmarksPolicy, layouts: layoutsPolicy,
                metadata: metadataPolicy, metadataFormats: metadataFormatsPolicy
            )
            summary = await LibraryImportExportService.apply(
                loadedFile, policies: policies,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                metadataStore: metadataStore, metadataFormatStore: metadataFormatStore
            )
            isImporting = false
        }
    }
}
