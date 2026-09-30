import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// インスペクタの部品のうち、本かどうかに関わらないもの(2026-09-30): 名前の見出し・「情報」の節(Finder のプレビューと同じ
// 場所・サイズ・作成日・変更日・種類)・本でない項目の絵(Finder のプレビューに揃える)。

// MARK: - 名前

/// 絵の直下の名前(と、その下の種類・サイズの 1 行)。すりガラス面に直に置く文字なので輪郭を掛ける。名前は選んでコピーできる。
struct HomeInspectorTitle: View {
    let name: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: name)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(name)
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .panelOutlinedContent()
    }
}

// MARK: - 情報の節

/// 「情報」の節の 1 行。
struct HomeInspectorInfoRow {
    let label: LocalizedStringKey
    let value: String
    /// 値が切れて見えるとき(場所)に全体を見せるツールチップ。
    var help: String?
}

/// 「情報」の節(Finder のプレビューの「情報」と同じ、見出しの右に値を並べる形)。
struct HomeInspectorInfoSection: View {
    let rows: [HomeInspectorInfoRow]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HomeInspectorSectionTitle("Information")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                    // 行の並びは出どころごとに決まっていて、並べ替わらない(位置を識別子にする)。
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                                .fixedSize()
                            Text(verbatim: row.value)
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(row.help ?? "")
                        }
                    }
                }
                // 本文の大きさ(.callout = 12pt)。最初は .caption(10pt)で、読みづらかった(2026-09-30、利用者の指摘)。
                .font(.callout)
                .panelOutlinedContent()
            }
        }
    }
}

/// 情報の節に並べる値(ファイル 1 つぶん)。値の出どころ(ファイルブラウザの一覧・スマートライブラリの記録・ファイルを読み直した値)
/// によらず同じ形で並べる。
struct HomeInspectorFileFacts: Equatable {
    var url: URL
    var isFolder: Bool
    var kind: String?
    /// 大きさ。フォルダは一覧が合計しない(Finder と同じ)ので nil のことがあり、そのときは節が自分で数える(`HomeInspectorFolderSize`)。
    var size: Int64?
    var created: Date?
    var modified: Date?
    /// 読めなかった(見つからない・繋がっていない)。情報の値は出さず、その旨を 1 行。
    var isMissing = false

    init(url: URL, isFolder: Bool, kind: String?, size: Int64?, created: Date?, modified: Date?) {
        self.url = url
        self.isFolder = isFolder
        self.kind = kind ?? Self.kind(forName: url.lastPathComponent, isFolder: isFolder)
        self.size = size
        self.created = created
        self.modified = modified
    }

    init(entry: FileBrowserEntry) {
        self.init(
            url: entry.url, isFolder: entry.isNavigableFolder, kind: entry.typeDescription,
            size: entry.fileSize, created: entry.creationDate, modified: entry.modificationDate
        )
    }

    /// スマートライブラリが探したときに記録した値から(ファイルには触らない ―― ネットワークの本でも待たない)。
    init(smartBook book: SmartBook) {
        self.init(
            url: URL(fileURLWithPath: book.id, isDirectory: book.kind == .folder), isFolder: book.kind == .folder,
            kind: nil, size: book.fileSize, created: book.creationDate, modified: book.modificationDate
        )
    }

    /// 名前(拡張子)から引いた種類。ファイルに触らない(FileBrowserIconProvider と同じ考え)。
    static func kind(forName name: String, isFolder: Bool) -> String? {
        if isFolder { return UTType.folder.localizedDescription }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return nil }
        return type.localizedDescription
    }
}

/// 値の書き方(日付はファイルブラウザのリストと同じ DateFormatter、ただし省かない長い形。大きさは Finder と同じ数え方)。
@MainActor
enum HomeInspectorFormat {
    private static var dateFormatters: [String: DateFormatter] = [:]

    static func date(_ date: Date?, locale: Locale) -> String {
        guard let date else { return "--" }
        let key = locale.identifier
        let formatter: DateFormatter
        if let cached = dateFormatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .long
            formatter.timeStyle = .short
            dateFormatters[key] = formatter
        }
        return formatter.string(from: date)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 場所(入っているフォルダのパス)。ホームフォルダの中は `~` で縮める(実際のホーム。サンドボックスのコンテナではない)。
    static func location(of url: URL) -> String {
        abbreviated(url.deletingLastPathComponent().path)
    }

    /// パスのホームフォルダの部分を `~` に縮める。
    static func abbreviated(_ path: String) -> String {
        let home = FileBrowserListing.realHomeDirectory().path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// 名前の下の 1 行(種類・サイズ)。
    static func subtitle(kind: String?, size: Int64?) -> String {
        [kind, size.map(Self.size)].compactMap { $0 }.joined(separator: " – ")
    }
}

/// ファイル 1 つぶんの情報の行を並べる節(フォルダの大きさは、読んでよい場所なら自分で数える)。
struct HomeInspectorFileInfoSection: View {
    /// フォルダの大きさを数えるか。
    enum FolderSizePolicy: Equatable {
        /// 数えない(呼び出し側が数えた・数えられない)。
        case never
        /// 利用者が入っていない場所を読んでよいときだけ数える(`DirectoryProbe.mayReadUnentered`。ネットワーク越し・TCC の保護下は
        /// 数えない)。`currentFolder` は利用者が見ているフォルダ(ファイルブラウザ)。判定はマウント表を読むので、本体ではなく
        /// 数える直前(`.task`)に行う ―― 本体はストアの publish のたびに評価される。
        case ifReadable(currentFolder: URL?)
    }

    let facts: HomeInspectorFileFacts
    let folderSizePolicy: FolderSizePolicy
    /// 後ろに足す行(追加日など、出どころに固有のもの)。
    var extraRows: [HomeInspectorInfoRow] = []

    @Environment(\.locale) private var locale
    @State private var folderSize: HomeInspectorFolderSize.Outcome?

    var body: some View {
        HomeInspectorInfoSection(rows: rows)
            .task(id: measuringKey) {
                folderSize = nil
                guard let measuringKey, case .ifReadable(let currentFolder) = folderSizePolicy else { return }
                let folder = URL(fileURLWithPath: measuringKey, isDirectory: true)
                guard DirectoryProbe.mayReadUnentered(folder, from: currentFolder, mountTable: .current()) else { return }
                folderSize = .measuring
                folderSize = await HomeInspectorFolderSize.measure(folder)
            }
    }

    /// 数えるフォルダ(数えないなら nil)。
    private var measuringKey: String? {
        guard facts.isFolder, facts.size == nil, folderSizePolicy != .never, !facts.isMissing else { return nil }
        return facts.url.path
    }

    private var rows: [HomeInspectorInfoRow] {
        guard !facts.isMissing else {
            return [HomeInspectorInfoRow(label: "Location", value: HomeInspectorFormat.location(of: facts.url),
                                         help: facts.url.path),
                    HomeInspectorInfoRow(label: "Status", value: String(localized: "Not Found", language: locale))]
        }
        // 場所をいちばん上に(2026-09-30、利用者の指示)。続けて種類・サイズ・日付。
        var rows: [HomeInspectorInfoRow] = [
            .init(label: "Location", value: HomeInspectorFormat.location(of: facts.url), help: facts.url.path),
        ]
        if let kind = facts.kind { rows.append(.init(label: "Kind", value: kind)) }
        if let size = sizeText { rows.append(.init(label: "Size", value: size)) }
        rows.append(.init(label: "Created", value: HomeInspectorFormat.date(facts.created, locale: locale)))
        rows.append(.init(label: "Modified", value: HomeInspectorFormat.date(facts.modified, locale: locale)))
        return rows + extraRows
    }

    private var sizeText: String? {
        if let size = facts.size { return HomeInspectorFormat.size(size) }
        guard facts.isFolder else { return nil }
        switch folderSize {
        case .measuring?: return String(localized: "Calculating…", language: locale)
        case .measured(let bytes, let isPartial)?:
            let text = HomeInspectorFormat.size(bytes)
            return isPartial ? String(format: String(localized: "More than %@", language: locale), text) : text
        case .unavailable?, nil: return "--"
        }
    }
}

/// フォルダの中身の大きさを数える(Finder のプレビューのフォルダの「サイズ」)。**FileIO の上で**、選び直したら取り消す。
nonisolated enum HomeInspectorFolderSize {
    enum Outcome: Equatable, Sendable {
        case measuring
        /// 数えた大きさ。`isPartial` は数え切れなかった(件数・時間の上限)。
        case measured(Int64, isPartial: Bool)
        case unavailable
    }

    /// 数える件数の上限(巨大なフォルダで延々と回さない)。
    static let itemLimit = 200_000
    /// 待つ上限。
    static let timeLimit: Duration = .seconds(20)

    /// FileIO の上で数える(期限付き。選び直したら取り消す)。
    static func measure(_ folder: URL) async -> Outcome {
        do {
            return try await FileIO.withDeadline(timeLimit) {
                await FileIO.perform { sum(folder) }
            }
        } catch {
            return .unavailable
        }
    }

    /// **ブロッキングする。** 取り消し(`Cancellation`)を 256 件ごとに見る。
    static func sum(_ folder: URL) -> Outcome {
        let keys: [URLResourceKey] = [.totalFileSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return .unavailable }
        var total: Int64 = 0
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count % 256 == 0, Cancellation.isRequestedInCurrentScope { return .unavailable }
            if count > itemLimit { return .measured(total, isPartial: true) }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileSize ?? values.fileSize ?? 0)
            // 値はファイルシステムから来る。足して溢れるなら打ち切る(ありえない大きさでも落ちない)。
            let (next, overflow) = total.addingReportingOverflow(max(0, size))
            if overflow { return .measured(total, isPartial: true) }
            total = next
        }
        return .measured(total, isPartial: false)
    }
}

// MARK: - 本でない項目の絵

/// 本でない項目の絵(Finder のプレビューに揃える)。
///
/// 1. 画像・動画・アプリ・記号リンク/エイリアス・画像の入ったフォルダ → アイコン表示と同じ提供役(`FileBrowserThumbnailProvider`)。
///    動画はサムネイル(環境設定「動画のサムネイルを生成」が OFF でも、選んだ 1 つには作る ―― Finder のプレビューと同じ)
/// 2. それ以外のファイル → QuickLook(`QLThumbnailGenerator` の最良の表現。中身の絵が無い種類はアイコン)
/// 3. 作れなければ、フォルダ・ボリュームはシステムのアイコン(カスタムアイコンも)、最後は種類のアイコン
///
/// 利用者が入っていない場所の中は読まない(DirectoryProbe の約束。フォルダの中・リンクの先は提供役が見る)。項目自身を読むのは、
/// 利用者がそのフォルダを見ていて選んだもの(Finder のプレビューと同じ)。
struct HomeInspectorItemPreview: View {
    let entry: FileBrowserEntry
    /// 利用者が見ているフォルダ(ファイルブラウザ)。記号リンクの先・フォルダの中を読んでよいかの規則に使う。
    let currentFolder: URL?
    /// 使ってよい幅と高さの上限。中身の絵(画像・動画・書類)は比のまま幅 × 上限の箱に収め、枠も絵の大きさに縮める(横長の動画は
    /// ペインの幅まで広がる。HomeInspectorBookView.maxCoverHeight)。アイコンは正方形。
    let width: CGFloat
    let maxHeight: CGFloat
    let savesToDisk: Bool

    @EnvironmentObject private var thumbnails: FileBrowserThumbnailProvider
    @State private var image: CGImage?
    @State private var isLoading = true

    /// アイコン・場所取りの正方形の一辺。
    private var iconSide: CGFloat { min(width, maxHeight) }

    /// 描く枠の大きさ。
    private var frameSize: CGSize {
        guard let image, !isIcon, image.width > 0, image.height > 0 else { return CGSize(width: iconSide, height: iconSide) }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let fittedWidth = min(width, maxHeight * aspect)
        return CGSize(width: fittedWidth, height: fittedWidth / aspect)
    }

    var body: some View {
        let frameSize = frameSize
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(isIcon ? 0 : 0.3), radius: 1.5, y: 0.5)
            } else {
                Image(nsImage: FileBrowserIconProvider.icon(for: entry))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .opacity(isLoading ? 0.5 : 1)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .task(id: "\(entry.identityKey)|\(thumbnails.revision)") { await load() }
        .accessibilityHidden(true)
    }

    /// 絵がアイコン(影を付けない)か。中身の絵(画像・動画・書類の 1 ページ目)には影を付ける。
    @State private var isIcon = false

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let pixelSize = FileBrowserThumbnailProvider.pixelTier(forDisplaySize: max(width, maxHeight))
        if let kind = BookThumbnailer.kind(
            forName: entry.url.lastPathComponent, isNavigableFolder: entry.isNavigableFolder,
            isPackage: entry.isPackage, isSymbolicLink: entry.isSymbolicLink, isAliasFile: entry.isAliasFile
        ), !(kind == .folder && !mayReadUnentered) {
            let buffer = await thumbnails.thumbnail(
                for: entry, kind: kind, pixelSize: pixelSize, savesToDisk: savesToDisk, currentFolder: currentFolder
            )
            guard !Task.isCancelled else { return }
            if let made = buffer?.makeImage() {
                isIcon = kind == .application || kind == .alias
                image = made
                return
            }
        }
        if !entry.isDirectory || entry.isPackage, !entry.isLink {
            let made = await HomeInspectorQuickLook.image(for: entry.url, pixelSize: pixelSize * 2)
            guard !Task.isCancelled else { return }
            if let made {
                isIcon = made.isIcon
                image = made.image
                return
            }
        }
        // フォルダ・ボリューム(と QuickLook が作れなかったもの)はシステムのアイコン。読んでよい場所だけ(読まないなら種類のアイコンのまま)。
        guard mayReadUnentered else { return }
        let url = entry.url
        let side = Int(pixelSize * 2)
        let buffer = await FileIO.perform { FileBrowserSystemIcon.render(at: url, pixelSize: side) }
        guard !Task.isCancelled, let made = buffer?.makeImage() else { return }
        isIcon = true
        image = made
    }

    /// フォルダの中(画像の入ったフォルダの絵)・フォルダ自身のアイコン(カスタムアイコンはフォルダの中のファイル)を読んでよいか。
    /// ネットワーク越しは種類のアイコンのまま(応答しない共有で待たない)、保護下の場所は見ているフォルダと同じ場所のときだけ。
    private var mayReadUnentered: Bool {
        DirectoryProbe.mayReadUnentered(entry.url, from: currentFolder, mountTable: .current())
    }
}

/// QuickLook の絵(Finder のプレビューと同じ出どころ)。期限付きで、返ってこなければ nil。
nonisolated enum HomeInspectorQuickLook {
    struct Made: Sendable {
        let image: CGImage
        /// 中身の絵ではなくアイコンだった。
        let isIcon: Bool
    }

    static let timeoutSeconds: Double = 8

    /// `QLThumbnailGenerator.Request` は Sendable ではない。期限の側からは `cancel(_:)` に渡すだけ(VideoThumbnailer と同じ)。
    private struct RequestBox: @unchecked Sendable {
        let request: QLThumbnailGenerator.Request
    }

    /// 最初の 1 回だけ戻す箱(完了・期限・取り消しのどれが先でも 1 度だけ)。
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Made?, Never>?

        func install(_ continuation: CheckedContinuation<Made?, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(_ value: Made?) {
            let taken = lock.withLock { () -> CheckedContinuation<Made?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            taken?.resume(returning: value)
        }
    }

    @concurrent static func image(for url: URL, pixelSize: CGFloat) async -> Made? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: pixelSize, height: pixelSize), scale: 1, representationTypes: .all
        )
        let box = RequestBox(request: request)
        let once = Once()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Made?, Never>) in
                once.install(continuation)
                QLThumbnailGenerator.shared.generateBestRepresentation(for: box.request) { thumbnail, _ in
                    once.resume(thumbnail.map { Made(image: $0.cgImage, isIcon: $0.type == .icon) })
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                    QLThumbnailGenerator.shared.cancel(box.request)
                    once.resume(nil)
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(box.request)
            once.resume(nil)
        }
    }
}

// MARK: - 案内

/// 選んでいない・たくさん選んでいるときの案内(すりガラス面に直に置く文字なので輪郭を掛ける)。
struct HomeInspectorMessage: View {
    let systemImage: String?
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .panelOutlinedContent()
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
