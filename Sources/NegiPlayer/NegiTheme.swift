import SwiftUI

struct NegiBackground: View {
    var body: some View {
        ZStack {
            surface
            RadialGradient(colors: [accent.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 650)
            RadialGradient(colors: [pinkAccent.opacity(0.075), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 500)
        }.ignoresSafeArea()
    }
}

struct NegiGlass: ViewModifier {
    var cornerRadius: CGFloat
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular.tint(accent.opacity(0.09)).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        } else if reduceTransparency {
            content.background(surface.opacity(0.98), in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}
extension View {
    func negiGlass(_ radius: CGFloat = 16, interactive: Bool = false) -> some View {
        modifier(NegiGlass(cornerRadius: radius, interactive: interactive))
    }
    @ViewBuilder func negiProminentButton() -> some View {
        if #available(macOS 26.0, *) { self.buttonStyle(.glassProminent) }
        else { self.buttonStyle(.borderedProminent) }
    }
}
