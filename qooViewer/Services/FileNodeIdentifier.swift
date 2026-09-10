import Foundation

/// ユーザー要望: お気に入り・レイアウト・ブックマークのデータを、ファイルパス(bookID)だけに
/// 頼らず、ファイルノード(iノード番号)でも識別できるようにしたい。これにより、同一ボリューム内
/// でファイル/フォルダを移動・リネームしても、お気に入り・レイアウト・ブックマークを引き継げる
/// ようにする(ボリュームを跨いだ移動は諦める)。
///
/// iノード番号はファイルシステム内でのみ一意なため、異なるボリューム(ファイルシステム)にある
/// 別ファイルが偶然同じiノード番号を持つことがありうる。そのため「iノード番号 + どのボリュームか」
/// の組を「ファイルノード識別子」として扱う。
///
/// ■ ボリュームの同定にデバイス番号(st_dev)を使うのをやめた理由(実測 2026-09-10)
/// 元々はボリュームをデバイス番号(FileManagerの.systemNumber、POSIXのstat()のst_devに相当)
/// だけで表していた。「再マウントやOS再起動で変わりうるが、同じマウント状態が続く限りは安定」
/// という前提だったが、**実際には他のボリュームを先に挿しただけで変わる**。st_devの下位バイトは
/// attach時に割り当てられるスロット番号であり、ディスクイメージで測ると:
///
/// ```
/// A を単独でマウント:           st_dev=16777249  st_ino=17
/// B を先にマウントしてから A:   st_dev=16777253  st_ino=17   ← 同一ファイル・無変更
/// ```
///
/// 外付けを複数使っていて挿す順番が変わる、ハブの都合で列挙順が変わる、といった普通の状況で、
/// 無変更のファイルが「別のファイル」と判定される。この状態で本をリネームすると、5つのストア
/// (お気に入り・ブックマーク・レイアウト・メタデータ・コレクション)の追従がすべて黙って失敗し、
/// 保存データの読み込み時の照合(`resolvedURL(matching:)`)も外れる。
///
/// そこで**ボリュームの同定は`volumeUUID`(URLResourceKeyの`.volumeUUIDStringKey`)を主とする**。
/// 同じ実測で、st_devが変わった条件でもUUIDは一致していた(`.volumeIdentifierKey`のほうは
/// st_devと同様に変わったので使わない ―― ドキュメントどおり「マウント中のみ有効」な値)。
///
/// ■ デバイス番号を残してある理由
/// 1. **UUIDを持たないボリュームがある。** ネットワークボリュームや一部の合成マウントでは
///    `.volumeUUIDStringKey`が取れない。そこではこれまで通りデバイス番号で照合する。
/// 2. **UUIDを記録する前に保存された行がある。** 既存データはデバイス番号しか持たないので、
///    片側でもUUIDが無ければデバイス番号で比べる(==の実装参照)。これらの行は、その本を開いた
///    タイミングで各ストアの`backfillFileNodeIdentifier`がUUIDを書き足して昇格する。
///
/// なお、照合が外れた場合も「移動を検知できず、従来通りファイルパスでの照合にフォールバックする」
/// だけで、データ自体はbookID(パス)をキーとして保持され続ける。
struct FileNodeIdentifier: Hashable, Codable {
    /// stat()のst_inoに相当するiノード番号。
    var inodeNumber: Int64
    /// stat()のst_devに相当する、ファイルシステム(ボリューム)を識別する番号。
    /// **マウント順で変わりうる**ので、単独では当てにしない(型コメント参照)。
    var volumeDeviceNumber: Int64
    /// ボリュームのUUID(`.volumeUUIDStringKey`)。マウントを跨いで安定する。
    /// 取得できないボリューム・これを記録する前に保存された行ではnil。
    var volumeUUID: String?

    /// 指定URLの現在のファイルノード識別子を取得する。取得できない(ファイルが存在しない、
    /// アクセス権が無い等)場合はnil。ボリュームUUIDだけが取れない場合はnilのまま値を返す
    /// (iノード + デバイス番号での照合は従来どおり成立するため)。
    ///
    /// 呼び出し側は、サンドボックス環境でアクセス権が必要なURLに対しては、あらかじめ
    /// `startAccessingSecurityScopedResource()`を呼んでおく必要がある(このメソッド自体は
    /// アクセス権の開始/終了を行わない。ContentFingerprint.current(for:)と同じ役割分担)。
    ///
    /// `nonisolated`: 中身はファイル属性の問い合わせ(stat相当)だけで、アクターの状態には
    /// 一切触れない。一方でこの問い合わせは、対象が未接続の外付け/ネットワークボリュームを
    /// 指していると秒単位ブロックしうるため、メインアクターの外から呼べる必要がある
    /// (このプロジェクトの既定のアクター隔離はMainActorなので、明示しないとメインアクター
    /// 限定になってしまう。Services/ArchiveReading.swift冒頭のコメント参照)。
    nonisolated static func current(for url: URL) -> FileNodeIdentifier? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber
        else { return nil }
        // iノード/デバイス番号とは別の問い合わせになる(attributesOfItemはst_devしか返さない)。
        // 失敗してもここで諦めない ―― 上のguardを通った時点で従来と同じ識別子は作れている。
        let volumeUUID = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return FileNodeIdentifier(
            inodeNumber: inode.int64Value,
            volumeDeviceNumber: device.int64Value,
            volumeUUID: volumeUUID
        )
    }

    /// 行に記録済みの識別子を、今取れた識別子で書き足すべきか。
    ///
    /// 各ストアの`backfillFileNodeIdentifier`が使う。識別子そのものを持たない古い行に加えて、
    /// **iノード + デバイス番号は持つがボリュームUUIDを持たない行**も対象にする ―― そこが
    /// 既存データをUUIDでの照合へ昇格させる唯一の経路(型コメント参照)。判定を1箇所に置いて
    /// おかないと、5つのストアのどれかだけ昇格しない、という取りこぼしが起きる。
    static func needsBackfill(_ recorded: FileNodeIdentifier?) -> Bool {
        guard let recorded else { return true }
        return recorded.volumeUUID == nil
    }

    /// 「同じファイルか」の判定。iノード番号が一致し、かつ同じボリュームだと言えることを求める。
    ///
    /// ボリュームの比較は**両方がUUIDを持つときだけUUIDで**行い、片側でも欠けていれば
    /// デバイス番号で比べる(UUIDを持たないボリューム・UUIDを記録する前の古い行のため。
    /// 型コメント参照)。UUIDが両方あって食い違うなら、デバイス番号が偶然一致していても別物。
    ///
    /// この緩いフォールバックのため、**==は推移的でない**
    /// (A(uuid: X, dev: 1) == B(uuid: nil, dev: 1)、A == C(uuid: X, dev: 2)、しかし B != C)。
    /// `hash(into:)`がiノード番号だけを混ぜるのはそのためで、同じiノードの候補が必ず同じバケツに
    /// 入るので`Set.contains`・`filter`は「どれか1つと一致するか」を正しく答える。
    /// **この型をSetに入れてよいのは重複判定の用途だけ**で、集合演算の結果を期待してはいけない。
    static func == (lhs: FileNodeIdentifier, rhs: FileNodeIdentifier) -> Bool {
        guard lhs.inodeNumber == rhs.inodeNumber else { return false }
        if let lhsUUID = lhs.volumeUUID, let rhsUUID = rhs.volumeUUID {
            return lhsUUID == rhsUUID
        }
        return lhs.volumeDeviceNumber == rhs.volumeDeviceNumber
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(inodeNumber)
    }
}
