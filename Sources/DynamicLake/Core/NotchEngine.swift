import AppKit
import SwiftUI
import Combine

/// The presentation state of the notch surface.
public enum NotchState: Equatable {
    /// Thin pill hugging the notch; nothing live to show.
    case idle
    /// Pill grown to host compact live-activity content on either side.
    case compact
    /// Full panel dropped below the menu bar.
    case expanded
}

/// Owns the notch window, geometry, hover detection, the module list, and the state
/// machine. Builds the `NotchContext` handed to every module and exposes the data the
/// SwiftUI root view binds against.
@MainActor
public final class NotchEngine: ObservableObject {
    // MARK: Published presentation state

    @Published public private(set) var state: NotchState = .idle
    @Published public private(set) var geometry: NotchGeometry = .zero
    /// Bumped whenever a module's compact contribution appears/disappears so the pill
    /// re-lays-out and the window re-sizes.
    @Published public private(set) var compactRevision: Int = 0

    /// The enabled, activated modules sorted by `order`.
    public private(set) var modules: [any NotchModule] = []

    // MARK: Collaborators

    private let settings: SettingsStore
    private let geometryProvider = ScreenGeometryProvider()
    private let hover = HoverMonitor()
    private let window = NotchWindow()

    private var cancellables: Set<AnyCancellable> = []
    private var peekTask: Task<Void, Never>?
    /// True while a peek is forcing the compact surface to show even without live content.
    @Published public private(set) var isPeeking: Bool = false
    /// True while the cursor is hovering the notch. Drives a subtle grow affordance; the
    /// sheet itself only opens on a click.
    @Published public private(set) var isHovered: Bool = false

    private(set) lazy var context: NotchContext = NotchContext(
        requestExpand: { [weak self] in self?.requestExpand() },
        requestCollapse: { [weak self] in self?.requestCollapse() },
        requestPeek: { [weak self] seconds in self?.requestPeek(seconds) },
        setNeedsCompactRefresh: { [weak self] in self?.setNeedsCompactRefresh() }
    )

    // MARK: Layout metrics (read by the UI)

    /// Half-width of the compact canvas beyond the notch on each side. The window is a
    /// fixed-size transparent canvas; SwiftUI measures the actual compact content and
    /// centers it, so this only bounds how wide compact content may grow.
    public var compactSideReserve: CGFloat { settings.miniLakeEnabled ? 120 : 160 }
    /// Size of the expanded panel that drops below the notch.
    public let expandedPanelSize = CGSize(width: 420, height: 320)

    public init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    // MARK: Lifecycle

    /// Build the module list, activate modules, show the window, and start hover tracking.
    public func install() {
        geometry = geometryProvider.geometry

        // Reflow whenever the screen configuration changes.
        geometryProvider.$geometry
            .sink { [weak self] geo in
                guard let self else { return }
                self.geometry = geo
                self.reflowWindow()
            }
            .store(in: &cancellables)

        // Re-derive the hover dwell/grace from sensitivity, live.
        settings.$hoverSensitivity
            .sink { [weak self] value in
                self?.hover.setSensitivity(value)
            }
            .store(in: &cancellables)

        // miniLake changes the reserved footprint; reflow when toggled.
        settings.$miniLakeEnabled
            .dropFirst()
            .sink { [weak self] _ in
                self?.reflowWindow()
            }
            .store(in: &cancellables)

        // Recompute notch geometry when the user calibrates its width/position.
        settings.$notchWidthAdjust
            .dropFirst()
            .sink { [weak self] _ in self?.geometryProvider.recompute() }
            .store(in: &cancellables)
        settings.$notchOffsetX
            .dropFirst()
            .sink { [weak self] _ in self?.geometryProvider.recompute() }
            .store(in: &cancellables)

        buildModules()

        // Compose the root view bound to this engine.
        window.setRootView(NotchRootView().environmentObject(self))

        hover.setSensitivity(settings.hoverSensitivity)
        hover.onEnter = { [weak self] in self?.handleHoverEnter() }
        hover.onExit = { [weak self] in self?.handleHoverExit() }

        reflowWindow()
        // Idle/compact are click-through so the desktop and menu bar under the transparent
        // canvas stay usable; only the expanded panel captures the mouse.
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        hover.start()
    }

    /// Tear down modules and stop tracking. Called on app termination.
    public func shutdown() {
        hover.stop()
        peekTask?.cancel()
        for module in modules {
            module.deactivate()
        }
        window.orderOut(nil)
    }

    /// Build the enabled module set from the registry, activate each, and sort by order.
    private func buildModules() {
        let all = ModuleRegistry.allModules()
        for module in all {
            settings.registerModuleIfNeeded(module.moduleID)
        }
        let enabled = all
            .filter { settings.isEnabled($0.moduleID) }
            .sorted { $0.order < $1.order }
        for module in enabled {
            module.activate(context)
        }
        modules = enabled
    }

    // MARK: NotchContext actions

    public func requestExpand() {
        peekTask?.cancel()
        isPeeking = false
        transition(to: .expanded)
    }

    public func requestCollapse() {
        peekTask?.cancel()
        isPeeking = false
        transition(to: resolvedRestingState())
    }

    /// Briefly present the compact surface, then auto-collapse. Never steals the expanded
    /// panel: if already expanded, a peek is a no-op.
    public func requestPeek(_ seconds: TimeInterval) {
        guard state != .expanded else { return }
        peekTask?.cancel()
        isPeeking = true
        transition(to: .compact)
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.isPeeking = false
            self.transition(to: self.resolvedRestingState())
        }
    }

    public func setNeedsCompactRefresh() {
        compactRevision &+= 1
        // Appearance/disappearance of compact content can change the resting state.
        if state != .expanded {
            transition(to: resolvedRestingState())
        }
        reflowWindow()
    }

    // MARK: Hover / click handling

    /// Cursor entered the notch region: show the subtle grow affordance and make the surface
    /// clickable. The sheet does NOT open until the user clicks.
    private func handleHoverEnter() {
        isHovered = true
        updateInteractivity()
    }

    /// Cursor left the notch region: drop the hover affordance and, if the sheet was open,
    /// close it.
    private func handleHoverExit() {
        isHovered = false
        if state == .expanded {
            transition(to: resolvedRestingState())
        } else {
            updateInteractivity()
        }
    }

    /// A click on the notch surface toggles the sheet open/closed.
    public func toggleSheet() {
        if state == .expanded {
            transition(to: resolvedRestingState())
        } else {
            transition(to: .expanded)
        }
    }

    /// The window receives clicks while hovered (so a click can open the sheet) or while the
    /// sheet is open (so its controls work); otherwise it is click-through so the desktop and
    /// menu bar under the transparent canvas stay usable.
    private func updateInteractivity() {
        window.ignoresMouseEvents = !(isHovered || state == .expanded)
        hover.activationRect = activationRect(for: state, hovered: isHovered, geometry: geometry)
    }

    // MARK: State machine

    /// The non-expanded resting state: compact if any module currently contributes compact
    /// content (or a peek is active), otherwise idle.
    private func resolvedRestingState() -> NotchState {
        if isPeeking { return .compact }
        return hasCompactContent() ? .compact : .idle
    }

    private func hasCompactContent() -> Bool {
        for module in modules {
            if module.compactLeading() != nil || module.compactTrailing() != nil {
                return true
            }
        }
        return false
    }

    private func transition(to newState: NotchState) {
        guard newState != state else { return }
        // The window is a constant-size canvas; only the SwiftUI content morphs, so the
        // Dynamic-Island animation is never clipped by a window resize. `NotchRootView` owns
        // the springs (keyed on the published `state`), so we just publish the new state.
        state = newState
        // Interactivity depends on both hover and the new state; recompute outside animation.
        updateInteractivity()
        hover.refresh()
    }

    // MARK: Window geometry

    /// Position the fixed-size canvas window and update the hover activation rect. The
    /// window does NOT resize per state — it is always large enough for the expanded panel
    /// and the widest compact content — so SwiftUI animates the morph inside it without the
    /// window jumping. Called only when geometry (or the miniLake footprint) changes.
    private func reflowWindow() {
        let geo = geometry
        guard geo.screenFrame.width > 0 else { return }

        window.setFrame(canvasFrame(for: geo), display: true)
        hover.activationRect = activationRect(for: state, hovered: isHovered, geometry: geo)
    }

    /// The constant window frame (global, bottom-left origin): top-aligned, centered on the
    /// notch, tall enough for the dropped panel and wide enough for the widest state.
    private func canvasFrame(for geo: NotchGeometry) -> CGRect {
        let top = geo.screenTop
        let width = max(geo.notchWidth + 2 * compactSideReserve, expandedPanelSize.width + 40)
        let height = max(geo.notchHeight, 32) + expandedPanelSize.height
        return CGRect(
            x: geo.centerX - width / 2,
            y: top - height,
            width: width,
            height: height
        )
    }

    /// The cursor region that triggers expand/collapse. Kept tight around the notch so the
    /// panel only opens when the pointer is actually near the cutout — not when brushing
    /// distant menu-bar items. While expanded it covers exactly the open panel (plus a small
    /// margin) so the panel does not collapse out from under the pointer, but no wider.
    private func activationRect(for state: NotchState, hovered: Bool, geometry geo: NotchGeometry) -> CGRect {
        let top = geo.screenTop
        let notchH = max(geo.notchHeight, 32)
        // Reach a little ABOVE the screen's top edge so the very top row — where the cursor
        // sits at maxY when pinned to the menu bar / notch — stays inside the zone.
        // `CGRect.contains` excludes the max-y edge, which would otherwise drop the hover the
        // instant the cursor reaches the top of the screen.
        let topOverscan: CGFloat = 16
        let maxY = top + topOverscan

        switch state {
        case .idle, .compact:
            // Just the notch plus a small aiming margin on each side. A larger margin once
            // hovered gives tolerance so the slightly-grown notch doesn't flicker the hover.
            let pad: CGFloat = hovered ? 40 : 24
            let width = geo.notchWidth + 2 * pad
            let minY = top - notchH - (hovered ? 22 : 12)
            return CGRect(x: geo.centerX - width / 2, y: minY, width: width, height: maxY - minY)
        case .expanded:
            // Exactly the open panel bounds plus a small margin.
            let pad: CGFloat = 12
            let width = expandedPanelSize.width + 2 * pad
            let minY = top - notchH - expandedPanelSize.height - pad
            return CGRect(x: geo.centerX - width / 2, y: minY, width: width, height: maxY - minY)
        }
    }
}
