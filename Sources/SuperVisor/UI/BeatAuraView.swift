import SwiftUI

/// The beat aura: a blurred echo of the notch surface, tinted with the artwork's dominant color,
/// whose intensity follows the music's bass envelope — the notch appears to glow and thump with
/// what's playing.
///
/// Rendered by `NotchRootView` *behind* (and unclipped by) the morphing surface, sized and
/// transformed identically to it. Pull-based like the spectrum bars: the `TimelineView` reads
/// the latest envelope from `SpectrumFeed` each frame, so nothing publishes at audio rate. The
/// view only exists while the tap is capturing, so it costs nothing otherwise.
struct BeatAuraView: View {
    /// The morphing surface's current bottom-corner radius, so the glow hugs the same silhouette.
    var cornerRadius: CGFloat
    /// How far the surface has lifted off the screen's top edge, so the glow lifts with it.
    var pillness: CGFloat
    /// The surface's drop distance at full pillness.
    var topDrop: CGFloat
    /// The artwork's dominant color.
    var accent: Color

    var body: some View {
        TimelineView(.animation) { _ in
            let aura = Double(SpectrumFeed.shared.snapshot().aura)
            // Below the visibility threshold, skip the blurred shape entirely — a per-frame
            // GPU blur is real work, and on quiet passages the glow would be invisible anyway.
            if aura > 0.02 {
                NotchShape(cornerRadius: cornerRadius, pillness: pillness, topDrop: topDrop)
                    .fill(accent)
                    .blur(radius: 10 + 16 * aura)
                    // Quadratic ramp: near-invisible on quiet passages, a real flare on hits.
                    .opacity(aura * (0.22 + 0.55 * aura))
                    // A slight downward swell so the glow reads as the notch breathing, anchored
                    // at the screen's top edge (it can never rise above the bezel).
                    .scaleEffect(x: 1 + 0.02 * aura, y: 1 + 0.10 * aura, anchor: .top)
            } else {
                Color.clear
            }
        }
    }
}
