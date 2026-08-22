import AppKit
import Foundation

/// 「Finderで開く」の共通実装(ユーザー要望: サイドパネル・ページ一覧の右クリックからも
/// 使えるようにしたい)。
///
/// この操作はもともとAppState.revealCurrentBookInFinder()とSidePanelBrowserState.openInFinder()に
/// 分かれて実装されていた。右クリックメニューを各所へ足すにあたって、同じ判断
/// (フォルダなら開く/ファイルなら親フォルダで選択状態にする)を何度も書き直さずに済むよう、
/// ここへ集約している。呼び出し元の2つは、それぞれ自分の事情に合った薄いラッパとして残す。
///
/// nonisolated: 呼び出し元がView・ViewModelの双方にまたがるため、特定のアクターに縛らない
/// (中でNSWorkspaceに触れるが、これらのAPI自体はメインスレッド専用ではない)。
nonisolated enum FinderReveal {
    /// フォルダならFinderでそのフォルダを開き、ファイルなら親フォルダを開いてそのファイルを
    /// 選択状態にする。
    ///
    /// ファイルを`NSWorkspace.open(_:)`してしまうと既定のアプリ(このアプリ自身や
    /// アーカイブユーティリティ)が起動してしまい、「場所を確認したい」という目的に合わない。
    /// Xcode・プレビューなど多くのMacアプリの「Finderで表示」と同じ挙動に揃えてある。
    ///
    /// - Parameter isDirectory: フォルダかどうかが呼び出し側で既に分かっている場合に渡す。
    ///
    ///   **サンドボックス下では、アクセス権の無いURLに対して`fileExists(atPath:)`自体が
    ///   失敗する**(実体があっても「無い」と判定され、何も起きない)。履歴やお気に入りの
    ///   一覧が持っているのはセキュリティスコープの付かない表示用URLなので、そのままでは
    ///   この判定を通れない。一方で、Finderへ「ここを見せて」と頼む
    ///   `activateFileViewerSelecting`/`open`はこのアプリのアクセス権を必要としない。
    ///   種別さえ分かっていれば存在確認は省いてよいので、分かっている呼び出し側は渡すこと。
    ///   (履歴は`RecentFilesStore.Entry.isDirectory`にキャッシュ済み。お気に入りは
    ///   セキュリティスコープ付きブックマークを解決したURLを渡せば、下の既定の経路で
    ///   正しく判定できる。)
    static func reveal(_ url: URL, isDirectory: Bool? = nil) {
        if let isDirectory {
            performReveal(url, isDirectory: isDirectory)
            return
        }
        // スコープ付きで解決されたURLなら、ここで開いてから確認する必要がある。
        // スコープの付いていないURLではfalseが返るだけで無害(start/stopは回数さえ
        // 釣り合っていればよい。RecentFilesStore.fileExists(at:)と同じ考え方)。
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        performReveal(url, isDirectory: isDir.boolValue)
    }

    private static func performReveal(_ url: URL, isDirectory: Bool) {
        if isDirectory {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// 1ページ(`PageRef`)を右クリックしたときに、Finder上で何を指し、書き出しの導線が要るのか。
///
/// ユーザー要望の要点は次の2つ。
///   ・アーカイブの中の画像を右クリックしたときの「Finderで開く」は、**アーカイブ自体**を指す
///     (中の画像はFinderからは見えないため)
///   ・その代わり、中の画像には「画像をエクスポート」を出す
/// サイドパネルの本の中身ブラウザ・ページモードと、ページ一覧パネルの3箇所で判断を揃える
/// ため、ここ1箇所に集約している。
nonisolated enum PageFileAccess {
    /// このページを「Finderで開く」ときに指す実体。
    ///
    /// - Parameter bookSourceURL: 本そのものの場所。入れ子になったアーカイブのページで
    ///   フォールバック先として使う(下記)。分からない場合はnilでよく、そのときは
    ///   一時ファイルであってもそのまま指す(何も示さないよりはまし、という程度の意味)。
    ///
    /// ■ 入れ子のアーカイブについて
    /// 書庫の中の書庫は、読み出すために一時ディレクトリへ書き出してから開いている
    /// (BookLoader.collectPages(fromArchiveURL:...)参照)。そのため`PageSource`が持つ
    /// `archiveURL`が一時ファイルを指していることがあり、それをFinderで示しても
    /// ユーザーには何の意味も無い(そのうえ本を閉じると消える)。一時ディレクトリ配下だった
    /// 場合は、代わりに本そのものを指す。
    static func revealTargetURL(for page: PageRef, bookSourceURL: URL?) -> URL {
        let candidate: URL
        switch page.source {
        case .file(let url):
            candidate = url
        case .zip(let archiveURL, _), .sevenZip(let archiveURL, _), .rar(let archiveURL, _):
            candidate = archiveURL
        case .pdf(let pdfURL, _):
            candidate = pdfURL
        }
        if isInTemporaryDirectory(candidate), let bookSourceURL { return bookSourceURL }
        return candidate
    }

    /// このページの画像が、Finderからは直接取り出せない場所にあるかどうか
    /// (= 右クリックメニューに「画像をエクスポート」を出すべきか)。
    ///
    /// アーカイブ(zip/cbz・rar/cbr・7z/cb7、およびEPUBの中身)に加えて、PDFのページも
    /// trueにしてある。要望の文面はアーカイブだけを挙げていたが、PDFのページもFinderには
    /// 1枚の画像として存在せず、「Finderで開く」がPDFファイル自体を指す点まで含めて
    /// アーカイブとまったく同じ状況にあるため。フォルダの本の画像だけがfalseで、
    /// そちらはFinderで実物を選択できるので書き出しの導線は要らない。
    static func isInsideContainer(_ page: PageRef) -> Bool {
        !page.source.isFile
    }

    private static func isInTemporaryDirectory(_ url: URL) -> Bool {
        let temporaryPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(temporaryPath)
    }
}
