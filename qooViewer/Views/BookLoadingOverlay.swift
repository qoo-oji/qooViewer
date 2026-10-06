import SwiftUI

/// 本を読み込んでいるあいだ、内容の上に重ねて出す進捗表示。
///
/// ■ なぜ必要か
/// 読み込みが終わるまで`AppState.currentBook`はnilのままなので、以前は大きな本を開いても
/// ウェルカム画面(または直前の本)が出たきりで、進んでいるのか固まったのかが全く
/// 分からなかった。入れ子の書庫を含む本は、中身を数え上げるだけでも書庫を1つずつ開く
/// 必要があり(BookLoader.collectPages参照)、外付け/ネットワークボリューム上では
/// なおさら待つ。
///
/// ■ 割合ではなく件数を出す
/// 総数を先に確定できない ―― 書庫の中に何本の書庫が入っているかは開いてみるまで
/// 分からない ―― ため、分母(discoveredArchiveCount)は走査が進むほど増えていく。
/// 「37%」のような割合にすると数字が戻ったように見えるので、件数のまま見せる
/// (BookLoadProgressの型コメント参照)。
///
/// ■ すぐには出さない
/// 普通の本は一瞬で開くため、無条件に出すと本を開くたびに画面が点滅する。
/// `appearanceDelay`だけ待ってから出し、それより早く終わった読み込みでは一度も現れない。
///
/// パネル面(PanelSurface)ではないので、文字の輪郭処理(.panelOutlinedContent等)は不要
/// ―― 背景は`.regularMaterial`で、ユーザーが任意の色で塗れる面ではない。
struct BookLoadingOverlay: View {
    /// 読み込み中でなければnil(このときオーバーレイは何も描かない)。開く前の確かめの間(`AppState.isWaitingToOpen`)は、
    /// 件数の無い値を渡す(2026-10-06 の応答性の点検 R2 ―― 確かめから読み込みへ途切れずに出し続ける)。
    let progress: BookLoadProgress?
    /// 開く前の確かめの種類(本の場所を確かめているだけ・コレクションへ足している。`AppState.OpenWait.Purpose`)。nil は本を開いている。
    var purpose: AppState.OpenWait.Purpose?
    let onCancel: () -> Void

    /// 表示までの待ち時間。「反応が無い」と感じ始める手前に置いてある。
    private static let appearanceDelay: TimeInterval = 0.4

    @State private var isVisible = false
    /// 待ち始めた回の番号(前の回の時限が、次の回の待ちを縮めないように)。
    @State private var visibilityToken = 0

    var body: some View {
        ZStack {
            if isVisible, let progress {
                // 背後の内容を薄く沈め、同時にクリックも受け止める(読み込み中の
                // ウェルカム画面のボタンを押せてしまわないように)。
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .contentShape(Rectangle())
                card(for: progress)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isVisible)
        // 「読み込み中かどうか」が変わったときだけ測り直すので、進捗の数字が更新されるたびに
        // 待ち時間が測り直されることはない。
        //
        // **時限は `DispatchQueue`**(2026-10-06 の応答性の点検 R7-2)。以前は `.task` の中の `Task.sleep` で、協調スレッドプールが
        // 塞がっていると発火しなかった(FileIO.swift の型コメントの実測)―― 待ちが長くなるのはまさにその場面で、札が出なかった。
        .onAppear { scheduleVisibility(isLoading: progress != nil) }
        .onChange(of: progress == nil) { _, isIdle in scheduleVisibility(isLoading: !isIdle) }
    }

    private func scheduleVisibility(isLoading: Bool) {
        visibilityToken &+= 1
        guard isLoading else {
            isVisible = false
            return
        }
        let token = visibilityToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.appearanceDelay) {
            if visibilityToken == token { isVisible = true }
        }
    }

    private var title: LocalizedStringKey {
        switch purpose {
        case .locating: "Looking for the book…"
        case .adding: "Adding books…"
        case .opening, nil: "Opening the book…"
        }
    }

    private func card(for progress: BookLoadProgress) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                // 入れ子の書庫が1本も無い本(=本そのものだけ)では件数を出しても
                // 意味が無いので省く。
                if progress.discoveredArchiveCount > 1 {
                    Text("Read \(progress.completedArchiveCount) of \(progress.discoveredArchiveCount) archives")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let name = progress.currentArchiveName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 240, maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}
