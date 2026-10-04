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

    /// 編集メニューに出す名前(「コレクションの削除」など。メニューは「%@を取り消す」で包む)。
    private(set) var undoTitle: String?
    private(set) var redoTitle: String?

    @ObservationIgnored private var undoSteps: [any DataUndoStep] = []
    @ObservationIgnored private var redoSteps: [any DataUndoStep] = []

    /// 削除を済ませた後に積む。新しい操作をしたらやり直し先は捨てる。
    func push(_ step: any DataUndoStep) {
        for dropped in redoSteps { dropped.discard() }
        redoSteps.removeAll()
        undoSteps.append(step)
        if undoSteps.count > Self.depth { undoSteps.removeFirst().discard() }
        publish()
    }

    /// ⌘Z。戻せなかった(相手が別の操作で消えていた等)ときは、その操作を捨てる。
    func undo() {
        guard let step = undoSteps.popLast() else { return }
        if step.undo() {
            redoSteps.append(step)
        } else {
            step.discard()
            NSSound.beep()
        }
        publish()
    }

    /// ⇧⌘Z。
    func redo() {
        guard let step = redoSteps.popLast() else { return }
        if step.redo() {
            undoSteps.append(step)
        } else {
            step.discard()
            NSSound.beep()
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
        for step in dropped { step.discard() }
        publish()
    }

    private func publish() {
        let undo = undoSteps.last?.title
        let redo = redoSteps.last?.title
        if undo != undoTitle { undoTitle = undo }
        if redo != redoTitle { redoTitle = redo }
    }
}

/// 取り消せる削除 1 回分。消す前に控えた値を持ち、書き戻す・もう一度消すことができる。
@MainActor
protocol DataUndoStep: AnyObject {
    /// 編集メニューに出す名前(表示言語で引いたもの)。
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
