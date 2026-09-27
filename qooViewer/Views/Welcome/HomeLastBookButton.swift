import SwiftUI

/// ホームの「直前の本へ戻る」(2026-09-28、利用者の要望「ホームから前の本に戻るボタン」)。
///
/// このウインドウ(タブ)で直前に開いていた本(`AppState.lastOpenedBook`。メモリの上だけの控えなので、シークレット
/// ウインドウでも使える)を開き直す。一度も本を開いていないタブでは淡色。
///
/// ■ 置き場所
/// - 帯があるホーム(ライブラリかスマートライブラリが ON) → 帯のいちばん左、すぐ右のボタンとは区切り線で分ける(`WelcomeTopBar`)
/// - 帯が無く、ファイルブラウザも OFF(旧ウェルカム画面) → 画面の左上(`ClassicWelcomeView`)
/// - 帯が無く、ファイルブラウザだけ → 置き場が無いので、ボタンではなくファイルブラウザがその本を選んで見せる
///   (`WelcomeLibraryState.revealsLastBookInFileBrowser`)
///
/// ■ 見た目
/// 帯の「＋」と同じ、選ばれていないチップの地に左向きの三角(利用者の指定)。記号は `Text` に埋め込んでチップと高さを揃える
/// (`WelcomeTopBar.newLibraryButton` と同じ理由)。地がほぼ無いので輪郭を掛ける(すりガラス面の決まりごと)。淡色は、
/// `.disabled` に任せず自分で薄くする(プレーンなボタンの淡色は地には掛からないため、押せない状態が地の色からも読めるように)。
struct HomeLastBookButton: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        let last = appState.lastOpenedBook
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button {
            appState.reopenLastBook()
        } label: {
            Text(Image(systemName: "arrowtriangle.left.fill"))
                .panelOutlinedContent()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(shape.fill(Color.primary.opacity(0.07)))
                .foregroundStyle(Color.primary)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(last == nil)
        .opacity(last == nil ? 0.4 : 1)
        .help(helpText(for: last))
        .accessibilityLabel(Text("Return to Last Book"))
    }

    /// ツールチップ。戻る先が分かるよう題名を添える(無ければボタンの名前だけ)。
    private func helpText(for last: AppState.LastOpenedBook?) -> String {
        guard let last else { return String(localized: "Return to Last Book", language: locale) }
        return String(format: String(localized: "Return to “%@”", language: locale), last.title)
    }
}
