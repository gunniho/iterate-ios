import SwiftUI
import UIKit

/// The app's motion, in the two numbers Apple designs springs with: how soon a value arrives
/// (`response`, in seconds) and how much it overshoots (`dampingRatio`, where 1 is none).
enum IterateMotion {
    /// No overshoot. For anything a finger did not throw: lists that change, notes that arrive.
    static let standard = Animation.spring(response: 0.35, dampingFraction: 1)
    /// A little overshoot, only where the gesture itself carried speed.
    static let momentum = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// A spring that goes on at the finger's speed. `velocity` is relative: points per second
    /// over the points left to travel.
    static func released(response: Double, dampingRatio: Double, velocity: Double) -> Animation {
        .interpolatingSpring(Spring(response: response, dampingRatio: dampingRatio), initialVelocity: velocity)
    }

    /// How far a release at `velocity` (points per second) still travels, as a scroll view
    /// decelerates. 0.998 is a scroll view's normal rate and 0.99 its fast one.
    static func projection(_ velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        velocity / 1000 * decelerationRate / (1 - decelerationRate)
    }

    /// What `overshoot` past an edge is drawn as: the further past, the less it follows.
    static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return overshoot * dimension * constant / (dimension + constant * abs(overshoot))
    }
}

/// Where an animated value is on screen now, which its state no longer says once it has a target.
final class LiveValue: @unchecked Sendable {
    var value: CGFloat = 0
}

/// A horizontal offset that keeps `live` at the drawn position through an animation, so a
/// finger that lands mid-flight takes the view from where it is.
struct TrackedOffset: ViewModifier, Animatable {
    private var x: CGFloat
    private let live: LiveValue

    init(x: CGFloat, live: LiveValue) {
        self.x = x
        self.live = live
        live.value = x
    }

    nonisolated var animatableData: CGFloat {
        get { x }
        set {
            x = newValue
            live.value = newValue
        }
    }

    func body(content: Content) -> some View { content.offset(x: x) }
}

/// Feedback the moment a finger lands, for a control that draws its own shape.
struct PressFeedback: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pressed(configuration: configuration) }

    private struct Pressed: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .opacity(isEnabled ? (pressed ? 0.7 : 1) : 0.4)
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .animation(pressed ? .easeOut(duration: 0.1) : IterateMotion.standard, value: pressed)
        }
    }
}

/// A list row's highlight, for a row that draws its own background.
struct RowPressFeedback: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color(uiColor: .systemFill).opacity(configuration.isPressed ? 1 : 0))
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.3), value: configuration.isPressed)
    }
}

/// A surface that arrives as a material does: it sharpens and grows into place.
struct Materialize: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(phase.isIdentity ? 1 : 0.94)
            .modifier(Sharpen(blurred: !phase.isIdentity))
    }

    /// Liquid Glass brings its own arrival, and a blur over it flattens the glass.
    private struct Sharpen: ViewModifier {
        let blurred: Bool
        func body(content: Content) -> some View {
            if #available(iOS 26, *) { content }
            else { content.blur(radius: blurred ? 6 : 0) }
        }
    }
}

extension AnyTransition {
    /// How a floating note comes and goes: up from the bottom edge and back to it, or a fade alone
    /// with Reduce Motion on.
    static func floatingNote(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: AnyTransition(Materialize()))
    }
}

/// A short note that floats over a list: glass where the system has it, a material before.
struct FloatingNoteSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular, in: .capsule) }
        else { content.background(.regularMaterial, in: .capsule).shadow(color: .black.opacity(0.08), radius: 12, y: 4) }
    }
}

extension View {
    /// At least the 44 points a finger needs, around a control that draws smaller.
    func tapTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}
