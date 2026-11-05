import AppKit
import SwiftUI

/// A full-width native popup field. SwiftUI's menu Picker keeps its intrinsic
/// title width even inside a wider frame, which makes form edges ragged.
struct NativeMenuPicker<Value: Equatable>: NSViewRepresentable {
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    var label: String
    var enabled = true

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 13)
        control.cell?.lineBreakMode = .byTruncatingMiddle
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map { $0.title }
        if control.itemTitles != titles {
            control.removeAllItems()
            control.addItems(withTitles: titles)
        }
        control.isEnabled = enabled
        control.setAccessibilityLabel(label)
        control.cell?.setAccessibilityLabel(label)
        reflectSelection(in: control)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 200, height: nsView.intrinsicContentSize.height)
    }
    private func reflectSelection(in control: NSPopUpButton) {
        if let index = options.firstIndex(where: { $0.value == selection }) {
            control.selectItem(at: index)
            control.toolTip = options[index].title
            control.setAccessibilityValue(options[index].title)
            control.cell?.setAccessibilityValue(options[index].title)
        } else {
            control.selectItem(at: -1)
            control.setAccessibilityValue(nil)
            control.cell?.setAccessibilityValue(nil)
        }
    }
    final class Coordinator: NSObject {
        var parent: NativeMenuPicker
        init(parent: NativeMenuPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            guard parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.options[sender.indexOfSelectedItem].value
            // Reflect the binding immediately: asynchronous hardware controls
            // keep showing their confirmed value until readback publishes it.
            parent.reflectSelection(in: sender)
            sender.window?.makeFirstResponder(sender)
        }
    }
}
