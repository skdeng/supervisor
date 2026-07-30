import SwiftUI

struct AttentionGlowView: View {
    var cornerRadius: CGFloat
    var pillness: CGFloat
    var topDrop: CGFloat

    /// How far the glow reaches past the silhouette: half the stroke width plus the blur's
    /// tail, with headroom. The view is laid out this much larger than the surface on every
    /// side, because the gradient renders only within its own bounds — a frame that stopped at
    /// the silhouette would cut the glow wherever the shape touches the frame's edge.
    static let spill: CGFloat = 12

    @State private var angle = 0.0

    var body: some View {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: NotchTheme.brandPink, location: 0.18),
                .init(color: NotchTheme.brandCyan, location: 0.36),
                .init(color: .clear, location: 0.54),
                .init(color: .clear, location: 1)
            ]),
            center: .center,
            startAngle: .degrees(angle),
            endAngle: .degrees(angle + 360)
        )
        .mask {
            // The padding pulls the shape back in from the enlarged bounds so the stroked
            // silhouette lands exactly on the morphing surface; the blur then spreads into
            // the surrounding spill ring, where the gradient has content to reveal.
            NotchShape(cornerRadius: cornerRadius, pillness: pillness, topDrop: topDrop)
                .stroke(style: StrokeStyle(lineWidth: 5))
                .padding(Self.spill)
                .blur(radius: 5)
        }
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
        .allowsHitTesting(false)
    }
}
