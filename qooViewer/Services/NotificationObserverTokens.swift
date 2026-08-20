import Foundation

/// NotificationCenterの購読トークンをまとめて持ち、まとめて解除するための小さな箱。
///
/// ■ なぜ参照型を挟むのか(重要。ローカルのvarに戻さないこと)
/// このアプリには「ウインドウが閉じたら、その閉じるイベントの購読自身も含めて全部
/// removeObserverする」という後始末が何箇所かある(ContentView.observeMainWindowFrameChanges /
/// observeWindowBecameKey、ViewerView.setUpWindowObserversの末尾、AppDelegateの
/// 主ウインドウのフレーム記憶)。これを素直に書くと、
///
/// ```swift
/// var closeToken: NSObjectProtocol?
/// closeToken = NotificationCenter.default.addObserver(...) { _ in
///     if let closeToken { NotificationCenter.default.removeObserver(closeToken) }
/// }
/// ```
///
/// のように、ローカルの`var`をエスケープするクロージャがキャプチャして読み書きする形になる。
/// Swift 6の並行性チェックはこれを
/// 「'closeToken' mutated after capture by sendable closure」および
/// 「capture of 'closeToken' with non-Sendable type '(any NSObjectProtocol)?' in a '@Sendable'
/// closure」として警告する。クロージャが別スレッドで走らないことを型の上では否定できないためで、
/// 実際には`queue: .main`で登録しているので起こり得ないのだが、コンパイラにそれを伝える手段が
/// この形には無い。
///
/// 状態の持ち主を参照型へ移すと、クロージャがキャプチャするのは不変の参照1つだけになり、
/// 警告の前提そのものが消える。
///
/// ■ なぜ@MainActorなのか
/// 登録も解除もすべてメインスレッド(`queue: .main`)で行われる。@MainActorにしておくと
/// このクラス自体が暗黙にSendableになるため、`@Sendable`なクロージャから安全にキャプチャできる。
/// クロージャの中身は静的にはMainActor隔離だと分からないので、アクセスは
/// `MainActor.assumeIsolated`越しに行う(プロジェクト内の同種の箇所と同じ対処)。
@MainActor
final class NotificationObserverTokens {
    private var tokens: [NSObjectProtocol] = []

    init() {}

    /// 購読トークンを預ける。`addObserver`の戻り値をそのまま渡す。
    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    /// 複数のトークンをまとめて預ける。
    func add(contentsOf newTokens: [NSObjectProtocol]) {
        tokens.append(contentsOf: newTokens)
    }

    /// 預かっているトークンをすべて解除して空にする。
    ///
    /// 「自分自身を解除する購読」からそのまま呼んでよい。先に配列を空にしてから解除するため、
    /// 解除の途中で再入しても二重解除にはならない。何度呼んでも安全(2回目以降は何もしない)。
    func removeAll() {
        let pending = tokens
        tokens = []
        for token in pending {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
