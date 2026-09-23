import SwiftUI

/// スマートライブラリのアイコン表示に並ぶ表紙の形(環境設定「スマートライブラリ」、2026-09-23、利用者の要望)。
///
/// ライブラリの「カバーの形」(`CoverAspectRatio`。ライブラリごとの歯車)を持ち込んだもの。違いは 2 つ:
/// - **「実際の画像に合わせる」がある(既定)**。この設定を足す前の見た目で、縦長(2:3)の枠の中に表紙を切らずに収める
///   (横長の表紙は枠の下に寄って小さく出る)。ライブラリのカバーは抽出して保存したものを切って並べるので、切らない形は無い
/// - **アプリで 1 つ**。スマートライブラリにはライブラリのような単位が無い(スマートコレクションごとにすると、選び直すたびに
///   グリッドの形が変わる)
///
/// 切る形では、表紙を枠いっぱいに合わせて**中央を残す**(ライブラリの「切り取るときに残す位置」の既定と同じ)。
/// どの形でもセルの高さは揃う(`SmartLibraryContent` の行の位置の割り出しが頼っている。`SmartCaptionLines`)。
enum SmartLibraryCoverShape: String, CaseIterable, Identifiable, Hashable {
    case matchImage
    case portrait
    case square
    case landscape

    var id: String { rawValue }

    /// 切り取る枠の比(幅 ÷ 高さ)。「実際の画像に合わせる」は nil(切らない)。
    var cropAspect: CGFloat? {
        switch self {
        case .matchImage: nil
        case .portrait: CoverAspectRatio.portrait.value
        case .square: CoverAspectRatio.square.value
        case .landscape: CoverAspectRatio.landscape.value
        }
    }

    /// セルの表紙の枠の 高さ ÷ 幅。「実際の画像に合わせる」は従来どおり 2:3 の枠。
    var heightRatio: CGFloat {
        1 / (cropAspect ?? CoverAspectRatio.portrait.value)
    }
}

extension SmartLibraryCoverShape: SettingsOption {
    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .matchImage: "Match the Image"
        // ライブラリの「カバーの形」と同じ文言(LibrarySettingsPopover)。
        case .portrait: "Portrait (2:3)"
        case .square: "Square (1:1)"
        case .landscape: "Landscape (3:2)"
        }
    }
}
