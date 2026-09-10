import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 外から持ち込まれた画像を、**そのまま保存してよいか**判定する検査
/// (ユーザー要望 2026-09-11。zipからコレクション表紙を読み込む経路のため)。
///
/// ■ なぜ「再エンコードして安全にする」ではないのか
/// 当初は「取り込んだ画像は必ずこちらで焼き直す」方針にしていたが、見直した(ユーザー判断)。
/// **再エンコードは思ったほど安全性を買っていない** ―― 危ないのは「信用できないバイト列を
/// Image I/Oに復号させる」ところで、それは検査のためにどのみち通る。焼き直しで実際に落とせるのは
/// (a)埋め込みメタデータ と (b)末尾に継ぎ足された別データ の2つだけで、(b)は直接確かめられる。
/// 一方で焼き直しは確実に画質を1世代落とす。表紙は書き出して読み戻す道具でもあるので、
/// **検査に通ったものは元のバイトのまま持つ**ほうがよい。
///
/// ■ 「齟齬が無い」とはどういうことか
/// 1. 形式が許可した5種のいずれかで、拡張子ではなく**中身から**判定できる
/// 2. フレームが1つだけ(複数フレームを仕込んだファイルを弾く)
/// 3. ヘッダーが寸法を申告していて、0でも上限超えでもない
/// 4. **実際に復号した画素寸法が、ヘッダーの申告と一致する**
/// 5. **バイト列が、その形式自身の終端で終わっている**(画像の後ろに別のファイルを継ぎ足した
///    よくある細工を弾く)
///
/// 5を確かめられるのはJPEGとPNGだけなので、**そのまま持てるのもこの2形式だけ**にしてある。
/// 他の形式(HEIC/WebP/TIFF)は焼き直して取り込む。このアプリが書き出すのは常にJPEGなので、
/// 自分で書き出したzipは必ず無劣化で往復する。
///
/// ■ 4の全復号が重くならない理由
/// 全復号を通すのは**上限内の画像だけ**。上限を超えるものはどのみち縮小して焼き直すので、
/// その判定(ヘッダーの寸法)だけで先に振り分ける。つまりここで全復号するのは長辺
/// `maxPixelSize`以下の画像に限られる。
nonisolated enum ImageIntegrityCheck {
    /// 取り込みを断る/焼き直す理由。画面の一覧にそのまま出す。
    enum Reason: Error, Sendable, Equatable {
        /// 画像として読めない(形式が違う・壊れている)。
        case unreadable
        /// 対応していない形式。
        case unsupportedFormat
        /// フレームが複数ある(アニメーション等)。
        case multipleFrames
        /// 復号した寸法がヘッダーの申告と食い違う。
        case dimensionMismatch
        /// 画像の終端より後ろにデータが続いている。
        case trailingData
        /// 上限より大きい(焼き直しの理由であって、拒否の理由ではない)。
        case tooLarge
        /// 終端を確かめられない形式(JPEG/PNG以外)。同上。
        case formatNotVerifiable
    }

    enum Verdict: Sendable, Equatable {
        /// 元のバイトのまま保存してよい。
        case verbatim(fileExtension: String)
        /// 取り込んではよいが、こちらで焼き直す必要がある。
        case reencode(Reason)
        /// 取り込まない。
        case rejected(Reason)
    }

    /// 中身から判定できる形式。拡張子は見ない。
    private static let allowedTypes: [UTType] = [.jpeg, .png, .heic, .heif, .webP, .tiff]

    static func inspect(_ data: Data, maxPixelSize: CGFloat) -> Verdict {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return .rejected(.unreadable)
        }
        // 形式そのものが分からないもの(画像ではないバイト列)は「読めない」。
        // 形式は分かるが対応していないものだけを`.unsupportedFormat`にする ―― 利用者に出す
        // 文言が変わるので、ここは分けておく。
        guard let typeID = CGImageSourceGetType(source) as String?, let type = UTType(typeID) else {
            return .rejected(.unreadable)
        }
        guard allowedTypes.contains(where: { type.conforms(to: $0) }) else {
            return .rejected(.unsupportedFormat)
        }

        guard CGImageSourceGetCount(source) == 1 else { return .rejected(.multipleFrames) }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return .rejected(.unreadable) }

        // 上限を超えるものはどのみち焼き直すので、重い全復号まで進めない。
        guard CGFloat(max(width, height)) <= maxPixelSize else { return .reencode(.tooLarge) }
        // 終端を確かめられるのはJPEGとPNGだけ(型コメント参照)。
        guard type.conforms(to: .jpeg) || type.conforms(to: .png) else {
            return .reencode(.formatNotVerifiable)
        }

        // ここから先は長辺maxPixelSize以下の画像だけが通る。
        // CGImageSourceCreateImageAtIndexは向き(EXIF Orientation)を適用しないので、
        // 復号結果の寸法はヘッダーの申告とそのまま突き合わせられる。
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .rejected(.unreadable)
        }
        guard decoded.width == width, decoded.height == height else {
            return .rejected(.dimensionMismatch)
        }
        guard endsAtTerminator(data, isJPEG: type.conforms(to: .jpeg)) else {
            return .rejected(.trailingData)
        }
        return .verbatim(fileExtension: type.conforms(to: .jpeg) ? "jpg" : "png")
    }

    /// バイト列がその形式自身の終端で終わっているか。
    ///
    /// - JPEG: 最後の2バイトが EOI マーカー(FF D9)
    /// - PNG: 最後の12バイトが IEND チャンク(長さ0 + "IEND" + CRC)
    ///
    /// 「画像 + 後ろに別のファイル」という形は、両形式とも復号側が黙って無視するので、
    /// 復号できたことだけでは気づけない。ここで直接見る。
    private static func endsAtTerminator(_ data: Data, isJPEG: Bool) -> Bool {
        if isJPEG {
            guard data.count >= 2 else { return false }
            return data[data.index(data.endIndex, offsetBy: -2)] == 0xFF
                && data[data.index(data.endIndex, offsetBy: -1)] == 0xD9
        }
        guard data.count >= 12 else { return false }
        let tail = data[data.index(data.endIndex, offsetBy: -12)...]
        let expected: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44]
        return Array(tail.prefix(8)) == expected
    }
}
