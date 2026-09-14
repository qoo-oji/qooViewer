import AppKit
import UniformTypeIdentifiers

/// ファイルブラウザの右クリック「このアプリケーションで開く」の候補(改善要望7 段階 8、2026-09-14)。
///
/// ■ 候補は LaunchServices が返したものだけ
/// `NSWorkspace.urlsForApplications(toOpen:)`(適合順)。サンドボックスからは、その種類を宣言していないアプリで
/// 開こうとすると `kLSAppDoesNotClaimTypeErr` になる(FB9878055。検討メモ §12)ので、一覧に無いアプリを候補に足さない。
/// 「その他…」で選んだアプリはこの制限に当たりうる(失敗は報告する)。
///
/// ■ 引くのは種類ごとに 1 回
/// アイコン表示の右クリックメニューは SwiftUI の `.contextMenu` で、中身は右クリックの瞬間ではなく**セルの本体評価の
/// 一部として**組み立てられる(SidePanelView の folderRow のコメント)。そこで毎回 LaunchServices とアプリの
/// Info.plist を引くと、スクロールや選択のたびに見えているセルの数だけ走る。拡張子(とフォルダかどうか)ごとに覚え、
/// アプリが入れ替わりうる契機(qooViewer が前面に戻ったとき)に捨てる。
///
/// ■ ファイルに触らずに引く(2026-09-14 の監査 11)
/// これはメインアクターの上で走る。以前は `urlsForApplications(toOpen: URL)` にファイルの URL を渡していて、LaunchServices が
/// その項目を調べに行くので、応答しない共有の上の項目ではメインが待たされえた(拡張子の無いファイルはパスごとに引くので、
/// セルの数だけ)。いまは**種類(`UTType`)で引く** ―― 拡張子から決め、フォルダは `.folder`、拡張子の無いファイルは `.data`。
/// 失うもの: 1 つのファイルだけに付けた「このアプリケーションで開く」の既定(Finder の「情報を見る」で 1 件だけ変えたもの)が
/// 「(既定)」に反映されないことと、拡張子の無い実行ファイル・テキストを中身で見分けないこと。候補から開くこと自体は変わらない。
@MainActor
final class OpenWithApplications {
    static let shared = OpenWithApplications()

    struct Application: Equatable {
        let url: URL
        let name: String
        let bundleIdentifier: String?
        /// この種類の既定のアプリ(一覧の先頭に置き、名前に「(既定)」を添える)。
        let isDefault: Bool
    }

    private var cache: [String: [Application]] = [:]
    private var iconCache: [String: NSImage] = [:]
    private var activationObserver: NSObjectProtocol?

    private init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cache.removeAll() }
        }
    }

    /// `url`を開けるアプリ。既定のアプリが先頭、残りは名前順。qooViewer 自身は入れない(「開く」がそれにあたる)。
    func applications(for url: URL, isDirectory: Bool, isPackage: Bool) -> [Application] {
        let key = Self.cacheKey(for: url, isDirectory: isDirectory, isPackage: isPackage)
        if let cached = cache[key] { return cached }
        let workspace = NSWorkspace.shared
        let type = Self.contentType(for: url, isDirectory: isDirectory, isPackage: isPackage)
        let all = workspace.urlsForApplications(toOpen: type)
        let defaultApp = workspace.urlForApplication(toOpen: type)
        let candidates = all.map { appURL in
            Candidate(
                url: appURL,
                name: FileManager.default.displayName(atPath: appURL.path),
                bundleIdentifier: Bundle(url: appURL)?.bundleIdentifier
            )
        }
        let defaultCandidate = defaultApp.map { appURL in
            candidates.first { $0.url.standardizedFileURL == appURL.standardizedFileURL }
                ?? Candidate(
                    url: appURL, name: FileManager.default.displayName(atPath: appURL.path),
                    bundleIdentifier: Bundle(url: appURL)?.bundleIdentifier
                )
        }
        let result = Self.arrange(candidates, default: defaultCandidate, excludingBundleIdentifier: Bundle.main.bundleIdentifier)
        cache[key] = result
        return result
    }

    /// メニューに添えるアイコン(16pt)。
    func icon(for application: Application) -> NSImage {
        if let cached = iconCache[application.url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: application.url.path)
        let sized = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }
        iconCache[application.url.path] = sized
        return sized
    }

    /// 並べ方の本体(テストのための口)。
    struct Candidate: Equatable {
        let url: URL
        let name: String
        let bundleIdentifier: String?
    }

    /// - 同じアプリの複製(同じ bundle id)は、LaunchServices の適合順で先に来たもの 1 つにまとめる
    ///   (/Applications と外付けの複製が並ぶ。検討メモ §12)。既定のアプリと同じ bundle id の複製は消す。
    /// - `excludingBundleIdentifier`(qooViewer 自身。Debug と Release は bundle id が違うので、互いに候補に出る)は除く。
    nonisolated static func arrange(
        _ candidates: [Candidate], default defaultCandidate: Candidate?, excludingBundleIdentifier excluded: String?
    ) -> [Application] {
        var seenIDs = Set<String>()
        var seenPaths = Set<String>()
        var result: [Application] = []
        func accept(_ candidate: Candidate) -> Bool {
            if let id = candidate.bundleIdentifier {
                if id == excluded || seenIDs.contains(id) { return false }
                seenIDs.insert(id)
            }
            let path = candidate.url.standardizedFileURL.path
            if seenPaths.contains(path) { return false }
            seenPaths.insert(path)
            return true
        }
        if let defaultCandidate, accept(defaultCandidate) {
            result.append(Application(
                url: defaultCandidate.url, name: defaultCandidate.name,
                bundleIdentifier: defaultCandidate.bundleIdentifier, isDefault: true
            ))
        }
        let others = candidates.filter(accept).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        result += others.map {
            Application(url: $0.url, name: $0.name, bundleIdentifier: $0.bundleIdentifier, isDefault: false)
        }
        return result
    }

    /// 引く種類が決まる単位で覚える(`contentType(for:isDirectory:isPackage:)` と同じ分け方)。
    nonisolated static func cacheKey(for url: URL, isDirectory: Bool, isPackage: Bool) -> String {
        if isDirectory, !isPackage { return "d:" }
        return (isDirectory ? "p:" : "f:") + url.pathExtension.lowercased()
    }

    /// 引く種類。**名前だけで決める**(ファイルに触らない。型コメント)。中へ入れるフォルダは名前に `.` があっても `.folder`、
    /// パッケージ(`.app` など)とファイルは拡張子の種類、拡張子の無いファイルは `.data`。
    nonisolated static func contentType(for url: URL, isDirectory: Bool, isPackage: Bool) -> UTType {
        if isDirectory, !isPackage { return .folder }
        let ext = url.pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext, conformingTo: isDirectory ? .package : .data)
        else { return isDirectory ? .package : .data }
        return type
    }
}
