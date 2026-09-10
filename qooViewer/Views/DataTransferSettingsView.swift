import SwiftUI

/// 環境設定ウインドウの「読み込みと書き出し」画面(ユーザー判断 2026-09-11)。
///
/// ■ なぜファイルメニューから移したのか
/// ライブラリデータ(保存データ)の読み込み・書き出しは、元はファイルメニューの
/// 「読み込み…」「書き出し…」だった。そこへコレクション表紙の読み込み・書き出しを足したところで、
/// **どちらも実際の利用頻度がごく低い**という指摘を受けた(別のMacへ移す・控えを取る、
/// といった場面でしか使わない)。ファイルメニューは「本を開く/本を書き出す」に絞り、
/// 4つまとめてこの画面へ集めた。
///
/// 開けるのはこの画面だけ ―― 「本ごとの保存データの削除」「履歴の削除」が環境設定の
/// 「リセット」からしか開けないのと同じ扱い(ResetDataSettingsViewの型コメント参照)。
/// どれもウインドウを開くだけで、この画面では何も起きない。
///
/// ■ 2つのセクションに分ける理由
/// 出来上がるものが違う。上はJSONファイル1枚(このアプリだけが読み戻せる)、下は画像の入ったzip。
/// 上の書き出しには**コレクション表紙が含まれない**(画像はJSONに入れない)ので、その断りを
/// footerに書いて、下のセクションへ目を移せるようにしてある。
struct DataTransferSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    /// ボタン幅の実測に使う表示言語(ResetDataSettingsViewと同じ理由・同じ書き方)。
    @Environment(\.locale) private var locale

    var body: some View {
        SettingsPaneContainer {
            // ボタンは4つとも幅を揃える(ResetDataSettingsViewの2つと同じ考え方 ――
            // 似た操作が縦に並んでいるのに、文言の長さのぶんだけ幅が違うと不揃いに見える)。
            Section {
                Button {
                    openWindow(id: "libraryImport")
                } label: {
                    Label("Import Saved Data…", systemImage: "square.and.arrow.down")
                        .frame(width: buttonWidth, alignment: .leading)
                }

                Button {
                    openWindow(id: "libraryExport")
                } label: {
                    Label("Export Saved Data…", systemImage: "square.and.arrow.up")
                        .frame(width: buttonWidth, alignment: .leading)
                }
            } header: {
                Text("Saved Data")
            } footer: {
                Text("Favorites, collections, bookmarks, page layout settings and metadata, as a single JSON file that only qooViewer can read back in. Collection covers are not included — use the section below for those.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button {
                    openWindow(id: "shelfCoverImport")
                } label: {
                    Label("Import Collection Covers…", systemImage: "square.and.arrow.down")
                        .frame(width: buttonWidth, alignment: .leading)
                }

                Button {
                    openWindow(id: "shelfCoverExport")
                } label: {
                    Label("Export Collection Covers…", systemImage: "square.and.arrow.up")
                        .frame(width: buttonWidth, alignment: .leading)
                }
            } header: {
                Text("Collection Covers")
            } footer: {
                Text("One image per book, as a zip file named after each book. Only books whose collection cover is an image you chose are included. Reading one back matches each image to a book by its file name, and shows you the result before importing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 4つのボタンの共通幅。いちばん長い文言が省略されずに収まる幅を実測して全部に与える。
    private var buttonWidth: CGFloat {
        MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Import Saved Data…", language: locale),
                String(localized: "Export Saved Data…", language: locale),
                String(localized: "Import Collection Covers…", language: locale),
                String(localized: "Export Collection Covers…", language: locale),
            ],
            minWidth: 0,
            chrome: Self.labelIconChrome
        )
    }

    /// Labelの先頭に付くSFシンボルと、その右の間隔ぶんの幅
    /// (ResetDataSettingsView.labelIconChromeと同じ値・同じ決め方)。
    private static let labelIconChrome: CGFloat = 40
}
