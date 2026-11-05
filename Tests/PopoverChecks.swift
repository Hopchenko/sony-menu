import AppKit
import SwiftUI

extension TestMain {
    private static func settledFrame(of window: NSWindow) async throws -> NSRect {
        var previous = window.frame
        var stable = 0
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(20))
            let current = window.frame
            stable = current == previous ? stable + 1 : 0
            if stable == 3 { return current }
            previous = current
        }
        throw TestFailure(description: "Popover never finished its initial layout")
    }

    static func popoverTests() async {
        await test("Open panel stays put when its original status window moves") {
            let screen = NSScreen.screens[0].visibleFrame
            let sourceWindow = NSWindow(contentRect: NSRect(x: screen.midX, y: screen.midY, width: 60, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
            sourceWindow.isReleasedWhenClosed = false
            let source = NSView(frame: NSRect(x: 5, y: 3, width: 24, height: 20))
            sourceWindow.contentView!.addSubview(source)
            sourceWindow.orderFront(nil)
            let popover = NSPopover()
            popover.animates = false
            popover.behavior = .applicationDefined
            let host = NSHostingController(rootView: Text("Fixed screen anchor").frame(width: 180, height: 80))
            popover.contentViewController = host
            popover.contentSize = NSSize(width: 180, height: 80)
            let presenter = PopoverPresenter(popover: popover)
            defer { presenter.close(); sourceWindow.close() }
            let expected = sourceWindow.convertToScreen(source.convert(source.bounds, to: nil))
            try expect(presenter.show(relativeTo: source))
            try expect(presenter.anchorRect == expected)
            let panelFrame = try await settledFrame(of: host.view.window!)
            let panel = presenter.panelWindow!
            let destination = NSScreen.screens.dropFirst().first?.visibleFrame ?? screen.offsetBy(dx: -100, dy: -100)
            sourceWindow.setFrameOrigin(NSPoint(x: destination.midX, y: destination.midY))
            try await Task.sleep(for: .milliseconds(80))
            try expect(presenter.anchorRect == expected, "Anchor followed the moving status window")
            try expect(host.view.window?.frame == panelFrame, "Open panel moved: \(panelFrame) → \(String(describing: host.view.window?.frame))")
            try expect(presenter.show(relativeTo: source))
            try expect(presenter.panelWindow === panel && host.view.window?.frame == panelFrame, "Reopen relocated the existing panel")
            try expect(!panel.collectionBehavior.contains(.moveToActiveSpace) && !panel.hidesOnDeactivate && panel.styleMask.contains(.borderless))
            host.preferredContentSize = NSSize(width: 180, height: 160)
            try await wait { abs(panel.frame.height - 160) < 1 }
            try expect(abs(panel.frame.maxY - panelFrame.maxY) < 1, "Resizing moved the top edge")
            panel.cancelOperation(nil)
            try await wait { presenter.panelWindow == nil }
            try expect(!panel.isVisible)
            let nextExpected = sourceWindow.convertToScreen(source.convert(source.bounds, to: nil))
            try expect(presenter.show(relativeTo: source))
            try expect(presenter.anchorRect == nextExpected, "New opening did not use the clicked screen")
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            try expect(!presenter.isShown && presenter.panelWindow == nil, "Switching apps did not dismiss the panel")
        }
        await test("Popover anchor rejects unattached views and closes idempotently") {
            let presenter = PopoverPresenter(popover: NSPopover())
            try expect(!presenter.show(relativeTo: NSView()))
            try expect(presenter.panelWindow == nil)
            presenter.close(); presenter.close()
            try expect(presenter.panelWindow == nil)
        }
        await test("Settings viewport is captured independently of later main-screen changes") {
            let rig = TestRig(); defer { rig.close() }
            rig.store.settingsShown = true
            let host = NSHostingView(rootView: HeadphonePanel(store: rig.store, settingsViewportHeight: 320))
            let initial = host.fittingSize
            rig.store.showBattery.toggle()
            host.layoutSubtreeIfNeeded()
            try expect(abs(host.fittingSize.height - initial.height) < 1)
            try expect(initial.height < 550 && abs(initial.width - 360) < 1)
            try expect(PopoverPresenter.settingsHeight(on: nil) == 500)
        }
    }
}
