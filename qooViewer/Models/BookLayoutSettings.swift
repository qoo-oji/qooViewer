import Foundation
import SwiftData

/// 本全体に関わるページレイアウト設定。SwiftDataで永続化する。
/// bookID には MangaBook.id (フォルダ/アーカイブファイルのパス) を使う。
///
/// フォルダ・zip/cbz・rar/cbr・7z/cb7・PDFに対して、EPUBが自身のpackage documentに
/// 埋め込んでいるのと同等の「読み方向・見開き強制・ページ順序の補正」をqooViewer自身が
/// 肩代わりするためのモデル(設計コンセプト2章参照)。ページ単位の設定は`PageLayoutOverride`
/// が別途持つ。
///
/// `BookReadingState`/`Bookmark`と異なり、`LibraryDataPruner`による自動削除の対象外とし、
/// 無制限に保持する(10.3節)。そのため、他の本ごとのデータと違って際限なく増えうる前提で
/// 扱う必要がある(4.1節の編集ウインドウに検索機能を設ける、等)。
///
/// 以前はbookIDに`@Attribute(.unique)`の一意制約を付けていたが、PageLayoutOverride.compositeKeyと
/// 同じ理由(コメント参照)で外した。同じModelContextに対して短時間に連続してinsert()+save()する
/// 際、一意制約を持つエンティティのupsert処理が原因と思われる不具合(既存の無関係な行が
/// 消えて見える)を避けるための対策。一意性自体は元々existingOrNewSettings(for:)/
/// bookLayoutSettings(forBookID:)がinsertする前に必ず既存行の有無を確認しているため
/// アプリ側で保証されており、SwiftData側の一意制約に頼る必要が無い。
@Model
final class BookLayoutSettings {
    var bookID: String

    /// 読み方向の上書き(未設定ならnil。その場合は環境設定の既定値/本ごとのBookReadingStateに従う)。
    var readingDirectionOverrideRaw: String?
    /// 本全体での見開き/単ページの強制(未設定ならnil)。
    var forcedDisplayModeRaw: String?
    /// ページ順序の補正(2.3節)。ページキー(アーカイブ内エントリ名/PDFページ番号の文字列表現)の
    /// 並びをJSON配列としてエンコードして保持する。未設定(nil)の間は自然順ソートのまま。
    ///
    /// SwiftDataのリレーションとして「複数行」で持たせる案もあったが、並べ替えのたびに大量行の
    /// インデックスを更新するコストを避けるため、1カラムのJSON文字列として持たせている
    /// (詳細は実装検討ドキュメント2.1節参照)。
    var pageOrderOverrideJSON: String?

    /// かつて、この本がEPUBのpackage document、またはPDFのDocument Catalogに権威的なレイアウト
    /// 指定(読み方向・見開き強制のいずれか)を持っているかどうかのキャッシュとして使っていた
    /// もの。編集ウインドウ(4.1節)が、本を毎回読み込み直さずに「読み方向ドロップダウン/
    /// レイアウト列を無効化すべきか」を判定するために参照していた。
    ///
    /// 名前はEPUB対応時の名残でhasEpubLayoutLockのままだが、PDF由来の同種のロックにも
    /// 同じ意味で使っていた。
    ///
    /// 現在このプロパティは書き込まれも読まれもしない(未使用)。ユーザー要望により
    /// 「EPUB/PDFのレイアウト指定でユーザー操作をロックする」という扱い自体をやめ、
    /// ファイル側の指定はDBの初期値として1回だけ取り込む方式(didImportSourceLayout)へ
    /// 移行したため。属性そのものを削除するとSwiftDataのスキーマ変更になり、既存ユーザーの
    /// ストアに対する移行が必要になるだけで得るものが無いため、宣言だけ残してある。
    var hasEpubLayoutLock: Bool = false

    /// このEPUB/PDFがファイル自身に持っていたレイアウト情報(読み方向・見開き強制・EPUBの
    /// ページ単位の見開き配置)を、この行へ取り込み済みかどうか。
    ///
    /// ユーザー要望による方針転換: 以前はEPUB/PDFのファイル側の指定を「権威」として毎回
    /// 優先適用し、ユーザーによる切り替え操作自体を無効化(グレーアウト)していた。現在は
    /// 「ファイルを初めて開いたときに読み込んでDBへ登録し、以降はDB上の情報に従う
    /// (ファイル側の情報はDBの初期値としてのみ扱う)」という扱いに変更している。
    ///
    /// このフラグは、その「初めて開いたとき」を1回だけにするためのもの。これが無いと、
    /// ユーザーがDB側の値を変更しても、次に本を開いたときにファイル側の値で上書きし直されて
    /// しまう(ユーザーの編集が保存できない)。
    ///
    /// `= false`という宣言時のデフォルト値は、この属性を後から追加したことによる
    /// ライトウェイトマイグレーションのために必須(Bookmark.updatedAt等と同じ理由)。
    /// 既存ユーザーの保存済みデータはfalseから始まり、次にその本を開いたときに1回だけ
    /// 取り込みが走る。
    var didImportSourceLayout: Bool = false

    /// 差し替え検知用の指紋(2.5節)。ContentFingerprint参照。
    var recordedPageCount: Int?
    var recordedSourceModificationDate: Date?
    var recordedSourceFileSize: Int64?

    /// この本を指すセキュリティスコープ付きブックマーク(Bookmark.bookmarkDataと同じもの)。
    /// 「ブックマーク・レイアウトの編集」ウインドウ(4節)が、レイアウト情報はあるが
    /// ブックマークは1件も無い本のサムネイルを表示するために、今開いていない本のURLを
    /// 解決する必要があり、そのために保持する。行の作成時点(LayoutStore.existingOrNewSettings)で、
    /// その時点で本を開けている=このURLへのアクセス権を持っている、という前提で生成する。
    /// Bookmark.bookmarkDataと同じくOptional(この属性を追加する前から存在する行には無いため)。
    var bookmarkData: Data?

    /// **書き出し用のカバー画像**の上書き(ユーザー要望: EPUB出力時のカバー画像を選択・変更
    /// できるようにしたい)。EPUB/CBZ/PDFの書き出しにだけ効く ―― 棚(コレクション)の表示に使う
    /// 絵は別物で、下のshelfCover*が持つ。
    ///
    /// ■ なぜ分けたのか(2026-09-11)
    /// 元はこの4列1つで両方を賄っていた。ところが**寿命が違う**: 棚の絵はアプリが768pxのJPEGに
    /// 焼いて持つ(CollectionCoverStore)ので元ファイルが消えても表示され続けるのに対し、
    /// 書き出しは毎回この列のブックマークから元ファイルを読み直す。つまり元ファイルを消すと
    /// 書き出しのカバーだけが黙って既定へ戻り、棚は何も変わらないので**誰も気づけない**。
    /// 実測(2026-09-11)では、外部ファイルを指定していた131冊すべてで元ファイルが失われていた
    /// (置き場所は全件`~/Downloads`で、名前も使い回されていた)。
    /// そこで用語ごと分け、棚側(コレクション表紙)はアプリの中で完結させた。書き出し用の
    /// カバー画像は従来どおり書き出しウインドウでだけ指定し、既定は実質的な先頭ページに戻した。
    ///
    /// coverPageKey/externalCoverBookmarkDataがどちらもnilの間は「既定」で、書き出し時に本の
    /// 実質的な先頭ページ(除外・並べ替えを反映した後の1ページ目)をカバーとして使う
    /// (EpubExporter参照)。
    ///
    /// 「本に含まれる既存ページを選ぶ」場合はcoverPageKeyに元のPageRef.sortKeyを設定する。
    /// coverPageDisplayNameは、そのページの表示名(本の中での相対パス。PageLocation.fullPath)を
    /// 選択した時点の値で
    /// キャッシュしたもの。編集ウインドウの一覧に表示するためだけに使い、本を再読み込みせずに
    /// 済ませる(LayoutStore.setCoverPageKey参照)。
    ///
    /// 「本に含まれない専用ファイルを追加する」場合はexternalCoverBookmarkData
    /// (セキュリティスコープ付きブックマーク)とexternalCoverFileName(表示・書き出し用の
    /// ファイル名)を設定する。この専用ファイルは本の一部として扱わない(LayoutStore/
    /// BookLoaderのどこからも参照しない)ため、ビューアのページ一覧には一切現れない。
    ///
    /// 両方が同時に設定されることは無い(LayoutStore.setCoverPageKey/setExternalCoverが
    /// 互いをクリアする)。
    var coverPageKey: String?
    var coverPageDisplayName: String?
    var externalCoverBookmarkData: Data?
    var externalCoverFileName: String?

    /// **コレクション表紙**(棚・コレクションの表示に使う絵)の上書き。上の書き出し用カバー画像
    /// とは完全に独立していて、片方を変えてももう片方は変わらない(分けた理由は上のコメント)。
    ///
    /// どちらもnilの間は「既定」で、その本の実質的な先頭ページを表紙にする(従来と同じ)。
    /// 「本に含まれるページを選ぶ」場合はshelfCoverPageKeyに元のPageRef.sortKeyを、
    /// shelfCoverPageDisplayNameにその時点の表示名(PageLocation.fullPath)を入れる。
    ///
    /// 「利用者が用意した画像を使う」場合はshelfCoverImageFileNameに、**アプリが自分の
    /// Application Supportへ複製した画像**のファイル名を入れる(CollectionCoverSourceStore)。
    /// ここがブックマークではなくファイル名なのが要点で、利用者が元の画像を消しても捨てても
    /// 表紙は壊れない ―― 上に書いた131冊の事故は、この経路を持たなかったことが原因。
    ///
    /// 両方が同時に設定されることは無い(LayoutStore.setShelfCoverPageKey/setShelfCoverImageが
    /// 互いをクリアする)。3列とも後から足したのでOptional(軽量マイグレーション)。
    var shelfCoverPageKey: String?
    var shelfCoverPageDisplayName: String?
    var shelfCoverImageFileName: String?

    /// ユーザー要望(2026-09-09): コレクションの札にカバーを並べるとき、画像の比が枠の比と
    /// 違うぶんを**どこで切るか**を本ごとに選べるようにしたい。CoverCropAnchor.rawValue
    /// ("start"/"center"/"end")を保存する。
    ///
    /// **nil = そのライブラリの設定に従う**(BookLibrary.coverCropAnchorRaw)。当初は
    /// nil = 「自動(読み方向から決める)」だったが、比を1:1にもできるようにした際に自動を
    /// 廃止した(上下方向の切り出しには読み方向が何も言えないため。CoverCropAnchorのコメント参照)。
    /// Optionalなのでライトウェイトマイグレーションで済む。
    ///
    /// **コレクション表紙だけに効く設定**(書き出すカバー画像はトリミングしない)。
    /// **hasShelfCoverOverrideには含めない。** 絵そのもの(shelfCoverPageKey/画像ファイル)とは
    /// 独立した属性で、「表紙を既定に戻す」で位置の指定まで消えてしまわないようにするため
    /// (位置の指定は本の属性として残る)。
    var coverCropAnchorRaw: String?

    /// ユーザー要望: 古いスキャン本(紙の黄ばみ等で白黒がくすんで見える)を、きっちりした
    /// 白黒に見えるよう補正する機能。本単位で記憶し(既定false=補正しない)、ユーザーが
    /// 明示的にONにした本にしか適用しない。実際の適用はPageLoader/ContrastCorrectorが行い、
    /// さらにページごとにカラー画像かどうかを判定してカラーページには適用しない
    /// (ContrastCorrector.swiftのコメント参照)。isBookLevelSettingEmptyには意図的に含めない
    /// (hasCoverOverride/coverPageKey等と同じ扱い。読み方向・見開き強制・ページ順補正という
    /// 狭義の「レイアウト」情報ではないため、4.1節の編集ウインドウの絞り込み対象には含めない)。
    var contrastCorrectionEnabled: Bool = false

    var updatedAt: Date = Date()

    /// ユーザー要望: レイアウト設定をファイルパスだけでなくファイルノード(iノード番号)でも
    /// 識別し、同一ボリューム内での移動・リネームを引き継げるようにしたい。作成時点の
    /// FileNodeIdentifierを記録しておく(取得できなかった場合はnilのまま)。
    /// LayoutStore.reconcileBookIDIfMoved(book:)が、この本を開き直したときにbookID(パス)が
    /// 変わっていないかをこれと照合し、変わっていれば自動的に追従させる(PageLayoutOverrideの
    /// bookIDも合わせて追従させる)。
    var inodeNumber: Int64?
    var volumeDeviceNumber: Int64?
    /// ボリュームのUUID。**デバイス番号だけではボリュームを同定できない**(マウント順で変わる)
    /// ことが実測で分かったため後から追加した。詳細はFileNodeIdentifierの型コメント参照。
    ///
    /// **後追加なのでOptional**(SwiftDataの軽量マイグレーション)。既存の行はnilで入り、
    /// その本を開いたときにストアのbackfillFileNodeIdentifierが書き足す。
    var volumeUUID: String?

    init(bookID: String, fileNodeIdentifier: FileNodeIdentifier? = nil) {
        self.bookID = bookID
        self.updatedAt = Date()
        self.inodeNumber = fileNodeIdentifier?.inodeNumber
        self.volumeDeviceNumber = fileNodeIdentifier?.volumeDeviceNumber
        self.volumeUUID = fileNodeIdentifier?.volumeUUID
    }

    /// inodeNumber/volumeDeviceNumberが両方揃っている場合のみFileNodeIdentifierとして返す。
    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(
            inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber, volumeUUID: volumeUUID
        )
    }

    var readingDirectionOverride: ReadingDirection? {
        get { readingDirectionOverrideRaw.flatMap(ReadingDirection.init(rawValue:)) }
        set { readingDirectionOverrideRaw = newValue?.rawValue }
    }

    var forcedDisplayMode: DisplayMode? {
        get { forcedDisplayModeRaw.flatMap(DisplayMode.init(rawValue:)) }
        set { forcedDisplayModeRaw = newValue?.rawValue }
    }

    /// 補正後のページキーの並び。未設定(nil)の間は自然順ソートのまま(BookLoader側の解釈)。
    var pageOrderOverride: [String]? {
        get {
            guard let pageOrderOverrideJSON, let data = pageOrderOverrideJSON.data(using: .utf8) else {
                return nil
            }
            return try? JSONDecoder().decode([String].self, from: data)
        }
        set {
            guard let newValue else {
                pageOrderOverrideJSON = nil
                return
            }
            pageOrderOverrideJSON = (try? JSONEncoder().encode(newValue))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// この行が「実質的に空」(読み方向・見開き強制・ページ順補正のいずれも設定されていない)かどうか。
    /// ページ単位の設定(PageLayoutOverride)はこの本に紐づく別モデルのため、この判定には含まれない
    /// (LayoutStore側で、本全体設定とページ単位設定の両方を見て「レイアウト情報がある本」かどうかを
    /// 判定する。4.1節の絞り込みドロップダウン参照)。
    var isBookLevelSettingEmpty: Bool {
        readingDirectionOverrideRaw == nil && forcedDisplayModeRaw == nil && pageOrderOverrideJSON == nil
    }

    /// カバーの切り出し位置の本ごとの上書き(nil = ライブラリの設定に従う)。
    /// coverCropAnchorRawのコメント参照。
    var coverCropAnchor: CoverCropAnchor? {
        get { CoverCropAnchor.stored(coverCropAnchorRaw) }
        set { coverCropAnchorRaw = newValue?.rawValue }
    }

    /// カバー画像が上書き設定されているかどうか(LayoutStore.coverOverrideBookIDs参照)。
    var hasCoverOverride: Bool {
        coverPageKey != nil || externalCoverBookmarkData != nil
    }

    /// コレクション表紙を上書きしているか(既定=実質的な先頭ページ、ではないか)。
    var hasShelfCoverOverride: Bool {
        shelfCoverPageKey != nil || shelfCoverImageFileName != nil
    }
}

/// レイアウト設定(BookLayoutSettings/PageLayoutOverride)の追加・変更・削除が、変更した側
/// (LayoutStore、または今開いているViewerViewModel)以外にも通知されるようにするための
/// 共通の通知名。Bookmark.swiftのNotification.Name.bookmarksDidChangeと同じ考え方・同じ理由
/// (「ブックマーク・レイアウトの編集」ウインドウと、今開いている本のViewerViewModelが、
/// 同じSwiftDataのモデルを同時に参照しうるため)。
///
/// userInfoの"bookID"(String)には、変更があった本のbookIDを入れる。全件リセット
/// (LayoutStore.deleteAllLayoutData())の場合はuserInfoを付けずに投げる。
extension Notification.Name {
    static let layoutDataDidChange = Notification.Name("qooViewer.layoutDataDidChange")
}
