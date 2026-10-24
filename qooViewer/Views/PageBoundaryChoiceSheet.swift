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
/// **`.confirmationDialog`はレイアウトの伝播範囲(選択肢 4 つ + キャンセル)でも同じく 4 つ目を捨て、キャンセルを「OK」に
/// 変えた**(2026-10-24 に AppKit 単体で再実測)ので、そちらも`ChoiceListSheet`にした。
///
/// 選択肢の中身はFirstPageBehavior/LastPageBehaviorの`promptChoices`が唯一の正典で、
/// 環境設定のポップアップとこのシートは同じ列挙から作られる ―― 片方だけ増減することがない。
struct PageBoundaryChoiceSheet<Choice: PageBoundaryChoice>: View {
    /// 見出し(「最初のページです。」「最後のページです。」)。
    let titleKey: LocalizedStringKey
    /// 前の本・次の本へ移る選択肢を淡色にするか(置き場所の無い本 ―― StackNest の本。MangaBook.hasBrowsableLocation)。
    var dimsAdjacentBookChoices = false
    /// ボタンが押されたときに呼ばれる。シートを閉じるのは呼び出し先の責任
    /// (performFirstPageBehavior/performLastPageBehaviorがpendingBoundaryPromptをnilへ戻す)。
    let onChoose: (Choice) -> Void

    var body: some View {
        // 「何もしない」は必ず最後(Esc。ダイアログの作法 ―― docs/09「ダイアログとシートの作法」)。
        let choices = Choice.promptChoices.filter { $0 != Choice.doNothing } + [Choice.doNothing]
        ChoiceListSheet(
            titleKey: titleKey,
            choices: choices.map { .init(id: $0, titleKey: $0.titleKey, isDisabled: dimsAdjacentBookChoices && $0.opensAdjacentBook) },
            cancelID: Choice.doNothing,
            onChoose: onChoose
        )
    }
}

/// 選択肢が 4 つ以上あるときに縦に並べて選ばせるシート(「最初のページです。」「レイアウトの変更をどこまで適用しますか?」など)。
///
/// **ダイアログの作法**(docs/09「ダイアログとシートの作法」、2026-10-24): 題は 1 文だけ(説明の 2 行目は付けない)、選択肢は上から
/// よく使う順、最後の 1 つが「キャンセル」「何もしない」で Esc。**Return の既定は作らない** ―― ページ送りや操作のキーを押している
/// 途中で出るシートなので、押し続けたキーで選ばれないように。
struct ChoiceListSheet<ID: Hashable>: View {
    struct Choice: Identifiable {
        let id: ID
        let titleKey: LocalizedStringKey
        var isDisabled = false
    }

    let titleKey: LocalizedStringKey
    let choices: [Choice]
    /// Esc で選ばれる選択肢(最後に置く)。
    let cancelID: ID
    let onChoose: (ID) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(titleKey)
                .font(.headline)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(choices) { choice in
                    Button {
                        onChoose(choice.id)
                    } label: {
                        Text(choice.titleKey)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(choice.isDisabled)
                    // ラベルを.frame(maxWidth:)で包むと、VoiceOver/アクセシビリティ検査から
                    // ボタン名が読めなくなる(実機で確認: AXTitleがmissing value)ため明示する。
                    .accessibilityLabel(Text(choice.titleKey))
                    // 「何もしない」「キャンセル」はEscキー・シート外のクリックと同じ結果なので、
                    // キャンセルのキー割り当てをこれに与える(別途「キャンセル」ボタンを
                    // 足すと同じ意味のボタンが2つ並んでしまう)。
                    .keyboardShortcut(choice.id == cancelID ? .cancelAction : nil)
                }
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
