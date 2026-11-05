import SwiftUI
import AppKit

struct HeadphonePanel: View {
    @ObservedObject var store: HeadphoneStore
    @State private var volume = 0.0
    @State private var ambient = 10.0
    @State private var editingVolume = false
    @State private var editingAmbient = false

    private let panelColor = Color(nsColor: .windowBackgroundColor)
    private let cardColor = Color.primary.opacity(0.035)

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.settingsShown { settings }
            else { controls }
            if let notice = store.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(panelColor)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { syncSliders() }
        .onChange(of: store.outputVolume) { if !editingVolume { volume = store.outputVolume ?? 0 } }
        .onChange(of: store.state.ambientLevel) { if !editingAmbient { ambient = Double(store.state.ambientLevel) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let image = NSImage(named: "Headphones") {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 72, height: 88)
                    .accessibilityLabel("Sony WH-1000XM3 headphones")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("WH-1000XM3").font(.system(size: 15, weight: .semibold))
                Text(store.connectionLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                if let codec = store.state.codecName, store.ready {
                    Text(codec).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let battery = store.state.batteryPercent, store.bluetoothConnected {
                HStack(spacing: 4) {
                    Image(systemName: battery > 80 ? "battery.100percent" : battery > 30 ? "battery.50percent" : "battery.25percent")
                    Text("\(battery)%").monospacedDigit()
                }.font(.system(size: 12))
            }
        }.padding(.bottom, 14)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Noise control").font(.system(size: 13, weight: .medium))
                HStack(spacing: 5) {
                    modeButton(.noiseCancellation, label: "Noise Cancelling", symbol: "waveform")
                    modeButton(.ambient, label: "Ambient Sound", symbol: "wind")
                    modeButton(.off, label: "Off", symbol: "circle.slash")
                }.disabled(!store.ready || store.state.noiseMode == nil)
                Text(noiseDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                if store.state.noiseMode == .ambient {
                    Divider()
                    HStack { Text("Ambient sound level"); Spacer(); Text("\(Int(ambient))").monospacedDigit() }
                        .font(.system(size: 12))
                    Slider(value: $ambient, in: 1...20, step: 1, onEditingChanged: { editing in
                        editingAmbient = editing
                        if !editing { store.setAmbient(level: Int(ambient)) }
                    }).accessibilityLabel("Ambient sound level").disabled(!store.ready)
                    Toggle("Focus on voice", isOn: Binding(get: { store.state.focusOnVoice }, set: { store.setAmbient(voice: $0) }))
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12)).disabled(!store.ready)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(13).background(cardColor, in: RoundedRectangle(cornerRadius: 13))

            VStack(spacing: 10) {
                HStack {
                    Text("Volume").fontWeight(.medium)
                    Spacer()
                    Text(store.outputVolume == nil ? "—" : "\(Int((volume * 100).rounded()))%")
                        .monospacedDigit()
                }.font(.system(size: 13))
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.1").font(.system(size: 13))
                    Slider(value: Binding(get: { volume }, set: { value in
                        volume = value
                        store.setVolume(value)
                    }), in: 0...1, onEditingChanged: { editing in
                        editingVolume = editing
                        if !editing { volume = store.outputVolume ?? volume }
                    }).accessibilityLabel("Headphone volume").disabled(!store.bluetoothConnected || store.outputVolume == nil)
                    Image(systemName: "speaker.wave.3").font(.system(size: 13))
                }
            }.padding(13).background(cardColor, in: RoundedRectangle(cornerRadius: 13))

            if !store.ready {
                Button(store.connection == .connecting ? "Connecting…" : "Connect headphones") { store.connect() }
                    .buttonStyle(.borderedProminent).disabled(store.connection == .connecting)
                    .padding(.vertical, 4)
            }
        }.padding(.bottom, 10)
    }

    private var noiseDescription: String {
        guard store.ready else { return "Connect your headphones to use these controls." }
        switch store.state.noiseMode {
        case .noiseCancellation: return "Reduce the noise around you."
        case .ambient: return "Let the outside world in."
        case .off: return "Noise control is turned off."
        case .windReduction: return "Wind noise reduction is on."
        case nil: return "Reading the current noise mode…"
        }
    }

    private func modeButton(_ mode: SonyV1NoiseMode, label: String, symbol: String) -> some View {
        let selected = store.state.noiseMode == mode
        return Button { store.setMode(mode) } label: {
            VStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 21, weight: .regular)).frame(height: 25)
                Text(label).font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity).frame(height: 74)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.system(size: 15, weight: .semibold))
            sectionLabel("CONNECTION")
            VStack(spacing: 0) {
                settingToggle("Disconnect when Mac sleeps", detail: "Release WH-1000XM3 when this Mac goes to sleep.", binding: $store.disconnectOnSleep)
                Divider()
                settingToggle("Reconnect after unlock", detail: "Only if disconnected by Sony Menu.", binding: $store.reconnectAfterUnlock)
                    .disabled(!store.disconnectOnSleep)
            }.padding(.horizontal, 13).background(cardColor, in: RoundedRectangle(cornerRadius: 13))
            Text(sleepSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
            sectionLabel("GENERAL").padding(.top, 3)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Appearance").font(.system(size: 12))
                    Picker("Appearance", selection: $store.appearance) {
                        ForEach(AppAppearance.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Text("Device follows your Mac’s appearance.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                settingToggle("Open at login", binding: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Divider()
                settingToggle("Show battery in menu bar", binding: $store.showBattery)
            }.padding(.horizontal, 13).background(cardColor, in: RoundedRectangle(cornerRadius: 13))
            Text("Sony Menu 1.0 · Unofficial Sony controller").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.vertical, 4)
        }.padding(.bottom, 12)
    }

    private var sleepSummary: String {
        if !store.disconnectOnSleep { return "Sony Menu will leave the connection unchanged on sleep." }
        return store.reconnectAfterUnlock
            ? "Disconnect on sleep. Reconnect after you unlock your Mac."
            : "Disconnect on sleep. Reconnect manually when you return."
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 3)
    }

    private func settingToggle(_ title: String, detail: String? = nil, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.mini)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            if store.settingsShown { Divider() }
            HStack {
                Button { store.settingsShown.toggle() } label: {
                    Label(store.settingsShown ? "Back to controls" : "Settings", systemImage: store.settingsShown ? "chevron.left" : "slider.horizontal.3")
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    if store.bluetoothConnected { Button("Disconnect headphones") { store.disconnect() } }
                    else { Button("Connect headphones") { store.connect() } }
                    Button("Refresh") { store.refresh() }
                    Divider()
                    Button("Quit Sony Menu") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("More options")
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func syncSliders() {
        volume = store.outputVolume ?? 0
        ambient = Double(store.state.ambientLevel)
    }
}
