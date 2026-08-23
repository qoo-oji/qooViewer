import Foundation
import CoreGraphics

/// デコード済みのページ画像を、`CGImage`ではなく**生のピクセルのバイト列**として保持するための箱。
/// PageLoaderのメモリキャッシュ(NSCache)に入るのはこの型で、表示のたびに
/// `makeImage()`で使い捨ての`CGImage`を作って渡す。
///
/// ■ なぜCGImageをそのままキャッシュしないのか(実測に基づく)
/// ImageIOがデコードした`CGImage`を画面に出すと、そのピクセル(幅×高さ×4バイト)に加えて
/// 同じ大きさのコピーが**2つ**作られる:
///   - CoreAnimationがGPUへ送るためのテクスチャ
///   - CoreAnimationが`CGDataProviderCopyData`で取り出す中間コピー(`vmmap`で"CG raster data")
/// しかもこの2つは、ページが画面から外れても**その`CGImage`が生きている限り残り続ける**。
/// キャッシュがCGImageを抱えたままだと、一度でも表示したページは実際には3倍のメモリを
/// 占め続ける(2500×3619のページで36MBのはずが108MB。4233×6050の本を8ページ送っただけで
/// アプリ全体が1GBを超えた)。NSCacheのコスト上限は1倍で数えているため、上限として機能
/// していなかった。
///
/// 実測した回避策のうち、最も効いたのがこの方式:
///   - キャッシュにはピクセルのバイト列(`Data`)だけを持つ(1倍)
///   - 表示には、そのバイト列を`CGDataProvider(data:)`で包んだ`CGImage`をその都度作る。
///     バイト列は共有され、コピーは発生しない
///   - CoreAnimationは`CGDataProvider(data:)`のバイト列を直接読めるため"CG raster data"の
///     コピーを作らない。テクスチャは作るが、それは使い捨ての`CGImage`に紐づくので、
///     ページが画面から外れてその`CGImage`が解放されると一緒に消える
/// 結果、キャッシュ済みで非表示のページ1枚あたり 108MB → 36MB になる(ImageIOが
/// purgeableゾーンに置くデコード直後のビットマップは、描き写しが済んだ時点で解放される)。
///
/// ■ ピクセル形式
/// CoreAnimationがそのまま使える形式に揃える。
///   - カラー: 8bit×4、BGRA(`premultipliedFirst` + `byteOrder32Little`)。色空間は元画像の
///     ものをそのまま引き継ぐ(RGB系なら。sRGBへ変換すると広色域の画像で色が変わる)
///   - グレースケール: 8bit×1。ImageIOは白黒JPEGを1バイト/画素で返してくるので、
///     4バイトに広げずそのまま保持する(白黒の本では1/4で済む)。以前のキャッシュの
///     コスト計算は一律`幅×高さ×4`だったため、白黒の本ではキャッシュの1/4しか使えていなかった
///
/// nonisolated / @unchecked Sendable: PageLoader(actor)の外のデコードタスクで作られ、
/// actorの中のNSCacheに入り、MainActorのViewModel/Viewで`makeImage()`される。
/// 保持しているのはinit後に変更されない値だけなので、スレッド間で共有して安全。
nonisolated final class PagePixelBuffer: @unchecked Sendable {
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let bitsPerPixel: Int
    private let colorSpace: CGColorSpace
    private let bitmapInfo: CGBitmapInfo
    /// ピクセル本体。`mmap`で確保した領域を`NSData(bytesNoCopy:length:deallocator:)`で包んだもの
    /// (解放時に`munmap`される。makePixelStorage参照)。
    ///
    /// ■ なぜmallocではなくmmapか(実測に基づく)
    /// `NSMutableData(length:)`や`Data(count:)`(=malloc)で確保した数十MBのバッファは、
    /// **解放してもプロセスの実メモリ(footprint)から減らない**。libmallocは大きなブロックを
    /// 次の確保に使い回すため手元に溜め込み、`malloc_zone_pressure_relief`を呼んでも
    /// 返さなかった(10枚×56MBを確保→解放しても562MBのまま)。本を閉じてもアクティビティ
    /// モニタの数字が戻らない原因がこれだった。`mmap`で確保して`munmap`で返せば、
    /// 解放した瞬間にOSへ戻る(同じ実験で562MB→1.9MB)。
    ///
    /// `NSData`のまま`CGDataProvider(data:)`へ渡すので、表示用のCGImageを作るときにも
    /// コピーは起きない(`CGDataProvider`は参照を保持するだけ)。
    private let pixels: NSData

    /// NSCacheのコストに使う、実際に占めているバイト数。
    var byteCount: Int { pixels.length }

    /// `image`のピクセルを描き写して作る。描き写しは1回だけで、以後`image`は不要になる
    /// (呼び出し側が手放せば、ImageIOのビットマップはそこで解放される)。
    ///
    /// CPUコストはメモリコピー相当(36MBで十数ms)。PageLoaderはこれをデコードと同じ
    /// バックグラウンドタスクの中で行うので、表示の待ち時間には実質乗らない。
    convenience init?(rendering image: CGImage) {
        let isGray = Self.isGrayscaleWithoutAlpha(image)
        // 描き写す先の色空間。元画像の色空間がビットマップコンテキストに使えない種類だった
        // 場合は、指定init側でデバイスグレー/sRGBへ落ちる。
        let colorSpace: CGColorSpace? = isGray ? image.colorSpace : Self.rgbColorSpace(for: image)
        self.init(width: image.width, height: image.height, grayscale: isGray, colorSpace: colorSpace) { context in
            // 等倍の描き写しなので補間は要らない(ピクセルをそのまま運ぶ)。
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// 空のバッファを確保し、`draw`にそのバッファを描画先とするCGContextを渡して中身を描かせる。
    /// PDFのページ描画(PageLoader.renderPDFPixels)のように「CGImageを経由せず直接描ける」
    /// 場合に使う。CGImageを一度作ってから描き写すより、ビットマップ1枚ぶんの確保と
    /// コピーを省ける(4096pxのPDFページなら最大95MB)。
    ///
    /// - Parameters:
    ///   - grayscale: trueなら8bitグレー1チャンネル、falseならBGRA 8bit×4。
    ///   - colorSpace: 描画先の色空間。nil、または受け付けられない種類なら
    ///     グレーはデバイスグレー、カラーはsRGBにする。
    ///   - draw: 描画先のCGContext(原点が左下の、CoreGraphics標準の座標系)。
    init?(
        width: Int,
        height: Int,
        grayscale: Bool,
        colorSpace requestedColorSpace: CGColorSpace? = nil,
        draw: (CGContext) -> Void
    ) {
        guard width > 0, height > 0 else { return nil }

        let bitmapInfo: CGBitmapInfo
        let bytesPerPixel: Int
        // 色空間の候補。先頭から順に試し、CGContextが受け付けたものを使う。
        let colorSpaceCandidates: [CGColorSpace]
        if grayscale {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            bytesPerPixel = 1
            colorSpaceCandidates = [requestedColorSpace, CGColorSpaceCreateDeviceGray()].compactMap { $0 }
        } else {
            bitmapInfo = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            bytesPerPixel = 4
            colorSpaceCandidates = [requestedColorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        }
        // 行の先頭を16バイト境界に揃える(CoreGraphics/CoreAnimationが速い経路を使える)。
        let bytesPerRow = (width * bytesPerPixel + 15) / 16 * 16

        // mmapはゼロ埋めの領域を返す。CGContextはここへ直接描く。
        guard let pixels = Self.makePixelStorage(byteCount: bytesPerRow * height) else { return nil }
        var usedColorSpace: CGColorSpace?
        for candidate in colorSpaceCandidates {
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: pixels.bytes),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: candidate,
                bitmapInfo: bitmapInfo.rawValue
            ) else { continue }
            draw(context)
            usedColorSpace = candidate
            break
        }
        guard let colorSpace = usedColorSpace else { return nil }

        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bitsPerPixel = bytesPerPixel * 8
        self.colorSpace = colorSpace
        self.bitmapInfo = bitmapInfo
        self.pixels = pixels
    }

    /// このバッファを参照する`CGImage`を作る(ピクセルのコピーは行わない)。
    ///
    /// 返る`CGImage`は呼び出し側が必要な間だけ持つこと。表示に使った`CGImage`を手放すと、
    /// CoreAnimationがそれ用に作ったテクスチャも一緒に解放される(型コメント参照)。
    /// 同じバッファから何度作っても、バイト列は1つのまま共有される。
    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: pixels) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - 確保

    /// ピクセル領域を`mmap`で確保し、解放時に`munmap`される`NSData`として返す(pixelsのコメント参照)。
    /// 確保に失敗した場合(アドレス空間の枯渇など)はnil。
    private static func makePixelStorage(byteCount: Int) -> NSData? {
        guard byteCount > 0,
              let raw = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              raw != MAP_FAILED
        else { return nil }
        return NSData(bytesNoCopy: raw, length: byteCount) { pointer, length in
            munmap(pointer, length)
        }
    }

    // MARK: - 形式の判定

    /// 1バイト/画素のまま保持してよい画像か(8bitグレースケール・アルファ無し)。
    private static func isGrayscaleWithoutAlpha(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 8, image.bitsPerComponent == 8,
              image.colorSpace?.model == .monochrome
        else { return false }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: return false
        }
    }

    /// カラー画像を描き写す先の色空間。元がRGB系ならそのまま(色を変えないため)、
    /// それ以外(CMYK・Lab・インデックスカラー等)はsRGBへ変換する。
    private static func rgbColorSpace(for image: CGImage) -> CGColorSpace {
        if let colorSpace = image.colorSpace, colorSpace.model == .rgb {
            return colorSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}
