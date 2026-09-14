import CoreGraphics
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 動画の絵を作る口(改善要望7 段階 7b、2026-09-14。qooLibrary の `VideoThumbnailLoading` を写したもの)。
/// テストは作り物を差し込む(実物は入っている QuickLook 拡張と実物の動画に左右されるので、自動テストの対象にしない)。
nonisolated protocol VideoThumbnailLoading: Sendable {
    /// 長辺 `maxPixelSize` 程度の絵。作れなければ nil。**呼び出し側のアクターの上で重い仕事をしないこと**
    /// (Approachable Concurrency の nonisolated async は呼び出し側のアクターで走る)。
    func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage?
}

/// 動画の絵に関わる判定と上限。
nonisolated enum VideoThumbnailer {
    /// 1 本を待つ上限(秒)。QuickLook の拡張が応答しないと完了が来ないので、ここで `cancel` する。
    static let timeoutSeconds: Double = 8

    /// 動画の名前か。**入っているアプリに左右される**(mkv の `.movie` への準拠は、mkv を扱うアプリがあるときだけ)。
    /// ―― それで困らない: 扱うアプリが無ければ、どのみち絵は作れない。
    static func isVideoFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie)
    }

    /// 実体が手元に無い(iCloud などに追い出された)ファイルか。判定できなければ false。
    ///
    /// 動画の絵は QuickLook がファイルを読むので、追い出されたファイルに頼むと**頼まれていないダウンロードが始まる**
    /// (qooLibrary 実測: 1 件ずつ実際に落としてきた)。Finder も追い出されたファイルの絵は作らない。
    /// 本・画像・フォルダの絵も同じ判定を使う(`DatalessFiles`。2026-09-14 の監査 6 まで動画だけが見ていた)。
    static func isDataless(_ url: URL) -> Bool {
        DatalessFiles.isDataless(url)
    }
}

/// `QLThumbnailGenerator` で作る(qooLibrary の `QLVideoThumbnailLoader`)。mp4 / mov などは OS の標準で作れる。
///
/// ■ mkv は入っている QuickLook 拡張しだい
/// qooLibrary の比較(2026-08): QLVideo 3.x はサムネイルの拡張点を持たず 102 で失敗、QLCodec-mkv は同時に頼むと
/// **別のファイルの絵と入れ替わり、上下も逆**、**QLMedia(App Store)は正しい** ―― ただし要求の大きさへ引き伸ばすので、
/// `MatroskaDimensionReader` で縦横比を読んで要求の大きさを合わせる。どれも無ければ mkv は種類のアイコンのまま。
///
/// ■ 実体と拡張子が食い違うファイル
/// `MediaContainerSniffer` で実体を見て、食い違うときだけ `Request.contentType` で宣言し直す。
///
/// ■ `hev1` の HEVC
/// AVFoundation が入口で断るので、どの型を宣言しても作れない。`RetaggedHEVCThumbnailLoader` が引き取る。
nonisolated struct QuickLookVideoThumbnailLoader: VideoThumbnailLoading {
    private let timeoutSeconds: Double

    init(timeoutSeconds: Double = VideoThumbnailer.timeoutSeconds) {
        self.timeoutSeconds = timeoutSeconds
    }

    private struct Preparation: Sendable {
        let size: CGSize
        let contentType: UTType?
    }

    /// 要求の大きさと宣言する型を、**先頭を 1 度読むだけで**決める。縦横比を補うのは実体が Matroska のときだけ
    /// (拡張子で絞ると、`.mp4` を名乗る mkv で補正が効かず正方形に潰れた ―― qooLibrary 実測)。16 バイトの判定が
    /// 「型の宣言し直し」と「mp4 の先頭 8MB を読まない」の両方を兼ねる。ブロッキングなので FileIO の上で呼ぶ。
    private static func prepare(for url: URL, maxPixelSize: Int) -> Preparation {
        let square = CGSize(width: maxPixelSize, height: maxPixelSize)
        let container = MediaContainerSniffer.sniff(fileAt: url)
        let contentType = container?.contentTypeToDeclare(forFileNamed: url.lastPathComponent)
        guard container == .matroska,
              let dimensions = MatroskaDimensionReader.dimensions(of: url),
              dimensions.width > 0, dimensions.height > 0
        else { return Preparation(size: square, contentType: contentType) }
        let aspect = dimensions.width / dimensions.height
        let size = aspect >= 1
            ? CGSize(width: Double(maxPixelSize), height: Double(maxPixelSize) / aspect)
            : CGSize(width: Double(maxPixelSize) * aspect, height: Double(maxPixelSize))
        return Preparation(size: size, contentType: contentType)
    }

    /// `QLThumbnailGenerator.Request` は Sendable ではない。タイムアウト側からは `cancel(_:)` に渡す識別子としてだけ使う。
    private struct RequestBox: @unchecked Sendable {
        let request: QLThumbnailGenerator.Request
    }

    @concurrent func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let preparation = await FileIO.perform { () -> Preparation in Self.prepare(for: url, maxPixelSize: maxPixelSize) }
        if Task.isCancelled { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: preparation.size, scale: 1, representationTypes: .thumbnail
        )
        // `contentType` は null_resettable。拡張子任せのままにするときは代入自体をしない。
        if let contentType = preparation.contentType {
            request.contentType = contentType
        }
        let box = RequestBox(request: request)

        enum Outcome: Sendable { case generated(CGImage?), timedOut }

        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: box.request) { thumbnail, _ in
                        continuation.resume(returning: .generated(thumbnail?.cgImage))
                    }
                }
            }
            group.addTask { [timeoutSeconds] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return .timedOut
            }
            let first = await group.next()
            if case .timedOut = first {
                // **走っている要求を明示的に取り消す。** 呼ばないと完了ハンドラが来ず、グループが子の終わりを待って
                // このスコープから抜けられない(qooLibrary 実測)。
                QLThumbnailGenerator.shared.cancel(box.request)
            } else {
                // **作り終えたら眠っているタイムアウト側を起こす。** 起こさないと下の待ち合わせが 8 秒の満了まで続き、
                // 成功した動画 1 本ごとに同時実行の枠を 8 秒ふさいでいた(qooLibrary の監査で発見)。
                group.cancelAll()
            }
            for await _ in group {}
            if case .generated(let image) = first { return image }
            return nil
        }
    }
}

/// 複数の作り方を順に試し、最初にできた絵を返す。既定は **QuickLook → `hev1` の再タグ付け**。
///
/// QuickLook を先にするのは、フレームの選び方・縦横比・ハードウェアの復号を OS に任せられるうちは任せたいから。
/// 再タグ付けは `hev1` に絞った最小限の代わりの経路で、対象外のファイルはトラックの情報を読むだけで nil を返す。
nonisolated struct CompositeVideoThumbnailLoader: VideoThumbnailLoading {
    /// private にしないのは、既定の並びをテストで確かめるため。
    let loaders: [any VideoThumbnailLoading]

    init(loaders: [any VideoThumbnailLoading]) {
        self.loaders = loaders
    }

    init() {
        self.init(loaders: [QuickLookVideoThumbnailLoader(), RetaggedHEVCThumbnailLoader()])
    }

    @concurrent func makeThumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        for loader in loaders {
            // 取り消されていたら次を試さない(画面の外へ出たセルの頼みが、代わりの経路のぶんだけ余計に走らないように)。
            if Task.isCancelled { return nil }
            if let image = await loader.makeThumbnail(for: url, maxPixelSize: maxPixelSize) { return image }
        }
        return nil
    }
}
