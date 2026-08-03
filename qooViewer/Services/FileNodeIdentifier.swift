import Foundation

/// ユーザー要望: お気に入り・レイアウト・ブックマークのデータを、ファイルパス(bookID)だけに
/// 頼らず、ファイルノード(iノード番号)でも識別できるようにしたい。これにより、同一ボリューム内
/// でファイル/フォルダを移動・リネームしても、お気に入り・レイアウト・ブックマークを引き継げる
/// ようにする(ボリュームを跨いだ移動は諦める)。
///
/// iノード番号はファイルシステム内でのみ一意なため、異なるボリューム(ファイルシステム)にある
/// 別ファイルが偶然同じiノード番号を持つことがありうる。そのため、iノード番号(inodeNumber)と
/// ボリュームを識別するデバイス番号(volumeDeviceNumber。FileManagerの.systemNumber、
/// POSIXのstat()のst_devに相当)の組を「ファイルノード識別子」として扱う。
///
/// デバイス番号はボリュームの再マウントやmacOSの再起動などで変わりうるため「絶対に不変」では
/// ないが、同一の起動セッション・同一のマウント状態が続く限りは安定しており、iノード番号との
/// 組み合わせでファイルパスより遥かに強い同一性の手がかりになる。万一デバイス番号がズレて
/// 一致しなくなった場合も、単に「移動を検知できず、従来通りファイルパスでの照合にフォールバック
/// する」だけであり、致命的な問題にはならない(お気に入り・レイアウト・ブックマークのデータ自体は
/// bookID(パス)をキーとして引き続き保持されるため)。
struct FileNodeIdentifier: Hashable, Codable {
    /// stat()のst_inoに相当するiノード番号。
    var inodeNumber: Int64
    /// stat()のst_devに相当する、ファイルシステム(ボリューム)を識別する番号。
    var volumeDeviceNumber: Int64

    /// 指定URLの現在のファイルノード識別子を取得する。取得できない(ファイルが存在しない、
    /// アクセス権が無い等)場合はnil。
    ///
    /// 呼び出し側は、サンドボックス環境でアクセス権が必要なURLに対しては、あらかじめ
    /// `startAccessingSecurityScopedResource()`を呼んでおく必要がある(このメソッド自体は
    /// アクセス権の開始/終了を行わない。ContentFingerprint.current(for:)と同じ役割分担)。
    static func current(for url: URL) -> FileNodeIdentifier? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber
        else { return nil }
        return FileNodeIdentifier(inodeNumber: inode.int64Value, volumeDeviceNumber: device.int64Value)
    }
}
