import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 設計コンセプト6.2節: インポート用の独立ウインドウ。NSOpenPanelでJSONファイルを選び、
/// ファイルに含まれているカテゴリ(お気に入り/ブックマーク/ページレイアウト設定)ごとに
/// 上書き/マージ/無視を選んでから取り込む。含まれていないカテゴリはピッカー自体を表示しない
/// (存在しないキーに対してユーザーが方針を選ぶ意味が無いため)。
struct LibraryImportWindow: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var preferences: AppPreferences

    @State private var loadedFile: QooLibraryExportFile?
    @State private var sourceFileName: String?
    @State private var favoritesPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var bookmarksPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var layoutsPolicy: LibraryImportExportService.ImportPolicy = .merge
    @State private var isImporting = false
    @State private var summary: LibraryImportExportService.ImportSummary?
    @State private var loadErrorMessage: String?
    @State private var hasPromptedForFile = false

    var body: some View {
        Form {
            if let loadedFile {
                Section {
                    Text(sourceFileName ?? "")
                        .font(.headline)
                    Button("Choose a Different File…") {
                        chooseFileButtonTapped()
                    }
                }

                if loadedFile.favorites != nil {
                    policyPicker("Favorites", selection: $favoritesPolicy)
                }
                if loadedFile.bookmarks?.isEmpty == false {
                    policyPicker("Bookmarks", selection: $bookmarksPolicy)
                }
                if loadedFile.layouts?.isEmpty == false {
                    policyPicker("Page Layout Settings", selection: $layoutsPolicy)
                }

                Section {
                    HStack {
                        Button("Import") {
                            importButtonTapped()
                        }
                        .disabled(isImporting)

                        if isImporting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
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
            } else {
                Section {
                    ContentUnavailableView(
                        "No File Selected",
                        systemImage: "square.and.arrow.down",
                        description: Text("Choose a JSON file exported from qooViewer.")
                    )
                    if let loadErrorMessage {
                        Text(loadErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Choose File…") {
                        chooseFileButtonTapped()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            guard !hasPromptedForFile else { return }
            hasPromptedForFile = true
            chooseFileButtonTapped()
        }
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
    }

    private func chooseFileButtonTapped() {
        let locale = preferences.effectiveLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Choose a JSON file exported from qooViewer.", locale: locale)
        if let lastFolder = LibraryIOFolderMemory.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LibraryIOFolderMemory.remember(url.deletingLastPathComponent())

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
                favorites: favoritesPolicy, bookmarks: bookmarksPolicy, layouts: layoutsPolicy
            )
            summary = await LibraryImportExportService.apply(
                loadedFile, policies: policies,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore
            )
            isImporting = false
        }
    }
}
