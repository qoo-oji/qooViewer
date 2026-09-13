import Foundation

/// bookID(本のパス)から「その本のタイトル」を1つ求める役。アプリ全体で1つ(AppStoresが持つ)。
///
/// 返す文字列は、**その本の「メタデータの編集」が出すタイトルと同じもの** ―― 登録済みなら
/// DBの値、未登録ならファイル名からの推測値(`MetadataEditorViewModel.initialDraft`。同じ関数を
/// 通しているので、シートを開いて確かめた文字列と画面の表示が食い違うことはない)。どちらも空
/// (タイトルだけ空にして登録した本・推測が何も拾えなかった本)のときは、拡張子を除いた
/// ファイル名へ落とす ―― 空文字のまま出すと、カバーの下でその1冊だけ行が潰れて高さが揃わず、
/// 並べ替えでも一箇所へ固まってしまう。
///
/// ■ なぜキャッシュを持つのか
/// カバーの下のキャプション(CollectionDetailView.caption(for:))だけだった頃は、その場で
/// 推測して捨てていた ―― LazyVGridが組み立てるのは見えているセルだけなので、1冊ぶんの推測を
/// メインアクター上でやっても一瞬で終わる。**「タイトル」順の並べ替え(ユーザー要望 2026-09-10)
/// で事情が変わった**: 並べるにはコレクションの全冊ぶんのタイトルが要り、しかも
/// `CollectionStore.items(in:sort:)`は描き直しのたびに呼ばれる。推測はルールの数だけ
/// NSRegularExpressionを回すので、数千冊のコレクションでは描き直しごとに効いてくる
/// (数千行の推測をメインアクターの外へ逃がしている`MetadataEditorViewModel.scheduleDerivation`と
/// 同じ理由)。一度求めたタイトルを覚えておけば、2回目からは辞書引きで済む。
///
/// ■ 捨てる契機は「読むその場での照合」だけ
/// メタデータ(`BookMetadataStore.revision`)とフォーマット定義(`MetadataFormatStore.revision`)の
/// 通し番号を、キャッシュを作った時点の値と読むたびに突き合わせ、変わっていれば捨てる。
/// **`.bookMetadataDidChange`は購読しない** ―― あの通知はメインキューへ積まれるので、画面の
/// 描き直しとの前後が保証されず、キャッシュを捨てる前に古い文字で描いてしまいうる(そして
/// このクラスは何もpublishしないので、そのあと描き直す契機が無い)。読むその場で確かめる形なら、
/// 誰がいつ変えても、次に読んだときには必ず新しい値になる。
@MainActor
final class BookTitleResolver {
    private let metadataStore: BookMetadataStore
    private let formatStore: MetadataFormatStore

    /// bookID -> 表示するタイトル。
    private var cache: [String: String] = [:]
    /// `cache`を作った時点の2つの通し番号(上記)。
    private var cachedMetadataRevision: UInt64
    private var cachedFormatRevision: Int

    init(metadataStore: BookMetadataStore, formatStore: MetadataFormatStore) {
        self.metadataStore = metadataStore
        self.formatStore = formatStore
        self.cachedMetadataRevision = metadataStore.revision
        self.cachedFormatRevision = formatStore.revision
    }

    /// この本のタイトル(型コメントの規則で決まる文字列)。
    func title(forBookID bookID: String) -> String {
        invalidateIfStale()
        if let cached = cache[bookID] { return cached }

        let baseName = MetadataEditorViewModel.baseName(forBookID: bookID)
        let draft = MetadataEditorViewModel.initialDraft(
            forBookID: bookID, baseName: baseName,
            metadataStore: metadataStore, formatStore: formatStore
        )
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = title.isEmpty ? baseName : title
        cache[bookID] = resolved
        return resolved
    }

    /// bookID -> 検索に照合する文字列(正規化済み)。
    private var searchableCache: [String: String] = [:]

    /// ウェルカム画面の検索(LibrarySearchQuery)が照合する、この本の文字列(ユーザー要望 2026-09-13)。
    ///
    /// 中身は**ファイル名/フォルダ名**(拡張子つき)と、**登録済みのメタデータ**(タイトル・作者・
    /// シリーズ・巻数)。ファイル名からの推測値は入れない ―― 推測はファイル名から取り出した
    /// 部分文字列なので、ファイル名で既に一致する。
    ///
    /// ■ 覚えておく理由と捨てる契機はtitle(forBookID:)と同じ
    /// 一覧の絞り込みは、描き直しのたびに棚の全冊ぶん照合する。正規化(folding)は1冊ずつなら
    /// 一瞬だが、数千冊では描き直しごとに効いてくる。DBが変われば通し番号の照合で捨てる。
    /// bookIDはリネーム・移動に追従して書き換わる(CollectionStore.reconcileBookIDIfMoved)ので、
    /// 名前が変われば鍵ごと別物になり、古い文字列は使われない。
    ///
    /// 語は改行で区切って1つにまとめる。語に改行は入らないので、項目の境目をまたいで
    /// 一致することはない。
    func searchableText(forBookID bookID: String) -> String {
        invalidateIfStale()
        if let cached = searchableCache[bookID] { return cached }
        var fields = [URL(fileURLWithPath: bookID).lastPathComponent]
        if let metadata = metadataStore.metadata(forBookID: bookID) {
            fields += [metadata.title, metadata.author, metadata.series, metadata.seriesIndex]
                .filter { !$0.isEmpty }
        }
        let text = LibrarySearchQuery.normalized(fields.joined(separator: "\n"))
        searchableCache[bookID] = text
        return text
    }

    /// DBの内容・推測のルールのどちらかが変わっていたら、覚えているものを全部捨てる。
    ///
    /// 変わった1冊だけを捨てる形にはしない ―― どのタイトルがDBの値でどれが推測値かを
    /// 覚えていないため、ルールの変更では結局全部を捨てることになる。作り直しは
    /// 「そのとき見えているぶんを引き直す」だけなので、まとめて捨てて構わない。
    private func invalidateIfStale() {
        let metadataRevision = metadataStore.revision
        let formatRevision = formatStore.revision
        guard metadataRevision != cachedMetadataRevision || formatRevision != cachedFormatRevision
        else { return }
        cache.removeAll(keepingCapacity: true)
        searchableCache.removeAll(keepingCapacity: true)
        cachedMetadataRevision = metadataRevision
        cachedFormatRevision = formatRevision
    }
}
