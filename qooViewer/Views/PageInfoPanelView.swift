import SwiftUI

/// コンテキストメニュー「情報を見る」(ユーザー要望)の表示先。以前はサブメニュー内に
/// 「ラベル: 値」の1行ずつをButtonとして並べていたが、ラベルの文字数がまちまちで値の
/// 開始位置が揃わず読みづらいという指摘(ユーザー報告。Finderの「情報を見る」のように
/// 値の先頭を揃えてほしい)を受け、このパネルに置き換えた。SwiftUIの.popoverは一度試したが、
/// ビューアウインドウの外にはみ出す吹き出しとして表示され意図と異なる(ユーザー報告)ため、
/// ページ一覧(ThumbnailGridView)と同じくmainZStack内のオーバーレイパネルとして
/// ViewerView側から表示する(ViewerView.mainZStack参照)。このView自身はレイアウトの
/// 中身だけを担当し、背景・シャドウ・外側クリックでの閉じ方はViewerView側の責務。
///
/// さらにユーザー要望により、Finderの「情報を見る」と同じく「一般情報」「詳細情報」の
/// 2グループへ整理し、見開き表示中にどちらのページの情報かを一目で識別できるよう末尾に
/// サムネイルを添えている。サムネイルの取得(非同期)のためにviewModel/pageIndexを持つ
/// (ThumbnailGridView.ThumbnailCellと同じ、セル自身の@State + .task(id:)によるパターン)。
struct PageInfoPanelView: View {
    let viewModel: ViewerViewModel
    let pageIndex: Int
    let info: PageImageInfo

    @State private var thumbnail: CGImage?

    private static let dateFormatStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("General Information")
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                row(label: "Kind") {
                    // PDFのページ自体は独立した画像ファイルではないため素の"PDF"のまま、
                    // それ以外の画像形式はFinderの「種類」表示にならい「◯◯画像」とする。
                    if info.formatDescription == "PDF" {
                        Text(info.formatDescription)
                    } else {
                        Text("\(info.formatDescription) Image")
                    }
                }
                if let fileSizeBytes = info.fileSizeBytes {
                    row(label: "Size") {
                        Text(ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file))
                    }
                }
                if let location = info.location {
                    row(label: "Location") {
                        Text(location)
                    }
                }
                row(label: "Name") {
                    Text(info.fileName)
                }
                if let createdDate = info.createdDate {
                    row(label: "Created") {
                        Text(createdDate, format: Self.dateFormatStyle)
                    }
                }
                if let modifiedDate = info.modifiedDate {
                    row(label: "Modified") {
                        Text(modifiedDate, format: Self.dateFormatStyle)
                    }
                }
            }

            Divider()

            sectionHeader("More Information")
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                row(label: "Resolution") {
                    Text("\(info.pixelWidth) × \(info.pixelHeight) px")
                }
                if let colorModel = info.colorModel {
                    row(label: "Color Space") {
                        Text(colorModel)
                    }
                }
                if let colorProfileName = info.colorProfileName {
                    row(label: "Color Profile") {
                        Text(colorProfileName)
                    }
                }
                if let hasAlphaChannel = info.hasAlphaChannel {
                    row(label: "Alpha Channel") {
                        if hasAlphaChannel {
                            Text("Yes")
                        } else {
                            Text("No")
                        }
                    }
                }
            }

            Divider()

            // 見開き表示中、この情報がどちらのページ(左/右)のものかを一目で識別できるように
            // (ユーザー要望)、対象ページのサムネイルを末尾に添える。
            HStack {
                Spacer(minLength: 0)
                thumbnailView
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .textSelection(.enabled)
        .task(id: pageIndex) {
            thumbnail = await viewModel.loadThumbnail(at: pageIndex)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.15))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 120, height: 120)
    }

    private func sectionHeader(_ titleKey: LocalizedStringKey) -> some View {
        Text(titleKey).font(.headline).panelOutlinedContent()
    }

    /// ラベル列(右揃え)・値列(左揃え)の1行。Finderの「情報を見る」と同じく、値の先頭が
    /// 行ごとにばらつかず揃うよう、Gridの列揃え(gridColumnAlignment)をラベル・値それぞれの
    /// 列に指定する。「一般情報」「詳細情報」は別々のGridインスタンスのため、列幅もそれぞれの
    /// グループ内で独立して揃う(Finderの実際の挙動と同じ)。
    @ViewBuilder
    private func row<Value: View>(label: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            // 文字だけに輪郭を掛ける(環境設定「外観」の「その他のパネル」の設定)。
            // 同じパネルにあるサムネイル(thumbnailView)は画像なので対象外
            // ―― 掛けると画像の縁に色が回ってしまう。
            Text(label)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
                .gridColumnAlignment(.trailing)
            value()
                .multilineTextAlignment(.leading)
                .panelOutlinedContent()
                .gridColumnAlignment(.leading)
        }
    }
}

/// 「情報を見る」のパネルの中身。相手は**開いた時点のページの鍵**で固定する(2026-10-04 の監査 V-11)。以前は表示中の見開きと
/// 右クリックの位置(`ViewerView.infoContextPageIndex`)から描くたびに引き直していたので、パネルを出したままページが送れると
/// (キーのモニタはパネルを見ていなかった)、黙って別のページの情報に変わった。今はパネルの間はページ送りも止める
/// (`ViewerView.makeScrollMonitor`)。情報がまだ無ければ取得を待って描き直す ―― キャッシュは @Published でないので、
/// 以前は「読み込み中…」のまま残った。
struct PageInfoPanelContent: View {
    let viewModel: ViewerViewModel
    let pageKey: String

    /// 取得を待って受け取った情報(キャッシュにあれば body がその場で読むので、待つのは無いときだけ)。
    @State private var fetched: PageImageInfo?
    /// 取得を待ったが情報が無かった(読めない・そのページが並びから消えた)。
    @State private var isUnavailable = false

    var body: some View {
        Group {
            // そのページが並びから消えた(別の窓で除外した等)なら、情報があっても出さない ―― 番号を引けない。
            if let index = viewModel.pageIndex(forPageKey: pageKey),
               let info = fetched ?? viewModel.pageImageInfo(atIndex: index) {
                PageInfoPanelView(viewModel: viewModel, pageIndex: index, info: info)
            } else if isUnavailable || viewModel.pageIndex(forPageKey: pageKey) == nil {
                Text("Information Unavailable")
                    .panelOutlinedContent()
                    .padding(16)
            } else {
                Text("Loading…")
                    .panelOutlinedContent()
                    .padding(16)
            }
        }
        .task(id: pageKey) {
            fetched = nil
            isUnavailable = false
            let info = await viewModel.pageImageInfo(forPageKey: pageKey)
            guard !Task.isCancelled else { return }
            fetched = info
            isUnavailable = info == nil
        }
    }
}
