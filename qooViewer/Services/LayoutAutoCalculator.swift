import Foundation

/// 設計コンセプト3.1節(現在の表示を基準に自動でレイアウトする)・3.3節(伝播範囲選択)で
/// 共通して使う、パリティ再計算アルゴリズム。
///
/// 基本方針: 既存の横長画像ヒューリスティック(ViewerViewModel.isWideImage/
/// shouldPairWithNextPage)を、単発の判定ではなく「範囲全体に対してあらかじめ計算し、
/// 結果をPageLayoutOverrideとして明示的に固定する」形に一般化したもの。
///
/// アルゴリズムの性質上、あるページが隣のページと組むかどうかは、そのページ自身の画像が
/// 横長かどうかだけで決まる(shouldPairWithNextPageと同じ判定)。パリティ計算は常に
/// 「起点(anchor)に隣接するページから、起点より遠いページへ向かって」伝播する
/// (ユーザー期待の挙動: 起点から前方・後方へそれぞれペアを広げていく)。そのため
/// 「起点より前のページ全体」を再計算する場合は、本の先頭から前方へシミュレーションする
/// のではなく、起点の直前のページから本の先頭へ向かって逆順にシミュレーションし
/// (simulateBackward参照)、端数が出る場合は起点から最も離れた位置(=本の先頭側)に
/// 単独ページとして押し出す。「起点より後のページ全体」は、逆に起点の直後のページから
/// 本の末尾へ向かって前方にシミュレーションする(simulateForward参照)。
nonisolated enum LayoutAutoCalculator {
    /// 現在表示されている組み合わせ(自動レイアウトの起点、3.1節)。
    /// 単ページ表示中、または見開き表示中でも実際には相手が見つからず1枚だけ表示されている
    /// 場合は1件、見開きで2ページとも表示されている場合は2件(読み順)。
    struct Anchor {
        let pageKeys: [String]
    }

    /// 再計算を行う。
    ///
    /// - orderedPageKeys: 本全体の、除外ページ(2.2節「除外」)を取り除いた後の、実際に読書
    ///   フローで使われる順序(2.3節のページ順補正を適用済みであること)。除外ページは
    ///   この配列に含めないこと(パリティ計算から除外するため。含めてしまうと巻き込まれて
    ///   単一/見開きの状態を書き込まれてしまう)。
    /// - anchor: 起点。wholeBookの場合、この起点自体の状態も明示的に結果に含める
    ///   (「今表示している組み合わせをそのまま基準にする」という3.1節の意図を反映する)。
    ///   beforeThisPage/afterThisPageの場合、起点自体は対象外(「このページより前/後」なので)。
    /// - scope: 伝播範囲。thisPageOnlyはこの関数を使わず呼び出し側で1ページ分を直接書き込む
    ///   運用のため、ここに渡された場合は空の結果を返す。
    /// - isWideImage: pageKeyに対応する画像が、見開き表示中でも単ページ扱いにすべき横長画像かどうか。
    ///   画像の読み込みは呼び出し側の責務とする(この関数自体は同期的な計算のみを行う)。
    /// - isRightToLeft: この本の読み方向(右開き=true、左開き=false)。ページの組を「見開き左/
    ///   見開き右」のどちらに割り当てるかを決める(下のsimulateForward/anchorPinのコメント参照)。
    ///
    /// - Returns: 書き込むべき[pageKey: PageLayoutState]。除外ページの状態を変更することは無い
    ///   (除外の設定・解除は別の操作(3.2節「除外(非表示)に設定する」)で行う)。
    static func recalculate(
        orderedPageKeys: [String],
        anchor: Anchor,
        scope: LayoutPropagationScope,
        isWideImage: (String) -> Bool,
        isRightToLeft: Bool
    ) -> [String: PageLayoutState] {
        guard let firstAnchorKey = anchor.pageKeys.first,
              let anchorStartIndex = orderedPageKeys.firstIndex(of: firstAnchorKey) else {
            return [:]
        }
        let anchorEndIndex = anchorStartIndex + anchor.pageKeys.count // exclusive

        // 「起点より前」は、起点に隣接するページ(anchorStartIndexの直前)から本の先頭へ
        // 向かって逆順にペアを広げていく(simulateBackward参照。ユーザー期待の挙動:
        // 端数は起点から最も離れた位置に押し出す)。
        let before = simulateBackward(
            orderedPageKeys: orderedPageKeys, upperBoundExclusive: anchorStartIndex,
            isWideImage: isWideImage, isRightToLeft: isRightToLeft
        )
        // 「起点より後」は、起点に隣接するページ(anchorEndIndex)から本の末尾へ向かって
        // 前方にペアを広げていく(simulateForward参照)。
        let after = simulateForward(
            orderedPageKeys: orderedPageKeys, from: anchorEndIndex, to: orderedPageKeys.count,
            isWideImage: isWideImage, isRightToLeft: isRightToLeft
        )

        switch scope {
        case .thisPageOnly:
            return [:]
        case .beforeThisPage:
            return before
        case .afterThisPage:
            return after
        case .wholeBook:
            var result = anchorPin(for: anchor, isRightToLeft: isRightToLeft)
            result.merge(before) { _, new in new }
            result.merge(after) { _, new in new }
            return result
        }
    }

    /// 起点自体(現在表示されている組み合わせ)を、そのまま明示的な状態として固定する。
    /// 2ページ表示の場合、読み順で先に読むページ(=画面上で最初に見えるページ)を「最初に
    /// 読むページの位置」、後で読むページを「2番目に読むページの位置」に割り当てる
    /// (simulateForwardのコメント参照)。1ページ表示なら単一ページとして書き込む。
    private static func anchorPin(for anchor: Anchor, isRightToLeft: Bool) -> [String: PageLayoutState] {
        if anchor.pageKeys.count >= 2, let earlier = anchor.pageKeys.first, let later = anchor.pageKeys.dropFirst().first {
            let earlierState: PageLayoutState = isRightToLeft ? .spreadRight : .spreadLeft
            let laterState: PageLayoutState = isRightToLeft ? .spreadLeft : .spreadRight
            return [earlier: earlierState, later: laterState]
        } else if let only = anchor.pageKeys.first {
            return [only: .single]
        }
        return [:]
    }

    /// [from, to)の範囲を、先頭から順にヒューリスティックでパリティ計算する。
    ///
    /// 各位置(cursor)について:
    /// - その画像が横長(isWideImage)なら単一ページとして確定し、1つだけ進む。
    /// - そうでなく、かつ次の位置がまだ範囲内(to未満)、かつ次のページ自身も横長でなければ、
    ///   その2ページを見開き左/右のペアとして確定し、2つ進む。
    /// - そうでなく(相手が見つからない、または相手が横長画像である)、単一ページとして確定し、
    ///   1つだけ進む(3.1節「端数が出た場合のフォールバック」。相手が横長の場合、その相手自身は
    ///   次のcursorで改めて評価され、横長ゆえに単独で単一ページとして確定する)。
    ///
    /// 横長画像は常に単独ページとして扱う(見開きの相手にしない)という制約は、cursor自身が
    /// 横長の場合だけでなく、ペア候補となる「次のページ」が横長の場合にも及ぶ。以前は
    /// cursor自身の横長判定しか行っておらず、縦長ページの直後に横長ページが来ると、その横長
    /// ページを見開き右として無理やりペアにしてしまう不具合があった(ユーザー報告の決定表:
    /// 「1ページ後(A+1)が横長の場合、(A)は単一ページ・レイアウトなし・除外の3つしか選べない」
    /// =横長ページを相手にした見開きは常に不成立であるべき)。
    ///
    /// recalculateからは「起点より後」の範囲(from: anchorEndIndex)にのみ使う。「起点より前」の
    /// 範囲はsimulateBackward(起点に隣接する側から逆順に辻褄を合わせる)を使う
    /// (ファイル冒頭のコメント参照。以前はこちらも「起点より前」に使っており、本の先頭から
    /// 前方に辻褄を合わせていたため、端数となる単独ページが起点のすぐ隣に生まれてしまう
    /// 不具合があった。ユーザー報告: 起点として指定したページのすぐ前のページが、意図せず
    /// 単独ページになってしまう)。
    ///
    /// ペアが確定した際、cursor側(読み順で先に読むページ)とpartner側(2番目に読むページ)への
    /// 「見開き左/見開き右」の割り当ては、読み方向(isRightToLeft)に応じて決める。
    ///
    /// 経緯: 以前はisRightToLeftに関わらず常にcursor→見開き左、partner→見開き右と固定で
    /// 割り当てていた。この「見開き左/見開き右」は元々「(cursor側)常に次のページと組む=
    /// 見開きの起点(最初に読むページ)」「(partner側)常に直前のページと組む」という読み順上の
    /// 意味で設計されていたが、実際の画面表示(ViewerView.orderedCurrentImages)は読み方向に
    /// 応じてファイル順を反転させて並べるため、右開き(RTL)の本では「最初に読むページ」が
    /// 画面の右側に表示される。そのため右開きの本で自動レイアウトを実行すると、実際には画面の
    /// 右に表示されているページの設定が「見開き左」に、画面の左に表示されているページの設定が
    /// 「見開き右」になるという食い違いが生じていた(ユーザー報告)。読み方向を考慮し、
    /// 「見開き右/見開き左」のラベルが常に実際の画面上の右/左と一致するようにする
    /// (右開き: cursor(先に読む=画面右)→見開き右、partner(後に読む=画面左)→見開き左。
    /// 左開き: 従来通りcursor→見開き左、partner→見開き右)。
    private static func simulateForward(
        orderedPageKeys: [String],
        from startIndex: Int,
        to endIndex: Int,
        isWideImage: (String) -> Bool,
        isRightToLeft: Bool
    ) -> [String: PageLayoutState] {
        guard startIndex < endIndex, endIndex <= orderedPageKeys.count, startIndex >= 0 else { return [:] }

        let cursorState: PageLayoutState = isRightToLeft ? .spreadRight : .spreadLeft
        let partnerState: PageLayoutState = isRightToLeft ? .spreadLeft : .spreadRight

        var result: [String: PageLayoutState] = [:]
        var cursor = startIndex
        while cursor < endIndex {
            let key = orderedPageKeys[cursor]
            if isWideImage(key) {
                result[key] = .single
                cursor += 1
                continue
            }
            let partnerIndex = cursor + 1
            if partnerIndex < endIndex, !isWideImage(orderedPageKeys[partnerIndex]) {
                result[key] = cursorState
                result[orderedPageKeys[partnerIndex]] = partnerState
                cursor += 2
            } else {
                result[key] = .single
                cursor += 1
            }
        }
        return result
    }

    /// [0, upperBoundExclusive)の範囲を、末尾(upperBoundExclusive - 1、=起点の直前のページ)
    /// から先頭(本の最初のページ)へ向かって逆順にヒューリスティックでパリティ計算する。
    /// recalculateの「起点より前」の計算に使う(ファイル冒頭のコメント参照)。
    ///
    /// 判定基準(横長画像は常に単独ページとして扱う、等)はsimulateForwardと全く同じで、
    /// 走査する順序(末尾から先頭へ)だけが異なる。起点に隣接するページ同士を先にペアにして
    /// いき、端数が出る場合は本の先頭側(=起点から最も離れた位置)に単独ページとして押し
    /// 出す。
    ///
    /// 経緯(ユーザー報告): 以前はこの「起点より前」の計算もsimulateForward(本の先頭から
    /// 前方へ)を使っていたため、範囲内のページ数が奇数だと、端数の単独ページが起点のすぐ
    /// 隣に生まれてしまっていた(例: 起点を9ページ目に設定して自動レイアウトを実行すると、
    /// 8ページ目ではなくその手前の7ページ目が意図せず単独ページになる)。「自動レイアウト
    /// 計算は起点から前方・後方へそれぞれペアにしていく挙動が期待」というユーザー指摘を
    /// 受け、この関数を新設して差し替えた。
    ///
    /// ペアが確定した際、cursor(走査上は後ろ側、=読み順ではpartnerIndexより後)とpartner
    /// (走査上は前側、=読み順ではcursorより前)への「見開き左/見開き右」の割り当ては、
    /// simulateForwardと同じく「読み順で先に読むページ」にcursorStateを割り当てる
    /// (partnerIndexの方が読み順で先なのでcursorState、cursor自身にはpartnerState。
    /// simulateForwardとは変数名の対応が逆になる点に注意)。
    private static func simulateBackward(
        orderedPageKeys: [String],
        upperBoundExclusive: Int,
        isWideImage: (String) -> Bool,
        isRightToLeft: Bool
    ) -> [String: PageLayoutState] {
        guard upperBoundExclusive > 0, upperBoundExclusive <= orderedPageKeys.count else { return [:] }

        let cursorState: PageLayoutState = isRightToLeft ? .spreadRight : .spreadLeft
        let partnerState: PageLayoutState = isRightToLeft ? .spreadLeft : .spreadRight

        var result: [String: PageLayoutState] = [:]
        var cursor = upperBoundExclusive - 1
        while cursor >= 0 {
            let key = orderedPageKeys[cursor]
            if isWideImage(key) {
                result[key] = .single
                cursor -= 1
                continue
            }
            let partnerIndex = cursor - 1
            if partnerIndex >= 0, !isWideImage(orderedPageKeys[partnerIndex]) {
                // partnerIndexの方が読み順で先(cursorより手前)なのでcursorStateを割り当てる。
                result[orderedPageKeys[partnerIndex]] = cursorState
                result[key] = partnerState
                cursor -= 2
            } else {
                result[key] = .single
                cursor -= 1
            }
        }
        return result
    }
}
