import Foundation

/// What `simprobe tap` was aimed at.
///
/// The same three spellings `frames` prints, so a ref read off one command is typed verbatim
/// into the next: `#accessibilityIdentifier`, `@index`, or a bare `x,y`.
public enum TapTarget: Equatable, Sendable {

    case identifier(String)
    case index(Int)
    case point(ElementPoint)

    /// - Throws: `ProbeError.invalidArgument` (exit 1) on anything else. A mis-read target taps
    ///   *somewhere*, which is worse than not tapping at all.
    public static func parse(_ text: String) throws -> TapTarget {
        if text.hasPrefix("#") {
            let identifier = String(text.dropFirst())
            guard !identifier.isEmpty else {
                throw ProbeError.invalidArgument("'#' is not an identifier")
            }
            return .identifier(identifier)
        }
        if text.hasPrefix("@") {
            guard let index = Int(text.dropFirst()), index >= 0 else {
                throw ProbeError.invalidArgument(
                    "'\(text)' is not an element index: expected e.g. @7")
            }
            return .index(index)
        }
        guard text.contains(",") else {
            throw ProbeError.invalidArgument(
                "'\(text)' is not a target: expected #id, @index or x,y")
        }
        return .point(try ElementPoint.parse(text))
    }

    /// How the target is printed back in the result line.
    public var label: String {
        switch self {
        case .identifier(let identifier): return "#\(identifier)"
        case .index(let index): return "@\(index)"
        case .point: return ""
        }
    }

    /// Whether this target names an element, and so needs a tree read before the tap.
    public var needsTree: Bool {
        if case .point = self { return false }
        return true
    }

    /// Finds the element this target names, and proves it is one a tap can land on.
    ///
    /// Four ways this refuses, all of them `ProbeError.invalidArgument` (exit 1), and all of
    /// them cases where tapping anyway would put a finger *somewhere* — which is worse than not
    /// tapping, because the caller reads "tapped" and believes it:
    ///
    /// - nothing answers to the ref: the tree has changed since it was read;
    /// - two elements answer to it: an app may reuse an identifier across a screen, and "the
    ///   first one" is a coin flip the caller did not ask for;
    /// - the frame has no area: idb reports hidden controls at `0x0`;
    /// - the centre is off screen: a row scrolled out of view is reported at its real
    ///   coordinates, and a tap there lands on whatever is drawn at the clamped edge instead.
    public func resolve(in snapshot: ElementSnapshot) throws -> AccessibilityElement {
        let matches = snapshot.elements.filter { self.matches($0) }
        guard let match = matches.first else {
            throw ProbeError.invalidArgument(
                "no element \(label) on screen; re-read it with: simprobe tree")
        }
        guard matches.count == 1 else {
            throw ProbeError.invalidArgument(
                "\(label) matches \(matches.count) elements (\(Self.positions(of: matches))); "
                    + "tap one of them by index")
        }
        guard !match.frame.isEmpty else {
            throw ProbeError.invalidArgument(
                "\(label) has an empty frame \(match.frame.summary); there is nothing to tap")
        }
        let centre = match.frame.centre
        guard snapshot.screen.contains(x: centre.x, y: centre.y) else {
            throw ProbeError.invalidArgument(
                "\(label) is centred at (\(centre.x),\(centre.y)), outside the screen "
                    + "\(snapshot.screen.summary); scroll it into view first")
        }
        return match
    }

    private func matches(_ element: AccessibilityElement) -> Bool {
        switch self {
        case .identifier(let identifier): return element.identifier == identifier
        case .index(let index): return element.index == index
        case .point: return false
        }
    }

    /// How duplicates are named back to the caller.
    ///
    /// By index, never by the ref they share: two elements with the same identifier print the
    /// same `#id`, and a message that lists it twice tells the caller nothing they can act on.
    private static func positions(of elements: [AccessibilityElement]) -> String {
        elements.map { element in element.index.map { "@\($0)" } ?? element.ref }
            .joined(separator: ", ")
    }
}
