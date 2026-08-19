import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 設計コンセプト6.2節: エクスポート用の独立ウインドウ。お気に入り・ブックマーク・ページ
/// レイアウト設定のうち書き出す種類をチェックボックスで選び、NSSavePanelで保存先を選ぶ。
/// 「ブックマーク・レイアウトの編集」ウインドウと同じく、本を今開いているかどうかに関わらず
/// メニューバーの「ファイル」メニューからいつでも開ける独立ウインドウとして実装している。
struct LibraryExportWindow: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var metadataFormatStore: MetadataFormatStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var includeFavorites = true
    @State private var includeBookmarks = true
    @State private var includeLayouts = true
    @State private var includeMetadata = true
    /// フォーマット定義(アプリ全体の設定)は、本ごとのデータとは性質が違ううえ、取り込み側の
    /// 設定を丸ごと置き換えるものになるため、既定ではチェックを外しておく。
    @State private var includeMetadataFormats = false
    @State private var isExporting = false
    @State private var resultMessage: String?
    @State private var didSucceed = false
    /// ユーザー要望: ファイルが見つからなかった本のパスを、カテゴリ(お気に入り/ブックマーク/
    /// レイアウト)をまたいで重複なく1つのリストにまとめてウインドウ下部に表示したい。
    /// 以前は「N冊はファイルが見つからなかったためスキップしました」という件数だけの文言
    /// だった(LibraryImportExportService.ExportResult.allSkippedFilePaths参照)。
    @State private var skippedFilePaths: [String] = []

    private var hasSelection: Bool {
        includeFavorites || includeBookmarks || includeLayouts || includeMetadata || includeMetadataFormats
    }

    // バグ修正(ユーザー報告): 以前はボタン行もFormの1Sectionとして中に含めていたが、
    // .formStyle(.grouped)のFormはList相当のスクロール領域として自身の親(このウインドウ)の
    // 高さいっぱいに広がろうとする性質があり、内容が少ないとSection同士の間に大きな空白が
    // 生まれ、結果としてウインドウの上下左右に無駄な余白ができてしまっていた。
    // EPUB出力ウインドウ(EpubExportWindow.bottomSection)と同じ構成に揃え、ボタン行はForm
    // (スクロール領域)の外側、VStack(spacing: 0)の中でDivider()の下に独立して置くことで、
    // ウインドウの高さがトグル部分とボタン行の実際の高さの合計に自然に収まるようにした
    // (ボタンを背景色の付いた箱で囲むのではなく、区切り線+右下配置という見た目もこれで揃う)。
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Favorites", isOn: $includeFavorites)
                    Toggle("Bookmarks", isOn: $includeBookmarks)
                    Toggle("Page Layout Settings", isOn: $includeLayouts)
                    Toggle("Metadata", isOn: $includeMetadata)
                    Toggle("Metadata Formats", isOn: $includeMetadataFormats)
                } footer: {
                    Text("This creates a single JSON file that only qooViewer can read back in. ComicInfo.xml is not supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let resultMessage {
                    Section {
                        Label {
                            Text(resultMessage)
                        } icon: {
                            Image(systemName: didSucceed ? "checkmark.circle" : "exclamationmark.triangle")
                        }
                        .foregroundStyle(didSucceed ? Color.primary : Color.orange)
                        .font(.caption)
                    }
                }

                // ユーザー要望: 「N冊はファイルが見つからなかったためスキップしました」という
                // 件数だけの文言を廃止し、代わりに見つからなかったファイルの実際のパスを
                // 一覧表示する(カテゴリをまたいで重複があれば1回だけ表示)。
                if !skippedFilePaths.isEmpty {
                    Section {
                        Text("The following files were skipped because they couldn't be found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(skippedFilePaths, id: \.self) { path in
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            // ユーザー報告: 素のForm(既定スタイル)に変更したところ、トグルがスイッチ状の
            // .formStyle(.grouped)の見た目(チェックボックス状の既定スタイルではなく)から
            // 変わってしまった、との指摘を受け、.formStyle(.grouped)に戻した。
            // 中身とボタン行の間の大きな空白の原因は、.formStyle(.grouped)がList相当の実装で、
            // 既定では親(このVStack)が与える高さをそのまま引き受けようとするため
            // (中身が少なくても、与えられた高さ分だけ余白を残して伸びる)。
            // .fixedSize(horizontal: false, vertical: true)を付けて「縦方向は中身の実サイズを
            // 使う」よう明示することで、見た目(グループ化されたトグル)を変えずにこの余白だけを
            // 無くす。
            //
            // ユーザー報告(左右の余白): .formStyle(.grouped)は内容を最大600ptまでの幅で
            // 中央寄せする仕様がある。ウインドウ自体の幅が.frame(minWidth:)で指定した最小幅
            // より広く開かれると、その余った幅がそのまま左右の余白として見えてしまう
            // (パディングの問題ではなく、ウインドウの既定幅がFormの実際に必要な幅より広い、
            // という指摘の通り)。.windowResizability(.contentSize)はコンテンツの「idealSize」を
            // 見てウインドウの既定サイズを決めるため、idealWidth/maxWidthを明示してForm自身が
            // 「本当はこの程度の幅で十分」と申告するようにし、ウインドウが不必要に広く開かない
            // ようにした。
            //
            // ユーザー報告(不要なスクロールバー): .formStyle(.grouped)はList相当の実装のため、
            // スクロールの必要が無い(中身が全部収まっている)場合でもスクロールバーの表示領域を
            // 予約してしまうことがある。.scrollIndicators(.hidden)で明示的に非表示にする
            // (.fixedSize(vertical: true)により実際にスクロールが発生することは無いため、
            // 隠しても操作性への影響は無い)。
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.hidden)

            Divider()
            bottomSection
        }
        .frame(minWidth: 440, idealWidth: 440, maxWidth: 520)
    }

    /// ユーザー要望: 「ライブラリデータをエクスポート」ボタンをウインドウ右下へ移動し、
    /// その左に「キャンセル」ボタンを追加してほしい。EPUB出力ウインドウの
    /// 「EPUB出力を開始」ボタンと同じアクセントカラー(既定ボタン=.keyboardShortcut(
    /// .defaultAction))になるよう揃える。
    @ViewBuilder
    private var bottomSection: some View {
        HStack {
            Spacer()
            if isExporting {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Export Library Data") {
                exportButtonTapped()
            }
            .disabled(!hasSelection || isExporting)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func exportButtonTapped() {
        let locale = preferences.effectiveLocale
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "qooViewer Library.json", locale: locale)
        panel.message = String(localized: "Choose where to save the exported JSON file.", locale: locale)
        if let lastFolder = LastUsedFolderMemory.libraryIO.lastFolder() {
            panel.directoryURL = lastFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LastUsedFolderMemory.libraryIO.remember(url.deletingLastPathComponent())

        isExporting = true
        resultMessage = nil
        skippedFilePaths = []
        Task {
            let selection = LibraryImportExportService.ExportSelection(
                includeFavorites: includeFavorites, includeBookmarks: includeBookmarks,
                includeLayouts: includeLayouts, includeMetadata: includeMetadata,
                includeMetadataFormats: includeMetadataFormats
            )
            let (file, result) = await LibraryImportExportService.buildExportFile(
                selection: selection, favoritesStore: favoritesStore, bookmarkStore: bookmarkStore,
                layoutStore: layoutStore, metadataStore: metadataStore, metadataFormatStore: metadataFormatStore
            )
            do {
                try LibraryImportExportService.write(file, to: url)
                didSucceed = true
                resultMessage = String(localized: "Export complete.", locale: locale)
                skippedFilePaths = result.allSkippedFilePaths
            } catch {
                didSucceed = false
                resultMessage = String(
                    format: String(localized: "Export failed: %@", locale: locale),
                    error.localizedDescription
                )
            }
            isExporting = false
        }
    }
}
