import AppKit
import SwiftUI

/// ウェルカム画面の帯の「履歴から開く」ボタンが出すポップオーバーの中身(改善要望5)。
///
/// 従来のウェルカム画面は「最近開いたファイル」を10件だけ画面に並べていたが、画面が
/// ライブラリ/コレクションのものになったため、履歴はここへ畳んだ。件数を10件に絞る理由も
/// 無くなったので、環境設定の保存件数どおり全件を見せる(入り切らないぶんだけスクロールする)。
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

    /// ポップオーバーの幅。空のときも同じ幅にする ―― 中身の文字幅なりに細くなると、
    /// 履歴が1件入っただけで倍近く広がり、同じボタンから出るものに見えない。
    private static let width: CGFloat = 360

    /// 実測した中身の高さ(rowsHeightのコメント参照)。
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if recentFiles.entries.isEmpty {
                Text("(No Recent Files)")
                    .foregroundStyle(.secondary)
                    .padding(24)
                    .frame(width: Self.width)
            } else {
                ScrollView {
                    // **LazyVStackではなくVStack。** 高さを実測して面の高さに使う(rowsHeight)ので、
                    // 画面外の行まで含めた本当の高さがその場で要る。Lazyだと見えているぶんしか
                    // 作られないため、実測値が最初の数行ぶんで止まる。履歴は環境設定の保存件数
                    // (既定20・上限100)までの短い一覧なので、全部作っても差し支えない。
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(recentFiles.entries) { entry in
                            row(for: entry)
                        }
                    }
                    .padding(.vertical, 6)
                    // 中身の高さを実測する。スクロール方向には枠から独立しているので、
                    // これを面の高さへ返しても堂々巡りにはならない。
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        contentHeight = height
                    }
                }
                .frame(width: Self.width, height: rowsHeight)
            }
        }
    }

    /// 面の高さ。
    ///
    /// **行の高さを掛け算で見積もるのはやめた**(ユーザー指摘 2026-09-09)。1行24ptと見て
    /// いたが実際はもう少し高く、7件でも中身が枠を超えてスクロールバーが出ていた ―― 行の
    /// 中身(文字の行送り、形式バッジ)が変われば正しい値も変わるので、掛け算では追い切れない。
    /// 実測した高さをそのまま使い、上限だけ決める。
    ///
    /// 上限は、履歴が多い人でも十分見えて、かつ小さめのウインドウでもはみ出さない程度
    /// (macOSは収まらない面を自分で縮める・向きを変えるが、そこに任せきりにはしない)。
    private var rowsHeight: CGFloat {
        min(560, max(80, contentHeight))
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
