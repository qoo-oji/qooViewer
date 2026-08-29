import SwiftUI

/// 「毎回確認」のシート(PageBoundaryChoiceSheet)へ並べられる選択肢。
/// FirstPageBehaviorとLastPageBehaviorが適合し、シート側は向きを知らずに済む。
protocol PageBoundaryChoice: Identifiable, Hashable {
    /// シートに並べる選択肢。「毎回確認」自身は含めない(シートの中でもう一度
    /// 「毎回確認」を選べても意味が無いため)。
    static var promptChoices: [Self] { get }
    /// シートを閉じるだけ(=何も起きない)選択肢。Escキーとシートの外側のクリックも
    /// これと同じ結果になるので、シートではこれにキャンセルのキー割り当てを与える。
    static var doNothing: Self { get }
    /// シートのボタンに出す名前。
    var titleKey: LocalizedStringKey { get }
}

/// 最初のページで「前のページへ」の操作をしたときの挙動。
///
/// 「前のページへ」は**物語的に1つ戻る**操作すべてを指す。右開き(RTL)の本で画面右側の
/// ページへ移動する操作も、左開きで画面左側へ移動する操作も、どちらもここに含まれる
/// (判定はViewerViewModel.advance(forward:)が読み方向を吸収した後で行われる)。
///
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
///
/// 経緯: 以前は最初のページと最後のページで共通の`LoopBehavior`を1つだけ持っていたが、
/// 「最後のページでだけ本を閉じたい」のような組み合わせが表現できなかったため、
/// ユーザー要望により前後それぞれの設定へ分離した(移行はAppPreferences.init参照)。
enum FirstPageBehavior: String, CaseIterable, Identifiable, Codable, Hashable, PageBoundaryChoice {
    /// 同じ本の最後のページへループする
    case loop
    /// 前の本を開き、その最後のページから読む
    case previousBookLastPage
    /// 前の本を開く(その本の続きから。どこから始まるかは環境設定「開始ページ」に従う)
    case previousBook
    /// 何もしない(最初のページで止まる)
    case none
    /// そのつどシートで尋ねる
    case ask

    var id: String { rawValue }

    static var promptChoices: [FirstPageBehavior] { allCases.filter { $0 != .ask } }
    static var doNothing: FirstPageBehavior { .none }

    var titleKey: LocalizedStringKey {
        switch self {
        case .loop: return "Loop"
        case .previousBookLastPage: return "Go to Previous Book's Last Page"
        case .previousBook: return "Previous Book"
        case .none: return "Do Nothing"
        case .ask: return "Ask Each Time"
        }
    }
}

/// 最後のページで「次のページへ」の操作をしたときの挙動。
/// 「次のページへ」の範囲の考え方は`FirstPageBehavior`と同じ(あちらのコメント参照)。
enum LastPageBehavior: String, CaseIterable, Identifiable, Codable, Hashable, PageBoundaryChoice {
    /// 同じ本の最初のページへループする
    case loop
    /// 次の本を開き、その最初のページから読む
    case nextBookFirstPage
    /// 次の本を開く(その本の続きから。どこから始まるかは環境設定「開始ページ」に従う)
    case nextBook
    /// 本を閉じる。ViewerAction.closeTabと同じ経路で、このタブ1枚だけを確認なしで閉じる
    /// (タブが1枚だけならウインドウごと閉じる)。ウインドウを残したい場合は
    /// `returnToWelcome`のほう。
    case closeBook
    /// 本だけ閉じて、同じウインドウにウェルカム画面を出す(AppState.closeBook())
    case returnToWelcome
    /// 何もしない(最後のページで止まる)
    case none
    /// そのつどシートで尋ねる
    case ask

    var id: String { rawValue }

    static var promptChoices: [LastPageBehavior] { allCases.filter { $0 != .ask } }
    static var doNothing: LastPageBehavior { .none }

    var titleKey: LocalizedStringKey {
        switch self {
        case .loop: return "Loop"
        case .nextBookFirstPage: return "Go to Next Book's First Page"
        case .nextBook: return "Next Book"
        case .closeBook: return "Close Book"
        case .returnToWelcome: return "Return to Welcome Screen"
        case .none: return "Do Nothing"
        case .ask: return "Ask Each Time"
        }
    }
}

/// 最初/最後のページの境界処理のうち、ViewerViewModel自身では行えないもの
/// (別の本を開く・タブを閉じる・ウェルカム画面へ戻る)をViewerViewへ依頼するための要求。
/// ViewerViewModel.onPageBoundaryRequest参照。
enum PageBoundaryRequest: Equatable {
    /// 隣の本を開く。
    /// - Parameter forward: trueなら次の本、falseなら前の本。
    /// - Parameter landsOnEdge: trueなら、読書位置の記憶や環境設定「開始ページ」より優先して
    ///   「次の本の最初のページ」「前の本の最後のページ」へ着地させる(AppState.PendingInitialEdge参照)。
    case openSiblingBook(forward: Bool, landsOnEdge: Bool)
    /// 本を閉じる(LastPageBehavior.closeBook参照)
    case closeBook
    /// 本だけ閉じてウェルカム画面へ戻る(LastPageBehavior.returnToWelcome参照)
    case returnToWelcome
}

/// 本を開いた直後に、保存された読書位置や環境設定「開始ページ」より優先して着地させる端。
/// 「次の本の最初のページへ」「前の本の最後のページへ」のためだけにある。
/// 積むのはAppState(`pendingInitialEdge`)、実際に読むのはViewerViewModel.init。
enum InitialPageEdge: Equatable {
    /// その本の最初のページ
    case first
    /// その本の最後のページ
    case last
}
