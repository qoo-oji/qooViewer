import Combine
import SwiftUI

/// ブックマーク・レイアウトの編集ウインドウの「開く」(左ペインのダブルクリック・右クリック、右ペインのページのダブルクリック)が、
/// 本の場所の解決(最長 45 秒。StoredBookLocator)を待っている仕事(2026-10-04 のレビューの R7-3)。以前は待つ仕事を誰も持たず、
/// 待つ間に編集ウインドウを閉じても数十秒後に手前の窓の本が黙って置き換わり、何度も押すと全部が順に開いた。待っている仕事は、
/// 解決を待ち終えた後で `Task.isCancelled` を見て降りる。参照型なのは、閉じる知らせの閉包からも同じ箱を見るため。
///
/// ■ 2 種類の「開く」を別の箱に持つ(2026-10-04 のレビューの RC-3)
/// - **手前の窓の本を置き換える「開く」**(`startReplacing`): 同じ窓の本を取り合うので、後から押した方が勝つ(前の待ちを取り消す)。
/// - **新しいタブ・ウインドウへの「開く」**(`startInNewWindow`): どの窓の本とも競わない(docs/04「新しいタブ・ウインドウへ開く
///   入口は…照合もしない」)ので、1 件ずつ持ち、ほかの「開く」で取り消さない。取り消すのはウインドウを閉じたとき(`cancelAll`)だけ。
///   以前(段 C の直し)は 1 つの箱を使い、A を「新しいタブで開く」(NAS で待ち)→ 続けて B も「新しいタブで開く」と、A が黙って
///   開かれなかった(直す前は両方開いた)。
///
/// テストが取り消しを確かめられるよう、View の外に置く(`PendingBookOpensTests`)。
///
/// ■ 待っている間は見せる(2026-10-06 の応答性の点検 R2-4)
/// 以前は解決を待つ最長 45 秒、編集ウインドウに何も出ず、期限切れはビープだけだった。待ち始めて `waitIndicatorDelay` を過ぎたら
/// `isShowingWait` を立て、ウインドウの下に「本を探しています…」を出す(`pendingBookOpenIndicator`)。
@MainActor
final class PendingBookOpens: ObservableObject {
    private var replacing: Task<Void, Never>?
    private var replacingID: UUID?
    private var inNewWindows: [UUID: Task<Void, Never>] = [:]
    /// 待っている「開く」(置き換える分は、取り消した時点で外す)。
    private var active: Set<UUID> = []
    /// 待っている「開く」があり、`waitIndicatorDelay` を過ぎた。
    @Published private(set) var isShowingWait = false

    /// 表示までの待ち(本を開く札 `BookLoadingOverlay` と同じ。ローカルの本はほぼ一瞬で解決するので、ちらつかせない)。
    /// **`Task.sleep` ではなく `DispatchQueue`**: 協調スレッドプールが塞がっていると `Task.sleep` は発火しない
    /// (FileIO.swift の型コメントの実測)―― 待ちが長くなるのはまさにその場面。
    static let waitIndicatorDelay: TimeInterval = 0.4

    /// 待っている「新しいタブ・ウインドウで開く」の数(テスト用。終わったものは外す)。
    var pendingNewWindowCount: Int { inNewWindows.count }

    /// 手前の窓の本を置き換える「開く」。前に頼まれた置き換える「開く」を取り消す(新しいタブ・ウインドウへの分は取り消さない)。
    @discardableResult
    func startReplacing(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        replacing?.cancel()
        if let replacingID { end(replacingID) }
        let id = begin()
        replacingID = id
        let task = Task { @MainActor [weak self] in
            await body()
            self?.end(id)
        }
        replacing = task
        return task
    }

    /// 新しいタブ・ウインドウへの「開く」。ほかの「開く」を取り消さず、ほかの「開く」にも取り消されない。
    @discardableResult
    func startInNewWindow(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = begin()
        let task = Task { @MainActor [weak self] in
            await body()
            self?.inNewWindows[id] = nil
            self?.end(id)
        }
        inNewWindows[id] = task
        return task
    }

    /// 編集ウインドウを閉じた ―― 閉じたウインドウの「開く」は、もう頼まれていない。
    func cancelAll() {
        replacing?.cancel()
        replacing = nil
        replacingID = nil
        inNewWindows.values.forEach { $0.cancel() }
        inNewWindows.removeAll()
        active.removeAll()
        isShowingWait = false
    }

    private func begin() -> UUID {
        let id = UUID()
        active.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.waitIndicatorDelay) { [weak self] in
            guard let self, self.active.contains(id), !self.isShowingWait else { return }
            self.isShowingWait = true
        }
        return id
    }

    private func end(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if replacingID == id { replacingID = nil }
        if active.isEmpty, isShowingWait { isShowingWait = false }
    }
}

extension View {
    /// 編集ウインドウの「開く」が本の場所の解決を待っている間、ウインドウの下に「本を探しています…」を出す(`PendingBookOpens`)。
    func pendingBookOpenIndicator(_ pending: PendingBookOpens) -> some View {
        modifier(PendingBookOpenIndicator(pending: pending))
    }
}

private struct PendingBookOpenIndicator: ViewModifier {
    @ObservedObject var pending: PendingBookOpens

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if pending.isShowingWait {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for the book…")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: pending.isShowingWait)
    }
}
