import CoreData
import CryptoKit
import Foundation
import SwiftData

/// **古いqooViewerが、新しいqooViewerの保存データを開くのを止める**番人(2026-09-13)。
///
/// ■ 何が起きたか
/// 2026-09-11、1.55で足したコレクション表紙の3列(BookLayoutSettings.shelfCover*)が、
/// 131冊ぶん丸ごと消えた。原因は、**1.55で移行を済ませたストアを、`/Applications`に残っていた
/// 1つ前のqooViewerで開いた**こと(統一ログでアプリのパスを確認した)。SwiftDataはストアと
/// モデルが食い違うと、**向きを問わず**黙って軽量マイグレーションをかける ―― 新しい列を知らない
/// 古いモデルへ「移行」すると、その列は中身ごと削除される。エラーも警告も出ない
/// (ディスク上の使い捨てストアで再現済み: 新しいモデルで書く → 古いモデルで開く → 新しいモデルで
/// 開き直すと、新しい列だけが空になる)。1.55を入れ直して列は戻ったが中身は戻らず、起動時の
/// 孤児掃除が、参照を失った表紙の元画像まで消した。
///
/// 同じ種類の事故は以前にも一度あった(同じバンドルIDの古いビルドが同じストアを開いて
/// リレーションが壊れた。QooViewerApp.deleteStoreFilesのコメント)。どちらも「開けてしまう」
/// ことが原因で、利用者から見て防ぎようがない。
///
/// ■ どう止めるか
/// ストアを開く**前に**、次の2つで「このストアは、いま動いているqooViewerより新しい
/// qooViewerが書いたものか」を判定し、そうなら開かずに尋ねる(QooViewerApp.modelContainer)。
///
/// 1. **スキーマの世代の記録**(UserDefaults `qooViewer.store.schemaGeneration`)。ストアを
///    開けたら、そのアプリの世代(`currentGeneration`)を記録する(大きいほうを残す)。記録が
///    自分の世代より大きければ、新しいアプリが既にこのストアを使った、ということ
/// 2. **ストアのメタデータ**(`NSStoreModelVersionHashes`)。いまのモデルと一致すれば何も
///    起きないので開いてよい。いまのモデルが知らないエンティティを持っていれば、新しいアプリの
///    ストア(記録が消えていても分かる)
///
/// 世代は**モデルを変えるたびに1つ上げる**(`generations`へ行を足す)。上げ忘れは
/// `StoreSchemaGuardTests`が落とす ―― いまのモデルから計算した指紋が、表の最後の行と
/// 一致しなければならない。
///
/// ■ 限界
/// この番人を持たない古いバージョン(1.55以前)へ戻したときは止められない。止められるのは、
/// これ以降のバージョン同士の行き来だけ。
///
/// nonisolated: 起動の最初(メインアクターの外かもしれない静的初期化)から呼ぶため。
nonisolated enum StoreSchemaGuard {
    /// これまでのスキーマの世代と、その指紋(`fingerprint(of:)`)。**行を消したり書き換えたり
    /// しないこと** ―― 古い世代の指紋は、そのストアを「知っている古いストア」と判定するのに使う。
    ///
    /// - 1: 1.55(コレクション表紙の3列を足した時点)。この番人を入れた最初の世代
    static let generations: [Int: String] = [
        1: "82a1fb6d0d07bdc10cc4f297ac78096f48f6d101c0d8ec685ede6c0e803429d2",
    ]

    /// いま動いているアプリの世代(表の最大)。
    static var currentGeneration: Int { generations.keys.max() ?? 0 }

    static let defaultsKey = "qooViewer.store.schemaGeneration"

    enum Verdict: Equatable {
        /// 開いてよい(ストアが無い・同じモデル・古いストアからの移行)。
        case proceed
        /// 新しいアプリが書いたストア。開くと、このアプリが知らないデータが消える。
        case newerStore
    }

    /// 判定の本体(純粋関数。テストから直接確かめる)。
    ///
    /// - Parameters:
    ///   - storeHashes: ストアのメタデータのエンティティごとの版の指紋。ストアが無ければnil。
    ///   - currentHashes: いまのモデルの同じもの。
    ///   - recordedGeneration: これまでに記録された最大の世代(記録が無ければnil)。
    static func verdict(
        storeHashes: [String: Data]?, currentHashes: [String: Data],
        recordedGeneration: Int?, currentGeneration: Int = currentGeneration
    ) -> Verdict {
        guard let storeHashes else { return .proceed }
        // いまのモデルと同じなら、移行そのものが起きない。
        if storeHashes == currentHashes { return .proceed }
        // 新しいアプリが既にこのストアを使った。
        if let recordedGeneration, recordedGeneration > currentGeneration { return .newerStore }
        // いまのモデルが知らないエンティティがある = 新しいアプリのストア(記録が消えていても分かる)。
        if !Set(storeHashes.keys).isSubset(of: currentHashes.keys) { return .newerStore }
        // 古いストア(このアプリより前の世代、または番人を入れる前のバージョン)からの移行。
        return .proceed
    }

    /// エンティティごとの版の指紋から、スキーマ全体の指紋を作る(名前順に並べてSHA-256)。
    static func fingerprint(of hashes: [String: Data]) -> String {
        var data = Data()
        for (name, hash) in hashes.sorted(by: { $0.key < $1.key }) {
            data.append(Data(name.utf8))
            data.append(0)
            data.append(hash)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// いまのモデルのエンティティごとの版の指紋(SwiftDataがストアのメタデータへ書くものと同じ)。
    static func currentHashes(for types: [any PersistentModel.Type]) -> [String: Data] {
        NSManagedObjectModel.makeManagedObjectModel(for: types)?.entityVersionHashesByName ?? [:]
    }

    /// ストアのメタデータに書かれた、エンティティごとの版の指紋。ストアが無い・読めなければnil。
    static func storeHashes(at url: URL) -> [String: Data]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                  type: .sqlite, at: url
              )
        else { return nil }
        return metadata[NSStoreModelVersionHashesKey] as? [String: Data]
    }

    static func recordedGeneration(in defaults: UserDefaults) -> Int? {
        defaults.object(forKey: defaultsKey) as? Int
    }

    /// ストアを開けたあとに呼ぶ。記録は**大きいほうを残す**(古いアプリを「それでも開く」で
    /// 使ったあとも、新しいアプリが使った事実は消さない ―― 次にまた古いアプリで開いたときに
    /// もう一度尋ねるため)。
    static func recordOpened(in defaults: UserDefaults, generation: Int = currentGeneration) {
        let recorded = recordedGeneration(in: defaults) ?? 0
        guard generation > recorded else { return }
        defaults.set(generation, forKey: defaultsKey)
    }
}
