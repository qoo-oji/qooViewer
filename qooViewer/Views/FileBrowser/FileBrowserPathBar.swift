import AppKit
import SwiftUI

/// 右ペインの下のパスバー(改善要望7 段階3、2026-09-13)。`NSPathControl`を包む。
///
/// ■ `url`を設定しない
/// `NSPathControl.url`を設定すると、**メインスレッドで**各成分の`realpath`・リソース値・アイコンの
/// 取得が同期に走り、遅い共有で固まる(FB22294400。検討メモ §12)。`NSPathControlItem`を自分で
/// 組み立て、名前はパスの成分(ローカルのボリュームだけ表示名)、アイコンは種類のアイコンにする。
///
/// ■ 輪郭
/// パスバーは不透明な帯(`controlBackgroundColor`)の上に置くので、輪郭は要らない(CLAUDE.md の表)。
///
/// ■ ドロップ(段階4b)
/// 成分(フォルダ・ボリューム)の上へ落とすと、そのフォルダへ移動・コピーする(Finder のパスバーと同じ)。
/// 「コンピュータ」の上は断る。`NSPathControl`の delegate のドロップは**コントロール全体**に対するもの
/// (編集できるパスバーの「パスを差し替える」)なので使わず、`FileBrowserPathControl`が自分で受ける。
struct FileBrowserPathBar: NSViewRepresentable {
    /// 表示しているフォルダ。nil はコンピュータ。
    let folder: URL?
    let computerTitle: String
    let actions: FileBrowserActions
    /// 成分をクリックした(nil はコンピュータ)。
    let onNavigate: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPathControl {
        let control = FileBrowserPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.focusRingType = .none
        control.backgroundColor = .clear
        control.font = .systemFont(ofSize: 12)
        control.target = context.coordinator
        control.action = #selector(Coordinator.handleClick(_:))
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.onNavigate = onNavigate
        context.coordinator.apply(folder: folder, computerTitle: computerTitle, to: control)
        control.registerForDraggedTypes([.fileURL])
        control.dropCoordinator = context.coordinator
        context.coordinator.actions = actions
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.onNavigate = onNavigate
        context.coordinator.actions = actions
        context.coordinator.apply(folder: folder, computerTitle: computerTitle, to: control)
    }

    static func dismantleNSView(_ control: NSPathControl, coordinator: Coordinator) {
        control.target = nil
        control.action = nil
        control.unregisterDraggedTypes()
        (control as? FileBrowserPathControl)?.dropCoordinator = nil
        coordinator.onNavigate = nil
        coordinator.actions = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var onNavigate: ((URL?) -> Void)?
        weak var actions: FileBrowserActions?
        private var destinations: [URL?] = []
        private var appliedKey: String?

        func apply(folder: URL?, computerTitle: String, to control: NSPathControl) {
            let key = (folder?.path ?? "") + "\u{0}" + computerTitle
            guard key != appliedKey else { return }
            appliedKey = key
            let components = Self.components(of: folder)
            destinations = [nil] + components.map(\.url)
            var items: [NSPathControlItem] = []
            let computer = NSPathControlItem()
            computer.title = computerTitle
            computer.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            items.append(computer)
            for (index, component) in components.enumerated() {
                let item = NSPathControlItem()
                item.title = component.title
                item.image = index == 0 ? FileBrowserIconProvider.volumeIcon : FileBrowserIconProvider.folderIcon
                items.append(item)
            }
            control.pathItems = items
        }

        @objc func handleClick(_ sender: NSPathControl) {
            guard let clicked = sender.clickedPathItem,
                  let index = sender.pathItems.firstIndex(where: { $0 === clicked }),
                  destinations.indices.contains(index)
            else { return }
            onNavigate?(destinations[index])
        }

        /// `index` 番目の成分へのドロップの判定(コンピュータの成分は nil へ落とす = 断る)。
        func dropDecision(for info: NSDraggingInfo, at index: Int) -> (FileBrowserDropDecision, [URL]) {
            guard let actions else { return (.refuse, []) }
            let destination = destinations.indices.contains(index) ? destinations[index] : nil
            return actions.dropDecision(for: info, into: destination)
        }

        func performDrop(_ decision: FileBrowserDropDecision, urls: [URL]) {
            actions?.performDrop(decision, urls: urls)
        }

        /// ボリュームの入口から今のフォルダまでの成分。起動ボリューム上なら`/`から、
        /// `/Volumes/<名前>/…`ならそのボリュームから始める(Finderのパスバーと同じ)。
        static func components(of folder: URL?) -> [(url: URL, title: String)] {
            guard let folder else { return [] }
            let path = MountTable.normalized(folder.path)
            let rootPath = MountTable.volumeRoot(of: path) ?? "/"
            let mountTable = MountTable.current()
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            var rootTitle = rootPath == "/" ? "/" : rootURL.lastPathComponent
            // 表示名(「Macintosh HD」)はローカルのときだけ問い合わせる(ネットワークは応答しないことがある)。
            if mountTable.isLocal(rootURL),
               let name = (try? rootURL.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName {
                rootTitle = name
            }
            var result: [(URL, String)] = [(rootURL, rootTitle)]
            let rest = path == rootPath ? "" : String(path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
            var current = rootURL
            for name in rest.split(separator: "/") where !name.isEmpty {
                current = current.appendingPathComponent(String(name), isDirectory: true)
                result.append((current, String(name)))
            }
            return result
        }
    }
}

/// 成分ごとにドロップを受けるパスバー(`FileBrowserPathBar`の型コメント)。受け口になっている成分を
/// アクセント色の枠で囲む(帯は不透明な地なので、枠に輪郭は要らない)。
final class FileBrowserPathControl: NSPathControl {
    weak var dropCoordinator: FileBrowserPathBar.Coordinator?
    /// いま受け口として囲んでいる成分の番号。
    private var targetIndex: Int? {
        didSet { if targetIndex != oldValue { needsDisplay = true } }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        targetIndex = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { targetIndex = nil }
        guard let dropCoordinator, let index = componentIndex(at: sender.draggingLocation) else { return false }
        let (decision, urls) = dropCoordinator.dropDecision(for: sender, at: index)
        dropCoordinator.performDrop(decision, urls: urls)
        return decision.isAccepted
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let targetIndex, let pathCell = cell as? NSPathCell,
              pathCell.pathComponentCells.indices.contains(targetIndex)
        else { return }
        let rect = pathCell.rect(of: pathCell.pathComponentCells[targetIndex], withFrame: bounds, in: self)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func updateTarget(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropCoordinator, let index = componentIndex(at: sender.draggingLocation) else {
            targetIndex = nil
            return []
        }
        let (decision, _) = dropCoordinator.dropDecision(for: sender, at: index)
        targetIndex = decision.isAccepted ? index : nil
        return decision.dragOperation(sourceMask: sender.draggingSourceOperationMask)
    }

    /// ウインドウ座標の点の下にある成分の番号(`pathItems`と同じ並び)。
    private func componentIndex(at windowPoint: NSPoint) -> Int? {
        guard let pathCell = cell as? NSPathCell else { return nil }
        let point = convert(windowPoint, from: nil)
        guard let component = pathCell.pathComponentCell(at: point, withFrame: bounds, in: self) else { return nil }
        return pathCell.pathComponentCells.firstIndex { $0 === component }
    }
}
