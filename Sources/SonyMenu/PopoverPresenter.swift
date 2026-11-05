import AppKit

/// An arrowless panel placed from a snapshot of the clicked status item.
/// Later menu bar/screen changes must not move an already-open panel.
@MainActor
final class PopoverPresenter {
    let popover: NSPopover // Retains the shared content and appearance configuration.
    private(set) var panelWindow: NSPanel?
    private(set) var anchorRect: NSRect?
    private var sizeObservation: NSKeyValueObservation?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    var isShown: Bool { panelWindow?.isVisible == true }

    init(popover: NSPopover) { self.popover = popover }

    static func settingsHeight(on screen: NSScreen?) -> CGFloat {
        min(500, max(280, (screen?.visibleFrame.height ?? 900) - 200))
    }

    @discardableResult
    func show(relativeTo source: NSView) -> Bool {
        guard !isShown else { return true }
        guard let sourceWindow = source.window, let controller = popover.contentViewController else { return false }
        let rect = sourceWindow.convertToScreen(source.convert(source.bounds, to: nil))
        let screen = sourceWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? rect.insetBy(dx: -500, dy: -800)
        let panel = HeadphonePanelWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = popover.appearance
        panel.onDismiss = { [weak self] in self?.close() }
        let view = controller.view
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        panel.contentViewController = controller
        panelWindow = panel
        anchorRect = rect
        let size = preferredSize(controller)
        let x = min(max(rect.midX - size.width / 2, visible.minX + 6), visible.maxX - size.width - 6)
        panel.setFrame(NSRect(x: x, y: min(rect.minY - 6, visible.maxY - 6) - size.height, width: size.width, height: size.height), display: false)
        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.resizeContent() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                // The status button handles its own toggle, avoiding close/reopen.
                if let self, event.window !== self.panelWindow, event.window !== sourceWindow,
                   (event.window?.level.rawValue ?? 0) < NSWindow.Level.popUpMenu.rawValue { self.close() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        panel.makeKeyAndOrderFront(nil)
        return isShown
    }

    private func preferredSize(_ controller: NSViewController) -> NSSize {
        let preferred = controller.preferredContentSize
        return preferred.width > 0 && preferred.height > 0 ? preferred : controller.view.fittingSize
    }

    private func resizeContent() {
        guard let panel = panelWindow, let controller = panel.contentViewController else { return }
        let size = preferredSize(controller)
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func close() {
        sizeObservation = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        let previous = panelWindow
        panelWindow = nil
        anchorRect = nil
        previous?.orderOut(nil)
        previous?.contentViewController = nil
        previous?.close()
    }
}

private final class HeadphonePanelWindow: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
