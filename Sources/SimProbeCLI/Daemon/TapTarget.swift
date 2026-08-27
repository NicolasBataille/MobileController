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

    /// Finds the element this target names.
    ///
    /// - Throws: `ProbeError.invalidArgument` (exit 1) when nothing on screen answers to it. The
    ///   ref came from a tree that has since changed — a push, a dismissed sheet — and the fix
    ///   is to re-read it, so the message says so.
    public func resolve(in snapshot: ElementSnapshot) throws -> AccessibilityElement {
        let match = snapshot.elements.first { element in
            switch self {
            case .identifier(let identifier): return element.identifier == identifier
            case .index(let index): return element.index == index
            case .point: return false
            }
        }
        guard let match else {
            throw ProbeError.invalidArgument(
                "no element \(label) on screen; re-read it with: simprobe tree")
        }
        return match
    }
}
