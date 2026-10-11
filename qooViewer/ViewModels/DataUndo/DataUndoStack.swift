import Observation
import SwiftUI

/// 保存データの削除の取り消し・やり直しの積み場所(2026-09-27、監査 34)。
///
/// 対象はブックマークの削除・履歴の削除・コレクションとライブラリの削除・コレクションからの削除。ファイル操作の
/// `FileCommandStack` とは別にしてある ―― あちらは非同期で途中で失敗しうる操作のための作りで、こちらは消す前に控えた値を
/// 書き戻すだけの同期の操作。`NSUndoManager` を使わないのも同じ理由(`FileCommand` の型コメント)。
///
/// **本のウインドウ(ホームとビューア)ごとに 1 つ**(`AppState.dataUndo`)。見えていない所の変更を ⌘Z で戻さないため
/// (`FileCommandStack` と同じ考え方)。ブックマーク・レイアウトの編集と履歴の削除のウインドウは、それぞれ自分のものを持つ
/// (`DataUndoRouter`)。どの画面からも環境値 `\.dataUndoStack` で受け取る。
///
/// ウインドウを閉じると積んだものは消える。本のウインドウではこの積み場所ごと(`AppState` と一緒に)手放され、そのとき削除した
/// ままになっていたコレクションの表紙のファイルは、次の起動の掃除(`CollectionStore.sweepOrphanedCovers`)が消す。道具のウインドウ
/// (`Window` シーン)は閉じても積み場所が残るので、閉じたときに `removeAll()` で空にする(2026-10-04 の監査 BE-11)。
@MainActor @Observable
final class DataUndoStack {
    /// 積む深さ。超えたら古いものから捨てる(`FileCommandStack.depth` と同じ)。
    static let depth = 50

    /// 一番上の操作(編集メニューが読む)。
    struct Top: Equatable {
        /// 編集メニューに出す名前(「コレクションの削除」など。メニューは「%@を取り消す」で包む)。
        let title: String
        /// ファイルブラウザが出ている画面で積んだか(`recordsOnFileBrowserScreen`)。
        let isFromFileBrowserScreen: Bool
        /// 積んだ・戻した・やり直した時の新しさ(`UndoRecency`)。
        let recency: Int
    }

    private(set) var undoTop: Top?
    private(set) var redoTop: Top?

    /// 編集メニューに出す名前(「コレクションの削除」など。メニューは「%@を取り消す」で包む)。
    var undoTitle: String? { undoTop?.title }
    var redoTitle: String? { redoTop?.title }

    /// 積むときに「ファイルブラウザが出ている画面で積んだか」を答える(本のウインドウの積み場所だけ。AppState が入れる)。
    ///
    /// **編集メニューの振り分けに使う**(2026-10-04 の監査 M-2、§3 の決定 13「表示中の画面が積んだかどうかで振り分ける」)。
    /// ファイルブラウザが出ている間の ⌘Z はファイル操作の取り消しへ流す(docs/09「見えている所の操作を戻す」)が、その画面にも
    /// 削除の入口がある ―― 帯のライブラリの「削除…」・履歴の吹き出しの削除・メニューの「メニューを消去」/「ライブラリを削除…」。
    /// 以前はファイルブラウザが出ている間は削除の積み場所を一切見ず、確認文の「取り消すで取り消せます」が守られなかった
    /// (本棚・ビューアへ移ったときに初めて「取り消す」に現れ、前触れなく戻った)。いまは、その画面で積んだものだけを出す。
    @ObservationIgnored var recordsOnFileBrowserScreen: @MainActor () -> Bool = { false }

    private struct Entry {
        let step: any DataUndoStep
        let isFromFileBrowserScreen: Bool
        let recency: Int
    }

    @ObservationIgnored private var undoSteps: [Entry] = []
    @ObservationIgnored private var redoSteps: [Entry] = []

    /// 削除を済ませた後に積む。新しい操作をしたらやり直し先は捨てる。
    func push(_ step: any DataUndoStep) {
        for dropped in redoSteps { dropped.step.discard() }
        redoSteps.removeAll()
        undoSteps.append(Entry(step: step, isFromFileBrowserScreen: recordsOnFileBrowserScreen(), recency: UndoRecency.next()))
        if undoSteps.count > Self.depth { undoSteps.removeFirst().step.discard() }
        publish()
    }

    /// ⌘Z。戻せなかった(相手が別の操作で消えていた等)ときは、その操作を捨てる。
    func undo() {
        guard let entry = undoSteps.popLast() else { return }
        if entry.step.undo() {
            // 戻したことが「いちばん新しい操作」(⇧⌘Z でファイル操作のやり直しと比べるとき)。積んだ画面はそのまま。
            redoSteps.append(Entry(step: entry.step, isFromFileBrowserScreen: entry.isFromFileBrowserScreen, recency: UndoRecency.next()))
        } else {
            entry.step.discard()
            UserFeedback.beep()
        }
        publish()
    }

    /// ⇧⌘Z。
    func redo() {
        guard let entry = redoSteps.popLast() else { return }
        if entry.step.redo() {
            undoSteps.append(Entry(step: entry.step, isFromFileBrowserScreen: entry.isFromFileBrowserScreen, recency: UndoRecency.next()))
        } else {
            entry.step.discard()
            UserFeedback.beep()
        }
        publish()
    }

    /// 積んだものをすべて捨てる(道具のウインドウを閉じたとき。`OwnsDataUndoStack`)。捨てる操作の後片付け(`discard`)も済ませる
    /// ―― 深さを超えて落ちたときと同じ扱い。
    func removeAll() {
        guard !undoSteps.isEmpty || !redoSteps.isEmpty else { return }
        let dropped = undoSteps + redoSteps
        undoSteps.removeAll()
        redoSteps.removeAll()
        for entry in dropped { entry.step.discard() }
        publish()
    }

    private func publish() {
        let undo = undoSteps.last.map { Top(title: $0.step.title, isFromFileBrowserScreen: $0.isFromFileBrowserScreen, recency: $0.recency) }
        let redo = redoSteps.last.map { Top(title: $0.step.title, isFromFileBrowserScreen: $0.isFromFileBrowserScreen, recency: $0.recency) }
        if undo != undoTop { undoTop = undo }
        if redo != redoTop { redoTop = redo }
    }
}

/// 取り消せる操作の新しさの通し番号(アプリ全体で 1 つ)。編集メニューが、ファイル操作の取り消し(`FileCommandStack`)と削除の取り消し
/// (`DataUndoStack`)の一番上のどちらが新しいかを比べるのに使う(2026-10-04 の監査 M-2)。積んだ・戻した・やり直したときに取る。
@MainActor
enum UndoRecency {
    private static var counter = 0

    static func next() -> Int {
        counter &+= 1
        return counter
    }
}

/// ホームのウインドウの編集メニューの「取り消す」「やり直す」を、削除の積み場所とファイル操作のどちらへ流すか
/// (2026-10-04 の監査 M-2、§3 の決定 13)。
///
/// - ファイルブラウザが出ていない: 削除の積み場所(ファイル操作は出ていない画面のものなので出さない。今までどおり)。
/// - ファイルブラウザが出ている: **その画面で積んだ削除**(帯・吹き出し・メニュー)とファイル操作のうち、新しいほう。ほかの画面
///   (本棚・ビューア)で積んだ削除は、その画面へ戻るまで出さない(見えていない所の操作を戻さない ―― docs/09)。
enum DataUndoMenuRoute: Equatable {
    case data
    case fileBrowser

    /// - Parameters:
    ///   - data: 削除の積み場所の一番上(取り消しなら `undoTop`、やり直しなら `redoTop`)。
    ///   - fileBrowserRecency: ファイル操作の一番上の新しさ(取り消せる・やり直せるものが無ければ nil)。
    static func choose(data: DataUndoStack.Top?, fileBrowserShown: Bool, fileBrowserRecency: Int?) -> DataUndoMenuRoute? {
        guard fileBrowserShown else {
            if data != nil { return .data }
            return fileBrowserRecency != nil ? .fileBrowser : nil
        }
        let ownData = data.flatMap { $0.isFromFileBrowserScreen ? $0 : nil }
        switch (ownData, fileBrowserRecency) {
        case (nil, nil): return nil
        case (.some, nil): return .data
        case (nil, .some): return .fileBrowser
        case let (.some(top), .some(recency)): return top.recency > recency ? .data : .fileBrowser
        }
    }
}

/// 取り消せる削除 1 回分。消す前に控えた値を持ち、書き戻す・もう一度消すことができる。
@MainActor
protocol DataUndoStep: AnyObject {
    /// 編集メニューに出す名前。**メニューバーの言語**(`AppLanguage.menuBarLocale` = 起動時の言語)で引く ―― メニューの「%@を取り消す」の
    /// 枠は起動時の言語なので、表示言語で引くと実行中に切り替えたときに枠と中身の言語が混ざる(2026-10-04 の監査 M-7)。
    var title: String { get }
    /// 書き戻す。戻せなかったら false(その操作は捨てられる)。
    func undo() -> Bool
    /// もう一度消す。
    func redo() -> Bool
    /// 積み場所から捨てられる(深さを超えた・やり直し先が捨てられた)。削除したままなら、後回しにしていた後片付け
    /// (コレクションの表紙のファイルを消す)をここで済ませる。
    func discard()
}

/// 本のウインドウに属さない道具のウインドウ(ブックマーク・レイアウトの編集、履歴の削除)の取り消しを、編集メニューへ
/// 渡すための仲立ち。窓がキーになったときに自分の積み場所を入れ、キーでなくなったら外す(`MetadataEditorUndoRouter` と同じ形)。
@MainActor @Observable
final class DataUndoRouter {
    static let shared = DataUndoRouter()
    weak var stack: DataUndoStack?

    /// 窓の `controlActiveState` の変化で呼ぶ。
    func windowKeyStateChanged(_ state: ControlActiveState, stack: DataUndoStack) {
        if state == .key {
            self.stack = stack
        } else if self.stack === stack {
            self.stack = nil
        }
    }
}

extension EnvironmentValues {
    /// このウインドウの削除の取り消しの積み場所(`DataUndoStack`)。本のウインドウでは `ContentView` が `AppState.dataUndo` を、
    /// 道具のウインドウでは自分のものを入れる。nil なら積まない(取り消せない削除として従来どおり動く)。
    @Entry var dataUndoStack: DataUndoStack?
}

extension View {
    /// 本のウインドウに属さない道具のウインドウに、自分の削除の取り消しの積み場所を持たせる(ブックマーク・レイアウトの編集、
    /// 履歴の削除)。窓がキーの間だけ `DataUndoRouter` から編集メニューへつながる。
    func ownsDataUndoStack() -> some View {
        modifier(OwnsDataUndoStack())
    }
}

private struct OwnsDataUndoStack: ViewModifier {
    @State private var stack = DataUndoStack()
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .environment(\.dataUndoStack, stack)
            .onChange(of: controlActiveState, initial: true) { _, state in
                DataUndoRouter.shared.windowKeyStateChanged(state, stack: stack)
            }
            .onDisappear {
                if DataUndoRouter.shared.stack === stack { DataUndoRouter.shared.stack = nil }
            }
            // **閉じたら積んだものを捨てる**(2026-10-04 の監査 BE-11。docs/09「ウインドウを閉じると消える」)。`Window` シーンは閉じても
            // `@State` を保つので、以前はこの積み場所が残り、閉じて開き直した窓で ⌘Z を押すと以前の削除が戻った(実測)。閉じたことは
            // onDisappear だけでなく窓の willClose でも受ける(View.auxiliaryWindowPresence)。
            .auxiliaryWindowPresence { presented in
                guard !presented else { return }
                if DataUndoRouter.shared.stack === stack { DataUndoRouter.shared.stack = nil }
                stack.removeAll()
            }
    }
}
