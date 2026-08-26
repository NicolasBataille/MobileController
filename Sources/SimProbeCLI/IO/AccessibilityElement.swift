import Foundation

/// A rectangle in **logical points**, the same unit `simprobe shot` writes its JPEG in.
///
/// idb reports frames as floating point and routinely lands a third of a point off an integer
/// (`119.66666666666667`). Whole points are what a caller taps with, so they are what is
/// stored: rounding once, here, keeps every consumer from rounding differently.
public struct ElementFrame: Equatable, Sendable {

    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Nothing can be tapped in a rectangle with no area.
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// `(22,781 119x44)`: origin then size, the order a tap command takes them in.
    public var summary: String { "(\(x),\(y) \(width)x\(height))" }

    public func intersects(_ other: ElementFrame) -> Bool {
        x < other.x + other.width && other.x < x + width
            && y < other.y + other.height && other.y < y + height
    }
}

/// The short vocabulary the accessibility snapshot already speaks.
///
/// idb reports a dozen platform-specific type names; an agent only ever branches on a handful,
/// and every extra distinction is tokens spent on a difference it will not act on. Anything
/// unrecognised becomes `Other` rather than being passed through, so the vocabulary stays
/// closed and a future iOS cannot widen it behind our back.
public enum ElementKind: String, Sendable, CaseIterable {
    case button = "Button"
    case text = "Text"
    case textField = "TextField"
    case image = "Image"
    case toggle = "Switch"
    case other = "Other"

    /// Whether an element of this kind is something a caller can act on.
    public var isActionable: Bool {
        switch self {
        case .button, .textField, .toggle: return true
        case .text, .image, .other: return false
        }
    }

    public init(idbType: String) {
        switch idbType {
        case "Button", "Link", "PopUpButton", "MenuItem", "Cell": self = .button
        case "StaticText", "Text", "Heading", "TextView": self = .text
        case "TextField", "SecureTextField", "SearchField": self = .textField
        case "Image", "Icon": self = .image
        case "CheckBox", "Switch", "Toggle", "RadioButton": self = .toggle
        default: self = .other
        }
    }
}

/// One accessibility element, reduced to what it takes to find it and tap it.
public struct AccessibilityElement: Equatable, Sendable {

    /// The character cap on a label. Long labels are common — an iOS Settings row can carry a
    /// whole paragraph — and the tail of one is never what identifies it.
    public static let labelLimit = 40

    /// Position in the array idb returned, or `nil` for a `--point` hit, which has no list to
    /// be an index into.
    public let index: Int?

    /// The app's own `accessibilityIdentifier`, when it set one.
    public let identifier: String?

    public let kind: ElementKind

    /// `AXLabel`, falling back to `AXValue`, truncated to `labelLimit` characters.
    public let label: String

    public let frame: ElementFrame
    public let isEnabled: Bool

    public init(
        index: Int?,
        identifier: String?,
        kind: ElementKind,
        label: String,
        frame: ElementFrame,
        isEnabled: Bool
    ) {
        self.index = index
        self.identifier = identifier
        self.kind = kind
        self.label = label
        self.frame = frame
        self.isEnabled = isEnabled
    }

    /// How a caller names this element: the identifier when the app set one, because it
    /// survives a relayout, and the list index otherwise, because it is all there is.
    public var ref: String {
        if let identifier, !identifier.isEmpty { return "#\(identifier)" }
        return index.map { "@\($0)" } ?? "@?"
    }

    /// Cuts a label to `labelLimit` *characters*, ellipsis included in the count.
    ///
    /// Characters and not bytes: `こんばんは` is five characters and fifteen bytes, and a byte
    /// cap would both mangle it and cut labels of different languages at different lengths.
    public static func truncate(_ text: String) -> String {
        guard text.count > labelLimit else { return text }
        return String(text.prefix(labelLimit - 1)) + "…"
    }
}

/// Everything one `describe-all` said: the app, the screen it fills, and its elements.
public struct ElementSnapshot: Equatable, Sendable {

    public let appLabel: String
    public let screen: ElementFrame

    /// Every element **except** the application itself, which becomes the header.
    public let elements: [AccessibilityElement]

    public init(appLabel: String, screen: ElementFrame, elements: [AccessibilityElement]) {
        self.appLabel = appLabel
        self.screen = screen
        self.elements = elements
    }
}
