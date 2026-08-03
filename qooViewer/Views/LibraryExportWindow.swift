import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 設計コンセプト6.2節: エクスポート用の独立ウインドウ。お気に入り・ブックマーク・ページ
/// レイアウト設定のうち書き出す種類をチェックボックスで選び、NSSavePanelで保存先を選ぶ。
/// 「ブックマーク・レイアウトの編集」ウインドウと同じく、本を今開いているかどうかに関わらず
/// メニューバーの「ファイル」メニューからいつでも開ける独立ウインドウとして実装している。
struct LibraryExportWindow: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var preferences: AppPreferences

    @State private var includeFavorites = true
    @State private var includeBookmarks = true
    @State private var includeLayouts = true
    @State private var isExporting = false
    @State private var resultMessage: String?
    @State private var didSucceed = false

    private var hasSelection: Bool {
        includeFavorites || includeBookmarks || includeLayouts
    }

    var body: some View {
        Form {
            Section {
                Toggle("Favorites", isOn: $includeFavorites)
                Toggle("Bookmarks", isOn: $includeBookmarks)
                Toggle("Page Layout Settings", isOn: $includeLayouts)
            } footer: {
                Text("This creates a single JSON file that only qooViewer can read back in. ComicInfo.xml is not supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let resultMessage {
                Section {
                    Label {
                        Text(resultMessage)
                    } icon: {
                        Image(systemName: didSucceed ? "checkmark.circle" : "exclamationmark.triangle")
                    }
                    .foregroundStyle(didSucceed ? Color.primary : Color.orange)
                    .font(.caption)
                }
            }

            Section {
                HStack {
                    Button("Export…") {
                        exportButtonTapped()
                    }
                    .disabled(!hasSelection || isExporting)

                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 440, minHeight: 320)
    }

    private func exportButtonTapped() {
        let locale = preferences.effectiveLocale
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "qooViewer Library.json", locale: locale)
        panel.message = String(localized: "Choose where to save the exported JSON file.", locale: locale)
        if let lastFolder = LibraryIOFolderMemory.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LibraryIOFolderMemory.remember(url.deletingLastPathComponent())

        isExporting = true
        resultMessage = nil
        Task {
            let selection = LibraryImportExportService.ExportSelection(
                includeFavorites: includeFavorites, includeBookmarks: includeBookmarks, includeLayouts: includeLayouts
            )
            let (file, result) = await LibraryImportExportService.buildExportFile(
                selection: selection, favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore
            )
            do {
                try LibraryImportExportService.write(file, to: url)
                didSucceed = true
                if result.skippedBookmarkBookIDs.isEmpty {
                    resultMessage = String(localized: "Export complete.", locale: locale)
                } else {
                    resultMessage = String(
                        format: String(
                            localized: "Export complete. %d book(s) were skipped because their files couldn't be found.",
                            locale: locale
                        ),
                        result.skippedBookmarkBookIDs.count
                    )
                }
            } catch {
                didSucceed = false
                resultMessage = String(
                    format: String(localized: "Export failed: %@", locale: locale),
                    error.localizedDescription
                )
            }
            isExporting = false
        }
    }
}
