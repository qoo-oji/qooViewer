import Foundation
import CoreFoundation
import ZIPFoundation

/// zip / cbz を読むための ArchiveReading 実装。
///
/// 昔の日本語Windows/Macで作られたzipは、ファイル名がUTF-8ではなくShift-JIS等の
/// レガシーな文字コードで格納されていることがある(ZIPの仕様上、UTF-8フラグが
/// 立っていないと ZIPFoundation は codepage437 として読んでしまい、文字化けする)。
/// ここでは、文字化けしていそうなパスを codepage437 として元のバイト列に戻し、
/// 文字コードを推定し直して正しいファイル名に補正している(EntryNameDecoder参照)。
/// nonisolated: PageLoader(actor、メインスレッド外)から呼ばれるため、Xcode 26既定の
/// MainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class ZipArchiveReader: ArchiveReading {
    private let archive: Archive
    /// 補正後のパス -> 実際のZIPFoundationのEntry
    private var entryByCorrectedPath: [String: Entry] = [:]

    init(url: URL) throws {
        self.archive = try Archive(url: url, accessMode: .read)
        indexEntries()
    }

    /// 入れ子になった書庫を、ディスクへ書き出さずメモリ上のDataから直接開く。rar/7zと異なり
    /// ZIPFoundation自体がData版のAPIを持っているため、一時ファイルが不要
    /// (NestedArchiveResolver、およびArchiveKind.opensFromMemory参照)。
    ///
    /// **渡すDataは必ず独立した実体にすること。** ZIPFoundationのMemoryFileはこのDataを
    /// 保持し続ける(funopenでFILE*を被せ、読み出しのたびにcopyBytesする実装)。ここへ
    /// 親書庫のバッファのsubrange(スライス)をそのまま渡すと、Swiftのスライスは元の
    /// バッファ全体を参照し続けるため、この小さな書庫を1つ開いているだけで**親の全バイトが
    /// 道連れで常駐する**。取り出した結果をそのまま渡すぶんには問題ない
    /// (ArchiveReading.data(at:)はどの実装も新しいDataを組み立てて返す)。
    init(data: Data) throws {
        self.archive = try Archive(data: data, accessMode: .read)
        indexEntries()
    }

    private func indexEntries() {
        // 判定はエントリ単位ではなく書庫単位で行うため、先に全エントリを集めてから
        // まとめてデコーダを作る(EntryNameDecoderのコメント参照)。
        let entries = archive.filter { $0.type == .file }
        let decoder = EntryNameDecoder(mangledPaths: entries.map(\.path))
        for entry in entries {
            entryByCorrectedPath[decoder.correctedPath(for: entry.path)] = entry
        }
    }

    func listFilePaths() throws -> [String] {
        Array(entryByCorrectedPath.keys)
    }

    /// 事前確保してよい非圧縮サイズの上限(64MB)。
    ///
    /// `entry.uncompressedSize`はセントラルディレクトリの自己申告値で、細工された書庫では
    /// Int.maxを超える値や天文学的な値になりうる。`Int(_:)`変換はInt.max超えで**トラップ
    /// (クラッシュ)**し、素直に信じると本を開いた瞬間(先読み)に過大確保でアプリが落ちる。
    /// 事前確保はあくまで再確保を減らすための最適化なので、健全な範囲までに留める
    /// (不足分はextractのチャンク追加で伸びるため、読み取り自体は正しく完了する)。
    /// 展開後サイズそのものの歯止めは呼び出し側(PageLoader.rawData / ComicInfoResolver /
    /// EpubStructureResolver / NestedArchiveResolver)が持つ。
    private static let reserveCapByteCount = 64 * 1024 * 1024

    func data(at path: String) throws -> Data {
        guard let entry = entryByCorrectedPath[path] else { throw ArchiveReaderError.entryNotFound }
        var result = Data()
        result.reserveCapacity(Int(min(entry.uncompressedSize, UInt64(Self.reserveCapByteCount))))
        _ = try archive.extract(entry) { chunk in
            result.append(chunk)
        }
        return result
    }

    /// 目的のバイト数に達したことを伝えるためだけの内部エラー。ZIPFoundationのextractは
    /// 「途中で止める」APIを持たないが、チャンクを受け取るクロージャ(Consumer)がthrowできる
    /// ので、それを打ち切りの合図として使い、呼び出し側で握り潰す。
    private struct PrefixReached: Error {}

    /// ArchiveReading.dataPrefix(at:maxByteCount:)のzip実装(プロトコル側のコメント参照)。
    /// 必要なバイト数が溜まった時点で伸長を打ち切る。
    ///
    /// extractは呼び出しのたびに対象エントリの先頭へ必ずシークし直す(ZIPFoundationの
    /// Archive+Reading.swift参照)ため、途中で打ち切ってもアーカイブ側の読み取り位置は
    /// 次回以降に影響しない。
    ///
    /// skipCRC32: true — CRC32はエントリ全体を読み切って初めて検証できる値で、途中で
    /// 打ち切るこの経路では最後まで計算しようがない。計算させても結果を使えないため省く
    /// (伸長した範囲のチェックサム計算ぶんだけ速くなる)。
    func dataPrefix(at path: String, maxByteCount: Int) throws -> Data {
        guard let entry = entryByCorrectedPath[path] else { throw ArchiveReaderError.entryNotFound }
        guard maxByteCount > 0 else { return Data() }
        var result = Data()
        // maxByteCountで頭打ちになるが、Int(_:)はInt.max超えの申告値でトラップするため
        // clampingで安全に変換する(reserveCapByteCountのコメント参照)。
        result.reserveCapacity(min(maxByteCount, Int(clamping: entry.uncompressedSize)))
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                result.append(chunk)
                if result.count >= maxByteCount { throw PrefixReached() }
            }
        } catch is PrefixReached {
            // 必要なぶんが読めたので打ち切っただけ。正常系。
        }
        return result
    }

    /// zipのセントラルディレクトリはMS-DOS形式の更新日時しか持たず、作成日時という概念が無い
    /// ため、createdは常にnil(ArchiveReading.entryDates(at:)のコメント参照)。
    func entryDates(at path: String) -> (created: Date?, modified: Date?) {
        guard let entry = entryByCorrectedPath[path] else { return (nil, nil) }
        return (nil, entry.fileAttributes[.modificationDate] as? Date)
    }

    /// ArchiveReading.extract(at:to:maxByteCount:)のzip実装(プロトコル側のコメント参照)。
    /// ZIPFoundationのconsumer版extractは、伸長したチャンクを順にクロージャへ渡す
    /// (Archive+Reading.swift参照)ため、エントリの大きさに関わらずメモリのピークは
    /// バッファ1つぶんに収まる。
    ///
    /// 以前は`extract(_:to:)`(ライブラリがファイルへ直接書く版)だったが、それだと書き出した
    /// 量を数えられず、索引が嘘をついている書庫を上限で止められなかった(監査で指摘)。
    /// チャンクごとに累計を数え、上限を超えた時点でthrowして伸長を打ち切る。書きかけの
    /// ファイルは残さない。CRCの検証はライブラリの既定どおり行う(以前と同じ)。
    func extract(at path: String, to url: URL, maxByteCount: Int) throws {
        guard let entry = entryByCorrectedPath[path] else { throw ArchiveReaderError.entryNotFound }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ArchiveReaderError.cannotOpen
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var writtenByteCount = 0
            _ = try archive.extract(entry) { chunk in
                writtenByteCount += chunk.count
                guard writtenByteCount <= maxByteCount else { throw ArchiveReaderError.entryTooLarge }
                try handle.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// セントラルディレクトリが持つ非圧縮サイズをそのまま返す(展開は伴わない)。
    func entryUncompressedSize(at path: String) -> Int64? {
        guard let entry = entryByCorrectedPath[path] else { return nil }
        return Int64(entry.uncompressedSize)
    }
}

/// 文字化けしたzipエントリ名を、書庫単位で文字コード判定して補正する。
///
/// **判定は1エントリずつではなく、書庫全体でまとめて1回行う。** ファイル名は数バイト〜
/// 数十バイトしかなく、1件ずつ渡すと統計的な手がかりが足りずに外れる。実測では
/// 「口絵.jpg」「扉.jpg」のような短い名前がwindows-1254/1257等と誤判定され、日本語の
/// ファイル名60件のうち個別判定で正しく戻せたのは46件だった。同じ60件を連結して1回
/// 判定すれば、日本語(CP932 / EUC-JP)・韓国語(CP949)・中国語(GBK / Big5)いずれも全て
/// 正しく戻せる。
///
/// 判定にはFoundationの`NSString.stringEncoding(for:...)`を使う。以前はuchardetの
/// Swiftラッパー(UniversalCharsetDetection)に依存していたが、
/// - 上と同じ60件を当時の実装(1件ずつ判定)に通すと**正解は5件だけ**で、日本語書庫の
///   ファイル名のほとんどを化けたまま通していた(WINDOWS-1252等を返すため)
/// - 韓国語・中国語のファイル名は0件正解(`UHC`のようにIANA名として解決できない名前を
///   返すことがあり、その場合は補正自体が行われない)
/// - 本家パッケージがuchardetを`git://cgit.freedesktop.org/...`のサブモジュールとして
///   参照しており、このプロトコルは配信終了済みで誰も解決できない(そのためURLだけを
///   差し替えたフォークを使っていた)
/// という理由で、依存ごと削除してFoundationに置き換えた。
///
/// Foundationの判定はアルゴリズム非公開で、OSの更新で結果が変わりうる。そのため
/// 判定結果をそのまま信じず、必ず「そのエンコーディングで実際に読めるか」を検証し、
/// 読めなければ決め打ちの候補順・最後は補正なしへ落とす(下記)。
///
/// **既知の限界**: 1つの書庫の中でレガシーな文字コードが2種類以上混ざっている場合
/// (例: CP932のエントリとCP949のエントリが同居)は正しく直せない。書庫全体で1つの
/// 文字コードを選ぶ設計のうえ、この手の文字コードは互いのバイト列を「読めてしまう」ため、
/// どちらか一方に倒れる。UTF-8だけは例外で、バイト列として厳密に検証できるため
/// エントリ単位で先に拾う(下記のdecodedAsUTF8)。
private nonisolated struct EntryNameDecoder {

    /// 書庫全体から決めた文字コード。決められなければnil(＝補正しない)。
    private let archiveEncoding: String.Encoding?

    /// 自動判定が何も返さなかったときに、決め打ちの順で試す候補。
    ///
    /// マルチバイトの文字コードは不正なバイト列をデコード時に弾いてくれる(＝検証として
    /// 働く)のに対し、windows-1252はほぼどんなバイト列でも通ってしまうため最後に置く。
    private static let fallbackCandidates: [String.Encoding] = [
        .shiftJIS, .japaneseEUC, .codepage949, .codepage936, .codepage950, .windowsCP1252,
    ]

    /// - Parameter mangledPaths: ZIPFoundationがcodepage437として読んだ状態のパス。
    init(mangledPaths: [String]) {
        // 判定材料は非ASCIIを含むものだけにする。ASCIIだけの名前はどの候補で読んでも
        // 同じ結果になり、判定を薄めるだけなので除く。
        // UTF-8として妥当なものも除く。UTF-8は他のレガシーな文字コードと違ってバイト列
        // だけで妥当性を判定できるので推定に頼る必要がなく、混ぜると「UTF-8のエントリと
        // CP932のエントリが同居する書庫」で両方に化ける文字コードが選ばれてしまう。
        let samples = mangledPaths.compactMap { Self.rawBytes(of: $0) }
            .filter { $0.contains { $0 >= 0x80 } && Self.decodedAsUTF8($0) == nil }
        self.archiveEncoding = Self.encoding(decodingAll: samples)
    }

    /// 補正後のパスを返す。補正できない/する必要がないものは元のパスをそのまま返す。
    func correctedPath(for mangledPath: String) -> String {
        guard
            let raw = Self.rawBytes(of: mangledPath),
            raw.contains(where: { $0 >= 0x80 })
        else {
            // codepage437へ戻せない = 元からUTF-8等として正しく読めている。
            // ASCIIだけの名前も化けようがないため、どちらもそのまま。
            return mangledPath
        }
        // UTF-8として妥当なバイト列は、推定を挟まずUTF-8として読む(UTF-8フラグを
        // 立て忘れている書庫がこれに当たる)。レガシーな文字コードのファイル名が偶然
        // マルチバイトのUTF-8として妥当になることはまず無いため、取り違えは起きない。
        if let corrected = Self.decodedAsUTF8(raw) {
            return corrected
        }
        if let encoding = archiveEncoding, let corrected = Self.decode(raw, as: encoding) {
            return corrected
        }
        // 書庫全体の文字コードでは読めないエントリだけ、そのエントリ単体で判定し直す
        // (1つの書庫に複数の文字コードが混在する書庫への保険)。ここも読めなければ
        // 補正せずに元のパスを返す — 根拠のない当て推量で改名するより、文字化けした
        // ままの方が利用者から見て「化けている」と分かるぶん安全。
        if let encoding = Self.detect(raw), let corrected = Self.decode(raw, as: encoding) {
            return corrected
        }
        return mangledPath
    }

    /// codepage437として再エンコードできる = 実際のUTF-8(日本語などを含む)ではなく、
    /// 1バイトずつcodepage437として誤読された文字列である可能性が高い、という判定。
    /// (実在する日本語などの文字はcodepage437の文字集合に含まれないため、
    ///  正しくUTF-8デコードされたパスは基本的にこの変換に失敗する)
    private static func rawBytes(of mangledPath: String) -> Data? {
        mangledPath.data(using: .codepage437)
    }

    /// 標本すべてを読み切れる文字コードを1つ選ぶ。
    ///
    /// 自動判定の結果であっても、標本の中に1つでも読めないものがあれば採用しない。
    /// 「その文字コードなら全エントリが破綻なく読める」という一致は、1件だけ読めた
    /// ことよりはるかに強い根拠になる。
    private static func encoding(decodingAll samples: [Data]) -> String.Encoding? {
        guard !samples.isEmpty else { return nil }

        var joined = Data()
        for sample in samples {
            if !joined.isEmpty { joined.append(0x0A) }
            joined.append(sample)
        }
        func decodesAll(_ encoding: String.Encoding) -> Bool {
            samples.allSatisfy { decode($0, as: encoding) != nil }
        }
        if let detected = detect(joined), decodesAll(detected) {
            return detected
        }
        return fallbackCandidates.first(where: decodesAll)
    }

    /// Foundationによる文字コードの自動判定。
    ///
    /// allowLossyKeyは省略時YES(＝読めない文字をU+FFFDに置き換えてでも結果を返す)なので、
    /// 明示的に禁止し、さらにusedLossyConversionも確認して欠落のある結果は捨てる。
    private static func detect(_ data: Data) -> String.Encoding? {
        var converted: NSString?
        var usedLossyConversion: ObjCBool = false
        let rawValue = NSString.stringEncoding(for: data,
                                               encodingOptions: [.allowLossyKey: false],
                                               convertedString: &converted,
                                               usedLossyConversion: &usedLossyConversion)
        guard rawValue != 0, !usedLossyConversion.boolValue else { return nil }
        return String.Encoding(rawValue: rawValue)
    }

    /// UTF-8として妥当で、かつ実際にマルチバイト文字を含むときだけ文字列を返す。
    /// (ASCIIだけの場合はここでは扱わない。呼び出し側で先に除いている)
    private static func decodedAsUTF8(_ raw: Data) -> String? {
        guard let decoded = String(data: raw, encoding: .utf8), decoded.contains(where: { !$0.isASCII }) else {
            return nil
        }
        return decoded
    }

    /// 指定の文字コードとして破綻なく読めたときだけ文字列を返す。
    /// 置換文字(U+FFFD)が混ざったものは「読めた」とみなさない。
    private static func decode(_ raw: Data, as encoding: String.Encoding) -> String? {
        guard
            let decoded = String(data: raw, encoding: encoding),
            !decoded.isEmpty,
            !decoded.unicodeScalars.contains("\u{FFFD}")
        else {
            return nil
        }
        return decoded
    }
}

/// ZIPFoundation内部にもcodepage437と同名の定義があるが、外部モジュールからは参照できない
/// (internal)ため、同じ仕組み(DOS Latin US)をこちらでも定義しておく。
/// nonisolated: EntryNameDecoder(nonisolated struct)から参照するため、こちらもXcode既定の
/// MainActor自動分離の対象外にしておく必要がある(付けないと「Main actor-isolated static
/// property 'codepage437' can not be referenced from a nonisolated context」というビルド
/// エラーになる)。
private extension String.Encoding {
    nonisolated static let codepage437 = fromCFStringEncoding(CFStringEncoding(0x400))
    /// 韓国語Windows (Unified Hangul Code)
    nonisolated static let codepage949 = fromCFStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
    /// 簡体字中国語Windows (GBK)
    nonisolated static let codepage936 = fromCFStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseSimplif.rawValue))
    /// 繁体字中国語Windows (Big5)
    nonisolated static let codepage950 = fromCFStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue))

    nonisolated static func fromCFStringEncoding(_ encoding: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}
