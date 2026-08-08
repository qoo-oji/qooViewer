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
    @EnvironmentObject private var layoutStore: LayoutStore
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
                // ユーザー報告: 従来の文言・説明だと、既にブックマークされている先頭ページの
                // 名前だけを変える機能に見えてしまう。実際は先頭ページにブックマークが無くても
                // (強制的に)「表紙」という名前のブックマークを付与する機能のため、それが
                // 伝わる文言に変更した(実装(applyRenaming)自体は元から変更なし)。
                Toggle("Assign a Fixed Cover to the First Page", isOn: $assignFixedCover)

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

            // ユーザー要望: 上から「番号前の文字列」→「連番開始番号」→「番号後の文字列」の順で
            // 並べてほしい(以前は開始番号が一番上、前後の文字列はその下に横並びだった)。
            // 見た目もそろえるため、3項目とも同じ「ラベル + 右寄せの入力欄」の行にしてある。
            Section {
                HStack {
                    Text("Text Before Number")
                    Spacer()
                    TextField("", text: $prefix)
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Sequence Start Number")
                    Spacer()
                    TextField("", value: $startNumber, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Text After Number")
                    Spacer()
                    TextField("", text: $suffix)
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                }
            }

            if !bookmarks.isEmpty {
                // ユーザー報告: プレビューが先頭6件しか表示されず、ブックマークが多い本では
                // 大半が確認できなかった。Form(macOSではList相当でスクロール可能)の中に
                // そのままForEachで全件並べれば、件数が多くてもスクロールして全件確認できる
                // ため、6件への打ち切りをやめた。
                Section("Preview") {
                    ForEach(previewNames(bookID: bookID, bookmarks: bookmarks), id: \.id) { item in
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
            // EPUB出力ウインドウの列見出し(EpubExportWindow.swift)で使っている"Cover"キーとは
            // 意図的に別のローカライズキーにしてある。あちらは「カバー画像」という列見出しの
            // 訳語(カバー画像)のままでよいが、ここで割り当てるのはブックマークの名前そのもの
            // (ユーザー要望: 「表紙」という名前を付けてほしい)のため、共用すると列見出しの
            // 訳語まで意図せず変わってしまう。
            let coverName = String(localized: "Cover Bookmark Name", locale: preferences.effectiveLocale)
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

        // ソート比較のたびにbookmarksを線形探索すると要素数が多いほど二乗オーダーで重くなる
        // (テキストフィールドを1文字打つたびに再計算されるため無視できない)。
        // 事前にID -> pageIndexの辞書を1回だけ作り、比較はO(1)ルックアップにする(結果は従来と同一)。
        let pageIndexByID = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0.pageIndex) })
        return items.sorted { lhs, rhs in
            let lhsIndex = pageIndexByID[lhs.id] ?? 0
            let rhsIndex = pageIndexByID[rhs.id] ?? 0
            return lhsIndex < rhsIndex
        }
    }

    /// 実際にリネームを適用する(設計コンセプト5節)。
    ///
    /// 経緯(ユーザー報告): 他にも「一括で処理できるはずのSQLite書き込みを個別に行っている
    /// 箇所」がないか確認してほしい、との依頼を受けて見つかった箇所。以前はここで
    /// bookmarkStore.rename(_:to:)を対象ブックマーク数ぶんループで個別に呼んでおり、
    /// そのたびに同期save()+reload()+通知が走っていた(本によっては数百件になることも
    /// 珍しくない)。実際のリネームはpendingRenamesへ集計するだけにとどめ、最後に
    /// bookmarkStore.renameBookmarks(bookID:renames:)へまとめて渡すことで、この「一括
    /// リネーム」の実行1回につき保存・再フェッチ・通知を1回にまとめる。
    private func applyRenaming(bookID: String, bookmarks: [Bookmark]) {
        var sorted = bookmarks
        var excludedIDs: Set<UUID> = []
        var pendingRenames: [(bookmark: Bookmark, newName: String)] = []

        if assignFixedCover {
            // EPUB出力ウインドウの列見出し(EpubExportWindow.swift)で使っている"Cover"キーとは
            // 意図的に別のローカライズキーにしてある。あちらは「カバー画像」という列見出しの
            // 訳語(カバー画像)のままでよいが、ここで割り当てるのはブックマークの名前そのもの
            // (ユーザー要望: 「表紙」という名前を付けてほしい)のため、共用すると列見出しの
            // 訳語まで意図せず変わってしまう。
            let coverName = String(localized: "Cover Bookmark Name", locale: preferences.effectiveLocale)
            if let cover = sorted.first(where: { $0.pageIndex == 0 }) {
                pendingRenames.append((cover, coverName))
                excludedIDs.insert(cover.id)
            } else {
                // 先頭ページにブックマークが無い場合は自動で追加する(5節)。本を今開いているか
                // どうかに関わらず動作させる必要があるため、BookmarkStore.addBookmark(bookID:
                // pageIndex:name:)を直接呼ぶ(ViewerViewModel.addBookmarkは今開いている本にしか
                // 使えないため)。これは新規追加(リネームではない)1件だけなので、まとめる対象には
                // 含めない。
                // ユーザー要望: ここで作成するブックマークにもファイルノード識別子を記録したい
                // (BookmarkDetailPane.addBookmark(atPageIndex:)と同じ理由・同じ解決手段)。
                var fileNodeIdentifier: FileNodeIdentifier?
                if let url = layoutStore.resolvedURL(forBookID: bookID) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    fileNodeIdentifier = FileNodeIdentifier.current(for: url)
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                bookmarkStore.addBookmark(
                    bookID: bookID, pageIndex: 0, name: coverName, fileNodeIdentifier: fileNodeIdentifier
                )
                sorted = bookmarkStore.bookmarks(forBookID: bookID).sorted { $0.pageIndex < $1.pageIndex }
                if let cover = sorted.first(where: { $0.pageIndex == 0 }) {
                    excludedIDs.insert(cover.id)
                }
            }
        }

        if let fixedNameKey = lastBookmarkTreatment.fixedNameKey, let last = sorted.last, !excludedIDs.contains(last.id) {
            let name = String(localized: fixedNameKey, locale: preferences.effectiveLocale)
            pendingRenames.append((last, name))
            excludedIDs.insert(last.id)
        }

        var number = startNumber
        for bookmark in sorted where !excludedIDs.contains(bookmark.id) {
            pendingRenames.append((bookmark, "\(prefix)\(number)\(suffix)"))
            number += 1
        }

        bookmarkStore.renameBookmarks(bookID: bookID, renames: pendingRenames)
    }
}
