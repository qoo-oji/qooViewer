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
struct FileBrowserPathBar: NSViewRepresentable {
    /// 表示しているフォルダ。nil はコンピュータ。
    let folder: URL?
    let computerTitle: String
    /// 成分をクリックした(nil はコンピュータ)。
    let onNavigate: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
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
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.onNavigate = onNavigate
        context.coordinator.apply(folder: folder, computerTitle: computerTitle, to: control)
    }

    static func dismantleNSView(_ control: NSPathControl, coordinator: Coordinator) {
        control.target = nil
        control.action = nil
        coordinator.onNavigate = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var onNavigate: ((URL?) -> Void)?
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
