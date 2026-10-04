import SwiftUI
import AppKit

/// 環境設定ウインドウの「フォルダのアクセス権」画面。
///
/// サンドボックス下では、パネルやドラッグ&ドロップで直接選んだファイル/フォルダにしか
/// アクセスできない。ここで任意のフォルダ(ルートフォルダ・ホームフォルダ・外部ボリュームなど)を
/// あらかじめ許可しておくことで、個別のアーカイブファイルを直接開いた場合でも、
/// そのフォルダ配下では「同じフォルダのファイルを開く」「前の本/次の本」が正しく機能するようになる。
/// 許可はセキュリティスコープ付きブックマークとして保存されるため、次回起動後も有効。
///
/// 以前はこの「なぜ許可が必要なのか」という説明が画面上のどこにもなく、
/// ソースコードのコメントとNSOpenPanelのmessageにしか書かれていなかった。
/// パネルを開く前に読めなければ意味がないので、Sectionのfooterに出している。
struct AccessPermissionsSettingsView: View {
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsPaneContainer {
            Section {
                // 並べるのは保存してある許可のすべて(2026-10-04 の監査 ST-3)。以前は解決できて開いたフォルダ(`entries`)だけで、
                // 外したボリューム・確認中・解決できなかった許可は見えず、取り消せなかった。開いていない許可は状態を添える。
                // 描くときにファイルには触らない(名前は作ったときに求めてある。ST-16)。
                if folderAccess.grants.isEmpty {
                    Text("No folders have been granted access yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folderAccess.grants) { grant in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: grant.displayName)
                                    .foregroundStyle(grant.status == .active ? .primary : .secondary)
                                Text(verbatim: grant.path)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let status = statusText(grant.status) {
                                    Text(status)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                folderAccess.remove(grant)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Revoke Access to This Folder")
                            .accessibilityLabel(Text("Revoke Access to This Folder"))
                        }
                        .padding(.vertical, 2)
                    }
                }

                Button("Add Folder…") {
                    addFolder()
                }
                // 「なぜ許可が必要なのか」はボタンのホバーで出す。
                // 以前はSectionのfooterに常時表示していたが、環境設定全体で説明文を
                // 画面に出さない方針になったため移した(ユーザーの指示)。
                // 消さずに残したのは、パネルを開く前にこれを読めないと意味がないため
                // (NSOpenPanelのmessageは開いた後にしか見えない)。
                .help("qooViewer can only reach files you opened yourself. Granting a folder lets “Previous Book” and “Next Book” find the other files next to a book you opened directly. Access is remembered after you quit.")
            } header: {
                Text("Granted Folders")
            }
        }
    }

    /// 開いていない許可の状態(開いている許可は何も添えない)。
    private func statusText(_ status: FolderAccessStore.Grant.Status) -> LocalizedStringKey? {
        switch status {
        case .active: nil
        case .notConnected: "The volume isn’t connected. Access returns when you connect it."
        case .resolving: "Checking…"
        case .unresolvable: "The folder can’t be found."
        }
    }

    private func addFolder() {
        let locale = preferences.effectiveLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Grant Access", language: locale)
        panel.message = String(
            localized: "Select a folder to grant qooViewer access to (e.g. your home folder, an external volume, or a drive's root folder).",
            language: locale
        )
        WindowSheet.begin(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            // ここでstartAccessingSecurityScopedResource()を呼ぶ必要は無い(対になるstopが無く、
            // 呼ぶたびにカーネルリソースを漏らしていた)。アクセスの開閉はFolderAccessStoreが
            // 一手に管理する(FolderAccessStore.accessedURLsByPathのコメント参照)。
            folderAccess.add(url: url)
        }
    }
}
