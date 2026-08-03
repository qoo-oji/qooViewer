import SwiftUI

/// 設計コンセプト5節: 選択中の本のブックマークをまとめてリネームするための小ウインドウ。
/// 「ブックマーク・レイアウトの編集」ウインドウ(4.4節)の「一括リネーム」ボタンから開く。
///
/// Windowシーンは単一インスタンス(for:による値のパラメータ化ができない)のため、対象bookIDは
/// launchCoordinator.pendingBulkRenameBookID経由で受け取る(EditorInitialFocusと同じ仕組み。
/// 詳細はLaunchCoordinator.swiftのコメント参照)。
enum LastBookmarkTreatment: String, CaseIterable, Identifiable {
    case normal
    case afterword
    case colophon
    case bonus

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .normal: return "Normal Bookmark"
        case .afterword: return "Afterword"
        case .colophon: return "Colophon"
        case .bonus: return "Bonus"
        }
    }

    /// String(localized:locale:)で使う、実際にリネームする際の固定名。
    /// .normalの場合は固定名を持たない(連番リネームの対象に含める)。
    var fixedNameKey: String.LocalizationValue? {
        switch self {
        case .normal: return nil
        case .afterword: return "Afterword"
        case .colophon: return "Colophon"
        case .bonus: return "Bonus"
        }
    }
}

struct BulkRenameBookmarksWindow: View {
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var bookID: String?
    @State private var assignFixedCover = false
    @State private var lastBookmarkTreatment: LastBookmarkTreatment = .normal
    @State private var startNumber = 1
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var hasInitializedDefaults = false

    var body: some View {
        Group {
            if let bookID {
                content(for: bookID)
            } else {
                ContentUnavailableView(
                    "No Book Selected",
                    systemImage: "textformat",
                    description: Text("Open this window from the “Bulk Rename Bookmarks…” button in the bookmark editor.")
                )
                .frame(minWidth: 420, minHeight: 320)
            }
        }
        .onAppear {
            bookID = launchCoordinator.pendingBulkRenameBookID
            initializeDefaultsIfNeeded()
        }
        .onChange(of: launchCoordinator.pendingBulkRenameBookID) { _, newValue in
            bookID = newValue
        }
    }

    private func initializeDefaultsIfNeeded() {
        guard !hasInitializedDefaults else { return }
        hasInitializedDefaults = true
        // 表示言語(preferences.effectiveLocale)に応じた既定値。既存のブックマーク既定名
        // (ViewerViewModel.addBookmarkの"Page N")と同じ考え方(設計コンセプト5節)。
        let isJapanese = preferences.effectiveLocale.identifier.hasPrefix("ja")
        prefix = isJapanese ? "第" : "Episode "
        suffix = isJapanese ? "話" : ""
    }

    @ViewBuilder
    private func content(for bookID: String) -> some View {
        let bookmarks = bookmarkStore.bookmarks(forBookID: bookID).sorted { $0.pageIndex < $1.pageIndex }
        let displayName = URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent

        Form {
            Section {
                Text(displayName)
                    .font(.headline)
            }

            Section {
                Toggle("Assign a Fixed Name to the Cover Page", isOn: $assignFixedCover)

                Picker("Last Bookmark", selection: $lastBookmarkTreatment) {
                    ForEach(LastBookmarkTreatment.allCases) { treatment in
                        Text(treatment.titleKey).tag(treatment)
                    }
                }
            } footer: {
                Text("The cover page and the last bookmark (if set to something other than “Normal Bookmark”) are excluded from the sequential numbering below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Start Number")
                    Spacer()
                    TextField("", value: $startNumber, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    TextField("Prefix", text: $prefix)
                    TextField("Suffix", text: $suffix)
                }
            }

            if !bookmarks.isEmpty {
                Section("Preview") {
                    ForEach(previewNames(bookID: bookID, bookmarks: bookmarks).prefix(6), id: \.id) { item in
                        HStack {
                            Text(item.originalName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                            Text(item.newName)
                        }
                        .font(.caption)
                    }
                }
            }

            Section {
                Button("Apply") {
                    applyRenaming(bookID: bookID, bookmarks: bookmarks)
                    dismiss()
                }
                .disabled(bookmarks.isEmpty && !assignFixedCover)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 480)
    }

    private struct PreviewItem: Identifiable {
        let id: UUID
        let originalName: String
        let newName: String
    }

    /// 実際のApply処理と同じロジックで、プレビュー表示用の「旧名 → 新名」一覧を組み立てる。
    /// 表紙をまだ追加していない状態(assignFixedCover ON、かつ先頭ページにブックマークが
    /// 無い)の場合は、追加される表紙自体はまだ存在しないためプレビューには含めない。
    private func previewNames(bookID: String, bookmarks: [Bookmark]) -> [PreviewItem] {
        var excludedIDs: Set<UUID> = []
        var items: [PreviewItem] = []

        if assignFixedCover, let cover = bookmarks.first(where: { $0.pageIndex == 0 }) {
            let coverName = String(localized: "Cover", locale: preferences.effectiveLocale)
            items.append(PreviewItem(id: cover.id, originalName: cover.name, newName: coverName))
            excludedIDs.insert(cover.id)
        }

        if let fixedNameKey = lastBookmarkTreatment.fixedNameKey, let last = bookmarks.last, !excludedIDs.contains(last.id) {
            let name = String(localized: fixedNameKey, locale: preferences.effectiveLocale)
            items.append(PreviewItem(id: last.id, originalName: last.name, newName: name))
            excludedIDs.insert(last.id)
        }

        var number = startNumber
        for bookmark in bookmarks where !excludedIDs.contains(bookmark.id) {
            items.append(PreviewItem(id: bookmark.id, originalName: bookmark.name, newName: "\(prefix)\(number)\(suffix)"))
            number += 1
        }

        return items.sorted { lhs, rhs in
            let lhsIndex = bookmarks.first { $0.id == lhs.id }?.pageIndex ?? 0
            let rhsIndex = bookmarks.first { $0.id == rhs.id }?.pageIndex ?? 0
            return lhsIndex < rhsIndex
        }
    }

    /// 実際にリネームを適用する(設計コンセプト5節)。
    private func applyRenaming(bookID: String, bookmarks: [Bookmark]) {
        var sorted = bookmarks
        var excludedIDs: Set<UUID> = []

        if assignFixedCover {
            let coverName = String(localized: "Cover", locale: preferences.effectiveLocale)
            if let cover = sorted.first(where: { $0.pageIndex == 0 }) {
                bookmarkStore.rename(cover, to: coverName)
                excludedIDs.insert(cover.id)
            } else {
                // 先頭ページにブックマークが無い場合は自動で追加する(5節)。本を今開いているか
                // どうかに関わらず動作させる必要があるため、BookmarkStore.addBookmark(bookID:
                // pageIndex:name:)を直接呼ぶ(ViewerViewModel.addBookmarkは今開いている本にしか
                // 使えないため)。
                bookmarkStore.addBookmark(bookID: bookID, pageIndex: 0, name: coverName)
                sorted = bookmarkStore.bookmarks(forBookID: bookID).sorted { $0.pageIndex < $1.pageIndex }
                if let cover = sorted.first(where: { $0.pageIndex == 0 }) {
                    excludedIDs.insert(cover.id)
                }
            }
        }

        if let fixedNameKey = lastBookmarkTreatment.fixedNameKey, let last = sorted.last, !excludedIDs.contains(last.id) {
            let name = String(localized: fixedNameKey, locale: preferences.effectiveLocale)
            bookmarkStore.rename(last, to: name)
            excludedIDs.insert(last.id)
        }

        var number = startNumber
        for bookmark in sorted where !excludedIDs.contains(bookmark.id) {
            bookmarkStore.rename(bookmark, to: "\(prefix)\(number)\(suffix)")
            number += 1
        }
    }
}
