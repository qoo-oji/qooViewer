import Combine
import SwiftUI

/// ホームの「直前の本へ戻る」(2026-09-28、利用者の要望「ホームから前の本に戻るボタン」)。
///
/// このウインドウ(タブ)で直前に開いていた本(`AppState.lastOpenedBook`。メモリの上だけの控えなので、シークレット
/// ウインドウでも使える)を開き直す。一度も本を開いていないタブでは淡色。
///
/// ■ 戻れなくなった本でも淡色(2026-09-29、利用者の指摘)
/// 控えは開けた時点の写しなので、その後に本が移っても消えても残る。戻れるかどうかは `AppState.lastBookAvailability` が
/// 持ち、淡色にするのは「開き直そうとして失敗した」と「開いたときの場所に無い」の 2 つ。後者は押す前に分かるよう、
/// **このボタンが画面に出ている間だけ**確かめ直しを頼む(`recheckTriggers`)。本が元の場所へ戻れば、また押せる。
/// ツールチップは、押せない理由を題名つきで言う。
///
/// ■ 置き場所
/// - 帯があるホーム(ライブラリかスマートライブラリが ON) → 帯のいちばん左。すぐ右に「履歴から開く」(時計に矢印の記号)が組になって並び
///   (`WelcomeTopBar.historyDropdownButton`)、その右のボタンとは区切り線で分ける
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

    /// 確かめ直す契機: アプリが前面に戻った(よそで移した・消した)、ボリュームの付け外し、アプリ自身がファイルを動かした
    /// (`FileSystemChange`。値つきで届き、直前の本に関わるものだけ確かめる)。前の 3 つは nil で届く。
    ///
    /// **型に 1 つだけ持つ**(`body` の中で作ると、描き直しのたびに購読し直す)。テストの中では、ファイルの変更の知らせは
    /// 自分だけの箱から来る = 何も届かない(`FileSystemChangeCenter.defaultForState`)。
    private static let recheckTriggers: AnyPublisher<FileSystemChange?, Never> = {
        let workspace = NSWorkspace.shared.notificationCenter
        let system = Publishers.Merge3(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            workspace.publisher(for: NSWorkspace.didMountNotification),
            workspace.publisher(for: NSWorkspace.didUnmountNotification)
        )
        .map { _ in FileSystemChange?.none }
        .receive(on: DispatchQueue.main)
        // ファイルの変更の知らせは、もともとメインで届く(FileSystemChangeCenter.changes)。
        let changes = FileSystemChangeCenter.defaultForState().changes.map(FileSystemChange?.some)
        return system.merge(with: changes).eraseToAnyPublisher()
    }()

    var body: some View {
        let last = appState.lastOpenedBook
        let canReopen = appState.canReopenLastBook
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
        .disabled(!canReopen)
        .opacity(canReopen ? 1 : 0.4)
        .help(helpText(for: last, availability: appState.lastBookAvailability))
        .accessibilityLabel(Text("Return to Last Book"))
        // ホームは本を開いている間は畳まれているので、本を閉じて戻るたびにここを通る(読んでいる間に消えた本)。
        .onAppear { appState.refreshLastBookAvailability() }
        .onReceive(Self.recheckTriggers) { change in
            if let change {
                appState.refreshLastBookAvailability(after: change)
            } else {
                appState.refreshLastBookAvailability()
            }
        }
    }

    /// ツールチップ。戻る先が分かるよう題名を添える(無ければボタンの名前だけ)。戻れないときは、その理由を言う。
    private func helpText(for last: AppState.LastOpenedBook?, availability: AppState.LastBookAvailability) -> String {
        guard let last else { return String(localized: "Return to Last Book", language: locale) }
        let format = switch availability {
        case .available: String(localized: "Return to “%@”", language: locale)
        case .missing: String(localized: "“%@” can’t be found", language: locale)
        case .failedToOpen: String(localized: "“%@” couldn’t be opened", language: locale)
        }
        return String(format: format, last.title)
    }
}
