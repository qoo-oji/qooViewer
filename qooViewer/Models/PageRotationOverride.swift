import Foundation
import SwiftData

/// ページごとに利用者が決めた画像の向き(2026-11-23、ユーザー要望「画像の向きがおかしい場合、ビューア上で回転できるように」)。
///
/// ■ 何を持つか
/// `rotation` は**元の画素から見た**時計回りの回転(0 / 90 / 180 / 270)。ファイル自身の向きの指定(画像の EXIF の向き、PDF の
/// `/Rotate`)に**重ねるのではなく置き換える**(ユーザー判断: ファイルの指定とアプリの記録が食い違うなら、アプリの記録のほうが
/// 新しいはずなのでアプリに従う)。重ねる形にすると、あとでファイル側の向きを直したときに二重に回ってしまう。行が無ければファイルの向きに
/// 従う(「元の向きに戻す」は行を消す)。EXIF の左右反転(向き 2・4・5・7)は、回転を記録したページでは捨てる(マンガのスキャンでは
/// まず無い)。
///
/// ■ 置き場所
/// `PageLayoutOverride` には混ぜない ―― あちらは「行がある = 単ページ/見開き/除外の指定がある」という意味で、多くの読み手が行の有無で
/// 判断している(除外の集合・「レイアウト情報を削除」の有無・書き出し)。向きはそれと独立に付く。書き込むのは `LayoutStore` だけで、
/// 付け替え(移動・改名)・削除・保存データの JSON は `PageLayoutOverride` と同じ道を通る(LayoutStore の該当箇所)。
///
/// `pageKey` は `PageRef.sortKey`(PageLayoutOverride と同じ)。`@Attribute(.unique)` は付けない(PageLayoutOverride.swift の経緯)。
@Model
final class PageRotationOverride {
    var bookID: String
    var pageKey: String
    /// 元の画素から見た時計回りの回転(0 / 90 / 180 / 270。読むときは `PageRotation.normalized` を通す)。
    var rotation: Int
    var updatedAt: Date = Date()

    init(bookID: String, pageKey: String, rotation: Int) {
        self.bookID = bookID
        self.pageKey = pageKey
        self.rotation = PageRotation.normalized(rotation)
        self.updatedAt = Date()
    }
}

/// 画像の向き(時計回りの回転、0 / 90 / 180 / 270)の計算。
nonisolated enum PageRotation {
    /// 0 / 90 / 180 / 270 へ(90 の倍数でない値は近い 90° 単位へ丸める ―― PDFPageGeometry.normalizedRotation と同じ)。
    static func normalized(_ degrees: Int) -> Int {
        PDFPageGeometry.normalizedRotation(degrees)
    }

    /// 90°/270°(幅と高さが入れ替わる)か。
    static func isSideways(_ rotation: Int) -> Bool {
        let value = normalized(rotation)
        return value == 90 || value == 270
    }

    /// 向きの指定(EXIF/TIFF の Orientation、1〜8)が表す回転。左右反転を含む値(2・4・5・7)は、反転を除いた回転として扱う
    /// (幅と高さが入れ替わるかどうかは指定どおり)。
    static func rotation(forOrientation orientation: Int) -> Int {
        switch orientation {
        case 3, 4: 180
        case 6, 7: 90
        case 5, 8: 270
        default: 0
        }
    }

    /// 回転 `rotation` を表す向きの指定(OrientationBaking.orientation(forClockwiseRotation:) と同じ)。
    static func orientation(for rotation: Int) -> Int {
        OrientationBaking.orientation(forClockwiseRotation: normalized(rotation))
    }
}

/// ビューアの「画像を回転」の操作(右クリックメニュー・メニューバー)。
nonisolated enum PageRotationCommand: Equatable, Sendable {
    /// 今の向きから時計回りに 90°。
    case rotateRight
    /// 今の向きから反時計回りに 90°。
    case rotateLeft
    /// 今の向きから 180°。
    case rotate180
    /// アプリの記録を消して、ファイルの向きに戻す。
    case reset

    /// 今の向きに足す回転(reset は nil)。
    var delta: Int? {
        switch self {
        case .rotateRight: 90
        case .rotateLeft: 270
        case .rotate180: 180
        case .reset: nil
        }
    }
}
