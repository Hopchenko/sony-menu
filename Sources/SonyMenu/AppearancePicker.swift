import AppKit
import SwiftUI

/// Native radio-style segments retain keyboard navigation, focus rings and
/// VoiceOver selection semantics even when their visible labels are icons.
struct AppearancePicker: NSViewRepresentable {
    @Binding var selection: AppAppearance

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        Self.makeControl(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = AppAppearance.allCases.firstIndex(of: selection) ?? 0
    }
    static func makeControl(target: AnyObject? = nil, action: Selector? = nil) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Auto", "", ""], trackingMode: .selectOne, target: target, action: action)
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.setAccessibilityLabel("Appearance")
        for (index, entry) in [("desktopcomputer", "Auto: follow Mac appearance"), ("sun.max", "Light appearance"), ("moon", "Dark appearance")].enumerated() {
            control.setImage(NSImage(systemSymbolName: entry.0, accessibilityDescription: entry.1), forSegment: index)
            control.setToolTip(entry.1, forSegment: index)
            control.setWidth(index == 0 ? 62 : 32, forSegment: index)
        }
        return control
    }
    final class Coordinator: NSObject {
        var selection: Binding<AppAppearance>
        init(selection: Binding<AppAppearance>) { self.selection = selection }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard AppAppearance.allCases.indices.contains(sender.selectedSegment) else { return }
            sender.window?.makeFirstResponder(sender)
            selection.wrappedValue = AppAppearance.allCases[sender.selectedSegment]
        }
    }
}
