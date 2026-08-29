import SwiftUI

/// 環境設定「閲覧中の動作」の「最初のページで」「最後のページで」が「毎回確認」のとき、
/// 境界に達したその場で、残りの選択肢をそのまま並べて選ばせるシート
/// (ViewerViewModel.pendingBoundaryPrompt参照)。
///
/// **なぜ`.confirmationDialog`ではなく自前のシートなのか**: macOSの`.confirmationDialog`は
/// NSAlertとして描かれる。実機で確認したところ、**渡したボタンのうち先頭3つしか出ず、
/// 残りは黙って捨てられて代わりに「OK」が1つ付く**(最後のページ側は選択肢が6つあるので、
/// 「本を閉じる」「ウェルカム画面へ戻る」「何もしない」が消えていた)。選択肢を減らす
/// わけにはいかないため、縦に並べたシートを自前で用意している。
///
/// 選択肢の中身はFirstPageBehavior/LastPageBehaviorの`promptChoices`が唯一の正典で、
/// 環境設定のポップアップとこのシートは同じ列挙から作られる ―― 片方だけ増減することがない。
struct PageBoundaryChoiceSheet<Choice: PageBoundaryChoice>: View {
    /// 見出し(「最初のページです。」「最後のページです。」)。
    let titleKey: LocalizedStringKey
    /// ボタンが押されたときに呼ばれる。シートを閉じるのは呼び出し先の責任
    /// (performFirstPageBehavior/performLastPageBehaviorがpendingBoundaryPromptをnilへ戻す)。
    let onChoose: (Choice) -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(titleKey)
                    .font(.headline)
                Text("Choose what to do next.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                ForEach(Choice.promptChoices) { choice in
                    Button {
                        onChoose(choice)
                    } label: {
                        Text(choice.titleKey)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    // ラベルを.frame(maxWidth:)で包むと、VoiceOver/アクセシビリティ検査から
                    // ボタン名が読めなくなる(実機で確認: AXTitleがmissing value)ため明示する。
                    .accessibilityLabel(Text(choice.titleKey))
                    // 「何もしない」はEscキー・シート外のクリックと同じ結果なので、
                    // キャンセルのキー割り当てをこれに与える(別途「キャンセル」ボタンを
                    // 足すと同じ意味のボタンが2つ並んでしまう)。
                    .keyboardShortcut(choice == Choice.doNothing ? .cancelAction : nil)
                }
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
