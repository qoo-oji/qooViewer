import SwiftUI
import AppKit

/// ビューアの右クリック →「本の書き出し」→「EPUB/PDF/CBZとして書き出す」で出るシート
/// (ユーザー要望)。
///
/// ■ 3つの書き出しウインドウとの関係
/// あちらは「登録済みの本の一覧から選んでまとめて書き出す」ための独立ウインドウで、この
/// シートは「いま開いている1冊を、その場で書き出す」ためのもの。実際に書き出す処理・進捗・
/// 同名確認は`BookExportViewModel`が共通で持っているため、ここが足しているのは
/// **保存先とオプションを尋ねる小さな画面**と、終わったことを呼び出し側へ返すところだけ。
///
/// ■ 何も尋ねずに終わる場合がある
/// 環境設定「レイアウト」で固定の保存先を決めてあると、このシートは保存先を尋ねず、開いた
/// 瞬間から書き出しの進捗だけを出して、終わったら自分で閉じる(ユーザー要望の中心にある
/// 「新しい本を開く → 書き出す → 次の本を開く」を操作なしで繰り返せるようにするため)。
/// 逆に固定の保存先が無い場合は、保存先の選択と書き出しオプションだけの小さなシートを出す。
struct OpenBookExportSheet: View {
    @ObservedObject var viewModel: BookExportViewModel
    let format: BookExportFormat
    /// いま開いている本。`MangaBook.sourceURL`はユーザーが実際に開いたURL(=アクセス権のある
    /// URL)なので、ストアに1行も無い本でもそのまま書き出せる
    /// (`BookExportViewModel.exportOpenBook(_:displayState:to:)`参照)。
    let book: MangaBook
    /// 画面での表示状態(読み方向・見開き/単ページ)。DBに保存が無い項目をこれで補う
    /// (`BookExportViewModel.OpenBookDisplayState`参照)。
    let displayState: BookExportViewModel.OpenBookDisplayState
    /// 環境設定で決めてある固定の保存先。nilなら保存先の選択から始める。
    let fixedDestination: URL?
    /// カバー画像を選ばせてよいか。falseにするのはDBへ書かない本
    /// (シークレットウインドウ)のときだけ ―― カバーの指定はDBに残るため。
    let allowsCoverSelection: Bool
    /// シートを閉じるときに呼ぶ。
    /// - Parameter didExport: 実際に1冊書き出せたか。falseなら(キャンセル・失敗)、
    ///   「書き出したあとの動作」へは進まない。
    let onFinish: (_ didExport: Bool) -> Void

    @EnvironmentObject private var preferences: AppPreferences

    /// 保存先の選択から始める場合に、選ばれたフォルダ。
    @State private var destination: URL?
    /// 書き出しを始めたかどうか。固定の保存先がある場合、`.task`で即座に始めるため、
    /// 「まだisExportingが立っていないだけの一瞬」に保存先の選択画面を出さないための番人。
    @State private var didStart = false
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if viewModel.isExporting {
                ExportProgressSheet(
                    viewModel: viewModel,
                    progressTitle: "Exporting Book…",
                    overwriteMessage: { displayName in
                        String(
                            format: String(localized: "“%1$@.%2$@” already exists in the destination folder."),
                            displayName, format.fileExtension
                        )
                    }
                )
            } else if let failureMessage {
                failureView(failureMessage)
            } else if didStart || fixedDestination != nil {
                // 書き出しを始めた直後・終えた直後の一瞬。すぐ次の状態へ移る。
                // fixedDestinationがある場合、下の.taskが走るまでの1フレームもここへ入れる
                // ―― 何も尋ねない約束なのに、保存先の選択画面が一瞬ちらつくのを避けるため。
                ProgressView()
                    .padding(32)
                    .frame(minWidth: 380, minHeight: 220)
            } else {
                configurationView
            }
        }
        .task {
            guard let fixedDestination, !didStart else { return }
            await run(destinationFolder: fixedDestination, isSecurityScoped: true)
        }
    }

    // MARK: - 保存先とオプション

    private var configurationView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(format.menuTitleKey)
                    .font(.headline)
                Text(displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            // 保存先・タイトル・著者名・カバー画像。ラベルの幅を揃えたいのでGridで組む
            // (書き出しウインドウでは一覧の「列」がその役目を果たしているが、こちらは
            // 1冊ぶんのフォームなので縦に揃える)。
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                // まだ選んでいなければ、下の「書き出す」は押せない。
                // フォルダ名だけでなくパス全体を出す理由はExportDestinationLabel参照。
                GridRow {
                    Text("Destination")
                        .gridColumnAlignment(.leading)
                    HStack(spacing: 8) {
                        ExportDestinationLabel(path: destination?.path)
                        Spacer(minLength: 0)
                        Button("Choose…") {
                            chooseDestination()
                        }
                    }
                }

                // タイトル・著者名(ユーザー要望: 書き出しウインドウと同じ項目をここにも)。
                // 初期値の決め方も同じで、メタデータの登録があればそれを、無ければ
                // ファイル名/フォルダ名からの推測を入れる
                // (BookExportViewModel.prepareOpenBook / seedTitleAndAuthorIfNeeded参照)。
                GridRow {
                    Text("Title")
                    TextField("", text: viewModel.titleBinding(forBookID: book.id))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Author")
                    TextField("", text: viewModel.authorBinding(forBookID: book.id))
                        .textFieldStyle(.roundedBorder)
                }

                // カバー画像。PDFはカバーという概念を持たないので出さない
                // (BookExportViewModel.supportsCoverSelection参照)。
                if viewModel.supportsCoverSelection {
                    GridRow {
                        Text("Cover")
                        // 選び方は書き出しウインドウのカバー列とまったく同じ部品
                        // (ExportCoverCell)。既定は本の実質的な先頭ページ。
                        ExportCoverCell(bookID: book.id, viewModel: viewModel)
                            // カバーの指定はDBへ書き込む(LayoutStore)。DBへ書かない本
                            // ―― シークレットウインドウ ―― では、ここから記録を作って
                            // しまわないよう操作させない(項目は消さずグレーアウトするのが
                            // このアプリの作法。AppState.isPrivateWindowのコメント参照)。
                            .disabled(!allowsCoverSelection)
                            .help(allowsCoverSelection
                                  ? "Change Cover Image"
                                  : "The cover can't be changed in a private window, because it would have to be saved.")
                    }
                }
            }

            Divider()

            // 3つの書き出しウインドウの「書き出しオプション…」と同じ項目・同じ並び
            // (BookExportFormatOptions参照)。
            VStack(alignment: .leading, spacing: 8) {
                BookExportFormatOptions(format: format, viewModel: viewModel)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onFinish(false)
                }
                .keyboardShortcut(.cancelAction)
                Button("Export") {
                    guard let destination else { return }
                    Task {
                        // NSOpenPanelで選んだフォルダはその場でアクセス権が付いているため、
                        // セキュリティスコープを開き直す必要は無い。
                        await run(destinationFolder: destination, isSecurityScoped: false)
                    }
                }
                .disabled(destination == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            // タイトル・著者名の初期値とカバー画像の名前は、この下ごしらえが済んでいないと
            // 解決できない(BookExportViewModel.prepareOpenBook参照)。
            viewModel.prepareOpenBook(book)
            // 前回この形式で選んだ保存先を初期値にしておく(毎回同じフォルダへ書き出す使い方が
            // 多いため。それを完全に無操作にしたい場合が、環境設定の「既定の保存先」)。
            if destination == nil {
                destination = format.lastUsedFolder.lastFolder()
            }
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn’t Export the Book")
                .font(.headline)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") {
                    onFinish(false)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    // MARK: - 実行

    private var displayName: String {
        book.sourceURL.deletingPathExtension().lastPathComponent
    }

    private func chooseDestination() {
        let locale = preferences.effectiveLocale
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", locale: locale)
        panel.message = String(localized: "Choose a destination folder for the exported book.", locale: locale)
        if let current = destination ?? format.lastUsedFolder.lastFolder() {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        destination = folder
        format.lastUsedFolder.remember(folder)
    }

    /// - Parameter isSecurityScoped: 保存先が、保存済みのブックマークから解決したフォルダか。
    ///   その場合は書き出しのあいだセキュリティスコープを開いておく必要がある(サンドボックス下
    ///   では、開かずに書き込もうとすると権限エラーになる)。NSOpenPanelで今まさに選んだ
    ///   フォルダには既に権限が付いているため不要。
    private func run(destinationFolder: URL, isSecurityScoped: Bool) async {
        didStart = true
        let didAccess = isSecurityScoped && destinationFolder.startAccessingSecurityScopedResource()
        defer { if didAccess { destinationFolder.stopAccessingSecurityScopedResource() } }

        // 空き容量チェック(BookExportViewModel.hasSufficientDiskSpace)は行わない。あれは
        // 一覧で選択した本の合計サイズを見るもので、一覧を通らないこの経路では常に0冊ぶん=
        // 「足りている」としか答えられない。容量が足りなければ書き込みの失敗として現れ、
        // 下のfailureMessageで伝わる(中途半端なファイルは残らない。exportOne参照)。
        let failure = await viewModel.exportOpenBook(book, displayState: displayState, to: destinationFolder)
        if let failure {
            failureMessage = failure
            return
        }
        // 成功。結果シートは出さず、そのまま閉じて「書き出したあとの動作」へ渡す
        // (ユーザーの指示。毎回OKを押させると、繰り返しの流れが途切れるため)。
        // ユーザーが同名確認でスキップを選んだ場合もここへ来るが、その場合は書き出して
        // いないので、後続の動作へは進めない(successCountで見分ける)。
        onFinish(viewModel.successCount > 0)
    }
}
