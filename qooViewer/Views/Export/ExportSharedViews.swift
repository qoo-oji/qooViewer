import SwiftUI
import AppKit

/// EPUB / PDF / CBZ の各出力ウインドウが共有する部品。
///
/// 元々はEpubExportWindow内のprivateな型としてだけ存在し、PDF出力ウインドウを足す際に
/// 「PDF」を頭に付けた同じ実装がもう1組コピーされていた。CBZ出力ウインドウで3組目に
/// なるため、形式に依存しないものをここへ集約した(ViewModel側をBookExportViewModelへ
/// 集約したのと同じ理由)。

/// 列の区切り線(ユーザー要望: 出力ウインドウにも区切り線を追加してほしい)。BookmarkListView.
/// ColumnDividerLineと同じ考え方で、素のRectangleをHStackへ直接置く(Divider()は既定で水平線に
/// なるため使えない)。チェックボックス列の直後だけはユーザーがドラッグして広げる意味が無い
/// ためこのまま(幅固定)で使い、ファイル名・タイトル・著者名・カバーの各列の直後は
/// ドラッグ可能なExportResizableColumnDividerを使う(ユーザー要望: タイトル行の区切り線を
/// ドラッグして列の幅を調整できるようにしてほしい)。ヘッダー行と各行の双方でこの同じ1pt幅の
/// Rectangleだけを使う限り、ZStackの最大サイズ問題(BookmarkListViewで経験した不具合)は
/// 起こりえない。
struct ExportColumnDividerLine: View {
    static let height: CGFloat = 18
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: Self.height)
    }
}

/// 区切り線をドラッグして、直前の列の幅(width、双方向Binding)を変更するためのハンドル
/// (ユーザー要望: タイトル行の区切り線をドラッグして列の幅を調整できるようにしてほしい)。
/// BookmarkListView.ResizableColumnDividerと全く同じ考え方・同じ実装(見た目は
/// ExportColumnDividerLineと完全に同じ1pt線のままレイアウトさせ、掴みやすくするための8pt幅の
/// 判定領域は.overlayとして重ねることで、見た目の線とレイアウト上の幅を一致させる。ZStackで
/// 重ねると実際より広い幅を親のHStackへ報告してしまい列がずれるため、あえてoverlayにしている)。
/// ヘッダー行だけで使い、各行側はドラッグ操作を持たない見た目だけのExportColumnDividerLine()の
/// ままにする(カバー列のpopover等、既にジェスチャーが載っているため、列幅の変更操作は
/// Finderのリスト表示などと同じくヘッダー行からだけ行える形にする)。
struct ExportResizableColumnDivider: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat = 90
    var maxWidth: CGFloat = 420

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        ExportColumnDividerLine()
            .overlay(
                Color.clear
                    .frame(width: 8, height: ExportColumnDividerLine.height)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if widthAtDragStart == nil {
                                    widthAtDragStart = width
                                }
                                let proposed = (widthAtDragStart ?? width) + value.translation.width
                                width = min(max(proposed, minWidth), maxWidth)
                            }
                            .onEnded { _ in
                                widthAtDragStart = nil
                            }
                    )
            )
    }
}

/// 出力ウインドウの各列(ファイル名・タイトル・著者名)の幅を、ウインドウを開いた時点の
/// 一覧の内容に応じて自動調整するための計算ロジック(ユーザー要望: 各列に表示する文字列の
/// 長さに応じて、ウインドウ幅と各列の幅を自動調整してほしい)。SidebarWidthEstimatorと
/// 同じ考え方・同じ実装パターン(NSStringのサイズ計測を使う)。
enum ExportColumnWidthEstimator {
    /// テキスト自体の幅以外に、列の左右パディングなどでおおよそ必要になる余白。
    private static let baseChrome: CGFloat = 20

    /// - Parameters:
    ///   - texts: この列に実際に表示されるテキストの一覧。
    ///   - extraChrome: baseChromeに加えて確保しておきたい余白(例: フォーマットバッジの分)。
    static func idealWidth(
        for texts: [String], minWidth: CGFloat, maxWidth: CGFloat, extraChrome: CGFloat = 0
    ) -> CGFloat {
        guard !texts.isEmpty else { return minWidth }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = texts.map { text -> CGFloat in
            (text as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return min(maxWidth, max(minWidth, (widest + baseChrome + extraChrome).rounded(.up)))
    }
}

/// 書き出し中の進捗シート。
///
/// 同名ファイルの確認は、書き出し中(このシートの表示中)にだけ起こりうる操作のため、あえて
/// この進捗シート自身にalertを付ける(親ビュー側に付けると、進捗シートの上に正しく重なって
/// 表示されない可能性があるため)。
struct ExportProgressSheet: View {
    @ObservedObject var viewModel: BookExportViewModel
    /// 「EPUBファイルをエクスポート中…」など、形式ごとの見出し。
    let progressTitle: LocalizedStringKey
    /// 「“<名前>.epub” はすでに出力先フォルダにあります。」の本文。拡張子が形式ごとに
    /// 異なるため、文言そのものは呼び出し側が組み立てる。
    let overwriteMessage: (String) -> String

    var body: some View {
        VStack(spacing: 16) {
            Text(progressTitle)
                .font(.headline)
            ProgressView(
                value: Double(viewModel.completedCount), total: Double(max(viewModel.totalCount, 1))
            )
            .frame(width: 320)
            Text(viewModel.currentBookDisplayName ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 320)
            Text(
                String(format: String(localized: "%d of %d"), viewModel.completedCount, viewModel.totalCount)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Cancel") {
                viewModel.cancel()
            }
        }
        .padding(32)
        .frame(minWidth: 380, minHeight: 220)
        .alert(
            "Overwrite Existing File?",
            isPresented: Binding(
                get: { viewModel.pendingOverwriteBookDisplayName != nil },
                set: { _ in }
            ),
            presenting: viewModel.pendingOverwriteBookDisplayName
        ) { _ in
            Button("Skip", role: .cancel) {
                viewModel.resolveOverwrite(.skip, applyToRemaining: false)
            }
            Button("Skip All Remaining") {
                viewModel.resolveOverwrite(.skip, applyToRemaining: true)
            }
            Button("Overwrite") {
                viewModel.resolveOverwrite(.overwrite, applyToRemaining: false)
            }
            Button("Overwrite All Remaining") {
                viewModel.resolveOverwrite(.overwrite, applyToRemaining: true)
            }
        } message: { displayName in
            Text(overwriteMessage(displayName))
        }
    }
}

/// 書き出し完了後の結果シート。成功件数と、失敗した本の一覧(理由つき)を表示する。
/// 形式による差が無いため、そのまま3つのウインドウで共有する。
struct ExportResultSheet: View {
    @ObservedObject var viewModel: BookExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Complete")
                .font(.headline)
            Text(
                String(
                    format: String(localized: "%d of %d book(s) exported successfully."),
                    viewModel.successCount, viewModel.totalCount
                )
            )
            if !viewModel.failures.isEmpty {
                Text("Failed:")
                    .font(.subheadline)
                    .padding(.top, 4)
                List(viewModel.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.displayName)
                            .font(.callout)
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120)
            }
            HStack {
                Spacer()
                Button("OK") {
                    viewModel.acknowledgeFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: viewModel.failures.isEmpty ? 160 : 320)
    }
}
