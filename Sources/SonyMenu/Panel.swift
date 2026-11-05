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
            if !store.settingsShown { noticeView }
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

    @ViewBuilder private var noticeView: some View {
        if let notice = store.notice {
            Text(notice).font(.system(size: 12)).foregroundStyle(secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let image = NSImage(named: NSImage.Name(store.headphoneColor.imageName)) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 72, height: 88)
                    .accessibilityLabel("\(store.headphoneColor.title) Sony WH-1000XM3 headphones")
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
        }.padding(.bottom, 16)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Noise control").font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) {
                    modeButton(.noiseCancellation, label: "Noise\nCancelling", symbol: "waveform")
                    modeButton(.ambient, label: "Ambient\nSound", symbol: "wind")
                    modeButton(.off, label: "Off", symbol: "circle.slash")
                }.disabled(!store.ready || store.state.noiseMode == nil)
                Text(noiseDescription).font(.system(size: 12)).foregroundStyle(secondaryColor)
                if store.state.noiseMode == .ambient {
                    Divider()
                    HStack { Text("Ambient sound level"); Spacer(); Text("\(Int(ambient))").monospacedDigit() }
                        .font(.system(size: 13))
                    Slider(value: Binding(get: { ambient }, set: {
                        ambient = $0
                        store.setAmbient(level: Int($0))
                    }), in: 1...20, step: 1, onEditingChanged: { editing in
                        editingAmbient = editing
                    }).accessibilityLabel("Ambient sound level").accessibilityValue("\(Int(ambient)) of 20").disabled(!store.ready)
                    Toggle(isOn: Binding(get: { store.state.focusOnVoice }, set: { store.setAmbient(voice: $0) })) {
                        Text("Focus on voice").frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).controlSize(.small).font(.system(size: 13)).disabled(!store.ready)
                }
            }.padding(14).background(cardColor, in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 12) {
                HStack {
                    Text("Volume").fontWeight(.medium)
                    Spacer()
                    Text(store.outputVolume == nil ? "—" : "\(Int((volume * 100).rounded()))%")
                        .monospacedDigit()
                }.font(.system(size: 13))
                HStack(spacing: 8) {
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
            }.padding(14).background(cardColor, in: RoundedRectangle(cornerRadius: 12))


            if !store.ready {
                Button(store.connection == .connecting ? "Connecting…" : "Connect headphones") { store.connect() }
                    .buttonStyle(.borderedProminent).disabled(store.connection == .connecting)
                    .padding(.vertical, 4)
            }
        }
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
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 21)).frame(height: 24)
                    .accessibilityHidden(true)
                Text(label).font(.system(size: 12, weight: selected ? .medium : .regular))
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(maxWidth: .infinity).frame(height: 32, alignment: .top)
            }
            .padding(.horizontal, 8).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color(nsColor: palette.text))
            .background(selected ? Color(nsColor: palette.selected) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                        .padding(5).accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .accessibilityLabel(label.replacingOccurrences(of: "\n", with: " "))
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var soundQualitySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sound quality mode", systemImage: "hifispeaker")
                .font(.system(size: 13, weight: .medium))
            NativeMenuPicker(selection: Binding<SonyV1SoundQualityMode?>(get: { store.state.soundQualityMode }, set: { mode in
                if let mode { store.setSoundQualityMode(mode) }
            }), options: qualityOptions, label: "Sound quality mode", enabled: store.ready && store.state.soundQualityMode != nil)
                .accessibilityValue(store.state.soundQualityMode?.title ?? "Not available")
            Text("Changing this mode may interrupt audio.")
                .font(.system(size: 12)).foregroundStyle(secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(cardColor, in: RoundedRectangle(cornerRadius: 12))
    }

    private var qualityOptions: [(value: SonyV1SoundQualityMode?, title: String)] {
        let known = SonyV1SoundQualityMode.allCases.map { (value: Optional($0), title: $0.title) }
        guard store.state.soundQualityMode == nil else { return known }
        return [(nil, store.ready ? "Waiting for headphones…" : "Connect headphones")] + known
    }

    private var microphoneOptions: [(value: UInt32, title: String)] {
        let devices = store.microphones.devices.map { (value: $0.id, title: $0.name) }
        guard !store.microphones.devices.contains(where: { $0.id == store.microphones.selectedID }) else { return devices }
        return [(store.microphones.selectedID, "No microphone selected")] + devices
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Microphone", systemImage: "mic").font(.system(size: 13, weight: .medium))
            NativeMenuPicker(selection: Binding(get: { store.microphones.selectedID }, set: { store.selectMicrophone($0) }),
                             options: microphoneOptions, label: "Mac microphone", enabled: !store.microphones.devices.isEmpty)
                .accessibilityValue(microphoneOptions.first(where: { $0.value == store.microphones.selectedID })?.title ?? "No microphone selected")
            Text("Changes Mac input. Meet can use its own selection.")
                .font(.system(size: 12)).foregroundStyle(secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if store.microphones.devices.first(where: { $0.id == store.microphones.selectedID })?.name == "WH-1000XM3" {
                Text("The headphone mic may enable call sidetone.")
                    .font(.system(size: 12)).foregroundStyle(secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(cardColor, in: RoundedRectangle(cornerRadius: 12))
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                noticeView
                appearanceSetting
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Audio", symbol: "waveform")
                    VStack(spacing: 12) {
                        soundQualitySettings
                        microphoneSettings
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Connection", symbol: "bolt.horizontal.circle")
                    VStack(spacing: 0) {
                        settingToggle("Disconnect when Mac sleeps", detail: "Release WH-1000XM3 when this Mac goes to sleep.", binding: $store.disconnectOnSleep)
                        Divider()
                        settingToggle("Reconnect after unlock", detail: "Only if this app disconnected them.", binding: $store.reconnectAfterUnlock)
                            .disabled(!store.disconnectOnSleep)
                    }.padding(.horizontal, 14).background(cardColor, in: RoundedRectangle(cornerRadius: 12))
                    Text(sleepSummary).font(.system(size: 12)).foregroundStyle(secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("General", symbol: "gearshape")
                    VStack(spacing: 0) {
                        settingToggle("Open at login", binding: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                        Divider()
                        settingToggle("Show battery in menu bar", binding: $store.showBattery)
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Headphone color", systemImage: "paintpalette").font(.system(size: 13, weight: .medium))
                            HStack(spacing: 8) {
                                ForEach(HeadphoneColorChoice.allCases) { choice in colorTile(choice) }
                            }
                            Text(store.headphoneColorDetail).font(.system(size: 12)).foregroundStyle(secondaryColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 12)
                    }.padding(.horizontal, 14).background(cardColor, in: RoundedRectangle(cornerRadius: 12))
                }
                Text("\(AppIdentity.displayName) · Unofficial").font(.system(size: 12)).foregroundStyle(secondaryColor)
            }.padding(.bottom, 12).padding(.trailing, 14)
        }.labelStyle(SettingsLabelStyle()).scrollIndicators(.visible)
            // Let the scroll rail occupy the outer margin while the content
            // keeps the same 16 pt edges as the main panel and header.
            .frame(height: settingsViewportHeight).padding(.trailing, -14)
    }

    private func colorTile(_ choice: HeadphoneColorChoice) -> some View {
        let selected = store.colorChoice == choice
        let color = choice.resolve(reported: store.state.color, remembered: store.lastDetectedColor)
        let title = choice == .automatic ? "Auto" : choice == .black ? "Black" : "Silver"
        return Button { store.colorChoice = choice } label: {
            VStack(spacing: 8) {
                if let image = NSImage(named: NSImage.Name(color.imageName)) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 58).accessibilityHidden(true)
                }
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
            }.padding(.horizontal, 8).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(selected ? Color(nsColor: palette.selected) : panelColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).padding(5).accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if choice == .automatic {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)).padding(6).accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).help(choice.title)
            .accessibilityLabel(choice.title).accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var appearanceSetting: some View {
        HStack {
            Label("Appearance", systemImage: "desktopcomputer").font(.system(size: 13))
            Spacer(minLength: 8)
            AppearancePicker(selection: $store.appearance).frame(width: 148, height: 28)
        }.padding(.horizontal, 14).padding(.vertical, 8)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 12))
    }

    private var sleepSummary: String {
        if !store.disconnectOnSleep { return "The connection stays unchanged on sleep." }
        return store.reconnectAfterUnlock
            ? "Disconnect on sleep. Reconnect after you unlock your Mac."
            : "Disconnect on sleep. Reconnect manually when you return."
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(secondaryColor).accessibilityAddTraits(.isHeader)
    }

    private func settingToggle(_ title: String, detail: String? = nil, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(secondaryColor).fixedSize(horizontal: false, vertical: true) }
            }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityHint(detail ?? "")
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            HStack {
                Button { store.settingsShown.toggle() } label: {
                    Label(store.settingsShown ? "Back to controls" : "Settings", systemImage: store.settingsShown ? "chevron.left" : "slider.horizontal.3")
                }.buttonStyle(.plain).padding(.vertical, 6)
                Spacer()
                Menu {
                    if store.bluetoothConnected { Button("Disconnect headphones") { store.disconnect() } }
                    else { Button("Connect headphones") { store.connect() } }
                    Button("Refresh") { store.refresh() }
                    Divider()
                    Button("Quit \(AppIdentity.displayName)") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28).accessibilityLabel("More options").help("More options")
            }.font(.system(size: 12)).foregroundStyle(secondaryColor)
        }.frame(maxWidth: .infinity).padding(.top, 12)
    }

    private func syncSliders() {
        volume = store.outputVolume ?? 0
        ambient = Double(store.state.ambientLevel)
    }
}

private struct SettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 16, height: 16).accessibilityHidden(true)
            configuration.title
        }
    }
}
