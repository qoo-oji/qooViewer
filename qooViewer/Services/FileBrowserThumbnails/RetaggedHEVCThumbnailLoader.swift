import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// `hev1` の HEVC から絵を作る(改善要望7 段階 7b、2026-09-14。qooLibrary の同名の型を写したもの)。
/// **元のファイルは 1 バイトも書き換えない。**
///
/// ■ なぜ要るのか(qooLibrary の実機の蔵書で踏んだ)
/// HEVC を mp4 に入れるときのサンプルエントリのタグは 2 通りある。`hvc1`(パラメータセットはサンプルエントリにある)は
/// Apple のメディアスタックで再生も絵もできる。`hev1`(ビットストリームの中にもある)は仕様上正しいが、AVFoundation が
/// **入口で断る**ので、QuickLook も Finder も絵を作れない(102 を 0.02〜0.04 秒で返す)。ffmpeg の libx265 の mp4 は
/// 既定で `hev1` を付けるので、動画を集めていれば普通に出会う。
///
/// ■ どう避けるか
/// 「復号できない」のではなく「タグを見て断られている」だけだった。`hvcC` には VPS/SPS/PPS が揃っている。
/// 1. `AVAssetReaderTrackOutput(track:, outputSettings: nil)`(復号しない素通し)でキーフレームを取り出す
///    (`decodable=false` のトラックでも読める)
/// 2. 元の format description の extensions(`hvcC` を含む)をそのまま使い、subtype だけ `hvc1` で作り直す
/// 3. 同じデータに新しい description を付けたサンプルを組み、`VTDecompressionSession` に渡す(VideoToolbox は受け付ける)
///
/// QuickLook が失敗したときだけ働く(`CompositeVideoThumbnailLoader`)。
nonisolated struct RetaggedHEVCThumbnailLoader: VideoThumbnailLoading {
    private let timeoutSeconds: Double
    /// キーフレームを探して読むサンプルの数の上限。
    private let keyframeScanLimit: Int

    /// 探し始める位置(尺に対する割合と、その上限の秒)。冒頭は黒い画面やロゴのことが多い。
    static let seekFraction = 0.1
    static let seekCapSeconds = 120.0

    init(timeoutSeconds: Double = VideoThumbnailer.timeoutSeconds, keyframeScanLimit: Int = 600) {
        self.timeoutSeconds = timeoutSeconds
        self.keyframeScanLimit = keyframeScanLimit
    }

    /// AVFoundation が入口で断るタグ → VideoToolbox が受け付けるタグ。**実測で確かめた組み合わせだけ**
    /// (Dolby Vision の `dvhe`/`dvh1` も同じ関係だが、確かめるファイルが無いので入れていない)。
    private static let retagTable: [FourCharCode: CMVideoCodecType] = [
        fourCharCode("hev1"): kCMVideoCodecType_HEVC,
    ]

    @concurrent func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        // 1 本の異常なファイルで同時実行の枠をふさがないよう、QuickLook の経路と同じ上限を付ける。
        try? await FileIO.withDeadline(.seconds(timeoutSeconds)) {
            await Self.makeThumbnailWithoutDeadline(for: url, maxPixelSize: maxPixelSize, scanLimit: keyframeScanLimit)
        }?.image
    }

    private static func makeThumbnailWithoutDeadline(for url: URL, maxPixelSize: Int, scanLimit: Int) async -> ImageBox? {
        let asset = AVURLAsset(url: url)
        // `loadTracks` / `load` は AVFoundation 自身のキューで走るので、FileIO は要らない。
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let original = (try? await track.load(.formatDescriptions))?.first,
              let retagged = retaggedFormatDescription(for: original)
        else { return nil }
        let start = await keyframeSearchStart(of: asset)
        // AVURLAsset / AVAssetTrack は Sendable ではない。借りたスレッド 1 本へ渡して、そこだけで触る。
        let box = AssetBox(asset: asset, track: track)
        return await FileIO.perform {
            thumbnail(asset: box.asset, track: box.track, retagged: retagged, startSeconds: start,
                      maxPixelSize: maxPixelSize, scanLimit: scanLimit)
        }
    }

    // MARK: - タグの差し替え

    /// subtype だけを差し替えた format description。対象外のタグなら nil。
    private static func retaggedFormatDescription(for original: CMFormatDescription) -> CMFormatDescription? {
        guard let replacement = retagTable[CMFormatDescriptionGetMediaSubType(original)] else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(original)
        // **extensions をそのまま引き継ぐのが要点**(`hvcC` がここにあるので VideoToolbox が復号器を組める)。
        var retagged: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: replacement, width: dimensions.width, height: dimensions.height,
            extensions: CMFormatDescriptionGetExtensions(original), formatDescriptionOut: &retagged
        )
        return status == noErr ? retagged : nil
    }

    // MARK: - キーフレームの取り出しと復号(ブロッキング)

    private static func keyframeSearchStart(of asset: AVURLAsset) async -> Double {
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(seconds * seekFraction, seekCapSeconds)
    }

    /// **ブロッキング。FileIO の上で呼ぶ**(`copyNextSampleBuffer()` は実際に読む)。
    private static func thumbnail(
        asset: AVURLAsset, track: AVAssetTrack, retagged: CMFormatDescription, startSeconds: Double,
        maxPixelSize: Int, scanLimit: Int
    ) -> ImageBox? {
        // 少し進んだ位置で同期サンプルが見つからなければ先頭から取り直す。
        var sample = copyKeyframe(asset: asset, track: track, startSeconds: startSeconds, scanLimit: scanLimit)
        if sample == nil, startSeconds > 0 {
            sample = copyKeyframe(asset: asset, track: track, startSeconds: 0, scanLimit: scanLimit)
        }
        guard let sample, let retaggedSample = retag(sample, with: retagged),
              let image = decode(retaggedSample, formatDescription: retagged)
        else { return nil }
        return ImageBox(image: downscale(image, maxPixelSize: maxPixelSize) ?? image)
    }

    private static func copyKeyframe(
        asset: AVURLAsset, track: AVAssetTrack, startSeconds: Double, scanLimit: Int
    ) -> CMSampleBuffer? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // `outputSettings: nil` は素通し(復号しない)。これが `decodable=false` のトラックでも読める理由。
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        // **コピーさせる。** false だとファイルのメモリ写像を指しうる。ネットワークの共有が落ちると写像への
        // フォルトが SIGBUS になり、try では捕まえられない(qooLibrary の遮断の計測で実測)。
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        if startSeconds > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600), duration: .positiveInfinity
            )
        }
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var scanned = 0
        while scanned < scanLimit, !Cancellation.isRequestedInCurrentScope {
            guard let candidate = output.copyNextSampleBuffer() else { return nil }
            scanned += 1
            // 中身を持たない印だけのバッファ(フォーマットの変化の通知など)は飛ばす。飛ばさないと空のバッファを
            // キーフレームと取り違える(qooLibrary の実装中に踏んだ)。
            guard CMSampleBufferGetNumSamples(candidate) > 0, CMSampleBufferGetDataBuffer(candidate) != nil
            else { continue }
            if isSyncSample(candidate) { return candidate }
        }
        return nil
    }

    /// 同期サンプル(キーフレーム)か。添付が無ければ同期扱い(「同期でない」という指定が無い)。
    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// 同じデータに、差し替えた format description を付けたサンプル。
    private static func retag(_ sample: CMSampleBuffer, with formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample)
        )
        let count = CMSampleBufferGetNumSamples(sample)
        var sizes = (0..<count).map { CMSampleBufferGetSampleSize(sample, at: $0) }
        // 個々の大きさが取れない構成では、合計を 1 件として渡す。
        if sizes.isEmpty || sizes.contains(0) {
            sizes = [CMSampleBufferGetTotalSampleSize(sample)]
        }
        guard sizes.allSatisfy({ $0 > 0 }) else { return nil }
        var retagged: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: dataBuffer, formatDescription: formatDescription,
            sampleCount: CMItemCount(sizes.count), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: CMItemCount(sizes.count), sampleSizeArray: &sizes, sampleBufferOut: &retagged
        )
        return status == noErr ? retagged : nil
    }

    private static func decode(_ sample: CMSampleBuffer, formatDescription: CMFormatDescription) -> CGImage? {
        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: formatDescription, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session
        )
        // 失敗するのは `hvcC` にパラメータセットが無いなど、差し替えても復号器を組めないとき。
        guard created == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        // 出力のハンドラは VideoToolbox のスレッドから呼ばれうるので、受け取り口は錠で守る。借りたスレッドの上に
        // いるので、待ち合わせは `WaitForAsynchronousFrames` に任せる(継続を使わないので、期限で見捨てられても
        // 継続が取り残されない)。
        let sink = ImageSink()
        let submitted = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &image)
            sink.store(image)
        }
        guard submitted == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return sink.take()
    }

    /// 復号は元の解像度(1920×1080 など)で行われるので、ほかの経路と同じ大きさに収める。
    private static func downscale(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize, longest > 0 else { return image }
        let scale = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Sendable でない型の受け渡し

    private struct AssetBox: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
    }

    fileprivate struct ImageBox: @unchecked Sendable {
        let image: CGImage
    }

    /// VideoToolbox のスレッドから書かれ、こちらのスレッドから読まれる 1 枚。
    private final class ImageSink: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?

        func store(_ newValue: CGImage?) {
            lock.lock()
            // 最初の 1 枚だけを採る。
            if image == nil { image = newValue }
            lock.unlock()
        }

        func take() -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        Array(string.utf8).reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
    }
}
