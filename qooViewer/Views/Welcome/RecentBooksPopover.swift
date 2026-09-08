import AppKit
import SwiftUI

/// ウェルカム画面の帯の「履歴から開く」ボタンが出すポップオーバーの中身(改善要望5)。
///
/// 従来のウェルカム画面は「最近開いたファイル」を10件だけ画面に並べていたが、画面が
/// ライブラリ/コレクションのものになったため、履歴はここへ畳んだ。件数を10件に絞る理由も
/// 無くなったので、環境設定の保存件数どおり全件をスクロールで見せる。
///
/// 行の見た目・右クリックの中身は、サイドパネルの「履歴」モード(SidePanelHistorySectionView)と
/// 揃えてある。検索欄だけは付けない ―― 絞り込みたくなるほどの件数を扱うのはサイドパネル側の
/// 役目で、こちらは「さっきの本をもう一度」のための短い導線であるため。
///
/// ポップオーバーの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md参照)。
struct RecentBooksPopover: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recentFiles: RecentFilesStore
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if recentFiles.entries.isEmpty {
                Text("(No Recent Files)")
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(recentFiles.entries) { entry in
                            row(for: entry)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(width: 360, height: rowsHeight)
            }
        }
    }

    /// 件数に応じた高さ(少ないときに無駄な余白を出さない)。1行 = 24pt + 上下の余白。
    private var rowsHeight: CGFloat {
        min(420, max(80, CGFloat(recentFiles.entries.count) * 24 + 12))
    }

    private func row(for entry: RecentFilesStore.Entry) -> some View {
        HStack(spacing: 8) {
            Image(
                systemName: entry.isDirectory
                    ? "folder"
                    : sidePanelFileIconName(fileName: entry.displayURL.lastPathComponent)
            )
            .frame(width: 16)
            .foregroundStyle(.secondary)
            Text(entry.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            FormatBadgeView(bookID: entry.path)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(entry.path)
        // 開く直前に初めてブックマークを解決する(SidePanelHistorySectionView.rowと同じ約束。
        // 行を描くたびに解決すると、一覧全体でディスクを触ることになる)。
        .onTapGesture {
            open(entry)
        }
        .contextMenu {
            BookOpenContextMenuItems(
                onOpen: { open(entry) },
                onOpenIn: { destination in
                    guard let url = recentFiles.resolveForOpening(entry) else { return }
                    dismiss()
                    BookWindowOpener.open(
                        BookOpenRequest(url), to: destination, from: appState,
                        launchCoordinator: launchCoordinator, openWindow: openWindow
                    )
                }
            )
            Divider()
            Button("Show in Finder") {
                FinderReveal.reveal(entry.displayURL, isDirectory: entry.isDirectory)
            }
            Divider()
            Button("Remove from History", role: .destructive) {
                recentFiles.remove(entry)
            }
        }
    }

    private func open(_ entry: RecentFilesStore.Entry) {
        guard let url = recentFiles.resolveForOpening(entry) else { return }
        dismiss()
        appState.open(url: url)
    }
}
