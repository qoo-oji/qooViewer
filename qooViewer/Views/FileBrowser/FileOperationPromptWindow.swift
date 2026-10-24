import AppKit

/// ファイル操作の問い合わせと報告を、**Finder の「コピー」「ゴミ箱」ウインドウの行と同じ形で**見せる(2026-10-24、ユーザー決定)。
///
/// ■ なぜアラートではないのか
/// Finder は同じ名前の項目・ロック・名前が長すぎる・空き不足などを、アラートではなく操作のウインドウ(幅 404pt・題を出さない)の
/// 中の行として出す(実測 2026-10-24、macOS 27)。以前の NSAlert のシートは 4 つのボタンが縦に積まれて読みにくかった。
/// 1 行は「34pt のアイコン + 注意のバッジ / 幅 332pt の本文 / 右下に 88×22pt のボタン」で、新しい行が上に積まれ、
/// 行の間には 1pt の線が入る。既定のボタン(Return)も Esc の割り当ても無い(AXDefaultButton・AXCancelButton とも空)。
/// 寸法は Finder の実物を撮った画像と画素で突き合わせて決めた(docs/15「操作の問い合わせ」)。
///
/// ■ 持ち主のウインドウ
/// 行はどのウインドウの操作のものかを持つ(weak)。持ち主が閉じたら、`answerWhenOwnerCloses` の答えで片付ける
/// (以前のシートが閉じるときに「キャンセル」で答えていたのと同じ ―― 見ていないところで新しく何かを決めない)。
/// OK だけの報告は持ち主が閉じても残す(Finder と同じく、読むまで消えない)。
///
/// この型は AppKit だけに頼る(Finder の画像と並べて撮る確かめの道具が、このファイルだけを取り込んで描けるように)。
struct FileOperationPrompt {
    var icon: NSImage
    var message: String
    /// 左から右の順。Finder と同じく右端がその操作を進める答え。
    var buttons: [String]
    /// 左下の「すべてに適用」。nil なら出さない。
    var checkboxTitle: String?
    /// 持ち主のウインドウが閉じたときの答え(`buttons` の添字)。nil なら閉じても残す。
    var answerWhenOwnerCloses: Int?
    /// ウインドウの題(画面には出ない。ウインドウメニューと読み上げに使う)。
    var windowTitle: String
}

struct FileOperationPromptAnswer: Equatable {
    /// 押したボタン(`FileOperationPrompt.buttons` の添字)。
    let button: Int
    let checkboxIsOn: Bool
}

@MainActor
final class FileOperationPromptCenter {
    static let shared = FileOperationPromptCenter()

    /// false ならウインドウを出さない(テストが行の出し入れだけを確かめる)。
    private let showsWindow: Bool

    init(showsWindow: Bool = true) {
        self.showsWindow = showsWindow
    }

    /// 新しい行が先頭。
    private var rows: [PromptRowView] = []
    private var window: FileOperationPromptWindow?
    private var ownerObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// 行を出して、ボタンが押されるまで待つ。
    func ask(_ prompt: FileOperationPrompt, owner: NSWindow?) async -> FileOperationPromptAnswer {
        await withCheckedContinuation { continuation in
            add(PromptRowView(prompt: prompt, owner: owner) { answer in continuation.resume(returning: answer) })
        }
    }

    /// 答えを待たない報告(OK だけの行)。
    func report(_ prompt: FileOperationPrompt, owner: NSWindow?) {
        add(PromptRowView(prompt: prompt, owner: owner) { _ in })
    }

    /// 出ている行の数(テストと制御口から)。
    var pendingCount: Int { rows.count }

    private func add(_ row: PromptRowView) {
        row.onAnswer = { [weak self, weak row] in
            guard let self, let row else { return }
            self.remove(row)
        }
        rows.insert(row, at: 0)
        if let owner = row.owner { watch(owner) }
        guard showsWindow else { return }
        let window = window ?? makeWindow()
        self.window = window
        window.show(rows: rows, title: row.prompt.windowTitle, isNew: true)
    }

    private func remove(_ row: PromptRowView) {
        rows.removeAll { $0 === row }
        guard let window else { return }
        if rows.isEmpty {
            window.orderOut(nil)
        } else {
            window.show(rows: rows, title: rows[0].prompt.windowTitle, isNew: false)
        }
        // 閉じるのを見張る相手を、行の残っている持ち主だけにする。
        let owners = Set(rows.compactMap { $0.owner.map(ObjectIdentifier.init) })
        for (id, observer) in ownerObservers where !owners.contains(id) {
            NotificationCenter.default.removeObserver(observer)
            ownerObservers[id] = nil
        }
    }

    private func watch(_ owner: NSWindow) {
        let id = ObjectIdentifier(owner)
        guard ownerObservers[id] == nil else { return }
        ownerObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: owner, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ownerWillClose(id) }
        }
    }

    private func ownerWillClose(_ id: ObjectIdentifier) {
        for row in rows where row.owner.map(ObjectIdentifier.init) == id {
            guard let answer = row.prompt.answerWhenOwnerCloses else { continue }
            row.answer(answer)
        }
    }

    private func makeWindow() -> FileOperationPromptWindow {
        FileOperationPromptWindow()
    }
}

/// 行を積むウインドウ。Finder の操作ウインドウと同じく、題は出さず、閉じるボタンは押せない(問い合わせに答えるまで閉じない)。
@MainActor
final class FileOperationPromptWindow: NSWindow {
    static let width: CGFloat = 404
    /// 行が増えたときにスクロールし始める高さ(Finder の実測: 内容 485pt + 題の帯 32pt = 517pt)。
    static let maximumContentHeight: CGFloat = 485

    private let scrollView = NSScrollView()
    private let stack = FlippedView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: true
        )
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isEnabled = false
        standardWindowButton(.zoomButton)?.isEnabled = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = stack
        contentView = scrollView
    }

    func show(rows: [PromptRowView], title: String, isNew: Bool) {
        self.title = title
        stack.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                // 行の間: 上の行のボタンの下 9pt に 1pt の線、線の下 7pt で次の行(実測)。
                y += PromptRowView.gapAboveSeparator
                let line = SeparatorLine(frame: NSRect(x: 0, y: y, width: Self.width, height: 1))
                stack.addSubview(line)
                y += 1 + PromptRowView.gapBelowSeparator
            } else {
                y += PromptRowView.topInset
            }
            row.layOut(width: Self.width)
            row.setFrameOrigin(NSPoint(x: 0, y: y))
            stack.addSubview(row)
            y += row.frame.height
        }
        y += PromptRowView.bottomInset
        stack.frame = NSRect(x: 0, y: 0, width: Self.width, height: y)
        let contentHeight = min(y, Self.maximumContentHeight)
        let top = isVisible ? frame.maxY : nil
        var frame = frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: contentHeight))
        if let top {
            frame.origin = NSPoint(x: self.frame.minX, y: top - frame.height)
        } else if let screen = NSScreen.main {
            // Finder の操作ウインドウが出る場所(画面の左上から 223pt・147pt。実測)。
            frame.origin = NSPoint(x: screen.frame.minX + 223, y: screen.frame.maxY - 147 - frame.height)
        }
        setFrame(frame, display: true)
        standardWindowButton(.zoomButton)?.isEnabled = rows.count > 1
        if isNew {
            makeKeyAndOrderFront(nil)
        }
    }
}

/// 1 件の問い合わせ・報告。
@MainActor
final class PromptRowView: NSView {
    static let topInset: CGFloat = 1
    static let bottomInset: CGFloat = 11
    static let gapAboveSeparator: CGFloat = 9
    static let gapBelowSeparator: CGFloat = 7
    static let iconX: CGFloat = 17
    static let iconSize: CGFloat = 34
    static let badgeSize: CGFloat = 18
    static let textX: CGFloat = 61
    static let textWidth: CGFloat = 332
    /// 本文の左右の余白。字の頭は 62pt、折り返す幅は 330pt(Finder の字の位置と、9 通りの文の折り返しに合わせた実測値)。
    static let textPadding: CGFloat = 1
    static let textY: CGFloat = 0
    static let textExtraHeight: CGFloat = 2
    static let lineHeight: CGFloat = 14
    static let textToButtons: CGFloat = 10
    static let buttonSize = NSSize(width: 88, height: 22)
    static let buttonSpacing: CGFloat = 6
    static let checkboxX: CGFloat = 12

    let prompt: FileOperationPrompt
    weak var owner: NSWindow?
    var onAnswer: (() -> Void)?
    private let resume: (FileOperationPromptAnswer) -> Void
    private var answered = false

    private let iconView = NSImageView()
    private let badgeView = NSImageView()
    /// 本文。折り返しは `keepingWordsTogether` を通す。
    private let textView = NSTextView(usingTextLayoutManager: true)
    private var buttons: [NSButton] = []
    private var checkbox: NSButton?

    override var isFlipped: Bool { true }

    init(prompt: FileOperationPrompt, owner: NSWindow?, resume: @escaping (FileOperationPromptAnswer) -> Void) {
        self.prompt = prompt
        self.owner = owner
        self.resume = resume
        super.init(frame: .zero)
        iconView.image = prompt.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        badgeView.image = Self.cautionBadge
        badgeView.imageScaling = .scaleProportionallyUpOrDown
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = Self.textPadding
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: Self.textWidth, height: .greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        textView.textStorage?.setAttributedString(NSAttributedString(string: Self.keepingWordsTogether(prompt.message), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]))
        textView.setAccessibilityRole(.staticText)
        textView.setAccessibilityValue(prompt.message)
        addSubview(iconView)
        addSubview(badgeView)
        addSubview(textView)
        for (index, title) in prompt.buttons.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(press(_:)))
            button.tag = index
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            // 既定のボタンを作らない(Finder の行には Return も Esc も無い)。NSButton は題が「Cancel」のボタンに Esc を付けない。
            button.keyEquivalent = ""
            buttons.append(button)
            addSubview(button)
        }
        if let title = prompt.checkboxTitle {
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.controlSize = .small
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            checkbox = box
            addSubview(box)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func layOut(width: CGFloat) {
        var textHeight: CGFloat = 16
        if let layout = textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            textHeight = ceil(layout.usageBoundsForTextContainer.height) + Self.textExtraHeight
        }
        // 読み上げの枠は Finder と同じ 34pt・18pt だが、絵はその中に 32pt・16pt で描かれている(画素の突き合わせ)。
        iconView.frame = NSRect(x: Self.iconX + 1, y: 1, width: Self.iconSize - 2, height: Self.iconSize - 2)
        badgeView.frame = NSRect(
            x: Self.iconX + Self.iconSize - Self.badgeSize + 1, y: Self.iconSize - Self.badgeSize + 3,
            width: Self.badgeSize - 2, height: Self.badgeSize - 2
        )
        textView.frame = NSRect(x: Self.textX, y: Self.textY, width: Self.textWidth, height: textHeight)
        // 「すべてに適用」のある行は、ボタンが 1pt 下がる(Finder の実測: 窓の高さ 107pt と 106pt)。
        let buttonsY = textHeight + Self.textToButtons + (checkbox == nil ? 0 : 1)
        var x = Self.textX + Self.textWidth
        for button in buttons.reversed() {
            x -= Self.buttonSize.width
            // 枠は 88pt だが、Finder のボタンの地は左右 1pt ずつ内側(86pt)に描かれている。
            button.frame = NSRect(x: x + 1, y: buttonsY, width: Self.buttonSize.width - 2, height: Self.buttonSize.height)
            x -= Self.buttonSpacing
        }
        if let checkbox {
            checkbox.sizeToFit()
            checkbox.setFrameOrigin(NSPoint(x: Self.checkboxX, y: buttonsY + (Self.buttonSize.height - checkbox.frame.height) / 2))
        }
        frame = NSRect(x: 0, y: 0, width: width, height: buttonsY + Self.buttonSize.height)
    }

    @objc private func press(_ sender: NSButton) {
        answer(sender.tag)
    }

    func answer(_ index: Int) {
        guard !answered else { return }
        answered = true
        resume(FileOperationPromptAnswer(button: index, checkboxIsOn: checkbox?.state == .on))
        onAnswer?()
    }

    /// Finder の行と同じ所で折り返すよう、**漢字かカタカナを含む語の中では折り返さない**(語の字の間に WORD JOINER を挟む)。
    ///
    /// Finder の行は「…あります。/現在コピー中の…」「…使用す/るには…」のように折り返す ―― 「現在」「コピー」「置き換え」は割らず、
    /// 「する」は割る。NSTextField・TextKit 2・SwiftUI の Text はどれも、`lineBreakStrategy` や言語の指定によらず「現/在」で割った。
    /// 語は CFStringTokenizer(日本語)で区切り、漢字かカタカナを含む語だけを守ると、撮った 9 通りの文がすべて Finder と同じ所で
    /// 折り返った(2026-10-24 の実測。仕組みとして Finder がそうしているかは確かめていない ―― 結果が一致するだけ)。
    nonisolated static func keepingWordsTogether(_ text: String) -> String {
        let string = text as NSString
        guard string.length > 1 else { return text }
        let tokenizer = CFStringTokenizerCreate(
            nil, text as CFString, CFRange(location: 0, length: string.length), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale
        )
        var joinsAfter = IndexSet()
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.length > 1 else { continue }
            let word = string.substring(with: NSRange(location: range.location, length: range.length))
            guard word.unicodeScalars.contains(where: isHanOrKatakana) else { continue }
            // 語の最後の字の後ろは挟まない(語の間では今までどおり折り返せる)。
            var index = range.location
            while index < range.location + range.length {
                let character = string.rangeOfComposedCharacterSequence(at: index)
                let next = character.location + character.length
                if next < range.location + range.length { joinsAfter.insert(next) }
                index = next
            }
        }
        guard !joinsAfter.isEmpty else { return text }
        var result = ""
        var start = 0
        for index in joinsAfter {
            result += string.substring(with: NSRange(location: start, length: index - start)) + "\u{2060}"
            start = index
        }
        return result + string.substring(from: start)
    }

    private nonisolated static func isHanOrKatakana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3005, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true
        default: false
        }
    }

    /// Finder の行の注意のバッジ。システムの警告のアイコンを 16pt で描くと画素まで同じになった(CoreTypes の AlertCautionBadgeIcon は
    /// 枠の右下に小さく描かれた絵で、18pt では三角が小さすぎた ―― 2026-10-24 の突き合わせ)。
    static let cautionBadge: NSImage? = NSImage(named: NSImage.cautionName)
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SeparatorLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}
