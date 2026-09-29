import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// 動画の**表示の縦横**(画素の縦横比と回転を掛けた後)を、形式ごとの読み方で取り出す(2026-09-29)。
///
/// QLMedia が作る絵は要求した大きさへ引き伸ばされるので、絵を頼む前に縦横比を知っておく(`VideoContainerDimensionReader` の型コメント)。
///
/// | 実体 | 読み方 |
/// |---|---|
/// | Matroska / WebM | `MatroskaDimensionReader`(先頭 8MB の EBML) |
/// | AVI・ASF・FLV・Ogg・RealMedia | `VideoContainerDimensionReader`(先頭 1MB のヘッダ) |
/// | mp4 / mov / m4v / 3gp、署名で見分けないもの(ts / mpg / vob / dv など) | AVFoundation(映像トラックの寸法・画素の縦横比・回転) |
///
/// 2026-09-29 の実測(ffmpeg 7.1 で作った実物 37 本): AVFoundation は mp4 / mov / m4v / 3gp / avi / ts(H.264・MPEG-2)/ mpg / vob / dv を
/// 読み、mkv / webm / flv / wmv / ogv / rm / mxf と HEVC の ts は読めなかった。回転の指定は QLMedia も絵に掛ける(mp4。mkv のものは掛けない)
/// ので、mp4 は回転した後の縦横を返す。
///
/// 読めなければ nil(呼び出し側は正方形で頼む)。
nonisolated enum VideoDimensionReader {
    /// AVFoundation を待つ上限(秒)。応答しない共有の上のファイルで、絵を作る枠をふさがない。
    static let assetTimeoutSeconds: Double = 4

    /// 実体の形式と表示の縦横。
    struct Probe: Sendable, Equatable {
        let container: MediaContainer?
        let displaySize: CGSize?
    }

    /// 先頭を読んで形式を見分け、表示の縦横を取り出す。
    @concurrent static func probe(_ url: URL) async -> Probe {
        // 署名とヘッダは同じ読み取りの中で(ファイルを開くのは 1 回)。
        let header = await FileIO.perform { () -> Probe in
            guard let container = MediaContainerSniffer.sniff(fileAt: url) else { return Probe(container: nil, displaySize: nil) }
            switch container {
            case .matroska:
                return Probe(container: container, displaySize: MatroskaDimensionReader.dimensions(of: url))
            case .avi, .asf, .flv, .ogg, .realMedia:
                return Probe(container: container, displaySize: VideoContainerDimensionReader.displaySize(of: url, container: container))
            case .isoBMFF:
                return Probe(container: container, displaySize: nil)
            }
        }
        switch header.container {
        case .isoBMFF, nil:
            return Probe(container: header.container, displaySize: await assetDisplaySize(of: url, container: header.container))
        default:
            return header
        }
    }

    /// AVFoundation で読む。AVFoundation は形式を**拡張子から**決めるので、実体が mp4 なのに別の拡張子を名乗るファイルは
    /// MIME 型を渡して読ませる。
    static func assetDisplaySize(
        of url: URL, container: MediaContainer?, timeoutSeconds: Double = assetTimeoutSeconds
    ) async -> CGSize? {
        var options: [String: Any] = [:]
        if container == .isoBMFF, !MediaContainer.isoBMFF.matchingExtensions.contains(url.pathExtension.lowercased()) {
            options[AVURLAssetOverrideMIMETypeKey] = "video/mp4"
        }
        let box = OptionsBox(options: options)
        let size = try? await FileIO.withDeadline(.seconds(timeoutSeconds)) { () -> CGSize? in
            // `loadTracks` / `load` は AVFoundation 自身のキューで走るので、FileIO は要らない。
            let asset = AVURLAsset(url: url, options: box.options)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (natural, transform, descriptions) = try? await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
            else { return nil }
            return displaySize(natural: natural, transform: transform, description: descriptions.first)
        }
        return size ?? nil
    }

    /// トラックの値から表示の縦横を決める。画素の縦横比は format description の側にだけ出ることがある(MPEG-2 の ts:
    /// `naturalSize` は 720×480、表示は 872×480)ので、そちらを先に使う。回転は最後に掛ける。
    static func displaySize(natural: CGSize, transform: CGAffineTransform, description: CMFormatDescription?) -> CGSize? {
        var base = natural
        if let description {
            let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
                description, usePixelAspectRatio: true, useCleanAperture: true
            )
            if presentation.width >= 1, presentation.height >= 1 { base = presentation }
        }
        let shown = CGRect(origin: .zero, size: base).applying(transform).standardized.size
        guard shown.width.isFinite, shown.height.isFinite, shown.width >= 1, shown.height >= 1,
              shown.width < 100_000, shown.height < 100_000
        else { return nil }
        return shown
    }

    /// `AVURLAsset` のオプション(値は文字列だけ)を期限付きの閉包へ渡す箱。
    private struct OptionsBox: @unchecked Sendable {
        let options: [String: Any]
    }
}

/// 動画の絵の大きさと縦横比の決めごと(2026-09-29)。
nonisolated enum VideoThumbnailAspect {
    /// 要求の短い辺の下限。QLMedia はこれより小さい要求を受けない(`QLThumbnailMinimumDimension` = 32)。
    static let minimumSide: CGFloat = 32
    /// 返ってきた絵の比が、表示の比からこれ以上ずれていたら直す。
    static let tolerance: CGFloat = 0.03

    /// 絵を頼む大きさ。長辺 `maxPixelSize`、比は表示の縦横。縦横が分からない・極端に細長い(短い辺が下限を割る)なら正方形。
    static func requestSize(displaySize: CGSize?, maxPixelSize: Int) -> CGSize {
        let side = CGFloat(maxPixelSize)
        guard let fitted = fitted(displaySize, longSide: side) else { return CGSize(width: side, height: side) }
        return fitted
    }

    /// 返ってきた絵の比が表示の比と違えば、表示の比へ作り直す。合っていれば・縦横が分からなければそのまま。
    ///
    /// ■ 正しい比で頼んでも、伸びた絵が返ることがある(2026-09-29 実測)
    /// QuickLook は作った絵を覚えていて、**同じ長辺の要求には前の絵を返す**。正方形(512×512)で作ったことのある動画に 512×288 を
    /// 頼むと、前の伸びた 512×512 が返った(511×288 なら作り直された)。以前のこのアプリが正方形で頼んだ動画が、どれもこれに当たる。
    /// QLMedia の絵は動画の全体を要求の大きさへ伸ばしたものなので、表示の比へ縮め直せば元の見た目に戻る。
    static func corrected(_ image: CGImage, displaySize: CGSize?) -> CGImage {
        guard image.width > 0, image.height > 0,
              let target = fitted(displaySize, longSide: CGFloat(max(image.width, image.height)))
        else { return image }
        let actual = CGFloat(image.width) / CGFloat(image.height)
        let expected = target.width / target.height
        guard abs(actual - expected) / expected > tolerance else { return image }
        let width = max(1, Int(target.width.rounded()))
        let height = max(1, Int(target.height.rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// 長辺を `longSide` にした、表示の比の大きさ。縦横が分からない・短い辺が下限を割るなら nil。
    private static func fitted(_ displaySize: CGSize?, longSide: CGFloat) -> CGSize? {
        guard let displaySize, displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0, longSide > 0
        else { return nil }
        let aspect = displaySize.width / displaySize.height
        let size = aspect >= 1
            ? CGSize(width: longSide, height: longSide / aspect)
            : CGSize(width: longSide * aspect, height: longSide)
        guard min(size.width, size.height) >= min(minimumSide, longSide) else { return nil }
        return size
    }
}
