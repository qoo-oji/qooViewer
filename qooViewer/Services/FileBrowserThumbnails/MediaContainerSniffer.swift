import Foundation
import UniformTypeIdentifiers

/// 動画ファイルの**実体のコンテナ形式**(拡張子ではなく先頭バイト列で見分ける。改善要望7 段階 7b、2026-09-14。
/// qooLibrary の `MediaContainer` を写したもの)。
///
/// ■ なぜ拡張子では足りないのか(qooLibrary の実機の蔵書で踏んだ)
/// macOS は UTI を**拡張子から**決めるので、実体と拡張子が食い違うファイルは違うパーサへ渡されて絵ができない。
/// `.mp4` を名乗る実体 Matroska のファイル(ダウンロード元の付け間違いで普通に流通する)は
/// `QLThumbnailErrorDomain code 102` で即座に失敗し、mkv を扱える QuickLook 拡張が入っていても**呼ばれさえしなかった**。
///
/// ■ 16 バイトで足りる
/// どの形式も先頭の署名だけで決まる(いちばん奥まで見るのは AVI の 12 バイト目)。動画の中身は復号しない。
nonisolated enum MediaContainer: Sendable, Equatable, CaseIterable {
    /// ISO Base Media File Format(mp4 / m4v / mov)。
    case isoBMFF
    /// Matroska / EBML(mkv / webm)。区別するには DocType まで読む必要があるが、同じ拡張が両方を扱うので分けない。
    case matroska
    /// RIFF / AVI。
    case avi
    /// Advanced Systems Format(wmv / asf)。
    case asf
    /// Flash Video。
    case flv

    /// この形式を素直に名乗る拡張子。**ここに入っていれば宣言し直さない。**
    var matchingExtensions: Set<String> {
        switch self {
        case .isoBMFF: ["mp4", "m4v", "mov", "qt"]
        case .matroska: ["mkv", "webm", "mka", "mks"]
        case .avi: ["avi"]
        case .asf: ["wmv", "asf", "wma"]
        case .flv: ["flv", "f4v"]
        }
    }

    /// 「この形式はこの機で何という型か」をシステムに尋ねるための代表の拡張子。
    var canonicalExtension: String {
        switch self {
        case .isoBMFF: "mp4"
        case .matroska: "mkv"
        case .avi: "avi"
        case .asf: "wmv"
        case .flv: "flv"
        }
    }

    /// 拡張子が実体と食い違うとき、QuickLook へ宣言し直す型(`QLThumbnailGenerator.Request.contentType`)。
    /// 食い違っていなければ nil(拡張子任せのまま)。
    ///
    /// - **型の識別子を決め打ちしない**: `.mkv` の UTI は入っているアプリ次第で変わる(qooLibrary の機では Infuse の
    ///   `com.firecore.fileformat.mkv` になり、`org.matroska.mkv` は存在しなかった)。拡張子からシステムに尋ねる。
    /// - **上位の型では通らない**: `public.movie` を渡しても 102 で失敗した。拡張が登録した具体的な型でなければならない。
    func contentTypeToDeclare(forFileNamed name: String) -> UTType? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !matchingExtensions.contains(ext) else { return nil }
        return Self.concreteMovieType(forExtension: canonicalExtension)
    }

    /// システムがこの拡張子に割り当てている**具体的な動画の型**。無ければ nil。
    ///
    /// `UTType(filenameExtension:)` は未知の拡張子でも nil を返さず、**`dyn.…` の型を作って返す**(qooLibrary 実測)。
    /// `.movie` への準拠を求めてそれを弾く ―― mkv を扱うアプリが 1 つも無い機(CI)で、意味の無い型を宣言しない。
    static func concreteMovieType(forExtension ext: String) -> UTType? {
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .movie) else { return nil }
        return type
    }
}

/// 先頭バイト列から `MediaContainer` を見分ける。
nonisolated enum MediaContainerSniffer {
    /// 見分けるのに読むバイト数。
    static let probeBytes = 16

    /// 純粋関数。見分けられなければ nil。
    static func sniff(_ bytes: [UInt8]) -> MediaContainer? {
        // EBML(Matroska / WebM)。
        if starts(bytes, with: [0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        // ISO BMFF は先頭が箱の大きさなので、種類はオフセット 4 から。
        if matches(bytes, at: 4, ascii: "ftyp") { return .isoBMFF }
        // RIFF は音声(WAVE)も同じ署名なので、フォームタイプまで見る。
        if matches(bytes, at: 0, ascii: "RIFF"), matches(bytes, at: 8, ascii: "AVI ") { return .avi }
        // ASF ヘッダオブジェクトの GUID の先頭 4 バイト。
        if starts(bytes, with: [0x30, 0x26, 0xB2, 0x75]) { return .asf }
        if matches(bytes, at: 0, ascii: "FLV") { return .flv }
        return nil
    }

    /// ファイルの先頭を読んで見分ける。**ブロッキングするので FileIO の上で呼ぶ。**
    static func sniff(fileAt url: URL) -> MediaContainer? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: probeBytes) else { return nil }
        return sniff([UInt8](data))
    }

    private static func starts(_ bytes: [UInt8], with signature: [UInt8]) -> Bool {
        bytes.count >= signature.count && Array(bytes[0..<signature.count]) == signature
    }

    private static func matches(_ bytes: [UInt8], at offset: Int, ascii: String) -> Bool {
        let signature = Array(ascii.utf8)
        guard bytes.count >= offset + signature.count else { return false }
        return Array(bytes[offset..<(offset + signature.count)]) == signature
    }
}
