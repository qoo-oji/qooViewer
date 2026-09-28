import AppKit
import SwiftUI

/// ウェルカム画面の帯の「履歴から開く」ボタンが出すポップオーバーの中身(改善要望5)。
///
/// 2026-09-13 にボタンごと撤去し(ファイルブラウザを入れる準備。WelcomeTopBar の型コメント)、2026-09-21 に**環境設定
/// 「ファイルブラウザを有効にする」がOFFの間だけ**戻した(v1.50〜v1.56 の帯の形。ユーザー要望)。2026-09-28 からは、帯の左端の
/// 「直前の本へ戻る」の右に並ぶ履歴の記号(時計に矢印)のボタン(`WelcomeTopBar.historyDropdownButton`)が、ファイルブラウザの ON/OFF に
/// 関わらず常に出す。中身は当時のまま。
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
    /// 削除を取り消せるようにする積み場所(DataUndoStack。2026-09-27、監査 34)。
    @Environment(\.dataUndoStack) private var dataUndo
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
    ///
    /// **下限は置かない**(2026-09-28、利用者の指摘: 履歴が 1〜2 件のとき下に広い余白が残った)。以前の `max(80, …)` は
    /// 実測が届く前の 0 を避けるためだったが、実測が届いた後も 2 件(約 60pt)を 80pt に引き伸ばし、中身は上寄せなので
    /// 差のぶんが下の余白になっていた。実測が届く前だけ仮の高さにする。
    ///
    /// **確かめたのは macOS 27 だけ**(利用者の注意 2026-09-28)。ポップオーバーが中身の高さに合わせる振る舞いは OS の版で
    /// 事情が違いうるので、別の版で余白やスクロールバーの報告があれば、ここ(と `onGeometryChange` の実測)を疑う。
    private var rowsHeight: CGFloat {
        contentHeight > 0 ? min(560, contentHeight) : 80
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
                DataUndoStack.removeHistory([entry], in: recentFiles, recordingOn: dataUndo)
            }
        }
    }

    private func open(_ entry: RecentFilesStore.Entry) {
        guard let url = recentFiles.resolveForOpening(entry) else { return }
        dismiss()
        appState.open(url: url)
    }
}
