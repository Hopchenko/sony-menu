import AppKit
import SwiftUI
import Combine
import IOBluetooth
import CoreBluetooth

@main
@MainActor
enum SonyMenuMain {
    static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var store: HeadphoneStore!
    private var subscriptions = Set<AnyCancellable>()
    private var initialBluetoothAuthorization: Int = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        initialBluetoothAuthorization = CBManager.authorization.rawValue
        // A normal click on the installed app reuses this one instance.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.sonymenu.app")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Sony Menu")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Sony Menu — WH-1000XM3"
        }
        // Some macOS versions synchronously wait for CoreBluetooth callbacks
        // on the first IOBluetooth query. Keep the main run loop available.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = IOBluetoothDevice.pairedDevices()
            DispatchQueue.main.async { self?.finishLaunching() }
        }
    }

    private func finishLaunching() {
        store = HeadphoneStore()
        let host = NSHostingController(rootView: HeadphonePanel(store: store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        store.$appearance.removeDuplicates().sink { mode in
            NSApp.appearance = mode.native
        }.store(in: &subscriptions)
        Publishers.CombineLatest3(store.$state, store.$showBattery, store.$connection)
            .receive(on: RunLoop.main).sink { [weak self] state, show, connection in
                self?.item.button?.title = show && connection == .ready ? state.batteryPercent.map { " \($0)%" } ?? "" : ""
            }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showPopover() }
        }
        if CommandLine.arguments.contains("--diagnose") { runDiagnostics() }
    }

    @objc private func togglePopover() {
        if store == nil {
            let menu = NSMenu()
            let loading = NSMenuItem(title: "Initializing Bluetooth…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
            let quit = NSMenuItem(title: "Quit Sony Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp; menu.addItem(quit)
            if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
            return
        }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit Sony Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            menu.addItem(quit)
            if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
        } else if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = item.button, store != nil else { return }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }

    private func runDiagnostics() {
        if !store.bluetoothConnected && (CommandLine.arguments.contains("--verify-control") || CommandLine.arguments.contains("--verify-sleep")) {
            store.connect()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            var result: [String: Any] = ["connection": String(describing: store.connection), "bluetoothConnected": store.bluetoothConnected]
            result["battery"] = store.state.batteryPercent
            result["noiseMode"] = store.state.noiseMode.map { String(describing: $0) }
            result["ambientLevel"] = store.state.ambientLevel
            result["volume"] = store.state.volume
            result["bluetoothAuthorization"] = CBManager.authorization.rawValue
            result["initialBluetoothAuthorization"] = initialBluetoothAuthorization
            result["microphoneDevices"] = store.microphones.devices.map { ["id": $0.id, "name": $0.name] as [String: Any] }
            result["selectedMicrophoneID"] = store.microphones.selectedID
            if CommandLine.arguments.contains("--inspect-sidetone"), store.ready {
                store.client.inspectCallCapabilities()
                try? await Task.sleep(for: .seconds(11))
                result["sidetoneProbe"] = "Read-only V1 supported-function and general-setting inquiries; no setting writes"
            }
            if CommandLine.arguments.contains("--verify-microphone") {
                let original = MacMicrophone.read()
                if original.devices.contains(where: { $0.id == original.selectedID }),
                   let alternative = original.devices.first(where: { $0.id != original.selectedID }) {
                    result["microphoneChangeSucceeded"] = MacMicrophone.select(alternative.id)
                    try? await Task.sleep(for: .milliseconds(400))
                    result["externalMicrophoneChangeSynced"] = store.microphones.selectedID == alternative.id
                    store.selectMicrophone(original.selectedID)
                    try? await Task.sleep(for: .milliseconds(400))
                    result["originalMicrophoneRestored"] = MacMicrophone.read().selectedID == original.selectedID
                } else { result["microphoneCheckSkipped"] = "Two available microphones are required" }
            }
            if CommandLine.arguments.contains("--verify-idle") {
                let checks = store.connectionCheckCount
                let queries = Diagnostics.shared.entries.filter { $0.contains("outgoing:") && !$0.contains("outgoing: ACK") }.count
                try? await Task.sleep(for: .seconds(5))
                result["idleConnectionChecks"] = store.connectionCheckCount - checks
                result["idleBluetoothQueries"] = Diagnostics.shared.entries.filter { $0.contains("outgoing:") && !$0.contains("outgoing: ACK") }.count - queries
            }
            if CommandLine.arguments.contains("--verify-volume-sync") {
                if let original = HeadphoneVolume.read(), original > 0 {
                    let count = store.volumeEventCount
                    let target = max(0, original - 0.03)
                    // Bypass the store, just as a system/AVRCP change does.
                    let wrote = HeadphoneVolume.write(target)
                    try? await Task.sleep(for: .milliseconds(250))
                    result["externalVolumeWriteSucceeded"] = wrote
                    result["coreAudioVolumeEventReceived"] = store.volumeEventCount > count
                    result["externalVolumeSyncedToPanel"] = store.outputVolume.map { abs($0 - target) < 0.02 } ?? false
                    store.setVolume(original)
                    try? await Task.sleep(for: .milliseconds(250))
                    result["panelWriteSyncedToMac"] = HeadphoneVolume.read().map { abs($0 - original) < 0.02 } ?? false
                    result["originalVolumeRestored"] = store.outputVolume.map { abs($0 - original) < 0.02 } ?? false
                } else { result["volumeSyncCheckSkipped"] = "Sony output unavailable or at zero volume" }
            }
            if CommandLine.arguments.contains("--verify-control"), store.ready, let original = store.state.noiseMode {
                let level = store.state.ambientLevel
                let voice = store.state.focusOnVoice
                store.setMode(original == .off ? .noiseCancellation : .off)
                try? await Task.sleep(for: .seconds(3))
                result["controlChangeConfirmed"] = store.state.noiseMode != original
                if original == .ambient { store.client.setAmbient(level: level, focusOnVoice: voice) }
                else { store.setMode(original) }
                try? await Task.sleep(for: .seconds(3))
                result["originalModeRestored"] = store.state.noiseMode == original
                let originalVolume = HeadphoneVolume.read()
                if let originalVolume, originalVolume > 0 {
                    let targetVolume = max(0, originalVolume - 0.03)
                    store.setVolume(targetVolume)
                    try? await Task.sleep(for: .seconds(1))
                    store.client.refresh()
                    try? await Task.sleep(for: .seconds(1))
                    result["volumeChangeConfirmed"] = HeadphoneVolume.read().map { abs($0 - targetVolume) < 0.02 } ?? false
                    store.setVolume(originalVolume)
                    try? await Task.sleep(for: .seconds(1))
                    store.client.refresh()
                    try? await Task.sleep(for: .seconds(1))
                    result["originalVolumeRestored"] = HeadphoneVolume.read().map { abs($0 - originalVolume) < 0.02 } ?? false
                }
            }
            if CommandLine.arguments.contains("--verify-sleep"), store.ready {
                result["sleepHandlerDisconnectedHeadphones"] = await store.verifySleepDisconnect()
                try? await Task.sleep(for: .seconds(14))
                result["reconnectedAfterSleepTest"] = store.ready
            }
            if CommandLine.arguments.contains("--capture-preview") {
                capturePanel(settings: false, path: "/private/tmp/sony-menu-panel.png")
                capturePanel(settings: true, path: "/private/tmp/sony-menu-settings.png")
                capturePanel(settings: false, path: "/private/tmp/sony-menu-panel-dark.png", appearance: .dark)
                capturePanel(settings: true, path: "/private/tmp/sony-menu-settings-dark.png", appearance: .dark)
            }
            result["log"] = Diagnostics.shared.entries
            let destination = URL(fileURLWithPath: "/private/tmp/sony-menu-diagnostics.json")
            do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination) }
            catch { NSLog("Diagnostic export failed: %@", error.localizedDescription) }
            NSApp.terminate(nil)
        }
    }

    private func capturePanel(settings: Bool, path: String, appearance: AppAppearance = .light) {
        let previousAppearance = store.appearance
        let previousSettings = store.settingsShown
        defer { store.appearance = previousAppearance; store.settingsShown = previousSettings }
        store.appearance = appearance
        store.settingsShown = settings
        let host = NSHostingView(rootView: HeadphonePanel(store: store).environment(\.colorScheme, appearance == .dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.native
        window.contentView = host
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
