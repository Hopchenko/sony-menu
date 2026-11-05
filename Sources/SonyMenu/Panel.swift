import SwiftUI
import AppKit

struct HeadphonePanel: View {
    @ObservedObject var store: HeadphoneStore
    var settingsViewportHeight: CGFloat = 500
    @State private var volume = 0.0
    @State private var ambient = 10.0
    @State private var editingVolume = false
    @State private var editingAmbient = false

    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { store.appearance == .device ? systemScheme : store.appearance == .dark ? .dark : .light }
    private var palette: PanelPalette { PanelPalette(dark: scheme == .dark) }
    private var panelColor: Color { Color(nsColor: palette.background) }
    private var cardColor: Color { Color(nsColor: palette.card) }
    private var secondaryColor: Color { Color(nsColor: palette.secondary) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.settingsShown { settings }
            else { controls }
            if let notice = store.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            footer
        }
        .padding(16)
        .frame(width: 360)
        .background(panelColor)
        .foregroundStyle(Color(nsColor: palette.text))
        .environment(\.colorScheme, scheme)
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
                Text(store.connectionLabel).font(.system(size: 12)).foregroundStyle(secondaryColor)
                if let codec = store.state.codecName, store.ready {
                    Text("Codec: \(codec)").font(.system(size: 12)).foregroundStyle(secondaryColor)
                }
            }
            Spacer(minLength: 0)
            if let battery = store.state.batteryPercent, store.bluetoothConnected {
                HStack(spacing: 4) {
                    Image(systemName: battery > 80 ? "battery.100percent" : battery > 30 ? "battery.50percent" : "battery.25percent")
                    Text("\(battery)%").monospacedDigit()
                }.font(.system(size: 12))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Headphone battery")
                .accessibilityValue("\(battery) percent")
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
                Text(noiseDescription).font(.system(size: 12)).foregroundStyle(secondaryColor)
                if store.state.noiseMode == .ambient {
                    Divider()
                    HStack { Text("Ambient sound level"); Spacer(); Text("\(Int(ambient))").monospacedDigit() }
                        .font(.system(size: 12))
                    Slider(value: Binding(get: { ambient }, set: {
                        ambient = $0
                        store.setAmbient(level: Int($0))
                    }), in: 1...20, step: 1, onEditingChanged: { editing in
                        editingAmbient = editing
                    }).accessibilityLabel("Ambient sound level").accessibilityValue("\(Int(ambient)) of 20").disabled(!store.ready)
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
                    Image(systemName: "speaker.wave.1").font(.system(size: 13)).accessibilityHidden(true)
                    Slider(value: Binding(get: { volume }, set: { value in
                        volume = value
                        store.setVolume(value)
                    }), in: 0...1, onEditingChanged: { editing in
                        editingVolume = editing
                        if !editing { volume = store.outputVolume ?? volume }
                    }).accessibilityLabel("Headphone volume").accessibilityValue("\(Int((volume * 100).rounded())) percent").disabled(!store.bluetoothConnected || store.outputVolume == nil)
                    Image(systemName: "speaker.wave.3").font(.system(size: 13)).accessibilityHidden(true)
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
            VStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : symbol).font(.system(size: 21, weight: .regular)).frame(height: 25)
                Text(label).font(.system(size: 12)).multilineTextAlignment(.center).lineLimit(2).frame(height: 30)
            }
            .frame(maxWidth: .infinity).frame(height: 74)
            .foregroundStyle(Color(nsColor: palette.text))
            .background(selected ? Color(nsColor: palette.selected) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(selected ? "Selected" : "Not selected").accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
                Text("Microphone").font(.system(size: 13, weight: .medium))
                Picker("Mac microphone", selection: Binding(get: { store.microphones.selectedID }, set: { store.selectMicrophone($0) })) {
                    if !store.microphones.devices.contains(where: { $0.id == store.microphones.selectedID }) {
                        Text("No microphone selected").tag(store.microphones.selectedID)
                    }
                    ForEach(store.microphones.devices) { device in Text(device.name).tag(device.id) }
                }.labelsHidden().disabled(store.microphones.devices.isEmpty)
                Text("Changes Mac input. Meet can use its own selection.")
                    .font(.system(size: 12)).foregroundStyle(secondaryColor)
                if store.microphones.devices.first(where: { $0.id == store.microphones.selectedID })?.name == "WH-1000XM3" {
                    Text("The headphone mic may enable call sidetone.")
                        .font(.system(size: 12)).foregroundStyle(secondaryColor)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(13).background(cardColor, in: RoundedRectangle(cornerRadius: 13))

    }

    private var settings: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            appearanceSetting
            sectionLabel("Connection", symbol: "bolt.horizontal.circle")
            VStack(spacing: 0) {
                settingToggle("Disconnect when Mac sleeps", detail: "Release WH-1000XM3 when this Mac goes to sleep.", binding: $store.disconnectOnSleep)
                Divider()
                settingToggle("Reconnect after unlock", detail: "Only if disconnected by Sony Menu.", binding: $store.reconnectAfterUnlock)
                    .disabled(!store.disconnectOnSleep)
            }.padding(.horizontal, 13).background(cardColor, in: RoundedRectangle(cornerRadius: 13))
            Text(sleepSummary).font(.system(size: 12)).foregroundStyle(secondaryColor)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
            sectionLabel("Call audio", symbol: "mic").padding(.top, 3)
            microphoneSettings
            sectionLabel("General", symbol: "gearshape").padding(.top, 3)
            VStack(spacing: 0) {
                settingToggle("Open at login", binding: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Divider()
                settingToggle("Show battery in menu bar", binding: $store.showBattery)
            }.padding(.horizontal, 13).background(cardColor, in: RoundedRectangle(cornerRadius: 13))
            Text("Sony Menu · Unofficial Sony controller").font(.system(size: 12)).foregroundStyle(secondaryColor).padding(.vertical, 4)
        }.padding(.bottom, 12).padding(.trailing, 14)
        }.scrollIndicators(.visible).frame(height: settingsViewportHeight)
    }

    private var appearanceSetting: some View {
        HStack {
            Label("Appearance", systemImage: "desktopcomputer").font(.system(size: 12))
            Spacer(minLength: 8)
            AppearancePicker(selection: $store.appearance).frame(width: 148, height: 28)
        }.padding(.horizontal, 13).padding(.vertical, 8)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 13))
    }

    private var sleepSummary: String {
        if !store.disconnectOnSleep { return "Sony Menu will leave the connection unchanged on sleep." }
        return store.reconnectAfterUnlock
            ? "Disconnect on sleep. Reconnect after you unlock your Mac."
            : "Disconnect on sleep. Reconnect manually when you return."
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(secondaryColor).padding(.horizontal, 3)
    }

    private func settingToggle(_ title: String, detail: String? = nil, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(secondaryColor).fixedSize(horizontal: false, vertical: true) }
            }.padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.mini)
            .accessibilityLabel(title)
            .accessibilityHint(detail ?? "")
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
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More options").help("More options")
            }.font(.system(size: 12)).foregroundStyle(secondaryColor)
        }
    }

    private func syncSliders() {
        volume = store.outputVolume ?? 0
        ambient = Double(store.state.ambientLevel)
    }
}
