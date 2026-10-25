import Foundation

// アプリ(qooViewer)と、LAN の SMB サーバを探してその共有をマウントさせるだけの XPC サービス(NetworkVolumeConnector.xpc)の間の約束。
// このファイルはアプリとサービスの両方に入る(project.pbxproj の NetworkVolumeConnector フォルダの例外を参照)。
//
// ■ なぜ XPC サービスに分けるか(docs/10「ネットワークのサーバとボリュームの接続」)
// アプリ本体はネットワークの entitlement を持たない(StackNestConnectorWire.swift の冒頭と同じ理由)。Bonjour でサーバを探すにも
// (mDNSResponder への問い合わせが App Sandbox の `network.client` 無しでは断られる ―― `ServiceNotRunning`。2026-10-25 実測)、
// NetFS でマウントを頼むにも(`network.client` 無しのプロセスからは NetAuthSysAgent が EPERM で断る。同日実測)この権限が要る。
// そこで権限を持つのはこのサービスだけにし、サービスはファイルへのアクセスを持たず、決まった 2 つの仕事
// (`_smb._tcp` のサーバを探す・**いま見つかっている**サーバのマウントを NetFS に頼む)しかしない。マウントそのもの・認証の
// ダイアログ・共有の選択のダイアログは macOS の NetAuthSysAgent / NetAuthAgent がする(サービスは SMB を話さない)。
// マウントされたボリュームを読むのはアプリ本体で、ほかのボリュームと同じくフォルダの許可(FolderAccessStore)が要る。
// アンマウントはアプリ本体がする(`FileManager.unmountVolume` は App Sandbox の中から権限もダイアログも無しに通る。同日実測)。

/// アプリからサービスへの口。
@objc(QooNetworkVolumeConnecting)
nonisolated protocol NetworkVolumeConnecting {
    /// サーバを探し始める。見つかっているサーバの名前・ローカルネットワークの許可の有無が変わるたびに、接続の相手
    /// (`NetworkVolumeConnectorObserving`)へ知らせる。始めた直後には知らせない(結果が来たとき・断られたとき・断られずに少し
    /// 経ったときに知らせる ―― サービスの型コメント)。もう探していれば、いまの一覧を知らせ直すだけ。
    func startBrowsing()
    /// 探すのをやめる(一覧は空になる。知らせはしない)。
    func stopBrowsing()
    /// いま見つかっているサーバ `serverName`(Bonjour のサービス名)のマウントを NetFS に頼む。共有は指定しない ――
    /// macOS が認証(要れば)と、マウントする共有の選択のダイアログを出す(NetFS.h の `NetFSMountURLAsync` の説明)。
    /// 返事はどの要求にも 1 度だけ: `status` は NetFS の値(0 = 成功、正 = errno、負 = OSStatus。-128 は利用者の取り消し)、
    /// `mountPoints` は成功したときのマウント先の JSON(`[String]`)。見つかっていない名前・決まりに合わない名前は送らずに
    /// `NetworkVolumeConnectorPolicy.refusedStatus` で返す。
    func mount(serverName: String, withReply reply: @escaping @Sendable (_ status: Int32, _ mountPoints: Data?) -> Void)
}

/// サービスからアプリへの知らせ(接続の `exportedObject` がアプリの側で受ける)。
@objc(QooNetworkVolumeConnectorObserving)
nonisolated protocol NetworkVolumeConnectorObserving {
    /// 見つかっているサーバの名前(JSON の `[String]`。重なりなし・表示の順に並べたもの)と、ローカルネットワークの許可が無いか
    /// (システム設定 ▸ プライバシーとセキュリティ ▸ ローカルネットワークで断られている。そのとき名前は空)。
    func serversDidChange(_ names: Data, isLocalNetworkDenied: Bool)
}

/// 両側が同じに判定する決まり。
nonisolated enum NetworkVolumeConnectorPolicy {
    /// 探すサービスの種類(Finder のサイドバーの「場所」に出る SMB のサーバ)。
    static let serviceType = "_smb._tcp"
    static let domain = "local."
    /// 名前の長さの上限(DNS のラベル 1 つ = 63 バイト。Bonjour のサービス名もこれを超えない)。
    static let maxNameUTF8Bytes = 63
    /// 送らずに断った返事の `status`(NetFS の値と重ならない、errno の EPERM)。
    static let refusedStatus: Int32 = EPERM
    /// 利用者が認証・共有の選択のダイアログで取り消した(NetFS.h: userCanceledErr)。
    static let userCanceledStatus: Int32 = -128

    /// サーバの名前として受け付けるか(空・長すぎ・制御文字を含むものは断る)。
    static func isAcceptableServerName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxNameUTF8Bytes else { return false }
        return !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// サーバ `name` のマウントに使う URL(共有を指定しない ―― 選ぶのは macOS のダイアログ)。Finder のサイドバーから繋ぐときと
    /// 同じ Bonjour の名前の形(`smb://<名前>._smb._tcp.local`。キーチェーンの項目もこの名前で控えられている)。
    /// 名前は英数字と `-` `_` 以外をすべて百分率符号化する(空白・`/`・`@`・`:` などを URL の区切りとして読ませない)。
    static func mountURL(forServerName name: String) -> URL? {
        guard isAcceptableServerName(name) else { return nil }
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "smb://\(encoded).\(serviceType).local")
    }

    /// 名前の一覧を JSON にする / 戻す(XPC の引数は `Data` だけにする ―― StackNestConnectorWire と同じ)。
    static func encodeNames(_ names: [String]) -> Data {
        (try? JSONEncoder().encode(names)) ?? Data("[]".utf8)
    }

    static func decodeNames(_ data: Data?) -> [String] {
        guard let data, let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    /// 見つかったサーバの名前を、出す一覧に揃える(決まりに合わない名前を外し、重なりを除き、Finder と同じく名前順)。
    static func displayedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { isAcceptableServerName($0) && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
