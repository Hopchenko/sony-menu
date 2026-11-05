import AppKit

/// A status item's window can move when macOS changes the active menu bar.
/// Snapshot its screen coordinates at opening instead of following that window.
@MainActor
final class PopoverPresenter: NSObject, NSPopoverDelegate {
    let popover: NSPopover
    private(set) var anchorWindow: NSPanel?

    init(popover: NSPopover) {
        self.popover = popover
        super.init()
        popover.delegate = self
    }

    static func settingsHeight(on screen: NSScreen?) -> CGFloat {
        min(500, max(280, (screen?.visibleFrame.height ?? 900) - 200))
    }

    @discardableResult
    func show(relativeTo source: NSView) -> Bool {
        // Reopening the app must not relocate an already-open panel.
        guard !popover.isShown else { return true }
        guard let sourceWindow = source.window else { return false }
        let rect = sourceWindow.convertToScreen(source.convert(source.bounds, to: nil))
        let anchor = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.ignoresMouseEvents = true
        anchor.hidesOnDeactivate = false
        anchor.level = .statusBar
        anchor.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        anchor.contentView = view
        anchorWindow = anchor
        anchor.orderFrontRegardless()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        if !popover.isShown { releaseAnchor() }
        return popover.isShown
    }

    func close() {
        popover.close()
        releaseAnchor()
    }

    func popoverDidClose(_ notification: Notification) { releaseAnchor() }

    private func releaseAnchor() {
        let previous = anchorWindow
        anchorWindow = nil
        previous?.orderOut(nil)
        previous?.close()
    }
}
