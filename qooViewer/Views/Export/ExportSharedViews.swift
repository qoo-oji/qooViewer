import SwiftUI
import AppKit

/// EPUB / PDF / CBZ の各出力ウインドウが共有する部品。
///
/// 元々はEpubExportWindow内のprivateな型としてだけ存在し、PDF出力ウインドウを足す際に
/// 「PDF」を頭に付けた同じ実装がもう1組コピーされていた。CBZ出力ウインドウで3組目に
/// なるため、形式に依存しないものをここへ集約した(ViewModel側をBookExportViewModelへ
/// 集約したのと同じ理由)。

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
        idealWidth(
            for: texts.map { (text: $0, extraChrome: extraChrome) },
            minWidth: minWidth, maxWidth: maxWidth
        )
    }

    /// 行ごとに必要な余白が違う場合用。行末に付く形式バッジ(FormatBadgeView)のように、
    /// 添え物の幅が項目ごとに変わるときは、一律の値で見積もると「7Z」に合わせて足りなく
    /// なるか「フォルダ」に合わせて広すぎるかのどちらかになるため、項目ごとに渡す。
    ///
    /// - Parameter items: (テキスト, その行だけに必要な追加の余白)の一覧。
    static func idealWidth(
        for items: [(text: String, extraChrome: CGFloat)], minWidth: CGFloat, maxWidth: CGFloat
    ) -> CGFloat {
        guard !items.isEmpty else { return minWidth }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = items.map { item -> CGFloat in
            (item.text as NSString).size(withAttributes: [.font: font]).width + item.extraChrome
        }.max() ?? 0
        return min(maxWidth, max(minWidth, (widest + baseChrome).rounded(.up)))
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

// MARK: - 形式ごとの書き出しオプション

/// EPUB / PDF / CBZ それぞれの書き出しオプション(チェックボックス群)。
///
/// 元は各書き出しウインドウの中のprivateな型として3つ別々に置いてあった。ビューアの
/// 右クリックから1冊だけ書き出すシート(`OpenBookExportSheet`)でも**同じ項目を同じ並びで**
/// 出す必要が生まれたため、ここへ集約した(3か所で内容を揃える、というこのリポジトリの
/// 既定の作法。`PageContextMenuItems`のコメント参照)。
///
/// 受け取るのは基底クラスの`BookExportViewModel`。CBZ固有の項目だけは、その場で
/// `CbzExportViewModel`へ降ろして観測し直す(同じインスタンスなので、どちらで観測しても
/// 変更通知は届く)。
struct BookExportFormatOptions: View {
    let format: BookExportFormat
    @ObservedObject var viewModel: BookExportViewModel

    var body: some View {
        // どの項目を出すかはBookExportFormatが決める(環境設定「レイアウト」の既定値の行と
        // 同じ判断を2か所に書かないため。BookExportFormat.supportsImageRenumbering参照)。
        if format == .cbz {
            Toggle("Renumber Image Files Sequentially", isOn: $viewModel.renumberImagesSequentially)
                // CBZには読み順を表すメタデータが無く、ファイル名の並び順だけが順序を決めるため、
                // OFFにするとページの並べ替え・除外が他アプリで再現されないことがある
                // (この補足はCBZにしか当てはまらないので、EPUBの同じ項目には付けない)。
                .help("CBZ files have no page-order metadata, so readers sort by file name. Turn this off only if you want to keep the original file names.")
        } else if format.supportsImageRenumbering {
            Toggle("Renumber Image Files Sequentially", isOn: $viewModel.renumberImagesSequentially)
        }
        Toggle("Include Excluded Pages", isOn: $viewModel.includeExcludedPages)
        if format.supportsComicInfoVolumeElement, let cbz = viewModel as? CbzExportViewModel {
            CbzVolumeElementToggle(viewModel: cbz)
        }
    }
}

/// CBZ固有の1項目。`writesVolumeElement`は`CbzExportViewModel`にしかないため、双方向の
/// Bindingを作るにはその型として観測している必要がある。
private struct CbzVolumeElementToggle: View {
    @ObservedObject var viewModel: CbzExportViewModel

    var body: some View {
        Toggle("Also Write the Volume Number to ComicInfo\u{2019}s Volume Element", isOn: $viewModel.writesVolumeElement)
            .help("Kavita reads Volume as the volume number, but Komga appends it to the series name, which can split a series into one series per volume.")
    }
}
