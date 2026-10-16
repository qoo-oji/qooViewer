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
    /// 前へ出した後になる。読めないファイルは今までどおり前へ出すだけ。
    /// - Returns: 参照ファイルを読みに行ったときはその Task(試験が待つ)。参照ファイルの要求でない・本を表示していないなら nil。
    @discardableResult
    func reloadIfStackNestReferenceChanged(
        _ request: BookOpenRequest, initialEdge: InitialPageEdge? = nil, startsSlideshow: Bool = false
    ) -> Task<Void, Never>? {
        guard !request.bundlesMultipleImages, let url = request.primaryURL,
              isStackNestReferenceFile(url.lastPathComponent), currentBook != nil
        else { return nil }
        return Task { [weak self] in
            let reference = await FileIO.perform { try? StackNestBookReference.load(contentsOf: url) }
            // 読んでいる間に、このウインドウが別の本へ替わっていたら何もしない(同じ本かは openAppState(forBookAt:) と同じくパスで)。
            guard let self, let reference, let shown = self.currentBook, shown.sourceURL.path == url.path,
                  Self.reloadsForStackNestReference(showing: shown, read: reference)
            else { return }
            // このウインドウへ開く(ほかのウインドウを探さない)。
            self.open(request: request, reusesExistingWindow: false, initialEdge: initialEdge, startsSlideshow: startsSlideshow)
        }
    }

    /// 表示中の本 `shown` と同じパスの参照ファイルを読んだ中身が `reference` のとき、読み込み直すか(`viewerIdentity` が
    /// 変わるか)。
    static func reloadsForStackNestReference(showing shown: MangaBook, read reference: StackNestBookReference) -> Bool {
        MangaBook.ViewerIdentity(id: shown.id, isInSecretFolder: shown.isInSecretFolder, stackNestReference: reference) != shown.viewerIdentity
    }
}
