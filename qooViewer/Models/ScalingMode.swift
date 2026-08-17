import SwiftUI

/// ページ画像をウインドウに対してどう拡大縮小して表示するか
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
enum ScalingMode: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 画面内に収める(縦横とも画面に収まるように拡大縮小。cooViewerの「画面内に収める」相当)
    case fitToScreen
    /// 横幅に合わせる(横幅基準で拡大縮小し、縦が画面より長ければ縦スクロール)
    case fitWidth
    /// 「横幅に合わせる(単ページ)」(cooViewerの「見開き分割」= Fit to Screen Width(divide) 相当)。
    ///
    /// ■ 名前について
    /// ケース名は仕組み(fitWidthを半分の幅に対して行う)を表す`fitWidthSplit`のままだが、
    /// **画面に出る名前は「横幅に合わせる(単ページ)」**である。cooViewer由来の「見開き分割」
    /// という表示名は、「1枚の画像を2ページに分割する」機能だと強く誤解させるため採用しなかった
    /// (実際にその誤解が起きた)。この機能は画像を切らないし、ページ数も変わらない。
    /// fitWidthとの違いは「表示中の内容の**全体**の横幅を画面幅に合わせるか、**半分**の横幅を
    /// 合わせるか」の一点だけで、その半分がちょうど1ページ分にあたることが名前の由来。
    /// (rawValueは永続化に使われるため、表示名の変更に合わせて改名はしていない。)
    ///
    /// 画像を実際に2ページへ切り分ける機能ではない。表示中の内容(単ページ表示中の横長画像、
    /// または見開き表示で2ページを合成した状態)の**横幅の半分**が画面幅いっぱいになる倍率まで
    /// 拡大し、はみ出した分を左右スクロールで読ませる拡大縮小モードである
    /// (ページ番号も総ページ数も変化しない)。見開きスキャンや見開きページを、片側ずつ
    /// 画面幅いっぱいで大きく読むためのもの。
    ///
    /// 分割する意味が無い内容(単ページ表示中の縦長ページなど、合成後の縦横比が
    /// AppPreferences.singlePageAspectRatioThresholdに満たないもの)に対しては、cooViewerと
    /// 同じくfitWidthと全く同じ表示になるようフォールバックする
    /// (詳細はViewerView.renderScale(contentSize:containerSize:)参照)。
    case fitWidthSplit
    /// 拡大縮小しない(原寸のまま表示し、縦横ともスクロール)
    case noScale

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .fitToScreen: return "Fit to Screen"
        case .fitWidth: return "Fit Width"
        case .fitWidthSplit: return "Fit Width (Single Page)"
        case .noScale: return "No Scaling"
        }
    }

    /// メニューバーからこのモードを直接選ぶためのショートカット(commandと組み合わせる)。
    ///
    /// cooViewerが表示サイズの各モードに ⌘1〜⌘4 を割り当てているのに倣ったもの。ただし
    /// cooViewer自身は追加順の都合で「見開き分割」が⌘4、「画面に合わせない」が⌘3という
    /// メニューの並びとずれた振り方になっている。qooViewerでは**メニューの並び順どおり**に
    /// 1から振る(ユーザーの判断。並びと番号が一致するほうが直感的なため)。
    ///
    /// KeyBindingStoreの再割り当てではなくメニュー項目の`.keyboardShortcut`で実現しているのは、
    /// RemappableKeyがcommand付きのキーを意図的に対象外にしているため
    /// (RemappableKey.swift冒頭のコメント参照)。そのぶんユーザーによる変更はできないが、
    /// メニューに表示されるので見つけやすい。
    var menuShortcutKey: KeyEquivalent {
        switch self {
        case .fitToScreen: return "1"
        case .fitWidth: return "2"
        case .fitWidthSplit: return "3"
        case .noScale: return "4"
        }
    }

    /// ツールバーのボタンでモードを一つずつ切り替えるための「次のモード」
    var next: ScalingMode {
        switch self {
        case .fitToScreen: return .fitWidth
        case .fitWidth: return .fitWidthSplit
        case .fitWidthSplit: return .noScale
        case .noScale: return .fitToScreen
        }
    }
}
