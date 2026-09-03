import Foundation

/// 「そのページの画像は、どの書庫の中にあるのか」を表す座標。
///
/// ■ なぜURL1本では足りないのか
/// このアプリは書庫の中の書庫(章ごとに書庫化されたものが1つの書庫に詰められている、
/// フォルダの中に章ごとの書庫が並んでいる等)を1冊の本として開ける。以前は、入れ子になった
/// 書庫を本を開く時点ですべて一時ファイルへ書き出し、`PageSource`にはその一時ファイルの
/// URLを持たせていた ―― つまり「ページの出所」がディスク上の実ファイルであることを前提に
/// していた。この方式は、本を閉じるまで入れ子の書庫がまるごとディスクに居座り
/// (実測で8.4GBの残骸が溜まっていた。`TemporaryFileStore`の型コメント参照)、本を開く瞬間に
/// 全部の伸長と書き出しを一括で払う、という2つの代償を伴っていた。
///
/// そこで「出所」を実ファイルのURLではなく、**ユーザーが選んだ実在ファイル + そこから潜る
/// 道順**という座標で表すことにした。これなら、実際に書庫を開く必要が生じるまで展開を
/// 遅らせられる(`NestedArchiveResolver`)。予算に収まる書庫はメモリ上のまま開けるため
/// ディスクに一切出ず、予算より大きいものも、同時に使うぶんだけを一時ファイルにすれば済む。
///
/// ■ rootURLは必ず実在する
/// `rootURL`は常に「ユーザーが選んだファイル」か「ユーザーが選んだフォルダの中に実在する
/// 書庫ファイル」のいずれかで、一時ファイルを指すことは無い。サンドボックスのアクセス権
/// (`AppState.securityScopedBookURLs`)がそのまま効く相手であり、Finderで表示する対象
/// (`FinderReveal`)としてもそのまま使える。
///
/// ■ nestedPathは「親の中でのエントリパス」の積み重ね
/// 空なら`rootURL`自身を指す。`["vol1.7z", "ch03.cbz"]`なら「rootURLの中のvol1.7z、その中の
/// ch03.cbz」を指す。各要素は**その親の中での完全なエントリパス**であり、
/// `"chapters/ch03.cbz"`のようにフォルダを含みうる(書庫の中のフォルダはエントリパスの
/// 一部でしかないため)。
///
/// nonisolated: `BookLoader`(Task.detached内)が組み立て、`PageLoader`(actor)が読み出す。
/// つまりメインアクターの外で使われる値型のため(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated struct ArchiveLocator: Hashable, Sendable {
    /// ディスク上に実在する書庫ファイル。ここを起点に`nestedPath`を辿る。
    let rootURL: URL
    /// `rootURL`の中を潜っていくエントリパスの並び。空なら`rootURL`自身。
    let nestedPath: [String]

    init(rootURL: URL, nestedPath: [String] = []) {
        self.rootURL = rootURL
        self.nestedPath = nestedPath
    }

    /// 入れ子になった書庫か(= 開くのに親からの取り出しが要るか)。
    var isNested: Bool { !nestedPath.isEmpty }

    /// この座標が指している書庫のファイル名。形式の判定(zip / rar / 7z)は、
    /// **必ずこの名前の拡張子**から行う。エントリパスはフォルダを含みうるため、
    /// 最後のパス要素だけを取り出している。
    var archiveFileName: String {
        guard let last = nestedPath.last else { return rootURL.lastPathComponent }
        return (last as NSString).lastPathComponent
    }

    /// 1段浅い座標(この書庫を含んでいる書庫)。`rootURL`自身を指しているならnil。
    var parent: ArchiveLocator? {
        guard isNested else { return nil }
        return ArchiveLocator(rootURL: rootURL, nestedPath: Array(nestedPath.dropLast()))
    }

    /// 親の中でのこの書庫のエントリパス。`rootURL`自身を指しているならnil。
    var entryPathInParent: String? { nestedPath.last }

    /// この書庫の中で見つかった`entryPath`という書庫を指す、1段深い座標。
    func appending(_ entryPath: String) -> ArchiveLocator {
        ArchiveLocator(rootURL: rootURL, nestedPath: nestedPath + [entryPath])
    }

    /// 入れ子の深さ(`rootURL`自身が0)。`BookLoader.maxNestedArchiveDepth`の判定に使う。
    var depth: Int { nestedPath.count }

    /// ユーザーに見せる「この書庫の場所」(コンテキストメニュー「情報を見る」の“場所”欄)。
    /// 入れ子の場合は`/Users/…/vol1.7z/ch03.cbz`のように、実ファイルのパスの後ろへ
    /// 潜った道順をそのまま続ける。以前はここに一時ファイルのパス
    /// (`…/tmp/qooViewer-1234/<UUID>.cbz`)が出ていて、ユーザーには何の情報にも
    /// なっていなかった。
    var displayPath: String {
        guard isNested else { return rootURL.path }
        return ([rootURL.path] + nestedPath).joined(separator: "/")
    }
}
