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
    /// The monitor refresh matters for the same reason: a peek can move the activation rect
    /// under a stationary cursor, and only a refresh re-evaluates hover without a mouse move.
    @Published public private(set) var isPeeking: Bool = false {
        didSet {
            guard oldValue != isPeeking else { return }
            updateInteractivity()
            hover.refresh()
        }
    }
    /// True while the cursor is hovering the notch. Drives a subtle grow affordance; the
    /// sheet itself only opens on a click.
    @Published public private(set) var isHovered: Bool = false
    /// True while a close is waiting for the side card to fade back out. The root view
    /// animates the card off this; the state machine holds `.expanded` until the fade has
    /// played, then completes the collapse — so the card is never left floating beside a
    /// sheet that is already shrinking.
    @Published public private(set) var isSideCardRetracting: Bool = false
    /// The delayed second phase of a close begun while the side card was out.
    private var pendingCloseTask: Task<Void, Never>?

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

    /// The FileShelf's detached side card: its fixed width and the gap between it and the
    /// sheet's trailing edge. The canvas budgets for the card on both sides (it stays centered
    /// on the notch), and the expanded hit-test and hover rects extend over it while it shows.
    public let sideCardWidth: CGFloat = 128
    public let sideCardGap: CGFloat = 8
    /// Slack the card's clipping window keeps on its free edges so the card's shadow isn't cut
    /// where nothing occludes it. Part of the canvas budget: the window overflows the card by
    /// this much to the right and below.
    public let sideCardShadowPad: CGFloat = 32
    /// The card's height floor. The card matches the sheet's height, but the sheet's measured
    /// height comes from the other modules' sections — a quiet sheet near the height floor
    /// would otherwise crush the card below what its empty drop zone needs.
    public let sideCardMinHeight: CGFloat = 180

    /// The collapsed surface's laid-out width and strip height, reported by the root view so the
    /// hit-test and hover rects cover the pill as it actually renders — compact content and an
    /// inline peek both size it beyond the bare notch.
    ///
    /// Deliberately NOT `@Published`: the root view is the source of these values, and
    /// republishing them would re-render it — which rebuilds the whole `ExpandedPanelView`
    /// whenever the surface is hovered.
    public private(set) var collapsedSurfaceWidth: CGFloat = 0
    public private(set) var collapsedStripHeight: CGFloat = 0
    /// Widest the collapsed surface may render. Bounded by the canvas's COMPACT width term
    /// rather than the whole canvas: the canvas also budgets expanded-only surfaces (the side
    /// card and its shadow slack), and a collapsed pill has no business growing into that
    /// allowance. Derived from screen geometry alone, so clamping against it can never feed
    /// back into layout.
    public var collapsedWidthLimit: CGFloat {
        let pillGrowth = geometry.isHardwareNotch ? 1 : NotchTheme.pillHoverScale
        return (geometry.notchWidth + 2 * compactSideReserve) * pillGrowth - 8
    }

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
        pendingCloseTask?.cancel()
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
    /// panel: while the sheet is open a peek presents nothing, and only a zero-duration
    /// release still resolves a hold. A non-finite duration peeks indefinitely — the surface
    /// holds until the peeking module resolves it (`requestCollapse()` / `requestExpand()`)
    /// or the user opens the sheet.
    public func requestPeek(_ seconds: TimeInterval) {
        // Zero duration is the release idiom, and a release only ever resolves: with no hold
        // there is nothing to resolve (a module may release a toast whose hold the sheet-open
        // already cleared — acquiring here would resurrect a banner the user dismissed), and a
        // pending TIMED peek carries its own deadline, which a release from another module
        // must not shorten — that deadline's completion hands the hold off correctly.
        if seconds == 0, !isPeeking || peekTask != nil { return }
        guard state != .expanded else {
            // A file drag expands the sheet without cancelling a held peek, so a module can
            // withdraw its banner while the sheet is up. Its zero-duration release must land
            // even now: dropped, the stale hold would pin the resting state to `.compact` —
            // and its enlarged hit region — indefinitely after the sheet closes. As on the
            // timed path, the hold passes to any banner that remains.
            if seconds == 0, activePeekBanner() == nil {
                isPeeking = false
            }
            return
        }
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

    /// Report the collapsed surface's laid-out width and strip height so the hit-test and hover
    /// rects track the pill's real size. Called from the root view's layout; ignored when
    /// effectively unchanged so it can't feed back into a layout loop.
    ///
    /// `hover.refresh()` is load-bearing. `HoverMonitor` re-evaluates only on
    /// a mouse move or an explicit refresh, and an inline peek arrives precisely when the cursor is
    /// stationary — a break nudge fires at a micro-pause, by construction. Without the refresh,
    /// `isHovered` keeps whatever value the last mouse move left: a pill that swelled under a
    /// resting cursor and then retracted would stay detached indefinitely, because no further event
    /// would ever tell the monitor the cursor is now outside. Recursion is bounded by the epsilon
    /// guard here and by the monitor's own inside/outside change guard.
    public func reportCollapsedSurface(width: CGFloat, stripHeight: CGFloat) {
        guard abs(width - collapsedSurfaceWidth) > 0.5 || abs(stripHeight - collapsedStripHeight) > 0.5
        else { return }
        collapsedSurfaceWidth = width
        collapsedStripHeight = stripHeight
        updateInteractivity()
        hover.refresh()
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

    // MARK: Side card

    /// Whether the shelf's detached card accompanies the open sheet right now. Drives the
    /// asymmetric extension of the expanded hit-test and hover rects, so hovering or clicking
    /// the card behaves as part of the sheet.
    public var isSideCardVisible: Bool {
        state == .expanded && fileShelf?.wantsSideCard == true
    }

    /// The shelf's card content, for the root view to render beside the sheet. Nil while the
    /// sheet is closed or the shelf has nothing to show.
    public func sideCardView() -> AnyView? {
        guard state == .expanded else { return nil }
        return fileShelf?.sideCard()
    }

    /// Distance from the surface's top edge (below any pill drop) to the side card's bottom
    /// edge. Can exceed the sheet's own extent when the height floor lifts a card beside a
    /// short sheet, so the expanded hit-test and hover rects take the larger of the two.
    private var sideCardBottomExtent: CGFloat {
        let notchH = max(geometry.notchHeight, 32)
        let cardHeight = max(
            expandedSheetHeight + (geometry.isHardwareNotch ? 0 : notchH),
            sideCardMinHeight
        )
        return (geometry.isHardwareNotch ? notchH : 0) + cardHeight
    }

    /// A file drag entered the notch: open the sheet and show the file shelf's drop UI. With the
    /// shelf module disabled there is nowhere to drop, so don't open an inert sheet or advertise
    /// a drop target.
    private func handleFileDragEntered() {
        guard let fileShelf else { return }
        fileShelf.setDropTargeting(true)
        compactRevision &+= 1  // re-render the root so the side card appears with its drop zone
        if state != .expanded {
            transition(to: .expanded)
        } else {
            // Already expanded: no transition recomputes the rects, but the card just appeared
            // and the hit-test / hover regions must reach over it for the drop to land there.
            // The refresh matters because the hover monitor sees no mouse events during a drag
            // session, so only a refresh re-evaluates a rect that moved under the drag cursor.
            updateInteractivity()
            hover.refresh()
        }
    }

    /// The drag left without dropping: hide the drop UI, and collapse if nothing was staged.
    private func handleFileDragExited() {
        guard let fileShelf else { return }
        fileShelf.setDropTargeting(false)
        compactRevision &+= 1
        if fileShelf.stagedCount == 0, state == .expanded, !isHovered {
            transition(to: resolvedRestingState())
        } else {
            updateInteractivity()
            hover.refresh()
        }
    }

    /// Files were dropped: stage them and keep the sheet open so the user can act on them.
    private func handleFilesDropped(_ urls: [URL]) {
        guard let fileShelf else { return }
        fileShelf.stage(urls: urls)
        fileShelf.setDropTargeting(false)
        compactRevision &+= 1
        updateInteractivity()
        hover.refresh()
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

    /// Whether the current peek contributes a banner surface.
    public var hasActivePeekBanner: Bool {
        isPeeking && activePeekBanner() != nil
    }

    /// Whether that banner renders centered in the pill's cutout gap rather than as a strip below
    /// the notch. Over a physical cutout the banner drops below the hardware; with no cutout the
    /// pill widens and swells around the banner instead, so the surface stays one row.
    public var peekPresentsInline: Bool {
        hasActivePeekBanner && !geometry.isHardwareNotch
    }

    private func transition(to newState: NotchState) {
        if newState == .expanded {
            // An open (or re-open during a sequenced close) resolves any pending close: the
            // card slides back out and the sheet holds.
            pendingCloseTask?.cancel()
            pendingCloseTask = nil
            if isSideCardRetracting { isSideCardRetracting = false }
        } else if state == .expanded {
            // A close already sequencing needs no second trigger.
            if pendingCloseTask != nil { return }
            // Closing with the side card out is two-phase: fade the card out first, then
            // collapse the sheet itself — the reverse of the open, where the sheet forms
            // first and then presents the card. The target state is re-resolved when the
            // second phase fires, since compact presence can change during the fade.
            if isSideCardVisible {
                isSideCardRetracting = true
                pendingCloseTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(260))
                    guard let self, !Task.isCancelled else { return }
                    self.pendingCloseTask = nil
                    self.isSideCardRetracting = false
                    self.performTransition(to: self.resolvedRestingState())
                }
                return
            }
        }
        performTransition(to: newState)
    }

    private func performTransition(to newState: NotchState) {
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
        // A display change can move the activation rect under a stationary cursor (the surface
        // may land on a different screen); only a refresh re-evaluates hover without a mouse move.
        hover.refresh()
    }

    /// How much a hovered surface has swelled, for sizing the regions that must contain it.
    ///
    /// Only the detached pill is accounted for. The hardware notch's 6% nudge already sits well
    /// inside the aiming margins below, and inflating those by it would widen the zone enough to
    /// arm the notch from a brush past neighbouring menu-bar items. An inline peek is the one
    /// case where the zone legitimately spans the surface's own width: the pill has grown to host
    /// the banner, and a zone narrower than it would drop the hover mid-reach for the action.
    private func hoverGrowth(hovered: Bool, state: NotchState, geometry geo: NotchGeometry) -> CGFloat {
        guard hovered, state != .expanded, !geo.isHardwareNotch else { return 1 }
        return NotchTheme.pillHoverScale
    }

    /// How far past the notch strip an active peek reaches, for sizing the regions that must
    /// contain it. A below-notch banner adds its own fixed strip plus an aiming margin. An inline
    /// peek adds no second row — it swells the strip itself — so only the strip's growth beyond
    /// the bare notch counts, and an indefinitely-held nudge leaves no click-swallowing band under
    /// the pill.
    private func peekHeightExtension(notchStripHeight: CGFloat) -> CGFloat {
        guard hasActivePeekBanner else { return 0 }
        guard peekPresentsInline else { return peekBannerHeight + 8 }
        return max(0, collapsedStripHeight - notchStripHeight)
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
            // The side card hangs off the sheet's trailing edge, so the clickable region
            // extends asymmetrically: same left edge, wider to the right — and down to the
            // card's bottom when its height floor puts it below a short sheet.
            let cardVisible = isSideCardVisible
            height = max(
                notchH + expandedSheetHeight,
                cardVisible ? sideCardBottomExtent : 0
            ) + 12
            let cardExtension = cardVisible ? sideCardGap + sideCardWidth : 0
            return CGRect(
                x: centerX - width / 2,
                y: h - drop - height,
                width: width + cardExtension,
                height: height
            )
        case .compact:
            // The fixed allowance covers ordinary compact content; the measured surface covers
            // anything that outgrows it — an inline peek, or compact contributions wide enough to
            // push the pill's outer edges past the allowance and out of the clickable region.
            width = max(geo.notchWidth * growth + 180, collapsedSurfaceWidth + 24)
            height = notchH * growth + 16 + peekHeightExtension(notchStripHeight: notchH * growth)
        case .idle:
            width = geo.notchWidth * growth + 28
            height = notchH * growth + 14
        }
        return CGRect(x: centerX - width / 2, y: h - drop - height, width: width, height: height)
    }

    /// The constant window frame (global, bottom-left origin): top-aligned, centered on the
    /// notch, tall enough for the dropped panel and wide enough for the widest state.
    /// Internal (not private) so the tests can pin the side card's containment.
    func canvasFrame(for geo: NotchGeometry) -> CGRect {
        let top = geo.screenTop
        // A hovered pill swells, so the canvas has to be wide enough to hold the widest compact
        // content at full growth; the surface is only ever clipped by the window, never resized.
        // The expanded budget carries the side card and its shadow slack on BOTH sides: the
        // canvas stays centered on the notch, so the trailing card is only in frame if its
        // width is mirrored.
        let pillGrowth = geo.isHardwareNotch ? 1 : NotchTheme.pillHoverScale
        let width = max(
            (geo.notchWidth + 2 * compactSideReserve) * pillGrowth,
            expandedPanelWidth + 40 + 2 * (sideCardGap + sideCardWidth + sideCardShadowPad)
        )
        // Budget the canvas for the tallest possible sheet so the fixed-size window never has
        // to resize as the sheet grows/shrinks to fit its content — only the surface morphs.
        // The drop is budgeted too, since a detached pill pushes the sheet that far further
        // down, and the side card's shadow slack so a full-height card's shadow isn't cut.
        let height = max(geo.notchHeight, 32) + maxExpandedSheetHeight + geo.pillTopDrop
            + sideCardShadowPad
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
            let width = max(
                geo.notchWidth * growth + 2 * pad,
                peekPresentsInline ? collapsedSurfaceWidth + 2 * pad : 0
            )
            let bannerActive = hasActivePeekBanner
            let bannerExtension = peekHeightExtension(notchStripHeight: notchH * growth)
            // Keep the hover zone over the banner so moving down to its action does not dismiss
            // or detach the active surface. A held banner also detaches the surface off a
            // notched screen, so the zone reaches down over the drop just as it does for hover.
            let minY = top - ((hovered || bannerActive) ? geo.pillTopDrop : 0) - notchH * growth
                - (hovered ? 22 : 12) - bannerExtension
            return CGRect(x: geo.centerX - width / 2, y: minY, width: width, height: maxY - minY)
        case .expanded:
            // Exactly the open panel bounds plus a small margin — extended over the side card
            // while it shows, so moving the cursor onto the card does not close the sheet out
            // from under it. The card's floored height can reach below a short sheet, so the
            // zone reaches down to whichever bottom edge is lower.
            let pad: CGFloat = 12
            let width = expandedPanelWidth + 2 * pad
            let cardVisible = isSideCardVisible
            let cardExtension = cardVisible ? sideCardGap + sideCardWidth : 0
            let extent = max(
                notchH + expandedSheetHeight,
                cardVisible ? sideCardBottomExtent : 0
            )
            let minY = top - extent - pad - geo.pillTopDrop
            return CGRect(
                x: geo.centerX - width / 2,
                y: minY,
                width: width + cardExtension,
                height: maxY - minY
            )
        }
    }
}
