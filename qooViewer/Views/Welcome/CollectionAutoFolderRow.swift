import AppKit
import SwiftUI

/// 自動登録フォルダを1つ選ぶための行(ユーザー要望 2026-09-09)。
///
/// コレクションを作るときの名前入力シート(CollectionNameSheet)と、コレクションの中の
/// 歯車(CollectionSettingsPopover)の両方が同じ部品を使う ―― 選び方・解除の仕方・
/// アクセス権の求め方が入り口によって違うと、同じ設定に見えなくなるため。
///
/// ■ アクセス権
/// 選んだフォルダは必ずFolderAccessStoreへ足す。サンドボックスでフォルダを列挙する権限は
/// あそこが一手に持っており(FolderAccessStore.accessedURLsByPathのコメント参照)、
/// 走査する側もisPathCoveredにだけ訊く(CollectionAutoFolderScanner)。
///
/// **落とされたファイルの入っていたフォルダには権限が付いてこない。** その場合はパスだけが
/// 入った状態になるので、「アクセスを許可」を出して、既存の導線
/// (AppState.ensureAccess(toFolder:message:)と同じ形のNSOpenPanel)で許可してもらう。
/// 許可されるまで自動登録は静かに何もしない。
///
/// シート/ポップオーバーの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない
/// (CLAUDE.md)。
struct CollectionAutoFolderRow: View {
    @Binding var folder: URL?

    @EnvironmentObject private var folderAccess: FolderAccessStore
    @Environment(\.locale) private var locale
    @State private var isDropTargeted = false

    /// 選ばれているフォルダを列挙できる状態か。選ばれていなければ「問題なし」として扱う。
    private var hasAccess: Bool {
        guard let folder else { return true }
        return folderAccess.isPathCovered(folder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                pathField
                Button("Choose…") { choose() }
                    .fixedSize()
            }

            if let folder {
                HStack(spacing: 8) {
                    if !hasAccess {
                        // 警告は「何が起きていないか」を1行で。ここだけは文章を置く ――
                        // 設定は入っているのに何も起きない状態を、画面から読めるようにする
                        // ためで、飾りの説明ではない。
                        Label("qooViewer needs permission to read this folder.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Grant Access") { grantAccess(to: folder) }
                            .font(.caption)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    Button("Clear") { self.folder = nil }
                        .font(.caption)
                        .fixedSize()
                }
            }
        }
        .fileURLDropTarget(isTargeted: $isDropTargeted) { urls in
            adoptDroppedFolder(urls)
        }
    }

    /// 選ばれているパス。**編集はさせない** ―― 手で打ったパスにはアクセス権が伴わないので、
    /// 打てば動くように見えて動かない欄になる。選ぶのはパネルとドロップだけ。
    private var pathField: some View {
        Text(folder?.path ?? String(localized: "None (no auto-add)", language: locale))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(folder == nil ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: isDropTargeted ? 2 : 1
                    )
            )
            .help(folder?.path ?? "")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Choose", language: locale)
        panel.message = String(
            localized: "Choose a folder. Books added to it are added to this collection automatically.",
            language: locale
        )
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // パネルで選んだ時点で権限は付いているので、そのままFolderAccessStoreへ預ける
        // (自前でstartAccessing…しないこと。FolderAccessStore参照)。
        folderAccess.add(url: chosen)
        folder = chosen
    }

    /// 落とされたものからフォルダを1つだけ採る(ファイルは無視する ―― ここが受けるのは
    /// 「どのフォルダを見張るか」であって、本ではない)。
    private func adoptDroppedFolder(_ urls: [URL]) {
        var isDirectory: ObjCBool = false
        guard let dropped = urls.first(where: {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }) else { return }
        folderAccess.add(url: dropped)
        folder = dropped
    }

    /// 権限の付いていないフォルダ(落とされたファイルの親など)への許可を求める。
    /// AppState.ensureAccess(toFolder:message:)と同じ形・同じ保存先。
    private func grantAccess(to folder: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Grant Access", language: locale)
        panel.message = String(
            localized: "Grant access to this folder so books added to it can be added to the collection automatically.",
            language: locale
        )
        guard panel.runModal() == .OK, let granted = panel.url else { return }
        folderAccess.add(url: granted)
    }
}
