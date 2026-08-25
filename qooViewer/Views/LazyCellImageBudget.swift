import Foundation
import CoreGraphics

/// LazyVStack/LazyVGrid/Listのセルが`@State`で保持した画像の合計量を数え、予算を超えたら
/// コンテナを作り直させる(`epoch`を進める)ための帳簿。ページ一覧グリッド
/// (ThumbnailGridView)・サイドパネルのページモード(SidePanelPageCell)・
/// 「ブックマーク・レイアウトの編集」右ペインのList(BookmarkDetailPane)が使う。
///
/// ■ なぜコンテナごと作り直すのか(最小再現ハーネスでの実測に基づく)
/// SwiftUIのLazyコンテナは、一度生成したセルを画面外へスクロールした後も破棄せず、
/// そのセルの@State値と最後に描画したbodyの出力ツリーを保持し続ける。300セル(各1MBを
/// @Stateに保持)のLazyVStackを端まで流すと、画面内は約10行なのに170個が生存したままだった。
/// しかも次のどの方法でも解放できないことを個別に確認した:
///   - セルの`.onDisappear`で@Stateへnilを書く: 書き込み自体は保存領域に効く(再訪時は
///     必ずnilから始まる)が、旧値はAttributeGraphのスナップショットに保持されたままで、
///     そのセルが**再描画されるまで**解放されない。画面外のセルは再描画されないので減らない
///   - @Stateを使わずbodyの出力にだけ画像を埋める: 出力ツリー自体が保持される(267/300生存)
///   - 親の入力(tick)を変えて再描画を促す: 画面外のセルのbodyは再評価されない(約90セルのみ)
///   - `List`(NSTableView backed)へ置き換える: 半分程度は解放されるが残り(113/242)は保持
/// 唯一確実に効いたのが、コンテナ自体へ`.id(epoch)`を付けて作り直すこと。Lazyコンテナでは
/// 外側のScrollViewがそのまま残るためスクロール位置は1ptもずれず(offset=12796のまま)、
/// 再生成されるのは画面内のセルだけ(生存170→10、再生成10セル)だった。セルの画像は
/// PageLoaderのLRUキャッシュに残っていればそこから即座に復元されるので、見た目への影響は
/// 画面内ぶんの取得し直しだけで済む。
/// **Listだけは例外**で、作り直しはNSTableViewごと新しくなりスクロール位置が先頭へ戻る。
/// そのためListで使う側は、位置の控えと復元を自前で行う必要がある
/// (BookmarkDetailPane.cellImageBudget/LastThumbnailRowBox参照)。
///
/// ■ このままだと何が起きていたのか
/// セルが保持するCGImageはPagePixelBufferのmmap領域をCGDataProviderで共有しており、
/// LRUキャッシュが上限で追い出した後もCGImageが生きている限りバッファ本体は解放されない。
/// つまり一覧を端まで流すと「訪れたセルの枚数ぶんの画像」がキャッシュ上限の**外側**に
/// 積み上がり、パネルを閉じる(または本を閉じる)まで解放されなかった。1000ページ級の本では
/// GB単位になりうる(グリッドの拡大サムネイルは1枚1〜3MB)。
///
/// ■ 使い方
/// - コンテナに`.id(budget.epoch)`を付ける
/// - セルが画像を@Stateへ入れたときに`note(retaining:)`(または`note(retainedBytes:)`)を呼ぶ
/// - 予算超過でepochが進んだら、SwiftUIがコンテナごと作り直して帳簿は自然に0から数え直しになる
///
/// ■ 予算の決め方
/// `byteBudget`は「作り直すまでに許す残留量」。加えて呼び出しごとの`minimumCellCount`で
/// 「少なくとも画面数枚ぶんのセルを数えてから」という下限を課し、巨大なセル設定(グリッド
/// 最大320pt×大画面×拡大プレビューの先読みON)で画面内ぶんだけで予算に達して作り直しが
/// ループすることを防ぐ。下限が初期値ではなく呼び出しごとの引数なのは、画面内に収まる
/// セル数がウインドウサイズ・セルサイズのスライダーでいつでも変わるため(呼び出し側が
/// その時点の見積もりを渡す)。作り直し直後は画面内のセルが読み直されて再び帳簿に乗るが、
/// それは実際に保持され直した量なので二重計上ではない。
struct LazyCellImageBudget {
    /// `.id()`に渡す世代。進むとコンテナが作り直され、画面外セルの保持物がまとめて解放される。
    private(set) var epoch = 0
    private var retainedBytes = 0
    private var retainedCellCount = 0
    private let byteBudget: Int

    init(byteBudget: Int) {
        self.byteBudget = byteBudget
    }

    /// セルが画像を保持したことを記録する。予算を超えたらepochを進めて帳簿を0に戻す。
    /// - Parameter minimumCellCount: これ未満のセル数では作り直さない(型コメント参照)。
    mutating func note(retainedBytes bytes: Int, minimumCellCount: Int) {
        retainedBytes += bytes
        retainedCellCount += 1
        guard retainedBytes >= byteBudget, retainedCellCount >= minimumCellCount else { return }
        epoch &+= 1
        retainedBytes = 0
        retainedCellCount = 0
    }

    /// CGImage版の入り口。保持量はそのCGImageのビットマップの実サイズで数える。
    mutating func note(retaining image: CGImage, minimumCellCount: Int) {
        note(retainedBytes: image.bytesPerRow * image.height, minimumCellCount: minimumCellCount)
    }
}
