import AppKit
import UniformTypeIdentifiers

// ファイルブラウザのAppKit部品(リスト = NSTableView、ツリー = NSOutlineView、アイコン = NSCollectionView)が共有する小物
// (改善要望7 段階3、2026-09-13)。
//
// ■ すりガラス面の決まりごと(CLAUDE.md)をAppKitで守る
// ウェルカム画面は`PanelSurface.welcome`で、面を文字色で塗りつぶされうる。SwiftUIの
// `.panelOutlinedContent()`はAppKitのセルには届かないので、同じ輪郭(反対色の形を上下左右へ
// ずらして後ろに敷く。PanelContentShadow)をセルの描画で行う:
// - 行の文字 → `FileBrowserOutlinedTextFieldCell`(選択中はアクセント地の上なので掛けない)
// - 選択の地 → `FileBrowserRowView`が強調中はアクセント色・そうでなければ灰色で塗り(`SelectionEmphasis`)、
//   どちらにも反対色の縁を付ける(`.panelOutlinedAccent(in:)`相当)
// - アイコン → ファイルの種類のアイコン(色付きの絵)なので掛けない(「画像・サムネイルには掛けない」)
// - 列の見出し → `NSTableHeaderView`のまま(不透明な地を持つ)

/// 輪郭の色。文字色の反対色(ダークなら黒、ライトなら白)。PanelContentOutline.outlineColorと同じ。
@MainActor
func fileBrowserOutlineColor(for view: NSView) -> NSColor {
    view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
}

/// 輪郭を持つ文字のセル。
final class FileBrowserOutlinedTextFieldCell: NSTextFieldCell {
    /// 輪郭の太さ(pt)。0なら何もしない(環境設定「外観」の「文字の影」が既定の0なら従来どおり)。
    var outlineWidth: CGFloat = 0

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // 選択中の行(アクセント色・灰色の不透明な地の上)には掛けない ―― 不透明な地を持つ部品と同じ扱い。
        // 灰色の地のときは文字の強調(`backgroundStyle`)が .normal なので、行が選ばれているかを見る。
        if outlineWidth > 0, backgroundStyle != .emphasized, !isInSelectedRow(controlView),
           !attributedStringValue.string.isEmpty {
            let outlined = NSMutableAttributedString(attributedString: attributedStringValue)
            let whole = NSRange(location: 0, length: outlined.length)
            outlined.addAttribute(.foregroundColor, value: fileBrowserOutlineColor(for: controlView), range: whole)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = lineBreakMode
            paragraph.alignment = alignment
            outlined.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            let rect = drawingRect(forBounds: cellFrame)
            for direction in PanelContentShadow.outlineDirections {
                outlined.draw(
                    with: rect.offsetBy(dx: direction.x * outlineWidth, dy: direction.y * outlineWidth),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            }
        }
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }

    private func isInSelectedRow(_ view: NSView) -> Bool {
        var current = view.superview
        while let candidate = current {
            if let row = candidate as? NSTableRowView { return row.isSelected }
            current = candidate.superview
        }
        return false
    }
}

/// 行の地。選択は角丸で塗り(強調中はアクセント色、ウインドウが後ろ・一覧が操作先でなければ灰色)、
/// 面の色に溶けないよう反対色の縁を付ける。
final class FileBrowserRowView: NSTableRowView {
    var outlineWidth: CGFloat = 0 {
        didSet { if outlineWidth != oldValue { needsDisplay = true } }
    }
    /// リストの交互の地(面の色に追従するよう、不透明な色ではなく文字色のごく薄い重ねで描く)。
    var isStriped = false {
        didSet { if isStriped != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isStriped else { return }
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        fillRoundedRow(with: SelectionEmphasis.selectionBackground(isEmphasized: isEmphasized))
    }

    /// 行の上へのドロップの強調(フォルダの行)。AppKit 標準の強調は縁を持たず面の色に溶けるので、アイコン表示のセル
    /// (`FileBrowserIconCellView`)と同じ「アクセント色の薄い地 + 反対色の縁」で描く(2026-09-19 の総点検)。
    /// 受け口はウインドウが後ろにあっても出すものなので、常にアクセント色(`SelectionEmphasis` の型コメント)。
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        fillRoundedRow(with: NSColor.controlAccentColor.withAlphaComponent(0.35))
    }

    private func fillRoundedRow(with color: NSColor) {
        let rect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        color.setFill()
        path.fill()
        if outlineWidth > 0 {
            fileBrowserOutlineColor(for: self).setStroke()
            let border = NSBezierPath(
                roundedRect: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2),
                xRadius: 5, yRadius: 5
            )
            border.lineWidth = outlineWidth
            border.stroke()
        }
    }

    // 文字の強調(`interiorBackgroundStyle`)は AppKit の既定に任せる: 選択中かつ強調中(キーウインドウで一覧が
    // ファーストレスポンダ)なら白い文字、それ以外はふつうの文字。以前は選択中なら常に白にしていたが、地が
    // アクセント色のまま変わらなかったからで、いまは地も`isEmphasized`で灰色になる(`SelectionEmphasis`)。
    override var isEmphasized: Bool {
        didSet { if isEmphasized != oldValue { needsDisplay = true } }
    }
}

/// 名前などを1行で出すセル(アイコンは任意)。
final class FileBrowserCellView: NSTableCellView {
    let label: NSTextField
    let icon: NSImageView?

    /// 名前の欄(編集できるのは`editingName`を入れたセルだけ)。
    var nameField: FileBrowserNameField {
        // init が必ず FileBrowserNameField を作る。
        label as! FileBrowserNameField // swiftlint:disable:this force_cast
    }

    init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool, iconSize: CGFloat = 16) {
        let cell = FileBrowserOutlinedTextFieldCell(textCell: "")
        cell.lineBreakMode = .byTruncatingMiddle
        cell.truncatesLastVisibleLine = true
        cell.isEditable = false
        cell.isSelectable = false
        cell.drawsBackground = false
        let field = FileBrowserNameField(frame: .zero)
        field.cell = cell
        field.isBordered = false
        field.drawsBackground = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label = field
        if showsIcon {
            let imageView = NSImageView(frame: .zero)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            icon = imageView
        } else {
            icon = nil
        }
        super.init(frame: .zero)
        self.identifier = identifier
        textField = field
        addSubview(field)
        if let icon {
            imageView = icon
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: iconSize),
                icon.heightAnchor.constraint(equalToConstant: iconSize),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            ])
        } else {
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(text: String, color: NSColor = .labelColor, font: NSFont = .systemFont(ofSize: 13), outlineWidth: CGFloat) {
        label.stringValue = text
        label.textColor = color
        label.font = font
        if let cell = label.cell as? FileBrowserOutlinedTextFieldCell, cell.outlineWidth != outlineWidth {
            cell.outlineWidth = outlineWidth
            label.needsDisplay = true
        }
    }
}

/// ファイルの種類ごとのアイコン。**ファイルシステムに触らない**(拡張子と種類だけで引く)。
///
/// `NSWorkspace.icon(forFile:)`は、到達できない共有上のパスで30秒ブロックして「返る」(qooLibrary 実測)うえ、
/// フォルダのカスタムアイコンを読みにデスクトップ・書類の中へ触れると**TCCのダイアログが出る**
/// (検討メモ §3.3 の「勝手に出さない」)。種類のアイコンなら I/O が無い。フォルダのカスタムアイコンと
/// アプリ固有のアイコンは出ない ―― 本と画像の中身の絵は段階7のサムネイルで出す。
@MainActor
enum FileBrowserIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: FileBrowserEntry) -> NSImage {
        let key: String
        let type: UTType
        if entry.isVolume {
            key = "volume"
            type = .volume
        } else if entry.isNavigableFolder {
            key = "folder"
            type = .folder
        } else {
            let ext = entry.url.pathExtension.lowercased()
            key = (entry.isPackage ? "package." : "file.") + ext
            type = UTType(filenameExtension: ext).flatMap { $0.isDynamic ? nil : $0 }
                ?? (entry.isPackage ? .package : .data)
        }
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }

    static var folderIcon: NSImage {
        if let cached = cache["folder"] { return cached }
        let image = NSWorkspace.shared.icon(for: .folder)
        cache["folder"] = image
        return image
    }

    static var volumeIcon: NSImage {
        if let cached = cache["volume"] { return cached }
        let image = NSWorkspace.shared.icon(for: .volume)
        cache["volume"] = image
        return image
    }
}

/// 線画のアイコン(テンプレート画像)だけのボタン。**アイコンに輪郭を掛ける**(ツリーの「＋」)。
/// SwiftUIの`.panelIconButtonLabel()`が内側で輪郭を掛けるのと同じ扱い。
final class FileBrowserOutlinedIconButton: NSButton {
    var outlineWidth: CGFloat = 0 {
        didSet { if outlineWidth != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        if outlineWidth > 0, let image, let tinted = Self.tinted(image, color: fileBrowserOutlineColor(for: self)) {
            let size = image.size
            let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
            let base = NSRect(origin: origin, size: size)
            for direction in PanelContentShadow.outlineDirections {
                tinted.draw(
                    in: base.offsetBy(dx: direction.x * outlineWidth, dy: direction.y * outlineWidth),
                    from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5
                )
            }
        }
        super.draw(dirtyRect)
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// 列の見出し。**不透明な地を自分で敷く。** 既定の見出しは半透明のマテリアルで、ウェルカム画面の面を
/// 文字色で塗りつぶすと(ダーク+白100%)見出しの文字ごと面に溶けて消えた(実測 2026-09-13)。
/// 地があれば輪郭は要らない(CLAUDE.md の「不透明な地を持つ部品」)。
final class FileBrowserTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

/// 開閉の三角に輪郭を付ける`NSOutlineView`。
///
/// 三角はAppKitが作るボタン(`disclosureButtonIdentifier`)で、灰色の線画。面を文字色で塗ると
/// (ダーク+白100%)**選ばれていない行の三角が跡形もなく消えた**(実測 2026-09-13)。作られた
/// ボタンの絵を、反対色の輪郭を焼き込んだ絵に差し替える。
final class FileBrowserOutlineView: NSOutlineView {
    var outlineWidth: CGFloat = 0
    /// 出し口が移動を許すかを尋ねる相手(読み取り専用モード。`fileBrowserDragSourceMask`)。
    weak var editResponder: (any FileBrowserEditResponding)?

    override func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // よく使う項目の並べ替えは、この一覧の中だけで動かす(ファイルではないので読み取り専用モードとは関係しない)。
        if session.draggingPasteboard.types?.contains(fileBrowserFavoriteLocationPasteboardType) == true {
            return context == .withinApplication ? .move : []
        }
        return fileBrowserDragSourceMask(allowsFileChanges: editResponder?.allowsFileChanges ?? false)
    }

    /// いまこの一覧の上でドラッグを受けているか(ドラッグ中に行を開かないため。TreeView の shouldExpandItem)。
    /// 入ったら立て、出たら・落とされたら(`noteDropAccepted`)下ろす。**`draggingEnded` / `concludeDragOperation` は
    /// 上書きしない** ―― 上書きすると、この一覧へ落としたときにドラッグ元(リスト)の
    /// `draggingSession(_:endedAt:operation:)` が呼ばれなくなり、アプリの中のドラッグの記録
    /// (FileBrowserDragTracker)が残り続けた(実機 2026-09-13)。下ろし忘れても、マウスのボタンが離れていれば
    /// ドラッグ中とは見なさない(`isReceivingDrag` の読み出し側)。
    private var dragInside = false

    var isReceivingDrag: Bool {
        dragInside && NSEvent.pressedMouseButtons & 1 != 0
    }

    /// 行の名前の欄(編集しないラベル)を当たり先にしない。リストの `FileBrowserTableView.hitTest` と同じ理由
    /// (2026-09-14。アイコン表示の右クリックでサブメニューを開いて閉じたあと、ツリーの右クリックのメニューが開かなくなった)。
    override func hitTest(_ point: NSPoint) -> NSView? {
        resolvedHit(super.hitTest(point))
    }

    /// `hitTest` の結果を確かめ直す(テストはここを直に呼ぶ)。
    func resolvedHit(_ hit: NSView?) -> NSView? {
        hit is NSTextField ? self : hit
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragInside = true
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragInside = false
        super.draggingExited(sender)
    }

    func noteDropAccepted() {
        dragInside = false
    }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.disclosureButtonIdentifier, let button = view as? NSButton {
            decorate(button)
        }
        return view
    }

    /// 外観(ライト/ダーク)が変わったら、出ている三角の絵を焼き直す。輪郭の色(反対色)は焼いた時点の外観で決まるので、
    /// 焼き直さないと行が作り直されるまで逆の色の輪郭が残る(2026-09-19 の総点検)。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard outlineWidth > 0 else { return }
        enumerateAvailableRowViews { rowView, _ in
            for case let button as NSButton in rowView.subviews
            where button.identifier == NSOutlineView.disclosureButtonIdentifier {
                self.decorate(button)
            }
        }
    }

    private var originalImages: [ObjectIdentifier: (NSImage?, NSImage?)] = [:]

    private func decorate(_ button: NSButton) {
        let key = ObjectIdentifier(button)
        if originalImages[key] == nil { originalImages[key] = (button.image, button.alternateImage) }
        guard let (image, alternate) = originalImages[key] else { return }
        guard outlineWidth > 0 else {
            button.image = image
            button.alternateImage = alternate
            return
        }
        let outline = fileBrowserOutlineColor(for: self)
        button.image = image.map { Self.outlined($0, width: outlineWidth, outline: outline) }
        button.alternateImage = alternate.map { Self.outlined($0, width: outlineWidth, outline: outline) }
    }

    /// テンプレートの絵を「反対色の輪郭 + 文字色(副)の本体」で焼き直す。
    private static func outlined(_ image: NSImage, width: CGFloat, outline: NSColor) -> NSImage {
        let size = image.size
        let result = NSImage(size: size, flipped: false) { rect in
            func tinted(_ color: NSColor) -> NSImage {
                NSImage(size: size, flipped: false) { inner in
                    image.draw(in: inner)
                    color.set()
                    inner.fill(using: .sourceAtop)
                    return true
                }
            }
            let back = tinted(outline)
            for direction in PanelContentShadow.outlineDirections {
                back.draw(in: rect.offsetBy(dx: direction.x * width, dy: direction.y * width))
            }
            tinted(.secondaryLabelColor).draw(in: rect)
            return true
        }
        result.isTemplate = false
        return result
    }
}

/// 名前の欄。`editingName`を入れると編集できる欄になり、編集を始めた瞬間に**表示名ではなく実際の名前**へ
/// 差し替えて、拡張子を除いた部分を選ぶ(Finder と同じ。フォルダは全体)。
final class FileBrowserNameField: NSTextField {
    /// 編集に使う名前(`url.lastPathComponent`)。nil なら編集させない。
    var editingName: String? {
        didSet {
            let editable = editingName != nil
            if isEditable != editable {
                isEditable = editable
                isSelectable = editable
            }
        }
    }

    /// フォルダなら名前全体を選ぶ(`.` 以降も名前の一部)。
    var selectsWholeName = false

    override func becomeFirstResponder() -> Bool {
        if let editingName, isEditable { stringValue = editingName }
        let accepted = super.becomeFirstResponder()
        if accepted, let editingName, let editor = currentEditor() {
            editor.selectedRange = selectsWholeName
                ? NSRange(location: 0, length: (editingName as NSString).length)
                : Self.baseNameRange(of: editingName)
        }
        return accepted
    }

    /// 拡張子を除いた部分の範囲(UTF-16)。先頭の . だけの名前(`.hidden`)と拡張子の無い名前は全体。
    static func baseNameRange(of name: String) -> NSRange {
        let ns = name as NSString
        let dot = ns.range(of: ".", options: .backwards)
        guard dot.location != NSNotFound, dot.location > 0 else { return NSRange(location: 0, length: ns.length) }
        return NSRange(location: 0, length: dot.location)
    }
}
