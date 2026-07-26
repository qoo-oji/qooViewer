import SwiftUI
import AppKit

/// 環境設定ウインドウの「アクセス権」タブ。
///
/// サンドボックス下では、パネルやドラッグ&ドロップで直接選んだファイル/フォルダにしか
/// アクセスできない。ここで任意のフォルダ(ルートフォルダ・ホームフォルダ・外部ボリュームなど)を
/// あらかじめ許可しておくことで、個別のアーカイブファイルを直接開いた場合でも、
/// そのフォルダ配下では「同じフォルダのファイルを開く」「前の本/次の本」が正しく機能するようになる。
/// 許可はセキュリティスコープ付きブックマークとして保存されるため、次回起動後も有効。
struct AccessPermissionsSettingsView: View {
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Granted Folders") {
                if folderAccess.entries.isEmpty {
                    Text("No folders have been granted access yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folderAccess.entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                Text(entry.url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                folderAccess.remove(entry)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button("Add Folder…") {
                    addFolder()
                }
            }

            Section {
                Text("In a sandboxed app, qooViewer can only access files and folders you've explicitly selected. Granting access to a folder here — such as your home folder, an external volume, or a drive's root — lets features like same-folder browsing and previous/next book navigation work across that whole folder, even when you open a single archive file directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addFolder() {
        let locale = preferences.effectiveLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Grant Access", locale: locale)
        panel.message = String(
            localized: "Select a folder to grant qooViewer access to (e.g. your home folder, an external volume, or a drive's root folder).",
            locale: locale
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        folderAccess.add(url: url)
    }
}
