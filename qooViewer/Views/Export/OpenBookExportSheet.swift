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
/// ■ 保存先はシートより先に決まっている
/// 「毎回確認」のときは、メニューの項目を選んだ**その場でフォルダ選択パネルが開き**、
/// 選んでからこのシートが出る(ユーザー要望)。そのためシートに来た時点で保存先は必ず
/// 決まっていて、この画面のそれは「いまどこへ書き出すか」の表示と、選び直しの導線になる。
/// パネルでキャンセルした場合はシート自体が出ない(ViewerView.startOpenBookExport参照)。
///
/// ■ 何も尋ねずに終わる場合がある
/// 環境設定「レイアウト」で保存先を決めてあると、パネルもこの画面も出ず、開いた瞬間から
/// 書き出しの進捗だけを出して、終わったら自分で閉じる(ユーザー要望の中心にある
/// 「新しい本を開く → 書き出す → 次の本を開く」を操作なしで繰り返せるようにするため)。
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
    /// 書き出し先。シートが開く前に必ず決まっている(上のコメント参照)。
    let initialDestination: Destination
    /// falseなら、このシートは何も尋ねずに開いた瞬間から書き出しを始める
    /// (環境設定で保存先を決めてある場合)。
    let asksBeforeExporting: Bool
    /// カバー画像を選ばせてよいか。falseにするのはDBへ書かない本
    /// (シークレットウインドウ)のときだけ ―― カバーの指定はDBに残るため。
    let allowsCoverSelection: Bool
    /// シートを閉じるときに呼ぶ。
    /// - Parameter didExport: 実際に1冊書き出せたか。falseなら(キャンセル・失敗)、
    ///   「書き出したあとの動作」へは進まない。
    let onFinish: (_ didExport: Bool) -> Void

    @EnvironmentObject private var preferences: AppPreferences

    /// いまの書き出し先。「変更…」で選び直すとここが差し替わる。
    @State private var destination: Destination?
    /// 書き出しを始めたかどうか。何も尋ねない設定のときは`.task`で即座に始めるため、
    /// 「まだisExportingが立っていないだけの一瞬」にこの画面を出さないための番人。
    @State private var didStart = false
    @State private var failureMessage: String?

    /// 書き出し先のフォルダと、それを使うのに必要な後始末。
    struct Destination {
        let url: URL
        /// 保存済みのブックマークから解決したフォルダか。その場合、書き出しのあいだ
        /// セキュリティスコープを開いておく必要がある(サンドボックス下では、開かずに
        /// 書き込もうとすると権限エラーになる)。フォルダ選択パネルで今まさに選んだ
        /// フォルダには既に権限が付いているため不要。
        let isSecurityScoped: Bool
    }

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
            } else if didStart || !asksBeforeExporting {
                // 書き出しを始めた直後・終えた直後の一瞬。すぐ次の状態へ移る。
                // 何も尋ねない設定のときは、下の.taskが走るまでの1フレームもここへ入れる
                // ―― 何も尋ねない約束なのに、この画面が一瞬ちらつくのを避けるため。
                ProgressView()
                    .padding(32)
                    .frame(minWidth: 380, minHeight: 220)
            } else {
                configurationView
            }
        }
        .task {
            guard !asksBeforeExporting, !didStart else { return }
            await run(initialDestination)
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
                        ExportDestinationLabel(path: destination?.url.path)
                        Spacer(minLength: 0)
                        // 選ぶのはこの画面より前に済んでいるので、ここは「変更…」
                        // (環境設定「レイアウト」のフォルダの行と同じ言葉)。
                        Button("Change…") {
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
                    Task { await run(destination) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            // タイトル・著者名の初期値とカバー画像の名前は、この下ごしらえが済んでいないと
            // 解決できない(BookExportViewModel.prepareOpenBook参照)。
            viewModel.prepareOpenBook(book)
            if destination == nil {
                destination = initialDestination
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
        guard let folder = ExportDestinationPanel.present(
            for: format, startingAt: destination?.url, locale: preferences.effectiveLocale
        ) else { return }
        // パネルで今まさに選んだフォルダには既に権限が付いている。
        destination = Destination(url: folder, isSecurityScoped: false)
    }

    private func run(_ destination: Destination) async {
        didStart = true
        let folder = destination.url
        let didAccess = destination.isSecurityScoped && folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }

        // 空き容量チェック(BookExportViewModel.hasSufficientDiskSpace)は行わない。あれは
        // 一覧で選択した本の合計サイズを見るもので、一覧を通らないこの経路では常に0冊ぶん=
        // 「足りている」としか答えられない。容量が足りなければ書き込みの失敗として現れ、
        // 下のfailureMessageで伝わる(中途半端なファイルは残らない。exportOne参照)。
        let failure = await viewModel.exportOpenBook(book, displayState: displayState, to: folder)
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

// MARK: - 保存先フォルダの選択パネル

/// 「本の書き出し」で保存先フォルダを選ばせるパネル。
///
/// メニューの項目を選んだ直後(ViewerView.startOpenBookExport)と、シートの「変更…」の
/// 両方から呼ぶため、ここに1つだけ置いてある。選んだフォルダは、次にこのパネルを開いたときの
/// 初期位置として記憶する(LastUsedFolderMemory)。
@MainActor
enum ExportDestinationPanel {
    /// - Parameter startingAt: パネルを開く位置。nilならこの形式で前回選んだフォルダ。
    /// - Returns: 選ばれたフォルダ。キャンセルされたらnil。
    static func present(for format: BookExportFormat, startingAt: URL?, locale: Locale) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", language: locale)
        panel.message = String(localized: "Choose a destination folder for the exported book.", language: locale)
        if let current = startingAt ?? format.lastUsedFolder.lastFolder() {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        format.lastUsedFolder.remember(folder)
        return folder
    }
}
