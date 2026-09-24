import SwiftUI

/// スマートライブラリのアイコン表示に並ぶ表紙の形(環境設定「スマートライブラリ」、2026-09-23、利用者の要望)。
///
/// ライブラリの「カバーの形」(`CoverAspectRatio`。ライブラリごとの歯車)を持ち込んだもの。違いは 2 つ:
/// - **「実際の画像に合わせる」がある(既定)**。この設定を足す前の見た目で、縦長(2:3)の枠の中に表紙を切らずに収める
///   (横長の表紙は枠の下に寄って小さく出る)。ライブラリの形はどれも比の決まった枠なので、この形に当たるものは無い
/// - **アプリで 1 つ**。スマートライブラリにはライブラリのような単位が無い(スマートコレクションごとにすると、選び直すたびに
///   グリッドの形が変わる)
///
/// 切る形では、表紙を枠いっぱいに合わせ、はみ出した部分を「切り取るときに残す位置」で切る(2026-09-23、ライブラリと同じく
/// 既定は環境設定 `AppPreferences.smartLibraryCoverCropAnchor`、本ごとの指定 `BookLayoutSettings.coverCropAnchor` が勝つ。
/// 決めるのは `SmartLibraryContent.cropAnchor(for:)`)。「形の合わせ方」(`AppPreferences.smartLibraryCoverFit`、2026-09-24)が
/// 「余白を付ける」なら切らずに枠の中央へ収める(`cropAspect(fit:)` / `uncroppedAlignment`)。
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

    /// 実際に切る比。形が切る形でも、「形の合わせ方」が余白を付ける(`CoverFit.pad`)なら nil(切らずに枠へ収める)。
    func cropAspect(fit: CoverFit) -> CGFloat? {
        fit == .pad ? nil : cropAspect
    }

    /// 切らずに描くとき、絵を枠のどこへ置くか。「実際の画像に合わせる」はこれまでどおり下に揃える(棚に立てた本のように、
    /// 表紙の下端と題の行が揃う)。ほかの形で余白を付けるときは中央(上下左右に同じだけ余白を付ける。2026-09-24、利用者の要望)。
    var uncroppedAlignment: Alignment {
        self == .matchImage ? .bottom : .center
    }

    /// セルの表紙の枠の 高さ ÷ 幅。「実際の画像に合わせる」は従来どおり 2:3 の枠。
    var heightRatio: CGFloat {
        1 / (cropAspect ?? CoverAspectRatio.portrait.value)
    }
}

/// 環境設定「スマートライブラリ」の「切り取るときに残す位置」のポップアップ。文言はライブラリの設定と同じ
/// (LibrarySettingsPopover)。
///
/// `CoverCropAnchor` は nonisolated(カバーの抽出がメインの外で使う)で、`SettingsOption` はメインアクターの側なので、
/// 準拠はメインアクターに閉じたもの(isolated conformance)にする。付けないと、Xcode 26.6(CI)の Swift 6.2 は
/// 「main actor の側へ跨ぐ」警告を出す(CI は警告をエラーにする。2026-09-23 に Build が落ちた。手元の Xcode 27 は黙っていた)。
extension CoverCropAnchor: @MainActor SettingsOption {
    var id: String { rawValue }

    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .start: "Top / Left"
        case .center: "Center"
        case .end: "Bottom / Right"
        }
    }
}

/// 環境設定「スマートライブラリ」の「形の合わせ方」のポップアップ。文言はライブラリの設定と同じ(LibrarySettingsPopover)。
/// 隔離の付いた準拠にする理由は `CoverCropAnchor` と同じ。
extension CoverFit: @MainActor SettingsOption {
    var id: String { rawValue }

    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .crop: "Crop to Fill"
        case .pad: "Add Margins"
        }
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
