import SwiftUI

/// DynaKeys — the system HUD module.
///
/// Surfaces volume / brightness / keyboard-backlight changes inside the notch the way the
/// OS overlay would, but on the island:
///  - Reads + writes **output volume** via CoreAudio (`VolumeController`).
///  - Reads + writes **display brightness** via DisplayServices, with a CoreDisplay fallback
///    (`BrightnessController`).
///  - Reads + (best-effort) writes **keyboard backlight** via CoreBrightness'
///    `KeyboardBrightnessClient` (`KeyboardBacklightController`).
///  - Watches hardware media keys (`MediaKeyMonitor`) to choose which facet to peek the
///    instant a key is pressed, eliminating perceived lag.
///
/// When any value changes — whether from a media key, an external app, or our own expanded
/// sliders — the module updates the active facet, calls `requestPeek` to surface the compact
/// level bar trailing of the notch, and animates the indicator.
///
/// The expanded section exposes live sliders for volume and brightness (and keyboard backlight
/// when controllable) that write straight back to the system.
@MainActor
final class SystemHUDModule: NotchModule, ObservableObject {
    let moduleID = "systemhud"
    let displayName = "DynaKeys"
    let order = 30

    // MARK: Published UI state

    /// The facet currently driving the compact indicator.
    @Published private(set) var activeFacet: SystemHUDFacet = .volume(muted: false)
    /// Whether the compact level bar is currently being shown (drives compact layout).
    @Published private(set) var isShowingCompact: Bool = false

    @Published private(set) var volume: Float = 0
    @Published private(set) var muted: Bool = false
    @Published private(set) var brightness: Float = 0
    @Published private(set) var keyboardLevel: Float = 0

    @Published private(set) var brightnessAvailable: Bool = false
    @Published private(set) var keyboardAvailable: Bool = false

    /// Whether the user is actively dragging a slider; suppresses the self-triggered peek so
    /// dragging the expanded slider doesn't flicker the compact pill.
    @Published var isInteracting: Bool = false

    // MARK: Collaborators

    private var context: NotchContext?
    private let volumeController = VolumeController()
    private let brightnessController = BrightnessController()
    private let keyboardController = KeyboardBacklightController()
    private let mediaKeyMonitor = MediaKeyMonitor()

    /// How long each compact peek stays up.
    private let peekDuration: TimeInterval = 1.6

    /// Task that hides the compact bar after the latest peek settles.
    private var hideTask: Task<Void, Never>?

    /// Task that flips `primed` shortly after launch.
    private var primeTask: Task<Void, Never>?

    /// Suppresses peeks during the very first value emission at activation, so launching the
    /// app doesn't immediately flash the HUD for state that didn't actually change.
    private var primed = false

    /// Brightness changes surface the HUD only if they follow a brightness-key press within
    /// this window; ambient auto-brightness (no key press) updates the slider silently.
    private var brightnessKeyUntil: Date = .distantPast
    private let brightnessKeyWindow: TimeInterval = 2.0

    // MARK: Lifecycle

    func activate(_ context: NotchContext) {
        self.context = context

        volumeController.onChange = { [weak self] vol, muted in
            self?.handleVolume(vol, muted: muted)
        }
        brightnessController.onChange = { [weak self] value in
            self?.handleBrightness(value)
        }
        keyboardController.onChange = { [weak self] value in
            self?.handleKeyboard(value)
        }
        mediaKeyMonitor.onKeyDown = { [weak self] facet in
            self?.handleMediaKey(facet)
        }

        brightnessAvailable = brightnessController.isAvailable
        keyboardAvailable = keyboardController.isAvailable

        volumeController.start()
        brightnessController.start()
        keyboardController.start()
        mediaKeyMonitor.start()

        // Mark primed shortly after launch so the initial state reads don't peek.
        primeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.primed = true
        }
    }

    func deactivate() {
        volumeController.stop()
        brightnessController.stop()
        keyboardController.stop()
        mediaKeyMonitor.stop()
        hideTask?.cancel()
        hideTask = nil
        primeTask?.cancel()
        primeTask = nil
        context = nil
    }

    // MARK: Value handlers (main actor)

    private func handleVolume(_ vol: Float, muted: Bool) {
        let changed = abs(vol - volume) > 0.001 || muted != self.muted
        volume = vol
        self.muted = muted
        guard primed, changed else { return }
        present(facet: .volume(muted: muted))
    }

    private func handleBrightness(_ value: Float) {
        let changed = abs(value - brightness) > 0.001
        brightness = value
        guard primed, changed else { return }
        // Only surface MANUAL brightness changes — those following a recent brightness-key
        // press. Ambient auto-brightness from the light sensor has no key press, so it adjusts
        // the value silently without flashing the HUD.
        guard Date() < brightnessKeyUntil else { return }
        present(facet: .brightness)
    }

    private func handleKeyboard(_ value: Float) {
        let changed = abs(value - keyboardLevel) > 0.005
        keyboardLevel = value
        guard primed, changed else { return }
        present(facet: .keyboardBacklight)
    }

    /// A media key was pressed: surface the matching facet immediately at the current value.
    /// The controllers' value observers will follow with the settled value a beat later.
    private func handleMediaKey(_ facet: MediaKeyMonitor.Facet) {
        switch facet {
        case .volume:
            present(facet: .volume(muted: muted))
        case .mute:
            present(facet: .volume(muted: muted))
        case .brightness:
            guard brightnessAvailable else { return }
            // Mark this as a manual change so the settled value that follows surfaces the HUD.
            brightnessKeyUntil = Date().addingTimeInterval(brightnessKeyWindow)
            present(facet: .brightness)
        case .keyboardBacklight:
            guard keyboardAvailable else { return }
            present(facet: .keyboardBacklight)
        }
    }

    // MARK: Peek presentation

    /// Surfaces `facet` in the compact pill via a peek. The displayed level is read live
    /// from the module's published state by the compact view, so it always reflects the most
    /// recent value even if several changes arrive during a single peek.
    private func present(facet: SystemHUDFacet) {
        activeFacet = facet

        // While the user is dragging an expanded slider we keep state current but don't
        // hijack the compact pill with a peek.
        guard !isInteracting else { return }

        let appearing = !isShowingCompact
        isShowingCompact = true
        if appearing {
            context?.setNeedsCompactRefresh()
        }
        context?.requestPeek(peekDuration)

        // Schedule hiding the compact contribution after the peek settles.
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.peekDuration ?? 1.6))
            guard let self, !Task.isCancelled else { return }
            self.isShowingCompact = false
            self.context?.setNeedsCompactRefresh()
        }
    }

    // MARK: System writes (from expanded sliders)

    func setVolume(_ value: Float) {
        volume = value
        activeFacet = .volume(muted: value <= 0.001 ? muted : false)
        volumeController.setVolume(value)
    }

    func toggleMute() {
        let newMuted = !muted
        muted = newMuted
        activeFacet = .volume(muted: newMuted)
        volumeController.setMuted(newMuted)
    }

    func setBrightness(_ value: Float) {
        brightness = value
        activeFacet = .brightness
        brightnessController.setBrightness(value)
    }

    func setKeyboardLevel(_ value: Float) {
        keyboardLevel = value
        activeFacet = .keyboardBacklight
        keyboardController.setLevel(value)
    }

    // MARK: UI contributions

    func compactLeading() -> AnyView? {
        guard isShowingCompact else { return nil }
        return AnyView(SystemHUDCompactView(module: self))
    }

    func expandedSection() -> AnyView? {
        AnyView(SystemHUDExpandedView(module: self))
    }
}

// MARK: - Compact contribution

/// Wraps the transient level bar with an `@ObservedObject` so it tracks the module's live
/// facet/level state while shown.
private struct SystemHUDCompactView: View {
    @ObservedObject var module: SystemHUDModule

    var body: some View {
        SystemHUDCompactLevelBar(facet: module.activeFacet, level: compactLevel)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
    }

    private var compactLevel: Float {
        switch module.activeFacet {
        case .volume(let muted): return muted ? 0 : module.volume
        case .brightness: return module.brightness
        case .keyboardBacklight: return module.keyboardLevel
        }
    }
}

// MARK: - Expanded contribution

/// The expanded panel section: live sliders that write straight back to the system.
private struct SystemHUDExpandedView: View {
    @ObservedObject var module: SystemHUDModule

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.sectionSpacing) {
            HStack {
                Text(module.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryForeground)
                Spacer()
            }

            SystemHUDSliderRow(
                symbol: module.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                title: "Volume",
                value: Binding(
                    get: { Double(module.volume) },
                    set: { _ in }
                ),
                onChange: { module.setVolume(Float($0)) },
                trailingControl: AnyView(
                    Button {
                        module.toggleMute()
                    } label: {
                        Image(systemName: module.muted ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                module.muted ? NotchTheme.secondaryForeground : NotchTheme.primaryForeground
                            )
                    }
                    .buttonStyle(.plain)
                    .help(module.muted ? "Unmute" : "Mute")
                )
            )
            .onDragGesture(module: module)

            if module.brightnessAvailable {
                SystemHUDSliderRow(
                    symbol: "sun.max.fill",
                    title: "Brightness",
                    value: Binding(
                        get: { Double(module.brightness) },
                        set: { _ in }
                    ),
                    onChange: { module.setBrightness(Float($0)) }
                )
                .onDragGesture(module: module)
            }

            if module.keyboardAvailable {
                SystemHUDSliderRow(
                    symbol: "keyboard.fill",
                    title: "Keyboard Backlight",
                    value: Binding(
                        get: { Double(module.keyboardLevel) },
                        set: { _ in }
                    ),
                    onChange: { module.setKeyboardLevel(Float($0)) }
                )
                .onDragGesture(module: module)
            }
        }
        .padding(NotchTheme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
    }
}

private extension View {
    /// Marks the module as interacting for the duration of a press, so live slider drags
    /// don't fight the auto-peek on the compact pill.
    func onDragGesture(module: SystemHUDModule) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in module.isInteracting = true }
                .onEnded { _ in module.isInteracting = false }
        )
    }
}
