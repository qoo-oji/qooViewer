import AppKit

/// 一括リネームのシート(改善要望7 段階 5、2026-09-14。決定事項 Q7: AppKit で組み、この機の macOS 26.6 の Finder に合わせる)。
///
/// ■ 何を Finder に合わせたか(実物のシートを AX で読み、`screencapture` で撮って比べた)
/// - 部品と並び: 上に淡色の見出しと区切り線、方式のポップアップ(テキストを置き換える / テキストを追加 / フォーマット)、
///   方式ごとの欄、区切り線、下に「例:」と「キャンセル」「名前を変更」。**方式で高さが変わる**(置き換え 132pt、追加 103pt、
///   フォーマット 161pt。幅は 489pt)。「テキストを追加」だけは方式のポップアップと同じ行に欄が並ぶ。
/// - 右寄せのラベルの列(「名前のフォーマット:」「カスタムフォーマット:」の幅が揃う)。
/// - 「例:」は表示順で最初の項目。日付のときは開始番号の欄が淡色。開始番号は数字しか入らない。
/// - 押せない条件(検索文字列・追加するテキストが空)。
/// 文言は Finder の文言表(`BulkRenameWindow.strings` と `LocalizableMerged.strings` の `BR*`)を写した。
/// ただし見出しの「Finder項目の」は付けず、ボタンは qooViewer のほかの場所と同じ「名前を変更」にした(用語表)。
///
/// ■ Finder と違うところ
/// 使えない名前(先頭のドット・`/` など)ができる入力では、Finder は押した後にアラートを出して何もしないが、
/// ここでは例の行に赤字で理由を出し「名前を変更」を押せなくする(BulkRename の型コメント)。
///
/// ■ 寿命
/// シートが閉じるまでは`beginSheet`の完了の閉包がこれを掴み、閉じたら手放す。ホストのウインドウは引数で受け取るだけで持たない
/// (CLAUDE.md のリークの件)。
@MainActor
final class BulkRenamePanel: NSObject, NSTextFieldDelegate {
    /// 例の行だけでなく全件を毎回決め直す上限(超えたら例の行だけ。使えない名前は押した後に FileBrowserOperations が見る)。
    static let fullCheckLimit = 2000
    static let width: CGFloat = 489

    private let request: BulkRenameRequest
    private let locale: Locale
    private var settings: BulkRenameSettings
    private let panel: NSPanel

    private let titleLabel = NSTextField(labelWithString: "")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let findLabel = NSTextField(labelWithString: "")
    private let findField = NSTextField(string: "")
    private let replaceLabel = NSTextField(labelWithString: "")
    private let replaceField = NSTextField(string: "")
    private let addField = NSTextField(string: "")
    private let addPlacementPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatLabel = NSTextField(labelWithString: "")
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let placementLabel = NSTextField(labelWithString: "")
    private let formatPlacementPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customLabel = NSTextField(labelWithString: "")
    private let customField = NSTextField(string: "")
    private let startLabel = NSTextField(labelWithString: "")
    private let startField = NSTextField(string: "")
    private let exampleLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let renameButton = NSButton(title: "", target: nil, action: nil)
    private let body = NSView()
    private var bodyConstraints: [NSLayoutConstraint] = []

    private init(request: BulkRenameRequest, locale: Locale) {
        self.request = request
        self.locale = locale
        settings = request.settings
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 132),
            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true
        )
        super.init()
        panel.isReleasedWhenClosed = false
        buildViews()
        load(settings)
        layoutBody(animated: false)
        refresh()
        // 出た時点で方式の最初の欄に焦点を置く(ウインドウに入る前の makeFirstResponder は効かないので initialFirstResponder で)。
        panel.initialFirstResponder = firstField
    }

    /// シートで尋ねる。「名前を変更」なら入力を、「キャンセル」なら nil。ホストが無い・既にシートが出ているならモーダルのウインドウで。
    static func run(_ request: BulkRenameRequest, on host: NSWindow?, locale: Locale) async -> BulkRenameSettings? {
        let sheet = BulkRenamePanel(request: request, locale: locale)
        let response: NSApplication.ModalResponse
        if let host, host.attachedSheet == nil, host.isVisible {
            response = await withCheckedContinuation { continuation in
                host.beginSheet(sheet.panel) { continuation.resume(returning: $0) }
            }
        } else {
            sheet.panel.center()
            response = NSApp.runModal(for: sheet.panel)
            sheet.panel.orderOut(nil)
        }
        return response == .OK ? sheet.settings : nil
    }

    // MARK: - 組み立て

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, language: locale)
    }

    private func buildViews() {
        titleLabel.stringValue = text("Rename Items:")
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        modePopup.addItems(withTitles: [text("Replace Text"), text("Add Text"), text("Format")])
        addPlacementPopup.addItems(withTitles: [text("after name"), text("before name")])
        formatPlacementPopup.addItems(withTitles: [text("after name"), text("before name")])
        formatPopup.addItems(withTitles: [text("Name and Index"), text("Name and Counter"), text("Name and Date")])
        for popup in [modePopup, addPlacementPopup, formatPopup, formatPlacementPopup] {
            popup.target = self
            popup.action = #selector(controlsChanged(_:))
        }
        findLabel.stringValue = text("Find:")
        replaceLabel.stringValue = text("Replace with:")
        formatLabel.stringValue = text("Name Format:")
        placementLabel.stringValue = text("Where:")
        customLabel.stringValue = text("Custom Format:")
        startLabel.stringValue = text("Start numbers at:")
        startField.placeholderString = "1"
        for label in [findLabel, replaceLabel, formatLabel, placementLabel, customLabel, startLabel] {
            label.alignment = .right
        }
        for field in [findField, replaceField, addField, customField, startField] {
            field.delegate = self
            field.lineBreakMode = .byClipping
            field.cell?.isScrollable = true
            field.cell?.wraps = false
        }
        // 理由の文が長いときに、先頭の項目名が残るよう末尾を切る(全文はツールチップ)。
        exampleLabel.lineBreakMode = .byTruncatingTail
        exampleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.title = text("Cancel")
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        renameButton.title = text("Rename")
        renameButton.bezelStyle = .push
        renameButton.keyEquivalent = "\r"
        renameButton.target = self
        renameButton.action = #selector(rename(_:))

        let content = NSView()
        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        for view in [titleLabel, topSeparator, body, bottomSeparator, exampleLabel, cancelButton, renameButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 3),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 19),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            topSeparator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            topSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 19),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottomSeparator.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 7),
            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            renameButton.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor, constant: 7),
            renameButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            renameButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
            // 組のボタンは同じ幅(Finder も 86pt で揃う)。
            renameButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
            cancelButton.widthAnchor.constraint(equalTo: renameButton.widthAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: renameButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: renameButton.leadingAnchor, constant: -10),
            exampleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 19),
            exampleLabel.centerYAnchor.constraint(equalTo: renameButton.centerYAnchor),
            exampleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),
        ])
        panel.contentView = content
    }

    /// 方式に合わせて中身を並べ直し、シートの高さを合わせる。
    private func layoutBody(animated: Bool) {
        NSLayoutConstraint.deactivate(bodyConstraints)
        bodyConstraints = []
        body.subviews.forEach { $0.removeFromSuperview() }

        let views: [NSView]
        switch settings.kind {
        case .replaceText:
            views = [modePopup, findLabel, findField, replaceLabel, replaceField]
        case .addText:
            views = [modePopup, addField, addPlacementPopup]
        case .format:
            views = [modePopup, formatLabel, formatPopup, placementLabel, formatPlacementPopup, customLabel, customField, startLabel, startField]
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = [
            modePopup.topAnchor.constraint(equalTo: body.topAnchor),
            modePopup.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            // 幅は Finder の寸法を下限にする(macOS 26 の標準の大きさのポップアップは Finder の nib より余白が広く、143pt では「テキストを置き換える」が切れた。実機 2026-09-14)。
            modePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 143),
        ]
        switch settings.kind {
        case .replaceText:
            constraints += [
                findField.topAnchor.constraint(equalTo: modePopup.bottomAnchor, constant: 7),
                findField.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                findLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                findLabel.firstBaselineAnchor.constraint(equalTo: findField.firstBaselineAnchor),
                findField.leadingAnchor.constraint(equalTo: findLabel.trailingAnchor, constant: 6),
                replaceLabel.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 12),
                replaceLabel.firstBaselineAnchor.constraint(equalTo: findField.firstBaselineAnchor),
                replaceField.leadingAnchor.constraint(equalTo: replaceLabel.trailingAnchor, constant: 6),
                replaceField.centerYAnchor.constraint(equalTo: findField.centerYAnchor),
                replaceField.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
            ]
        case .addText:
            constraints += [
                modePopup.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                addField.centerYAnchor.constraint(equalTo: modePopup.centerYAnchor),
                addField.leadingAnchor.constraint(equalTo: modePopup.trailingAnchor, constant: 7),
                addPlacementPopup.leadingAnchor.constraint(equalTo: addField.trailingAnchor, constant: 5),
                addPlacementPopup.centerYAnchor.constraint(equalTo: modePopup.centerYAnchor),
                addPlacementPopup.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            ]
        case .format:
            // 左の列(ラベル・ポップアップ・欄)と右の列を、それぞれ幅を揃えて右寄せ。
            constraints += [
                formatPopup.topAnchor.constraint(equalTo: modePopup.bottomAnchor, constant: 5),
                customField.topAnchor.constraint(equalTo: formatPopup.bottomAnchor, constant: 7),
                customField.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                formatLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                customLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                formatLabel.widthAnchor.constraint(equalTo: customLabel.widthAnchor),
                formatLabel.firstBaselineAnchor.constraint(equalTo: formatPopup.firstBaselineAnchor),
                customLabel.firstBaselineAnchor.constraint(equalTo: customField.firstBaselineAnchor),
                formatPopup.leadingAnchor.constraint(equalTo: formatLabel.trailingAnchor, constant: 6),
                customField.leadingAnchor.constraint(equalTo: customLabel.trailingAnchor, constant: 6),
                formatPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 133),
                customField.widthAnchor.constraint(equalTo: formatPopup.widthAnchor),
                formatPlacementPopup.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                startField.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                formatPlacementPopup.centerYAnchor.constraint(equalTo: formatPopup.centerYAnchor),
                startField.centerYAnchor.constraint(equalTo: customField.centerYAnchor),
                formatPlacementPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
                startField.widthAnchor.constraint(equalTo: formatPlacementPopup.widthAnchor),
                placementLabel.trailingAnchor.constraint(equalTo: formatPlacementPopup.leadingAnchor, constant: -6),
                startLabel.trailingAnchor.constraint(equalTo: startField.leadingAnchor, constant: -6),
                placementLabel.firstBaselineAnchor.constraint(equalTo: formatPopup.firstBaselineAnchor),
                startLabel.firstBaselineAnchor.constraint(equalTo: customField.firstBaselineAnchor),
                placementLabel.leadingAnchor.constraint(greaterThanOrEqualTo: formatPopup.trailingAnchor, constant: 12),
                startLabel.leadingAnchor.constraint(greaterThanOrEqualTo: customField.trailingAnchor, constant: 12),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        bodyConstraints = constraints
        fitPanel(animated: animated)
    }

    private func fitPanel(animated: Bool) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: content.fittingSize.height)
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // シートは上端を保って伸び縮みする(Finder と同じ)。
        frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }

    // MARK: - 入力と表示

    private func load(_ settings: BulkRenameSettings) {
        modePopup.selectItem(at: BulkRenameSettings.Kind.allCases.firstIndex(of: settings.kind) ?? 0)
        findField.stringValue = settings.find
        replaceField.stringValue = settings.replaceWith
        addField.stringValue = settings.addedText
        addPlacementPopup.selectItem(at: settings.addPlacement == .afterName ? 0 : 1)
        formatPopup.selectItem(at: BulkRename.FormatStyle.allCases.firstIndex(of: settings.formatStyle) ?? 0)
        formatPlacementPopup.selectItem(at: settings.formatPlacement == .afterName ? 0 : 1)
        customField.stringValue = settings.customFormat ?? BulkRenameSettings.defaultCustomFormat(locale: locale)
        startField.stringValue = settings.startNumberText
    }

    private func readControls() {
        settings.kind = BulkRenameSettings.Kind.allCases[max(0, modePopup.indexOfSelectedItem)]
        settings.find = findField.stringValue
        settings.replaceWith = replaceField.stringValue
        settings.addedText = addField.stringValue
        settings.addPlacement = addPlacementPopup.indexOfSelectedItem == 1 ? .beforeName : .afterName
        settings.formatStyle = BulkRename.FormatStyle.allCases[max(0, formatPopup.indexOfSelectedItem)]
        settings.formatPlacement = formatPlacementPopup.indexOfSelectedItem == 1 ? .beforeName : .afterName
        settings.customFormat = customField.stringValue
        settings.startNumberText = startField.stringValue
    }

    /// 例の行・押せるか・開始番号の欄の淡色を今の入力に合わせる。
    private func refresh() {
        let mode = settings.mode(locale: locale)
        startField.isEnabled = settings.formatStyle != .nameAndDate
        startLabel.textColor = startField.isEnabled ? .labelColor : .disabledControlTextColor
        let checksAll = request.names.count <= Self.fullCheckLimit
        let plan = BulkRename.plan(
            names: request.names, existingNames: request.existingNames, mode: mode, locale: locale,
            limit: checksAll ? nil : 1
        )
        if let problem = BulkRename.firstProblem(in: plan), let reason = problem.problem {
            exampleLabel.stringValue = reason.message(for: problem.originalName, locale: locale)
            exampleLabel.textColor = .systemRed
            exampleLabel.toolTip = exampleLabel.stringValue
            renameButton.isEnabled = false
            return
        }
        exampleLabel.stringValue = String(format: text("Example: %@"), plan.first?.newName ?? "")
        exampleLabel.textColor = .labelColor
        exampleLabel.toolTip = nil
        renameButton.isEnabled = BulkRename.canApply(mode)
    }

    @objc private func controlsChanged(_ sender: Any?) {
        let previousKind = settings.kind
        readControls()
        if settings.kind != previousKind {
            layoutBody(animated: true)
            focusFirstField()
        }
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        // 開始番号の欄は数字だけ(Finder の欄も数字以外を受け付けない)。
        if (notification.object as? NSTextField) === startField {
            let digits = startField.stringValue.filter { $0.isASCII && $0.isNumber }
            if digits != startField.stringValue { startField.stringValue = digits }
        }
        readControls()
        refresh()
    }

    private var firstField: NSTextField {
        switch settings.kind {
        case .replaceText: findField
        case .addText: addField
        case .format: customField
        }
    }

    private func focusFirstField() {
        panel.makeFirstResponder(firstField)
        firstField.currentEditor()?.selectAll(nil)
    }

    @objc private func cancel(_ sender: Any?) {
        end(.cancel)
    }

    @objc private func rename(_ sender: Any?) {
        readControls()
        guard renameButton.isEnabled else { return }
        end(.OK)
    }

    private func end(_ response: NSApplication.ModalResponse) {
        if let host = panel.sheetParent {
            host.endSheet(panel, returnCode: response)
        } else {
            NSApp.stopModal(withCode: response)
        }
    }
}
