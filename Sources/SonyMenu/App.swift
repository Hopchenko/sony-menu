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
        app.setActivationPolicy(CommandLine.arguments.contains("--accessibility-audit") ? .regular : .accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private lazy var presenter = PopoverPresenter(popover: popover)
    private var auditWindow: NSWindow?
    private var store: HeadphoneStore!
    private var subscriptions = Set<AnyCancellable>()
    private var initialBluetoothAuthorization: Int = 0
    private let iconController = HeadphoneIconController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        initialBluetoothAuthorization = CBManager.authorization.rawValue
        // A normal click on the installed app reuses this one instance.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: AppIdentity.displayName)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = AppIdentity.displayName
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
        if CommandLine.arguments.contains("--accessibility-audit") {
            let window = NSWindow(contentViewController: host)
            window.title = "\(AppIdentity.displayName) — Accessibility Audit"
            window.styleMask = [.titled, .closable]
            window.center()
            auditWindow = window
        } else {
            popover.contentViewController = host
        }
        popover.behavior = CommandLine.arguments.contains("--accessibility-audit") ? .applicationDefined : .transient
        popover.animates = true
        store.$appearance.removeDuplicates().sink { [weak self] mode in
            guard let self else { return }
            PanelAppearance.apply(mode, to: self.popover)
            self.auditWindow?.appearance = mode.native
            self.auditWindow?.contentView?.appearance = mode.native
        }.store(in: &subscriptions)
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.iconController.update(self.store.headphoneColor, model: self.store.model)
            self.item.button?.toolTip = "\(AppIdentity.displayName) — \(self.store.modelName)"
        }.store(in: &subscriptions)
        iconController.update(store.headphoneColor, model: store.model)
        Publishers.CombineLatest3(store.$state, store.$showBattery, store.$connection)
            .receive(on: RunLoop.main).sink { [weak self] state, show, connection in
                self?.item.button?.title = show && connection == .ready ? state.batteryPercent.map { " \($0)%" } ?? "" : ""
            }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--accessibility-audit") {
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
            let quit = NSMenuItem(title: "Quit \(AppIdentity.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp; menu.addItem(quit)
            if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
            return
        }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit \(AppIdentity.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            menu.addItem(quit)
            if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
        } else if presenter.isShown { presenter.close() }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = item.button, store != nil else { return }
        store.refresh()
        if let auditWindow {
            auditWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if !presenter.isShown, let host = popover.contentViewController as? NSHostingController<HeadphonePanel> {
            host.rootView = HeadphonePanel(store: store, settingsViewportHeight: PopoverPresenter.settingsHeight(on: button.window?.screen))
        }
        presenter.show(relativeTo: button)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { presenter.close(); store?.shutdown() }

    private func runDiagnostics() {
        if !store.bluetoothConnected && (CommandLine.arguments.contains("--verify-control") || CommandLine.arguments.contains("--verify-sleep")) {
            store.connect()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            var result: [String: Any] = ["connection": String(describing: store.connection), "bluetoothConnected": store.bluetoothConnected]
            result["speakToChat"] = store.state.xm4.speakToChatEnabled
            result["multipoint"] = store.state.xm4.multipointEnabled
            result["wearDetection"] = store.state.xm4.wearDetectionEnabled
            result["wearPowerOff"] = store.state.xm4.wearPowerOffEnabled
            result["dseeExtreme"] = store.state.dseeEnabled
            result["disconnectOnSleep"] = store.disconnectOnSleep
            result["reconnectAfterUnlock"] = store.reconnectAfterUnlock
            result["modelName"] = store.modelName
            result["artworkName"] = store.artworkName
            result["systemVolume"] = store.outputVolume
            result["displayName"] = AppIdentity.displayName
            result["bundleIdentifier"] = Bundle.main.bundleIdentifier
            result["launchAtLogin"] = store.launchAtLogin
            result["battery"] = store.state.batteryPercent
            result["noiseMode"] = store.state.noiseMode.map { String(describing: $0) }
            result["ambientLevel"] = store.state.ambientLevel
            result["volume"] = store.state.volume
            result["bluetoothAuthorization"] = CBManager.authorization.rawValue
            result["initialBluetoothAuthorization"] = initialBluetoothAuthorization
            result["microphoneDevices"] = store.microphones.devices.map { ["id": $0.id, "name": $0.name] as [String: Any] }
            result["selectedMicrophoneID"] = store.microphones.selectedID
            result["soundQualityMode"] = store.state.soundQualityMode?.title
            result["reportedHeadphoneColor"] = store.state.color?.rawValue
            result["resolvedHeadphoneColor"] = store.headphoneColor.rawValue
            result["headphoneColorChoice"] = store.colorChoice.rawValue
            result["finderIconUpdated"] = iconController.finderIconUpdated
            if CommandLine.arguments.contains("--verify-color-artwork") {
                let original = store.colorChoice
                var checks: [String: Any] = [:]
                for choice in [HeadphoneColorChoice.silver, .black] {
                    store.colorChoice = choice
                    try? await Task.sleep(for: .milliseconds(300))
                    let expected = NSImage(named: NSImage.Name(store.artworkName))
                    let actual = NSApp.applicationIconImage
                    let finder = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
                    checks[choice.rawValue] = ["resolvedColor": store.headphoneColor.rawValue,
                                               "applicationIconMatches": HeadphoneArtwork.matches(actual, expected),
                                               "finderIconMatches": HeadphoneArtwork.matches(finder, expected),
                                               "finderIconUpdated": iconController.finderIconUpdated]
                    captureArtwork(NSApp.applicationIconImage, path: "/private/tmp/sony-menu-app-icon-\(choice.rawValue).png")
                    captureArtwork(finder, path: "/private/tmp/sony-menu-finder-icon-\(choice.rawValue).png")
                }
                store.colorChoice = original
                result["colorIconChecks"] = checks
                result["colorChoiceRestored"] = store.colorChoice == original
                result["bluetoothAuthorizationAfterIconChanges"] = CBManager.authorization.rawValue
            }
            if CommandLine.arguments.contains("--verify-sound-quality"), store.ready, let original = store.state.soundQualityMode {
                let alternate: SonyV1SoundQualityMode = original == .prioritizeSoundQuality ? .prioritizeStableConnection : .prioritizeSoundQuality
                store.setSoundQualityMode(alternate)
                try? await Task.sleep(for: .seconds(3))
                if !store.ready { store.connect(); try? await Task.sleep(for: .seconds(7)) }
                result["soundQualityChangeConfirmed"] = store.ready && store.state.soundQualityMode == alternate
                result["codecAfterSoundQualityChange"] = store.state.codecName
                store.setSoundQualityMode(original)
                try? await Task.sleep(for: .seconds(3))
                if !store.ready { store.connect(); try? await Task.sleep(for: .seconds(7)) }
                result["originalSoundQualityRestored"] = store.ready && store.state.soundQualityMode == original
                result["soundQualityAfterRestore"] = store.state.soundQualityMode?.title
            }
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
                if let original = HeadphoneVolume.read(target: store.selectedDeviceID), original > 0 {
                    let count = store.volumeEventCount
                    let target = max(0, original - 0.03)
                    // Bypass the store, just as a system/AVRCP change does.
                    let wrote = HeadphoneVolume.write(target, target: store.selectedDeviceID)
                    try? await Task.sleep(for: .milliseconds(250))
                    result["externalVolumeWriteSucceeded"] = wrote
                    result["coreAudioVolumeEventReceived"] = store.volumeEventCount > count
                    result["externalVolumeSyncedToPanel"] = store.outputVolume.map { abs($0 - target) < 0.02 } ?? false
                    store.setVolume(original)
                    try? await Task.sleep(for: .milliseconds(250))
                    result["panelWriteSyncedToMac"] = HeadphoneVolume.read(target: store.selectedDeviceID).map { abs($0 - original) < 0.02 } ?? false
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
                let originalVolume = HeadphoneVolume.read(target: store.selectedDeviceID)
                if let originalVolume, originalVolume > 0 {
                    let targetVolume = max(0, originalVolume - 0.03)
                    store.setVolume(targetVolume)
                    try? await Task.sleep(for: .seconds(1))
                    store.client.refresh()
                    try? await Task.sleep(for: .seconds(1))
                    result["volumeChangeConfirmed"] = HeadphoneVolume.read(target: store.selectedDeviceID).map { abs($0 - targetVolume) < 0.02 } ?? false
                    store.setVolume(originalVolume)
                    try? await Task.sleep(for: .seconds(1))
                    store.client.refresh()
                    try? await Task.sleep(for: .seconds(1))
                    result["originalVolumeRestored"] = HeadphoneVolume.read(target: store.selectedDeviceID).map { abs($0 - originalVolume) < 0.02 } ?? false
                }
            }
            if CommandLine.arguments.contains("--verify-ambient"), store.ready, let original = store.state.noiseMode {
                let level = store.state.ambientLevel
                let voice = store.state.focusOnVoice
                store.client.setAmbient(level: 7, focusOnVoice: true)
                try? await Task.sleep(for: .seconds(2))
                result["ambientLevelAndVoiceConfirmed"] = store.state.noiseMode == .ambient && store.state.ambientLevel == 7 && store.state.focusOnVoice
                store.client.setAmbient(level: 20, focusOnVoice: false)
                try? await Task.sleep(for: .seconds(2))
                result["ambientMaximumConfirmed"] = store.state.noiseMode == .ambient && store.state.ambientLevel == 20 && !store.state.focusOnVoice
                if original == .ambient { store.client.setAmbient(level: level, focusOnVoice: voice) }
                else { store.setMode(original) }
                try? await Task.sleep(for: .seconds(2))
                result["originalNoiseStateRestoredAfterAmbient"] = store.state.noiseMode == original && (original != .ambient || (store.state.ambientLevel == level && store.state.focusOnVoice == voice))
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

    private func captureArtwork(_ image: NSImage?, path: String) {
        guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private func capturePanel(settings: Bool, path: String, appearance: AppAppearance = .light) {
        let previousAppearance = store.appearance
        let previousSettings = store.settingsShown
        defer { store.appearance = previousAppearance; store.settingsShown = previousSettings }
        store.appearance = appearance
        store.settingsShown = settings
        let host = NSHostingView(rootView: HeadphonePanel(store: store))
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
