import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// 動画の表示の縦横の読み取りと、絵の縦横比の補正(2026-09-29。Services/FileBrowserThumbnails/ の `VideoDimensionReader` /
/// `VideoContainerDimensionReader` / `VideoThumbnailAspect`)。
///
/// 実物は `Fixtures/video/`(ffmpeg で作った数コマの動画。作り方は scripts/fixtures/build-video-fixtures.sh)。QuickLook の実物は
/// 使わない(入っている拡張しだい。`FileBrowserVideoThumbnailTests` の型コメント)―― ここで固定するのは「どの形式からも表示の縦横が
/// 読める」ことと「比の違う絵を直す」こと。
@MainActor
struct VideoDimensionReaderTests {
    nonisolated struct Sample: Sendable, CustomTestStringConvertible {
        let name: String
        let container: MediaContainer?
        let width: Double
        let height: Double

        var testDescription: String { name }
    }

    /// 画素が正方形でないもの(`-sar`)は 144×96 を 32:27 で見せる = 170.67×96。回転の指定つき(`-rot90`)は縦横が入れ替わる。
    nonisolated static let samples: [Sample] = [
        Sample(name: "h264-160x90.mp4", container: .isoBMFF, width: 160, height: 90),
        Sample(name: "h264-sar.mp4", container: .isoBMFF, width: 170.67, height: 96),
        Sample(name: "h264-rot90.mp4", container: .isoBMFF, width: 90, height: 160),
        Sample(name: "h264-160x90.mkv", container: .matroska, width: 160, height: 90),
        Sample(name: "h264-sar.mkv", container: .matroska, width: 170.67, height: 96),
        Sample(name: "mpeg4-160x90.avi", container: .avi, width: 160, height: 90),
        Sample(name: "mpeg4-sar.avi", container: .avi, width: 170.67, height: 96),
        Sample(name: "wmv2-160x90.wmv", container: .asf, width: 160, height: 90),
        Sample(name: "wmv2-sar.wmv", container: .asf, width: 170.67, height: 96),
        Sample(name: "flv1-160x90.flv", container: .flv, width: 160, height: 90),
        Sample(name: "theora-160x90.ogv", container: .ogg, width: 160, height: 90),
        Sample(name: "theora-sar.ogv", container: .ogg, width: 170.67, height: 96),
        Sample(name: "rv10-160x96.rm", container: .realMedia, width: 160, height: 96),
    ]

    private static func aspect(_ size: CGSize) -> Double {
        Double(size.width / size.height)
    }

    // MARK: - 実物から読む

    @Test("どの形式からも、画素の縦横比と回転を掛けた表示の縦横が読める", arguments: samples)
    func readsDisplaySize(_ sample: Sample) async throws {
        let probe = await VideoDimensionReader.probe(Fixtures.url("video/" + sample.name))
        #expect(probe.container == sample.container)
        let size = try #require(probe.displaySize)
        // 比が 2% 以内(mkv の DisplayWidth は整数に丸めてある)。
        #expect(abs(Self.aspect(size) / (sample.width / sample.height) - 1) < 0.02)
        // mkv の DisplayWidth / DisplayHeight は画素数とは限らない(比が合っていればよい)。
        if sample.container != .matroska {
            #expect(abs(Double(size.height) - sample.height) < 1)
        }
    }

    @Test("実体が mp4 なのに別の拡張子を名乗るファイルも読める(AVFoundation は拡張子で形式を決める)")
    func readsMisnamedMP4() async throws {
        let temporary = try TemporaryDirectory("video-dimensions-misnamed")
        let misnamed = temporary.file("clip.mkv")
        try FileManager.default.copyItem(at: Fixtures.url("video/h264-160x90.mp4"), to: misnamed)
        let probe = await VideoDimensionReader.probe(misnamed)
        #expect(probe.container == .isoBMFF)
        #expect(probe.displaySize == CGSize(width: 160, height: 90))
    }

    @Test("動画でない・無い・空のファイルは nil(落ちない)")
    func rejectsNonVideos() async throws {
        let temporary = try TemporaryDirectory("video-dimensions-broken")
        let text = temporary.file("text.mp4")
        try Data("this is not a video".utf8).write(to: text)
        #expect(await VideoDimensionReader.probe(text) == VideoDimensionReader.Probe(container: nil, displaySize: nil))
        let empty = temporary.file("empty.mp4")
        try Data().write(to: empty)
        #expect(await VideoDimensionReader.probe(empty).displaySize == nil)
        #expect(await VideoDimensionReader.probe(temporary.file("missing.mp4")).displaySize == nil)
    }

    // MARK: - 壊れたヘッダ

    /// 自前で読む形式の実物。
    nonisolated static let headerSamples = samples.filter {
        switch $0.container {
        case .avi, .asf, .flv, .ogg, .realMedia, .matroska: true
        default: false
        }
    }

    private static func read(_ bytes: [UInt8], as container: MediaContainer) -> CGSize? {
        container == .matroska
            ? MatroskaDimensionReader.dimensions(in: bytes)
            : VideoContainerDimensionReader.displaySize(in: bytes, container: container)
    }

    @Test("途中で切れたヘッダでも落ちず、読めたなら正しい縦横を返す", arguments: headerSamples)
    func survivesTruncation(_ sample: Sample) throws {
        let container = try #require(sample.container)
        let bytes = [UInt8](try Data(contentsOf: Fixtures.url("video/" + sample.name)))
        let expected = sample.width / sample.height
        var readable = 0
        for length in 0..<min(bytes.count, 2048) {
            guard let size = Self.read(Array(bytes[0..<length]), as: container) else { continue }
            readable += 1
            // 画素の縦横比が後ろにある形式(AVI の vprp・ASF の Metadata)は、そこまで届かなければ画素数の比になる。
            let ratio = Self.aspect(size)
            #expect(abs(ratio / expected - 1) < 0.02 || abs(ratio - 144.0 / 96.0) < 0.02)
        }
        #expect(readable > 0)
    }

    @Test("大きさの欄を細工したヘッダでも落ちない(足し算が溢れない・範囲の外を読まない)", arguments: headerSamples)
    func survivesCorruptedSizes(_ sample: Sample) throws {
        let container = try #require(sample.container)
        let original = [UInt8](try Data(contentsOf: Fixtures.url("video/" + sample.name)).prefix(1024))
        // 先頭 1KB の各位置から 8 バイトを 0xFF / 0x00 / 0x7F で塗って読ませる。結果は問わない(nil か、範囲の中の縦横)。
        for fill in [UInt8(0xFF), 0x00, 0x7F] {
            for start in stride(from: 0, to: original.count - 8, by: 1) {
                var bytes = original
                for index in start..<(start + 8) { bytes[index] = fill }
                if let size = Self.read(bytes, as: container) {
                    #expect(size.width >= 1 && size.width < 100_000 && size.height >= 1 && size.height < 100_000)
                }
            }
        }
    }

    @Test("対象外の形式・別の形式のバイト列は nil")
    func rejectsOtherContainers() throws {
        let avi = [UInt8](try Data(contentsOf: Fixtures.url("video/mpeg4-160x90.avi")))
        for container in MediaContainer.allCases where container != .avi {
            #expect(VideoContainerDimensionReader.displaySize(in: avi, container: container) == nil)
        }
        #expect(VideoContainerDimensionReader.displaySize(in: [], container: .avi) == nil)
        #expect(VideoContainerDimensionReader.displaySize(in: Array("RIFF\0\0\0\0AVI ".utf8), container: .avi) == nil)
    }

    // MARK: - Matroska の表示の縦横

    /// `Video` の中身だけを差し替えられる最小の mkv。
    private static func matroska(video: [UInt8]) -> [UInt8] {
        let videoElement: [UInt8] = [0xE0, 0x80 | UInt8(video.count)] + video
        let entryContent: [UInt8] = [0x83, 0x81, 0x01] + videoElement
        let entry: [UInt8] = [0xAE, 0x80 | UInt8(entryContent.count)] + entryContent
        let tracks: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, 0x80 | UInt8(entry.count)] + entry
        return [0x1A, 0x45, 0xDF, 0xA3, 0x84, 0x01, 0x02, 0x03, 0x04] + [0x18, 0x53, 0x80, 0x67, 0xFF] + tracks
    }

    private static let pixels720x480: [UInt8] = [0xB0, 0x82, 0x02, 0xD0, 0xBA, 0x82, 0x01, 0xE0]
    private static let display853x480: [UInt8] = [0x54, 0xB0, 0x82, 0x03, 0x55, 0x54, 0xBA, 0x82, 0x01, 0xE0]

    @Test("Matroska: DisplayWidth / DisplayHeight があればそれ。単位が「不明」か、片方だけなら画素数")
    func matroskaPrefersDisplaySize() {
        #expect(MatroskaDimensionReader.dimensions(in: Self.matroska(video: Self.pixels720x480)) == CGSize(width: 720, height: 480))
        #expect(MatroskaDimensionReader.dimensions(in: Self.matroska(video: Self.pixels720x480 + Self.display853x480))
            == CGSize(width: 853, height: 480))
        // 比で書いたもの(DisplayUnit = 3、16:9)。
        let ratio: [UInt8] = [0x54, 0xB0, 0x81, 16, 0x54, 0xBA, 0x81, 9, 0x54, 0xB2, 0x81, 3]
        #expect(MatroskaDimensionReader.dimensions(in: Self.matroska(video: Self.pixels720x480 + ratio)) == CGSize(width: 16, height: 9))
        let unknownUnit: [UInt8] = Self.display853x480 + [0x54, 0xB2, 0x81, 4]
        #expect(MatroskaDimensionReader.dimensions(in: Self.matroska(video: Self.pixels720x480 + unknownUnit))
            == CGSize(width: 720, height: 480))
        let widthOnly: [UInt8] = [0x54, 0xB0, 0x82, 0x03, 0x55]
        #expect(MatroskaDimensionReader.dimensions(in: Self.matroska(video: Self.pixels720x480 + widthOnly))
            == CGSize(width: 720, height: 480))
    }

    // MARK: - 絵の大きさと補正

    @Test("頼む大きさ: 長辺を上限に、比は表示の縦横。分からない・極端に細長いなら正方形")
    func requestSize() {
        #expect(VideoThumbnailAspect.requestSize(displaySize: CGSize(width: 1920, height: 1080), maxPixelSize: 512)
            == CGSize(width: 512, height: 288))
        #expect(VideoThumbnailAspect.requestSize(displaySize: CGSize(width: 1080, height: 1920), maxPixelSize: 512)
            == CGSize(width: 288, height: 512))
        #expect(VideoThumbnailAspect.requestSize(displaySize: nil, maxPixelSize: 512) == CGSize(width: 512, height: 512))
        // 短い辺が QLMedia の下限(32)を割る。
        #expect(VideoThumbnailAspect.requestSize(displaySize: CGSize(width: 3200, height: 100), maxPixelSize: 512)
            == CGSize(width: 512, height: 512))
        #expect(VideoThumbnailAspect.requestSize(displaySize: CGSize(width: 0, height: 100), maxPixelSize: 512)
            == CGSize(width: 512, height: 512))
        #expect(VideoThumbnailAspect.requestSize(displaySize: CGSize(width: Double.nan, height: 100), maxPixelSize: 512)
            == CGSize(width: 512, height: 512))
    }

    @Test("補正: 比の違う絵(QuickLook が返した前の正方形)は表示の比へ縮め直す。合っていれば・分からなければそのまま")
    func correctsStretchedImages() {
        // 左半分が赤、右半分が青の正方形(16:9 の動画を正方形へ伸ばしたもの、の代わり)。
        let square = PixelGrid.image(width: 512, height: 512) { x, _ in x < 256 ? (255, 0, 0) : (0, 0, 255) }
        let corrected = VideoThumbnailAspect.corrected(square, displaySize: CGSize(width: 1920, height: 1080))
        #expect(corrected.width == 512)
        #expect(corrected.height == 288)
        // 全体を縮めただけ(切り抜いていない): 左右の色はそのまま。
        let pixels = PixelGrid.pixels(of: corrected)
        let left = pixels.rgb(64, 100)
        let right = pixels.rgb(448, 100)
        #expect(left.0 > 200 && left.2 < 50)
        #expect(right.2 > 200 && right.0 < 50)

        let tall = VideoThumbnailAspect.corrected(square, displaySize: CGSize(width: 90, height: 160))
        #expect(tall.width == 288)
        #expect(tall.height == 512)

        // 比が合っている(3% 以内)・縦横が分からない・極端に細長い、は元の絵そのもの。
        let wide = PixelGrid.image(width: 512, height: 288) { _, _ in (9, 9, 9) }
        #expect(VideoThumbnailAspect.corrected(wide, displaySize: CGSize(width: 1920, height: 1080)) === wide)
        #expect(VideoThumbnailAspect.corrected(wide, displaySize: CGSize(width: 1920, height: 1088)) === wide)
        #expect(VideoThumbnailAspect.corrected(square, displaySize: nil) === square)
        #expect(VideoThumbnailAspect.corrected(square, displaySize: CGSize(width: 3200, height: 100)) === square)
    }

    // MARK: - ディスクキャッシュの鍵

    @Test("動画の絵の鍵は、作り方の世代ぶんだけ項目の鍵と違う(以前の伸びた絵は当たらない)")
    func videoKeyCarriesTheVariant() throws {
        let temporary = try TemporaryDirectory("video-key")
        let url = temporary.file("clip.mp4")
        try Data("bytes".utf8).write(to: url)
        let table = MountTable.current()
        let plain = try #require(FileBrowserThumbnailKey.of(url, mountTable: table))
        let video = try #require(FileBrowserThumbnailKey.ofVideo(url, mountTable: table))
        #expect(video.variant == VideoThumbnailer.cacheVariant)
        #expect(video.fileName != plain.fileName)
        var same = plain
        same.variant = VideoThumbnailer.cacheVariant
        #expect(same == video)
    }
}
