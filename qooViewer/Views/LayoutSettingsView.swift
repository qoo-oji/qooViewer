import SwiftUI

/// 環境設定ウインドウの「レイアウト」画面(ユーザー要望)。
///
/// ■ この画面が受け持つこと
/// 1. レイアウトの保存データを持っていない本を開いたときに、本全体を自動レイアウトするか
/// 2. 形式(EPUB / PDF / CBZ)ごとの、書き出しの保存先・オプションの既定値・
///    書き出し終わった本の後始末
/// 3. 右クリックから書き出したあと、次に何をするか
///
/// ■ なぜ1枚に同居しているのか
/// ユーザーが繰り返したい作業が「新しい本を開く(自動でレイアウトされる)→ 右クリックから
/// 書き出す → そのまま次の本を開く」という**一続きの流れ**だから。1〜3はその流れの
/// 3つの区切りに1対1で対応していて、どれか1つだけ設定しても流れは完成しない。
///
/// ■ 形式ごとの設定は子ページに分けてある(2階層)
/// 以前はこの1枚に、形式ごとのセクション(EPUB / PDF / CBZ)を丸ごと縦に並べていた。
/// 1形式あたり5〜7行あり、しかも**3つとも中の行名がほぼ同じ**なので、スクロールしながら
/// 「保存先」「保存データ」を読んでもどの形式の行なのかが見分けにくい ―― 「外観」の面ごとの
/// セクションで指摘されたのとまったく同じ問題(AppearanceSettingsView冒頭参照)。
/// ユーザーの指示で、あちらと同じ形へ揃えた。
///
/// この画面は「1」「形式の一覧(3行)」「3」だけにし、形式の行を押すとその形式の書き出し設定
/// だけを載せた子ページ(`BookExportFormatSettingsView`)へ進む。
/// 行の右にはその形式の保存先を要約して出してあるので、**子ページへ進まなくても3形式の
/// 保存先を見比べられる**(「外観」で2階層を選んだ理由と同じ)。
///
/// 形式ごとのセクションを画面から追い出しても「一続きの流れ」は壊れない ―― 1と3は流れの
/// 前後の区切りで、そのあいだにある「どの形式でどう書き出すか」への入口が一覧として
/// 残っているため。
///
/// ■ 子ページは次回に持ち越さない
/// 「外観」と同じく、環境設定を開き直したときは必ず一覧から始める。開いている子ページ
/// (SettingsNavigator.openedLayoutFormat)は、この画面が閉じる(ウインドウを閉じる、
/// 別の画面へ移る)たびにnilへ戻す(body末尾のonDisappear参照)。
struct LayoutSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    /// いま開いている形式の子ページ(SettingsNavigator.openedLayoutFormat参照)。
    /// `@ObservedObject`にしてあるのは、子ページの開閉に追従するため。
    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        // 詳細ペイン(SettingsViewのNavigationSplitViewの右側)の中で、一覧と子ページを
        // 自前で切り替える。「戻る」がウインドウのタイトルバーにある理由と、
        // `NavigationStack`を使わない理由はAppearanceSettingsView.body参照。
        Group {
            if let format = navigator.openedLayoutFormat {
                BookExportFormatSettingsView(format: format)
            } else {
                rootPage
            }
        }
        .onDisappear { navigator.openedLayoutFormat = nil }
    }

    /// 一覧のページ(自動レイアウト・形式の一覧・書き出したあとの動作・初期設定に戻す)。
    private var rootPage: some View {
        SettingsPaneContainer {
            autoLayoutSection
            formatsSection
            completionSection

            SettingsResetSection(
                help: "Restores every setting on this page and on every format’s page, including the fixed destination folders. Other pages, and your favorites, bookmarks and reading history, are not affected."
            ) {
                preferences.resetToDefaults(.layout)
            }
        }
    }

    // MARK: - 1. レイアウトの保存データを持っていない本を開いたとき

    private var autoLayoutSection: some View {
        Section {
            SettingsPicker(
                "Auto-Layout",
                selection: $preferences.missingLayoutAutoLayout,
                help: "Lays out the whole book the same way “Auto-Layout Based on Current View” does, using the first page as the starting point. Books that already have layout data — including EPUB and PDF, whose layout is imported the first time you open them — are left alone."
            )
        } header: {
            Text("Opening a Book Without Layout Data")
        }
    }

    // MARK: - 2. 形式ごとの書き出し

    /// 形式ごとの子ページへ進む行の一覧。並びは`BookExportFormat.allCases`のまま
    /// (形式を足してもこのファイルは触らなくてよい)。
    private var formatsSection: some View {
        Section {
            ForEach(BookExportFormat.allCases) { format in
                BookExportFormatRow(
                    format: format,
                    destination: preferences.bookExportDestinationMode(for: format),
                    // 固定の保存先はUserDefaultsを直接読む(`@Published`ではない)。
                    // 子ページでフォルダを選び直すとこの画面ごと組み直されるので
                    // (navigatorの変化で再評価される)、ここでは世代番号を持たなくてよい。
                    fixedFolderPath: format.fixedFolder.lastFolderPath()
                ) {
                    navigator.openedLayoutFormat = format
                }
            }
        } header: {
            Text("Export by Format")
        }
    }

    // MARK: - 3. 書き出したあとの動作

    private var completionSection: some View {
        Section {
            // 行のラベルはセクション見出しの言い換えにしない(SettingsControlsの3層の方針)。
            // 見出しが「いつの話か」を言い切っているので、ここは「そのあと何を決めるのか」
            // だけでよい。
            SettingsPicker(
                "Afterwards",
                selection: $preferences.bookExportCompletionBehavior,
                help: "“Close Book” closes this tab (the window too, if it is the only tab). “Return to Welcome Screen” keeps the window open."
            )
        } header: {
            Text("Exporting the Book You Are Reading")
        }
    }
}

// MARK: - 形式の一覧の1行

/// 「レイアウト」の形式の一覧の1行。左に形式名、右にいまの保存先と、子ページへ進む「>」。
///
/// 要約に**保存先**を選んでいるのは、形式ごとの設定の中でここだけが「毎回確認するのか、
/// 何も聞かずに書き出すのか」という操作そのものを変える設定で、3形式で食い違っていると
/// いちばん驚くところだから(他の行は書き出される中身の違い)。
///
/// `NavigationLink`ではなく行全体を1つのボタンにしてある(理由はPanelSurfaceRowと同じ)。
private struct BookExportFormatRow: View {
    let format: BookExportFormat
    let destination: BookExportDestinationMode
    /// 「保存先を設定」のときのフォルダ。まだ決まっていなければnil。
    let fixedFolderPath: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                // 形式名は固有名詞なので翻訳しない(BookExportFormat.displayName参照)。
                Text(verbatim: format.displayName)
                Spacer(minLength: 12)
                summary
                    .foregroundStyle(.secondary)
                // 「押すと進む」印。システム設定の一覧の行と同じ。
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var summary: some View {
        switch destination {
        case .askEachTime:
            Text(BookExportDestinationMode.askEachTime.shortTitleKey)
        case .fixedFolder:
            // 書き出しウインドウと同じ見せ方(フォルダのアイコン+パス。長ければ真ん中を省略)。
            ExportDestinationLabel(path: fixedFolderPath)
        }
    }
}
