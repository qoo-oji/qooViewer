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

    /// この本がEPUBのpackage document、またはPDFのDocument Catalogに権威的なレイアウト指定
    /// (読み方向・見開き強制のいずれか)を持っているかどうかのキャッシュ。編集ウインドウ
    /// (4.1節)が、本を毎回読み込み直さずに「読み方向ドロップダウン/レイアウト列を無効化
    /// すべきか」を判定するために使う。本を開いたとき(LayoutStore.recordEpubLayoutLock参照)に
    /// 更新する。
    ///
    /// 名前はEPUB対応時の名残でhasEpubLayoutLockのままだが、PDF由来の同種のロックにも
    /// 同じ意味で使う。単なるキャッシュ(本を開くたびに必ず再計算・上書きされる、詳細は
    /// ViewerViewModel.init参照)であり、意味を広げるためのリネームによる移行リスク
    /// (SwiftDataの永続化属性名を変えると、次回起動まで古い値が失われた状態になる)を
    /// 冒してまで変える理由が無いため、そのままにしてある。
    var hasEpubLayoutLock: Bool = false

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

    /// カバー画像の上書き(ユーザー要望: EPUB出力時のカバー画像を選択・変更できるようにしたい)。
    /// coverPageKey/externalCoverBookmarkDataがどちらもnilの間は「既定」で、書き出し時に本の
    /// 実質的な先頭ページ(除外・並べ替えを反映した後の1ページ目)をカバーとして使う
    /// (EpubExporter参照)。
    ///
    /// 「本に含まれる既存ページを選ぶ」場合はcoverPageKeyに元のPageRef.sortKeyを設定する。
    /// coverPageDisplayNameは、そのページの表示名(PageRef.displayName)を選択した時点の値で
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

    init(bookID: String, fileNodeIdentifier: FileNodeIdentifier? = nil) {
        self.bookID = bookID
        self.updatedAt = Date()
        self.inodeNumber = fileNodeIdentifier?.inodeNumber
        self.volumeDeviceNumber = fileNodeIdentifier?.volumeDeviceNumber
    }

    /// inodeNumber/volumeDeviceNumberが両方揃っている場合のみFileNodeIdentifierとして返す。
    var fileNodeIdentifier: FileNodeIdentifier? {
        guard let inodeNumber, let volumeDeviceNumber else { return nil }
        return FileNodeIdentifier(inodeNumber: inodeNumber, volumeDeviceNumber: volumeDeviceNumber)
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

    /// カバー画像が上書き設定されているかどうか(LayoutStore.coverOverrideBookIDs参照)。
    var hasCoverOverride: Bool {
        coverPageKey != nil || externalCoverBookmarkData != nil
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
