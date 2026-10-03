import AppKit
import SwiftData
import SwiftUI

/// 環境設定の「シークレットフォルダ」画面(2026-10-03。SecretFolderStore)。
///
/// - フォルダの一覧と、足す・外す(右クリックの「シークレットフォルダに追加」と同じ一覧)。
/// - フォルダごとに、**中に残っている保存データの冊数と履歴の冊数**(足す前にこのアプリが覚えていたもの。シークレットフォルダの本は
///   それを読むが書かない ―― シークレットウインドウと同じ)と、それを消すボタン。
/// - 表示中の外観: 本を表示している間はシークレットウインドウの外観になる。環境設定「シークレットウインドウに固有の外観を適用」が
///   OFF なら見た目は変わらないので、その旨と外観の画面への道を置く(利用者の決定 2026-10-03: 設定に従う)。
///
/// 以前の「メタデータの登録の対象外のフォルダ」(メタデータの編集ウインドウのツールバーのシート)を作り直したもの。メタデータに
/// 限らないので、メタデータの編集ウインドウから切り離してここへ置いた(docs/plans/secret-folder-plan.md の決定 11)。
/// 説明文は画面に出さず、ボタンのホバーに置く(環境設定全体の方針。AccessPermissionsSettingsView のコメント)。
struct SecretFolderSettingsView: View {
    @EnvironmentObject private var secretFolders: SecretFolderStore
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var recentFiles: RecentFilesStore
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var collectionStore: CollectionStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    /// フォルダごとの、保存データのある本(数え直すのは画面が出たとき・一覧が変わったとき・消したとき。描くたびには数えない)。
    @State private var savedBookIDsByFolder: [String: [String]] = [:]
    /// 削除を確かめているフォルダ。
    @State private var deleting: String?

    var body: some View {
        SettingsPaneContainer {
            Section {
                if secretFolders.folders.isEmpty {
                    Text("No secret folders yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(secretFolders.folders, id: \.self) { path in
                        row(for: path)
                    }
                }
                Button("Add Folder…") { addFolders() }
                    .help("Books in a secret folder and its subfolders leave no history, saved data or metadata, wherever they are opened from. While such a book is shown, its window looks like a private window.")
            } header: {
                Text("Secret Folders")
            }

            // 開き方(2026-10-03、利用者の要望)。既定 OFF ―― OFF なら、ノーマルの窓がその本を表示している間だけシークレットの見た目になる。
            Section {
                SettingsToggle(
                    "Always Open in a Private Window",
                    isOn: $preferences.secretFolderBooksOpenPrivately,
                    help: "Books in secret folders opened from a normal window open in a private window instead, wherever they are opened from. The normal window keeps what it shows. When off, a normal window looks like a private window only while it shows such a book."
                )
                SettingsPicker(
                    "Open In",
                    selection: $preferences.secretFolderPrivatePlacement,
                    help: "Where to open the book. As a Tab and In Place of the Book use the frontmost private window (In Place of the Book closes the book it shows); without one, a new private window opens."
                )
                .disabled(!preferences.secretFolderBooksOpenPrivately)
            } header: {
                Text("Opening")
            }

            Section {
                LabeledContent("Appearance") {
                    HStack(spacing: 8) {
                        Text(preferences.privateWindowsUseOwnAppearance
                             ? "Private window appearance" : "Same as normal windows")
                            .foregroundStyle(.secondary)
                            // 省略させない(実機で「シークレットウインド…」と切れた。2026-10-03)。
                            .fixedSize()
                        Button("Appearance Settings…") {
                            SettingsNavigator.shared.preparePane(.appearance)
                        }
                    }
                }
                .help("While a book in a secret folder is shown, its window uses the appearance of private windows. Unless private windows have their own appearance (Settings ▸ Appearance), only the private window mark in the title tells them apart.")
            } header: {
                Text("While a Book in a Secret Folder Is Shown")
            }

            SettingsResetSection(
                help: "Restores the opening settings on this page. Your secret folders are not affected."
            ) {
                preferences.resetToDefaults(.secretFolders)
            }
        }
        .onAppear { recount() }
        .onChange(of: secretFolders.folders) { _, _ in recount() }
        // 履歴は数え直さずに描くたびに見る(件数は環境設定の保持件数まで)。
        .alert(
            "Delete the saved data and history of the books in this folder?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { deleteData(in: deleting) }
                deleting = nil
            }
        } message: {
            Text(verbatim: deletionMessage)
        }
    }

    private var deletionMessage: String {
        let found = deleting.map { counts(in: $0) } ?? (saved: 0, history: 0)
        return "The saved data of %1$lld books and %2$lld books in the history are deleted. The books themselves are not deleted. This can't be undone."
            .ui(found.saved, found.history)
    }

    private func row(for path: String) -> some View {
        let found = counts(in: path)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)
                Text(verbatim: path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if found.saved > 0 || found.history > 0 {
                    Text(verbatim: "Saved data remains for %1$lld books, and the history has %2$lld books.".ui(found.saved, found.history))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                deleting = path
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(found.saved == 0 && found.history == 0)
            .help("Delete the Saved Data and History of the Books in This Folder…")
            .accessibilityLabel(Text("Delete the Saved Data and History of the Books in This Folder…"))

            Button {
                secretFolders.remove(path)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Remove from Secret Folders")
            .accessibilityLabel(Text("Remove from Secret Folders"))
        }
        .padding(.vertical, 2)
    }

    // MARK: - 数える・消す

    private func counts(in folder: String) -> (saved: Int, history: Int) {
        (savedBookIDsByFolder[folder]?.count ?? 0, historyEntries(in: folder).count)
    }

    private func historyEntries(in folder: String) -> [RecentFilesStore.Entry] {
        recentFiles.entries.filter { SecretFolderStore.contains(path: $0.path, in: [folder]) }
    }

    private func recount() {
        let folders = secretFolders.folders
        guard !folders.isEmpty else {
            savedBookIDsByFolder = [:]
            return
        }
        let known = KnownBooks.collect(from: KnownBooks.Sources(
            metadataStore: metadataStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
            favoritesStore: favoritesStore, collectionStore: collectionStore, modelContext: modelContext
        ))
        var result: [String: [String]] = [:]
        for folder in folders {
            result[folder] = known.filter { SecretFolderStore.contains(path: $0, in: [folder]) }.sorted()
        }
        savedBookIDsByFolder = result
    }

    /// フォルダの中の本の保存データ(「保存データの削除」ウインドウと同じ一式。BookSavedDataEraser)と履歴を消す。
    /// 開いている本は見送る(ビューアが行を握っている。ExternalMoveSweeper.excludingOpenBooks と同じ考え方)。
    private func deleteData(in folder: String) {
        let openBookIDs = ViewerViewModel.openBookIDs
        let bookIDs = (savedBookIDsByFolder[folder] ?? []).filter { !openBookIDs.contains($0) }
        BookSavedDataEraser(
            favoritesStore: favoritesStore, collectionStore: collectionStore, bookmarkStore: bookmarkStore,
            layoutStore: layoutStore, metadataStore: metadataStore, modelContext: modelContext
        ).deleteAllData(forBookIDs: bookIDs)
        recentFiles.remove(historyEntries(in: folder))
        recount()
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Add", language: locale)
        panel.message = String(
            localized: "Choose folders whose books should leave no history, saved data or metadata.", language: locale
        )
        // 読む権限は要らない(パスで比べるだけ)ので、FolderAccessStore には足さない。
        WindowSheet.begin(panel) { response in
            guard response == .OK else { return }
            secretFolders.add(paths: panel.urls.map { $0.standardizedFileURL.path })
        }
    }
}
