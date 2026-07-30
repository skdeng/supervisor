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
    /// Every registered module instance (enabled or not), built once. `modules` holds the
    /// currently-active subset; a Settings toggle reconciles against this roster live.
    private var moduleRoster: [any NotchModule] = []

    // MARK: Collaborators

    private let settings: SettingsStore
    private let geometryProvider = ScreenGeometryProvider()
    private let hover = HoverMonitor()
    private let window = NotchWindow()

    private var cancellables: Set<AnyCancellable> = []
    private var peekTask: Task<Void, Never>?
    /// True while a peek is forcing the compact surface to show even without live content.
    /// The hit-test and hover rects extend over a peek banner, and a peek can begin or end
    /// without a state transition (already compact), so recompute them on every flip here
    /// rather than relying on `transition(to:)` — which short-circuits when the state holds.
    @Published public private(set) var isPeeking: Bool = false {
        didSet {
            guard oldValue != isPeeking else { return }
            updateInteractivity()
        }
    }
    /// True while the cursor is hovering the notch. Drives a subtle grow affordance; the
    /// sheet itself only opens on a click.
    @Published public private(set) var isHovered: Bool = false
    /// True while a file is being dragged onto the notch (before it is dropped). While set,
    /// the expanded sheet surfaces only the FileShelf section so the drop target stands alone.
    @Published public private(set) var isFileDragging: Bool = false

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
    public let compactSideReserve: CGFloat = 160
    /// Fixed width of the expanded panel that drops below the notch. Content is laid out to
    /// this width, so the sheet never scrolls horizontally.
    public let expandedPanelWidth: CGFloat = 420
    /// Fixed height of a transient peek banner below the notch cutout.
    public let peekBannerHeight: CGFloat = 44
    /// Measured natural height of the expanded sheet's content (excludes the notch strip the
    /// sheet grows out of). Reported by the panel view so the morphing surface sizes to fit its
    /// content exactly — the sheet never scrolls vertically. Clamped to the bounds below.
    @Published public private(set) var expandedSheetHeight: CGFloat = 220
    /// Floor/ceiling for the measured sheet height. The ceiling also fixes the canvas budget,
    /// so the fixed-size window is always tall enough to host the tallest sheet.
    public let minExpandedSheetHeight: CGFloat = 96
    public let maxExpandedSheetHeight: CGFloat = 600

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

        // Recompute notch geometry when the user calibrates its width/position.
        settings.$notchWidthAdjust
            .dropFirst()
            .sink { [weak self] _ in self?.geometryProvider.recompute() }
            .store(in: &cancellables)
        settings.$notchOffsetX
            .dropFirst()
            .sink { [weak self] _ in self?.geometryProvider.recompute() }
            .store(in: &cancellables)

        // React live when a module is enabled/disabled in Settings: activate newly-enabled
        // modules and deactivate newly-disabled ones, so a disabled module actually sheds its
        // timers/observers/polls and a re-enabled one appears — no relaunch required. `@Published`
        // emits during willSet, so hop to the next main-queue turn to read the committed flags.
        settings.$moduleEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileModules() }
            .store(in: &cancellables)

        buildModules()

        // Compose the root view bound to this engine.
        window.setRootView(NotchRootView().environmentObject(self))

        hover.setSensitivity(settings.hoverSensitivity)
        hover.onEnter = { [weak self] in self?.handleHoverEnter() }
        hover.onExit = { [weak self] in self?.handleHoverExit() }

        // Dragging a file onto the notch opens the sheet with the file shelf.
        window.onFileDragEntered = { [weak self] in self?.handleFileDragEntered() }
        window.onFileDragExited = { [weak self] in self?.handleFileDragExited() }
        window.onFilesDropped = { [weak self] urls in self?.handleFilesDropped(urls) }

        reflowWindow()
        updateInteractivity()
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

    /// Build the full module roster from the registry once, then activate the enabled subset.
    private func buildModules() {
        let all = ModuleRegistry.allModules()
        for module in all {
            settings.registerModuleIfNeeded(module.moduleID)
        }
        moduleRoster = all
        let enabled = all
            .filter { settings.isEnabled($0.moduleID) }
            .sorted { $0.order < $1.order }
        for module in enabled {
            module.activate(context)
            AppLog.notice(.module, "activate \(module.moduleID)")
        }
        modules = enabled
    }

    /// Bring the active module set in line with the current Settings toggles: deactivate modules
    /// that were turned off (releasing their timers/observers/polls) and activate ones that were
    /// turned on, reusing the roster instances. Then re-evaluate the pill's compact presence and
    /// resting state.
    private func reconcileModules() {
        let desired = moduleRoster
            .filter { settings.isEnabled($0.moduleID) }
            .sorted { $0.order < $1.order }
        let activeIDs = Set(modules.map { $0.moduleID })
        let desiredIDs = Set(desired.map { $0.moduleID })
        guard activeIDs != desiredIDs else { return }

        for module in modules where !desiredIDs.contains(module.moduleID) {
            module.deactivate()
            AppLog.notice(.module, "deactivate \(module.moduleID)")
        }
        for module in desired where !activeIDs.contains(module.moduleID) {
            module.activate(context)
            AppLog.notice(.module, "activate \(module.moduleID)")
        }
        modules = desired
        // A module appearing/disappearing changes compact presence and the resting state, and
        // re-lays-out the pill.
        setNeedsCompactRefresh()
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
    /// panel: if already expanded, a peek is a no-op. A non-finite duration peeks
    /// indefinitely — the surface holds until the peeking module resolves it
    /// (`requestCollapse()` / `requestExpand()`) or the user opens the sheet.
    public func requestPeek(_ seconds: TimeInterval) {
        guard state != .expanded else { return }
        AppLog.debug(.engine, seconds.isFinite ? "peek \(seconds)s" : "peek held")
        peekTask?.cancel()
        peekTask = nil
        isPeeking = true
        transition(to: .compact)
        guard seconds.isFinite else { return }
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.peekTask = nil
            // A module supplying a banner is an unresolved hold: a timed peek that fired while
            // (or before) the banner was up must not tear the banner down when it expires, so
            // the surface stays held until every banner source has withdrawn.
            if self.activePeekBanner() != nil { return }
            self.isPeeking = false
            if self.state != .expanded {
                self.transition(to: self.resolvedRestingState())
            }
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

    /// Report the expanded sheet's measured natural content height so the morphing surface and
    /// the interactive / hover-activation rects size to fit it exactly (no scrolling). Called
    /// from the panel view's layout measurement; clamped, and ignored when effectively
    /// unchanged so it can't feed back into a layout loop.
    public func reportExpandedSheetHeight(_ height: CGFloat) {
        let clamped = min(max(height, minExpandedSheetHeight), maxExpandedSheetHeight)
        guard abs(clamped - expandedSheetHeight) > 0.5 else { return }
        expandedSheetHeight = clamped
        updateInteractivity()
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
            peekTask?.cancel()
            isPeeking = false
            transition(to: .expanded)
        }
    }

    /// Update the window's hit-test region (clicks + file drags land only over the notch /
    /// sheet, everything else passes through) and the hover activation rect.
    private func updateInteractivity() {
        window.interactiveRect = interactiveLocalRect()
        hover.activationRect = activationRect(for: state, hovered: isHovered, geometry: geometry)
    }

    // MARK: File drag → file shelf

    private var fileShelf: FileShelfModule? {
        modules.first { $0 is FileShelfModule } as? FileShelfModule
    }

    /// A file drag entered the notch: open the sheet and show the file shelf's drop UI. With the
    /// shelf module disabled there is nowhere to drop, so don't open an inert sheet or advertise
    /// a drop target.
    private func handleFileDragEntered() {
        guard let fileShelf else { return }
        fileShelf.setDropTargeting(true)
        isFileDragging = true
        compactRevision &+= 1  // force the panel to re-evaluate sections (show the shelf)
        if state != .expanded {
            transition(to: .expanded)
        }
    }

    /// The drag left without dropping: hide the drop UI, and collapse if nothing was staged.
    private func handleFileDragExited() {
        guard let fileShelf else { return }
        fileShelf.setDropTargeting(false)
        isFileDragging = false
        compactRevision &+= 1
        if fileShelf.stagedCount == 0, state == .expanded, !isHovered {
            transition(to: resolvedRestingState())
        }
    }

    /// Files were dropped: stage them and keep the sheet open so the user can act on them.
    private func handleFilesDropped(_ urls: [URL]) {
        guard let fileShelf else { return }
        fileShelf.stage(urls: urls)
        fileShelf.setDropTargeting(false)
        isFileDragging = false
        compactRevision &+= 1
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

    /// The first banner supplied by an active module, in module display order.
    public func activePeekBanner() -> AnyView? {
        modules.lazy.compactMap { $0.peekBanner() }.first
    }

    /// Whether the current peek contributes a below-notch banner surface.
    public var hasActivePeekBanner: Bool {
        isPeeking && activePeekBanner() != nil
    }

    private func transition(to newState: NotchState) {
        guard newState != state else { return }
        // The window is a constant-size canvas; only the SwiftUI content morphs, so the
        // Dynamic-Island animation is never clipped by a window resize. `NotchRootView` owns
        // the springs (keyed on the published `state`), so we just publish the new state.
        state = newState
        AppLog.debug(.engine, "state -> \(String(describing: newState))")
        // Interactivity depends on both hover and the new state; recompute outside animation.
        updateInteractivity()
        hover.refresh()
    }

    // MARK: Window geometry

    /// Position the fixed-size canvas window and update the hover activation rect. The
    /// window does NOT resize per state — it is always large enough for the expanded panel
    /// and the widest compact content — so SwiftUI animates the morph inside it without the
    /// window jumping. Called only when the geometry changes.
    private func reflowWindow() {
        let geo = geometry
        guard geo.screenFrame.width > 0 else { return }

        window.setFrame(canvasFrame(for: geo), display: true)
        window.interactiveRect = interactiveLocalRect()
        hover.activationRect = activationRect(for: state, hovered: isHovered, geometry: geo)
    }

    /// How much a hovered surface has swelled, for sizing the regions that must contain it.
    ///
    /// Only the detached pill is accounted for. The hardware notch's 6% nudge already sits well
    /// inside the aiming margins below, and inflating those by it would widen the zone enough to
    /// arm the notch from a brush past neighbouring menu-bar items.
    private func hoverGrowth(hovered: Bool, state: NotchState, geometry geo: NotchGeometry) -> CGFloat {
        guard hovered, state != .expanded, !geo.isHardwareNotch else { return 1 }
        return NotchTheme.pillHoverScale
    }

    /// The clickable / droppable region in the window content's bounds coordinates (bottom-left
    /// origin), pinned to the top: the notch pill when collapsed, the sheet when expanded.
    /// Everything outside passes events through.
    private func interactiveLocalRect() -> CGRect {
        let geo = geometry
        guard geo.screenFrame.width > 0 else { return .zero }
        let canvas = canvasFrame(for: geo)
        let w = canvas.width, h = canvas.height
        let notchH = max(geo.notchHeight, 32)
        let centerX = w / 2  // canvas is centered on the notch

        // Off a notched screen the surface detaches on hover, while the sheet is open, and while
        // a peek banner is held. The hit-test region drops with it, so the strip of menu bar it
        // vacates goes back to being the menu bar rather than a dead zone that swallows clicks.
        let drop = (isHovered || state == .expanded || hasActivePeekBanner)
            ? geo.pillTopDrop
            : 0
        let growth = hoverGrowth(hovered: isHovered, state: state, geometry: geo)

        let width: CGFloat
        let height: CGFloat
        switch state {
        case .expanded:
            width = expandedPanelWidth + 24
            height = notchH + expandedSheetHeight + 12
        case .compact:
            width = geo.notchWidth * growth + 180
            // Banner controls sit below the compact pill, so the hit region must cover that
            // fixed extension as well as a small aiming margin beneath it.
            height = notchH * growth + 16 + (hasActivePeekBanner ? peekBannerHeight + 8 : 0)
        case .idle:
            width = geo.notchWidth * growth + 28
            height = notchH * growth + 14
        }
        return CGRect(x: centerX - width / 2, y: h - drop - height, width: width, height: height)
    }

    /// The constant window frame (global, bottom-left origin): top-aligned, centered on the
    /// notch, tall enough for the dropped panel and wide enough for the widest state.
    private func canvasFrame(for geo: NotchGeometry) -> CGRect {
        let top = geo.screenTop
        // A hovered pill swells, so the canvas has to be wide enough to hold the widest compact
        // content at full growth; the surface is only ever clipped by the window, never resized.
        let pillGrowth = geo.isHardwareNotch ? 1 : NotchTheme.pillHoverScale
        let width = max((geo.notchWidth + 2 * compactSideReserve) * pillGrowth, expandedPanelWidth + 40)
        // Budget the canvas for the tallest possible sheet so the fixed-size window never has
        // to resize as the sheet grows/shrinks to fit its content — only the surface morphs.
        // The drop is budgeted too, since a detached pill pushes the sheet that far further down.
        let height = max(geo.notchHeight, 32) + maxExpandedSheetHeight + geo.pillTopDrop
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
            //
            // Off a notched screen the surface detaches on hover and drops away from the cursor
            // that summoned it. The zone has to reach down over where the pill lands — and still
            // start at the screen's top edge, where the surface rests — or the hover would end
            // the instant it began and the pill would chatter in and out.
            let pad: CGFloat = hovered ? 40 : 24
            let growth = hoverGrowth(hovered: hovered, state: state, geometry: geo)
            let width = geo.notchWidth * growth + 2 * pad
            let bannerActive = hasActivePeekBanner
            let bannerExtension = bannerActive ? peekBannerHeight + 8 : 0
            // Keep the hover zone over the banner so moving down to its action does not dismiss
            // or detach the active surface. A held banner also detaches the surface off a
            // notched screen, so the zone reaches down over the drop just as it does for hover.
            let minY = top - ((hovered || bannerActive) ? geo.pillTopDrop : 0) - notchH * growth
                - (hovered ? 22 : 12) - bannerExtension
            return CGRect(x: geo.centerX - width / 2, y: minY, width: width, height: maxY - minY)
        case .expanded:
            // Exactly the open panel bounds plus a small margin.
            let pad: CGFloat = 12
            let width = expandedPanelWidth + 2 * pad
            let minY = top - notchH - expandedSheetHeight - pad - geo.pillTopDrop
            return CGRect(x: geo.centerX - width / 2, y: minY, width: width, height: maxY - minY)
        }
    }
}
