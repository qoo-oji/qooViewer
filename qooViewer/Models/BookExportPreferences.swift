import SwiftUI

/// 書き出した本をどこへ置くか(形式ごとに設定する。環境設定「レイアウト」)。
///
/// ユーザー要望の中心にあるのは「新しい本を開く → 右クリックから書き出す → そのまま次の本を
/// 開く」を繰り返せることで、そのためには**書き出しの操作中に何も尋ねられない**必要がある。
/// `fixedFolder`はそのための設定で、保存先フォルダを1回だけ選んでおけば、以降その形式の
/// 書き出しは全部そのフォルダへ行く。
enum BookExportDestinationMode: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 書き出すたびに、保存先とオプションを尋ねるシートを出す(既定)。
    case askEachTime
    /// あらかじめ決めておいた1つのフォルダへ、何も尋ねずに書き出す。
    case fixedFolder

    var id: String { rawValue }
}

/// 書き出しが終わった本について、アプリが保存しているものをどうするか(形式ごと・
/// 「保存データ」と「履歴」それぞれに設定する。環境設定「レイアウト」)。
///
/// 「読み終わった本をEPUBへ移して元のファイルは捨てる」といった使い方では、書き出した後の
/// 本のレイアウトや読書位置がDBに残り続けても意味が無い。とはいえ**消してしまうと戻せない**
/// ので、既定は`keep`(何もしない)にしてある。
enum BookExportCleanup: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 何もしない(既定)。
    case keep
    /// 削除する。
    case delete

    var id: String { rawValue }
}

/// レイアウトの保存データを持っていない本を開いたときに、自動でレイアウトを計算するかどうか
/// (環境設定「レイアウト」)。
///
/// 自動レイアウトそのものは、右クリック→「レイアウト」→「現在の表示を基準に自動でレイアウト」
/// と同じ計算(`LayoutAutoCalculator`)を**本全体**に対して行う。違うのは起点(anchor)だけで、
/// ここでは1ページ目をどう置くかだけを指定する。
///
/// EPUB/PDFのように、ファイル自身がレイアウトを持っている本は対象にならない。それらは本を
/// 初めて開いた時点で`LayoutStore.importSourceLayoutIfNeeded(for:)`がDBへ取り込むため、
/// この判定を行う時点では既に「レイアウトの保存データを持っている本」になっている。
enum MissingLayoutAutoLayout: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 何もしない(既定)。これまでどおり、横長判定によるその場の見開き判定だけで表示する。
    case none
    /// 1ページ目を単ページとして、本全体を自動レイアウトする。
    case firstPageSingle
    /// 1ページ目を見開きの1枚目(2ページ目と組む)として、本全体を自動レイアウトする。
    case firstPageSpread

    var id: String { rawValue }
}

/// 右クリックの「本の書き出し」で、いま開いている本の書き出しが終わったあとの動作
/// (環境設定「レイアウト」)。
///
/// 選択肢と文言は、環境設定「閲覧中の動作」の「最後のページで」(`LastPageBehavior`)と
/// **意図的に同じ**にしてある。どちらも「この本を読み終えた/片付けた。次はどうするか」という
/// 同じ問いで、ユーザーが既に片方で選んだことのある語がそのまま使える。
/// `loop`(同じ本の最初のページへ)だけは、書き出しの後には意味が無いので持たない。
///
/// `PageBoundaryChoice`に適合しているのは、「毎回確認」のシートを`LastPageBehavior`と
/// 同じ`PageBoundaryChoiceSheet`で出すため(選択肢の正典がこの列挙型1つで済む)。
enum BookExportCompletionBehavior: String, CaseIterable, Identifiable, Codable, Hashable, PageBoundaryChoice {
    /// 何もしない(既定)。書き出した本をそのまま読み続ける。
    case none
    /// 次の本を開き、その最初のページから読む。
    case nextBookFirstPage
    /// 次の本を開く(その本の続きから。どこから始まるかは環境設定「開始ページ」に従う)。
    case nextBook
    /// 本を閉じる。`ViewerAction.closeTab`と同じ経路で、このタブ1枚だけを確認なしで閉じる
    /// (タブが1枚だけならウインドウごと)。ウインドウを残したい場合は`returnToWelcome`のほう。
    case closeBook
    /// 本だけ閉じて、同じウインドウにウェルカム画面を出す(`AppState.closeBook()`)。
    case returnToWelcome
    /// そのつどシートで尋ねる。
    case ask

    var id: String { rawValue }

    static var promptChoices: [BookExportCompletionBehavior] { allCases.filter { $0 != .ask } }
    static var doNothing: BookExportCompletionBehavior { .none }

    /// 「毎回確認」のシートに出すボタン名。`LastPageBehavior`と同じ文字列カタログのキーを
    /// 使い回している(同じ意味のものを別の語で呼ばないため。UI文言の用語表)。
    var titleKey: LocalizedStringKey {
        switch self {
        case .none: "Do Nothing"
        case .nextBookFirstPage: "Go to Next Book's First Page"
        case .nextBook: "Next Book"
        case .closeBook: "Close Book"
        case .returnToWelcome: "Return to Welcome Screen"
        case .ask: "Ask Each Time"
        }
    }
}
