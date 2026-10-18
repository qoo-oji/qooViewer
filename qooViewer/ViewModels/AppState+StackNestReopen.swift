import Foundation
import StackNestViewerKit

extension AppState {
    /// 同じ本(同じパス)を表示しているこのウインドウを、ほかの「開く」が前へ出すときに呼ぶ(前へ出すのは呼び出し側)。
    /// StackNest の参照ファイルの本で、ファイルの中身(鍵)が表示中の本と違えば、このウインドウで読み込み直す。
    /// 中身が同じなら何もしない(前へ出すだけ。今までどおり)。参照ファイルでない本も何もしない。
    ///
    /// ■ なぜ
    /// StackNest は開き直すたびに同じパスへ新しい鍵で参照ファイルを書き直す。施錠を変えた後は古い鍵が断られ、部品の案内は
    /// 「StackNest から開き直して」と言う。同じ本を表示しているウインドウを前へ出すだけだと新しい参照が読まれず、そのビューアは
    /// 止まった古いセッションのまま、ページは黒く案内も出ない。このウインドウ自身へ
    /// 開く道(「今のウインドウで開く」)は ContentView が `MangaBook.viewerIdentity` で受け渡し直す。ここは、ほかのウインドウが
    /// 「もう開いている」として前へ出すだけの道(別のウインドウで表示中・「Finder から」が新しいタブ/ウインドウ・新しいタブ/
    /// ウインドウで開く操作)を同じ結果にする。読み込み直す先はこのウインドウ: 呼び出し側のウインドウで開くと、同じ本が 2 つの
    /// ウインドウで開いてしまう(重複を防ぐ判定がある理由そのもの)。
    ///
    /// ■ 中身が同じなら読み込み直さない
    /// 同じ鍵で読み込み直しても新しいことは無い。その本に恒久的な失敗が記録されていれば、開くのに失敗して本が閉じてしまう。
    ///
    /// 参照ファイルは FileIO で読む(数百バイトだが、応答しないボリュームの上でもメインを止めない)ので、読み込み直すのは
    /// 前へ出した後になる。読む間は待ちの札(`waitingToOpen`)を出す。読めないファイルは今までどおり前へ出すだけ。
    /// 意図を取るのが読んだ後なのは、CLAUDE.md の「待ち始めるときに取る」の意図的な例外(下の「先に頼まれていた本を捨てない」)。
    ///
    /// ■ 読んでいる間に頼まれた本が勝つ・先に頼まれていた本を捨てない(2026-10-18 のレビュー)
    /// 読む前は今の意図を控えるだけにする(`openIntentWithoutClaiming()`)。以前は読む前に意図を取っていた(`beginOpenIntent()`)
    /// ので、読み直しが要らない(中身が同じ)ときでも、このウインドウで待っていた別の「開く」(兄弟の探索・遅いボリュームの本の
    /// 確かめ)が黙って捨てられた。読んだ後、控えが `isStillWanted(_:)` のまま(その間にこのウインドウで何も頼まれていない)で、
    /// 読み直しが要ると分かったときだけ意図を取り、`open(…intent:)` へ渡す。
    ///
    /// ■ 頼んだ側の指定は持ち込まない
    /// 要求は別のウインドウ(またはタブを作る入口)からのもの。その一覧の並び(`sequence`)・隣の本の端・スライドショーの指定を
    /// このウインドウの読み込み直しへ渡すと、このウインドウでスライドショーが始まったり、「次の本」がよその一覧をたどったりする。
    /// 読み込み直すのはこのウインドウの本なので、このウインドウの並び(`bookSequence`)を引き継ぐ。
    ///
    /// ■ 閉じかけのウインドウには読み込まない
    /// 読んでいる間にウインドウが閉じられたら(`hostWindow` が無い)何もしない。
    /// - Returns: 参照ファイルを読みに行ったときはその Task(試験が待つ)。参照ファイルの要求でない・本を表示していないなら nil。
    @discardableResult
    func reloadIfStackNestReferenceChanged(_ request: BookOpenRequest) -> Task<Void, Never>? {
        guard !request.bundlesMultipleImages, let url = request.primaryURL,
              isStackNestReferenceFile(url.lastPathComponent), currentBook != nil
        else { return nil }
        let noted = openIntentWithoutClaiming()
        // 呼び出し側はウインドウを見つけてから呼ぶ(hostWindow がある)。読んでいる間にそのウインドウが閉じられたら(弱い参照が
        // 外れる)読み込まない。ウインドウの無い AppState(試験)はこの確かめを飛ばす。
        let hadWindow = hostWindow != nil
        return Task { [weak self] in
            // 待つ間は窓の待ちの札を出す(数百バイトなのでふつうは札の出る前に終わる。応答しないボリュームの上でも何か出す ――
            // CLAUDE.md「A wait the user can feel shows something」)。
            guard let self else { return }
            let reference = await self.waitingToOpen {
                await FileIO.perform { try? StackNestBookReference.load(contentsOf: url) }
            }
            // 読んでいる間に、このウインドウで別の本が頼まれた・開いた・別の本へ替わった・閉じられたら何もしない(同じ本かは
            // openAppState(forBookAt:) と同じくパスで)。
            guard self.isStillWanted(noted), !hadWindow || self.hostWindow != nil, let reference,
                  let shown = self.currentBook,
                  shown.sourceURL.path == url.path,
                  Self.reloadsForStackNestReference(showing: shown, read: reference)
            else { return }
            let intent = self.beginOpenIntent()
            // このウインドウへ開く(ほかのウインドウを探さない)。
            self.open(
                request: BookOpenRequest(url, recordsInHistory: request.recordsInHistory, sequence: self.bookSequence),
                reusesExistingWindow: false, intent: intent
            )
        }
    }

    /// 表示中の本 `shown` と同じパスの参照ファイルを読んだ中身が `reference` のとき、読み込み直すか(`viewerIdentity` が
    /// 変わるか)。
    static func reloadsForStackNestReference(showing shown: MangaBook, read reference: StackNestBookReference) -> Bool {
        MangaBook.ViewerIdentity(
            id: shown.id, isInSecretFolder: shown.isInSecretFolder, stackNestReference: StackNestReferenceIdentity(reference)
        ) != shown.viewerIdentity
    }
}
