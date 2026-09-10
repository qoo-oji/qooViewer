import Foundation

/// 登録済みの本1冊が「いまどうなっているか」。コレクションの実体確認(`CollectionStore`)が
/// 本ごとにこれを出し、一覧の淡い表示・「本が見つかりません」の文言・
/// 起動時の掃除(`CollectionStore.missingBookSweep`)の判定に使う。
///
/// ■ なぜ Bool(あるか / 無いか)では足りないのか
/// 以前は「ブックマークが解決できて実体もあるか」の Bool だけを持っていた。淡く描くだけなら
/// それで足りるが、**行を消してよいかの判断には使えない**。見つからない理由には、消しても
/// よいもの(実体が無くなった)と、消してはいけないもの(ボリュームが付いていない、
/// ブックマーク自体が使えなくなった)が混ざっている。
nonisolated enum BookLocation: Equatable, Sendable {
    /// 場所が分かり、実体もある。
    case found(URL)
    /// **ボリュームは付いているのに、どの手がかりでも実体に届かない。** 削除・ゴミ箱を空にした・
    /// 別のボリュームへ移した、のいずれか(この3つは区別できない。だから文言は「見つからない」
    /// であって「削除された」ではない)。掃除の対象になるのはこれだけ。
    case missing
    /// その本があったボリュームがマウントされていない。外付けを外しているだけなので何も言えない。
    case volumeUnavailable
    /// ボリュームは付いているが、場所を確定できない。保存してあるブックマークが使えなくなった
    /// (別のMacへ移行した・Time Machineから戻した等)場合がこれで、**実体は別の場所に生きて
    /// いるかもしれない**。消してはいけない。
    case unreachable

    /// 一覧を淡く描くかどうかの従来の判定(`.found`以外はすべて淡く描く)。
    var exists: Bool {
        if case .found = self { return true }
        return false
    }

    var url: URL? {
        if case .found(let url) = self { return url }
        return nil
    }
}

/// 保存してあるブックマーク・パス・ボリュームUUIDから`BookLocation`を割り出す。
///
/// `nonisolated`: 実体確認はメインアクターの外(`Task.detached`)で何百件も回すため
/// (`CollectionStore.scheduleExistenceRefresh`)。
nonisolated enum BookLocationResolver {
    /// 1冊ぶんの材料。SwiftDataのモデルはアクターを跨げないので、メインアクターにいるうちに
    /// この値へ写し取ってから渡す(`CollectionStore`が行っている写し取りと同じ理由)。
    struct Probe: Sendable, Equatable {
        let itemID: UUID
        let bookmark: Data
        /// 登録時に記録したパス(`CollectionItem.bookID`)。
        let recordedPath: String
        /// 登録時に記録したボリュームUUID(持たない古い行ではnil)。
        let volumeUUID: String?
    }

    /// いまマウントされているボリュームのUUID。1回の掃き出しで1度だけ数えて使い回す。
    static func mountedVolumeUUIDs() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey], options: [.skipHiddenVolumes]
        ) ?? []
        return Set(urls.compactMap {
            (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        })
    }

    /// 判定の本体。**迷ったら消せない側に倒す**(`.missing`を返すのは、実体が無いと積極的に
    /// 言えるときだけ)。
    static func resolve(_ probe: Probe, mountedVolumeUUIDs: Set<String>) -> BookLocation {
        let resolved: URL?
        /// 解決の失敗が「そのファイルはもう無い」と言っているか(下のsaysNoSuchFile参照)。
        var resolutionSaysNoSuchFile = false
        do {
            var isStale = false
            resolved = try URL(
                resolvingBookmarkData: probe.bookmark, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &isStale
            )
            // isStaleは見るが失敗扱いにはしない ―― 同一ボリューム内のリネーム・移動でも立つ
            // (実測: ゴミ箱へ移動した本は stale=true で解決でき、実体もある)。
        } catch let error as NSError {
            resolved = nil
            resolutionSaysNoSuchFile = saysNoSuchFile(probe.bookmark, scopedError: error)
        }

        if let resolved {
            let didStartAccessing = resolved.startAccessingSecurityScopedResource()
            defer { if didStartAccessing { resolved.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: resolved.path) { return .found(resolved) }
        } else if !resolutionSaysNoSuchFile {
            // 場所が分からないまま終わった。このときの`fileExists`の「無い」は、権限が無いから
            // 見えないのと区別できない(ブックマークこそがその権限だった)ので、何も判断しない。
            return .unreachable
        }

        // 実体に届かなかった。記録してあるパスに何かあるなら、それだけで消す理由は消える
        // (権限が無ければここは常にfalseになるが、それは消せない側への倒れ方なので構わない)。
        if FileManager.default.fileExists(atPath: probe.recordedPath) { return .unreachable }

        return isVolumeAvailable(probe, mountedVolumeUUIDs: mountedVolumeUUIDs)
            ? .missing : .volumeUnavailable
    }

    /// `.withSecurityScope`付きの解決が失敗した理由が「そのファイルはもう無い」かどうか。
    ///
    /// ■ なぜ解き直すのか(実測 2026-09-10。アプリ本体の中=サンドボックス下で測った)
    /// エラーコードは**ブックマークの種類ではなく解決時のオプションで決まる**。
    ///
    /// ```
    ///                         .withSecurityScope      オプション無し
    /// 実体を消したブックマーク   259 (フォーマット違い)   4 (ファイルが存在しません)
    /// 壊れたデータ              259                    259
    /// 生きているファイル         成功                    成功
    /// ```
    ///
    /// つまり`.withSecurityScope`を付けた解決は、**実体が消えただけでも「壊れたデータ」と
    /// 同じ259で失敗する**ので、それだけでは区別できない。オプション無しで解き直すと
    /// 4と259に分かれる。権限は付かないが、ここで欲しいのは失敗の理由だけなので構わない。
    ///
    /// 解き直して**成功した**場合は「データは生きている(場所は分かる)が、スコープ付きでは
    /// 開けなかった」状態。実体の有無は言えないので、消せない側(false)に倒す。
    private static func saysNoSuchFile(_ bookmark: Data, scopedError: NSError) -> Bool {
        guard scopedError.domain == NSCocoaErrorDomain else { return false }
        if scopedError.code == NSFileNoSuchFileError { return true }
        guard scopedError.code == NSFileReadCorruptFileError else { return false }
        do {
            var isStale = false
            _ = try URL(
                resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return false
        } catch let error as NSError {
            return error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        }
    }

    /// その本があったボリュームが、いま付いているか。
    ///
    /// **ブックマークの解決結果からは判断しない。** 未接続のボリュームを指すパスに触ると、
    /// ディスクイメージでは自動で再マウントされる(実測 2026-09-10)ような挙動もあり、
    /// 「解決できたか」はボリュームの有無の証拠にならない。記録してあるUUIDを、いま
    /// マウントされているボリュームの一覧と照合する。
    private static func isVolumeAvailable(_ probe: Probe, mountedVolumeUUIDs: Set<String>) -> Bool {
        if let volumeUUID = probe.volumeUUID { return mountedVolumeUUIDs.contains(volumeUUID) }
        // UUIDを記録する前に保存された行。パスから見当をつける ―― `/Volumes/<名前>`が無ければ
        // そのボリュームは付いていない。`/Volumes`の下でなければ起動ボリュームなので必ず付いている。
        let components = URL(fileURLWithPath: probe.recordedPath).standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/\(components[2])")
    }
}
