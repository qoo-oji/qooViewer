import SwiftUI
import Combine

/// ウインドウに出す本(ビューア)を切り替えるときに、**新しい本の最初の見開きが揃うまで前の中身を出しておく**ための受け渡し役。
/// ContentView が 1 ウインドウに 1 つ持つ。
///
/// ■ なぜ要るか(2026-09-27、表示の切り替えの監査の 7)
/// ViewerView は本ごとに作り直し(`.id(book.id)`)、ビューモデルは `currentImages = []` から始まって、最初の見開きは init の後に
/// 非同期でデコードする。そのため、ホーム → 本・次の本・前の本・新しいウインドウで開く、のたびに、ページ領域が 1〜3 フレーム
/// (33〜50ms)ビューアの地(黒)だけになっていた(画面の取り込みで毎回実測)。
/// そこで、`AppState.currentBook` が別の本になったら、先にその本のビューモデルを作って最初の見開きを読ませ、揃うまでは今の中身
/// (前の本のビューア、またはホーム)を出したままにする。揃ったら(または `maximumWait` が過ぎたら)そのビューモデルを渡して
/// ViewerView を作る。待つのは長くて `maximumWait` なので、大きな本・遅いボリュームでも以前より遅くはならない
/// (過ぎたら以前と同じく、地を出して読み込みを待つ)。
///
/// ビューモデルは最初の見開きをビューの大きさに関係なく読む(`ViewerViewModel.loadCurrentSpread`)ので、ビューより先に作ってよい。
/// 使われずに捨てるビューモデル(待っている間にさらに別の本・ホームへ替わった)は `releaseResources()` で資源を手放す。
@MainActor
final class ViewerHandoff: ObservableObject {
    /// いまビューアに出している本とそのビューモデル。nil ならビューアを出していない(ホームなど)。
    @Published private(set) var shown: Entry?

    struct Entry {
        let book: MangaBook
        let model: ViewerViewModel
    }

    /// 最初の見開きを待っている本。
    private var pending: Entry?
    /// 待ち終わりのきっかけ(最初の見開きが揃った知らせと、`maximumWait` の時限)。
    private var readinessSubscription: AnyCancellable?
    private var timeoutTask: Task<Void, Never>?

    /// 最初の見開きを待つ長さの上限。デコードは合成の本で 30〜50ms、大きな画像で 100〜200ms ほど。
    static let maximumWait: Duration = .milliseconds(300)

    /// 最初の見開きを待っている最中か(ホームの代わりにビューアの地を出し続けるかの判定に使う)。
    var isPreparing: Bool { pending != nil }

    /// `AppState.currentBook` が変わったら呼ぶ。
    /// - Parameter makeModel: その本のビューモデルを作る(ViewerView の init と同じ引数で)。
    func update(to book: MangaBook?, makeModel: (MangaBook) -> ViewerViewModel) {
        guard let book else {
            discardPending()
            shown = nil
            return
        }
        // 同じ本(ページの並べ替え・除外で中身だけ変わった、同じ本の開き直し)は、今までどおり同じ ViewerView のまま
        // (`.id(book.id)` が同じなので、ビューモデルも作り直されない)。
        if let shown, shown.book.id == book.id {
            discardPending()
            self.shown = Entry(book: book, model: shown.model)
            return
        }
        if let pending, pending.book.id == book.id {
            self.pending = Entry(book: book, model: pending.model)
            return
        }
        discardPending()
        let model = makeModel(book)
        pending = Entry(book: book, model: model)
        let bookID = book.id
        readinessSubscription = model.$currentImages
            .first { !$0.isEmpty }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.showPending(bookID: bookID) }
            }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumWait)
            guard !Task.isCancelled else { return }
            self?.showPending(bookID: bookID)
        }
    }

    private func showPending(bookID: String) {
        guard let pending, pending.book.id == bookID else { return }
        stopWaiting()
        self.pending = nil
        shown = pending
    }

    private func stopWaiting() {
        readinessSubscription?.cancel()
        readinessSubscription = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// 待っている本を捨てる(使わなかったビューモデルの資源を手放す)。
    func discardPending() {
        stopWaiting()
        if let pending {
            pending.model.releaseResources()
            self.pending = nil
        }
    }
}
