import SwiftUI

/// Home tab — the animation ground truth.
///
/// Two independent, separately controllable motion sources:
///
/// 1. `home.animateButton` drives **exactly one** `easeInOut` transition of
///    `HomeView.transitionDuration` (300 ms) and then settles into a fully static
///    state. That gives `simprobe wait-stable` / `simprobe motion` a known answer:
///    motion must start within a frame of the tap and be over 300 ms later.
/// 2. `home.microAnimationToggle` (default **OFF**) starts a perpetual, subtle
///    pulse that never settles — the "idle screen with a micro-animation" case
///    where naive two-identical-frames stability detection never terminates.
struct HomeView: View {
    /// The single ground-truth transition duration, in seconds. 300 ms.
    static let transitionDuration: Double = 0.3

    @State private var isExpanded = false
    @State private var microAnimationEnabled = false
    @State private var microPhase = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                animatedCard
                stateLabel
                animateButton
                microAnimationRow
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Home")
            // `.contain` first, then the identifier. On a plain layout container
            // like this VStack an identifier alone is inherited by every child,
            // so `home.root` silently overwrote `home.animateButton` and the
            // others and no selector but `id=home.root` matched anything on this
            // screen. Making the stack an accessibility container of its own
            // keeps the identifier on the container and leaves the children
            // holding the identifiers DemoApp/README.md promises. ItemListView
            // and FormView do not need this: List and Form are already
            // containers, which is why only Home was affected.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AXID.homeRoot)
        }
    }

    // MARK: - Subviews

    private var animatedCard: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isExpanded ? Color.indigo : Color.teal)
            .frame(height: isExpanded ? 260 : 80)
            .overlay(
                Text(isExpanded ? "Expanded" : "Collapsed")
                    .font(.headline)
                    .foregroundStyle(.white)
            )
            .accessibilityIdentifier(AXID.animatedCard)
            .accessibilityLabel("Animated card")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var stateLabel: some View {
        Text("Card state: \(isExpanded ? "expanded" : "collapsed")")
            .font(.subheadline)
            .monospaced()
            .accessibilityIdentifier(AXID.animationStateLabel)
    }

    private var animateButton: some View {
        Button("Animate") {
            // Exactly one explicit 300 ms easeInOut transition per tap, in both
            // directions, so `--repeat N` measures the same thing every time.
            withAnimation(.easeInOut(duration: HomeView.transitionDuration)) {
                isExpanded.toggle()
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(AXID.animateButton)
    }

    private var microAnimationRow: some View {
        HStack(spacing: 12) {
            microAnimationDot
            Toggle("Micro-animation", isOn: $microAnimationEnabled)
                .accessibilityIdentifier(AXID.microAnimationToggle)
        }
        .onChange(of: microAnimationEnabled) { _, enabled in
            // Driving `microPhase` from the toggle is what starts/stops the
            // repeating animation; flipping it back to `false` with a zero-length
            // animation snaps the dot to a static size, so OFF is genuinely idle.
            microPhase = enabled
        }
    }

    private var microAnimationDot: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 24, height: 24)
            .scaleEffect(microPhase ? 1.25 : 0.75)
            .animation(microAnimation, value: microPhase)
            .accessibilityIdentifier(AXID.microAnimationDot)
            .accessibilityLabel("Micro-animation indicator")
    }

    private var microAnimation: Animation {
        microAnimationEnabled
            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            : .linear(duration: 0)
    }
}

#Preview {
    HomeView()
}
