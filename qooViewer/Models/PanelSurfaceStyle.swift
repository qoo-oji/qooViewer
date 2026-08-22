import SwiftUI

/// すりガラス(マテリアル)で描いている面の1つ。
///
/// ユーザー要望: ページ一覧パネル・ツールバー・プログレスバー・サイドパネルの
/// 背景色と透明度を、**それぞれ個別に**設定したい。設定項目そのもの(`PanelSurfaceStyle`)は
/// 4面で完全に共通なので、面の側だけをこの列挙で表し、環境設定「外観」画面は
/// `allCases`をそのまま並べるだけで済むようにしてある(面を1つ増やすときに
/// 触るのはこのファイルと、実際に描いている側の1箇所だけでよい)。
///
/// rawValueはUserDefaultsのキーの一部として使う永続化用の識別子。綴りを変えると
/// 保存済みの設定が読めなくなり既定値へ戻るだけだが、意味なく変えないこと。
enum PanelSurface: String, CaseIterable, Identifiable, Hashable {
    /// ページ一覧(サムネイルグリッド)パネル本体。ThumbnailGridView。
    case pageList
    /// ビューア上部のツールバー。自動的に隠す設定のときに重ねて表示される帯。
    case toolbar
    /// ビューア下部のプログレスバー。ツールバーと同じく自動的に隠すときの帯。
    case progressBar
    /// サイドパネル。ここだけAppKitのNSVisualEffectViewで描いている
    /// (SidebarVisualEffectView参照。理由はそちらのコメント)。
    case sidePanel

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .pageList: "Page List Panel"
        case .toolbar: "Toolbar"
        case .progressBar: "Progress Bar"
        case .sidePanel: "Side Panel"
        }
    }

    /// この面の既定値。**すべて「これまでの見た目と1ピクセルも変わらない」値**にしてある
    /// (ユーザー要望: 現在のパネルのデザインは気に入っているので、その見た目を維持した
    /// うえで調整できるようにしたい)。つまり、すりガラスは従来どおりの濃さ(1.0)で、
    /// 色は一切重ねない(tintOpacity = 0)。
    ///
    /// 色そのもの(tintColor)の既定を黒にしているのは、濃さを0から上げ始めたときに
    /// 「まず暗くなる」のがいちばん予想しやすいため(明るい色を既定にすると、
    /// スライダーを少し動かしただけでパネルが白飛びしたように見える)。
    var defaultStyle: PanelSurfaceStyle {
        PanelSurfaceStyle(
            materialOpacity: 1,
            tintColor: RGBColorValue(red: 0, green: 0, blue: 0),
            tintOpacity: 0
        )
    }
}

/// すりガラスで描く面1つ分の背景の見え方。
///
/// ■ なぜ「マテリアルの差し替え」ではなく「濃さ+重ね色」なのか
/// SwiftUIの`Material`(.ultraThin〜.ultraThick)を選ばせる案もあったが、採らなかった。
/// サイドパネルだけはAppKitの`NSVisualEffectView(.sidebar)`で描いており
/// (SidebarVisualEffectView参照。SwiftUIの`.regularMaterial`だと、フル高さのサイドバー配置で
/// ウインドウがキーのときだけ境界に青いアクセントカラーの線が出る不具合があったため)、
/// `NSVisualEffectView.Material`には`.ultraThin`〜`.ultraThick`のような**ぼかしの強さの
/// 順序が存在しない**。4面で意味の揃わない選択肢を並べることになるうえ、サイドパネルを
/// SwiftUIのマテリアルへ戻せば上記の不具合が再発する。
///
/// 代わりに、どちらの実装でも同じ意味を持つ2つの層として表現している。
///   1. すりガラスの層そのものの不透明度(`materialOpacity`)
///   2. その上に重ねる単色の層(`tintColor` × `tintOpacity`)
/// この2つだけで「今より透けさせる」「好きな色に染める」「すりガラスをやめて単色にする」
/// (= tintOpacity 100%)のすべてが表現でき、既定値では従来の描画と完全に一致する。
struct PanelSurfaceStyle: Equatable, Hashable {
    /// すりガラスの層自体の不透明度(0〜1)。1.0でこれまでどおり。
    /// 0にするとぼかしの層が消え、背後(ビューアの画像やウインドウの地)がそのまま透ける。
    var materialOpacity: Double { didSet { materialOpacity = Self.clampedOpacity(materialOpacity) } }
    /// すりガラスの上に重ねる色。
    var tintColor: RGBColorValue
    /// 重ねる色の不透明度(0〜1)。0で色を重ねない(既定)。1にすると単色で塗りつぶされ、
    /// 結果としてすりガラスは見えなくなる。
    var tintOpacity: Double { didSet { tintOpacity = Self.clampedOpacity(tintOpacity) } }

    init(materialOpacity: Double, tintColor: RGBColorValue, tintOpacity: Double) {
        self.materialOpacity = Self.clampedOpacity(materialOpacity)
        self.tintColor = tintColor
        self.tintOpacity = Self.clampedOpacity(tintOpacity)
    }

    /// UserDefaultsを直接書き換えられていた場合に備えて、読み出し時にも0〜1へ丸める
    /// (`RGBColorValue`が0〜255へ丸めているのと同じ考え方)。
    /// `didSet`内での再代入は`didSet`を再帰的に呼ばないため、無限ループにはならない。
    private static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// 重ねる色を、不透明度まで適用したSwiftUIの色として返す。
    /// `tintOpacity`が0のときは完全な透明色になるので、呼び出し側は場合分けせず
    /// そのまま重ねてよい(描画結果は「重ねていない」のと同じ)。
    var resolvedTint: Color {
        tintColor.color.opacity(tintOpacity)
    }
}
