import Foundation

/// A point on the screen, in the same logical points `frames` prints and `shot` writes.
public struct ElementPoint: Equatable, Sendable {

    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// Parses `x,y`.
    ///
    /// - Throws: `ProbeError.invalidArgument` (exit 1). Two non-negative integers separated by
    ///   one comma, and nothing else: a silently mis-parsed coordinate would describe the wrong
    ///   element with no sign that anything went wrong, and a negative one is off every screen
    ///   there is — which the HID stream will happily accept and quietly clamp.
    public static func parse(_ text: String) throws -> ElementPoint {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else {
            throw ProbeError.invalidArgument("--point takes 'x,y' in points, got '\(text)'")
        }
        guard x >= 0, y >= 0 else {
            throw ProbeError.invalidArgument(
                "(\(x),\(y)) is off screen: coordinates are in points from the top left")
        }
        return ElementPoint(x: x, y: y)
    }
}

/// What `frames` was asked to do.
public struct FramesOptions: Equatable, Sendable {

    public let udid: String

    /// Keep only elements that can actually be acted on.
    public let interactiveOnly: Bool

    /// Describe just the element under this point instead of the whole screen.
    public let point: ElementPoint?

    public let json: Bool

    public init(
        udid: String,
        interactiveOnly: Bool = false,
        point: ElementPoint? = nil,
        json: Bool = false
    ) {
        self.udid = udid
        self.interactiveOnly = interactiveOnly
        self.point = point
        self.json = json
    }
}

/// Lists the accessibility elements on screen with their 1x coordinates.
///
/// One line per element, banded by vertical position, because the question an agent asks of
/// this output is "what can I tap, and where" — and the answer is almost always in one band.
public struct FramesRunner {

    /// Where the top band ends. 120 points covers the status bar and a large navigation bar
    /// on every current iPhone; it is a reading aid, and the exact coordinates are on the line.
    static let topBandHeight = 120

    /// How tall the bottom band is, measured up from the bottom edge: enough for a tab bar
    /// plus its safe-area inset.
    static let bottomBandHeight = 120

    private let options: FramesOptions

    public init(options: FramesOptions) {
        self.options = options
    }

    public func run(describing describer: any ElementDescribing, to output: any OutputWriting)
        throws -> Int32
    {
        if let point = options.point {
            let hit = try describer.element(atX: point.x, y: point.y, udid: options.udid)
            try report(hit.map { [$0] } ?? [], header: nil, screenHeight: 0, to: output)
            if !options.json, hit == nil {
                output.writeLine("no element at (\(point.x),\(point.y))")
            }
            return 0
        }
        let snapshot = try describer.describeAll(udid: options.udid)
        try report(
            kept(in: snapshot),
            header: "\(snapshot.appLabel)  \(snapshot.screen.width)x\(snapshot.screen.height)",
            screenHeight: snapshot.screen.height,
            to: output
        )
        return 0
    }

    /// Everything worth printing, in reading order.
    ///
    /// A zero-size element cannot be tapped and an offscreen one is not there to be tapped;
    /// both are pure cost in the output. `--interactive` additionally drops what cannot be
    /// acted on — including an actionable *type* that is disabled, which is a control the
    /// caller would otherwise waste a turn pressing.
    private func kept(in snapshot: ElementSnapshot) -> [AccessibilityElement] {
        snapshot.elements
            .filter { !$0.frame.isEmpty && $0.frame.intersects(snapshot.screen) }
            .filter { !options.interactiveOnly || ($0.kind.isActionable && $0.isEnabled) }
            .sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
    }

    private func report(
        _ elements: [AccessibilityElement],
        header: String?,
        screenHeight: Int,
        to output: any OutputWriting
    ) throws {
        if options.json {
            output.writeLine(try JSONLine.encode(elements.map(Report.init)))
            return
        }
        header.map(output.writeLine)
        guard header != nil else {
            elements.map { Self.line(for: $0, widths: Columns()) }.forEach(output.writeLine)
            return
        }
        let widths = Columns(elements)
        for band in Band.allCases {
            let members = elements.filter { band.contains($0.frame.y, screenHeight: screenHeight) }
            guard !members.isEmpty else { continue }
            output.writeLine(band.header(screenHeight: screenHeight))
            members.map { Self.line(for: $0, widths: widths) }.forEach(output.writeLine)
        }
    }

    private static func line(for element: AccessibilityElement, widths: Columns) -> String {
        "  " + widths.pad(element.ref, to: widths.ref)
            + widths.pad(element.kind.rawValue, to: widths.kind)
            + widths.pad("\"\(element.label)\"", to: widths.label)
            + element.frame.summary
    }

    /// Column widths derived from the content, so short refs are not paid for in blank space.
    ///
    /// Padding never truncates: a column that overflows pushes the rest of its own line right
    /// rather than losing a character, because a clipped ref is a ref a caller cannot use.
    private struct Columns {

        let ref: Int
        let kind: Int
        let label: Int

        /// Two spaces between columns, which is the least that still reads as a column.
        private static let gutter = 2

        init(_ elements: [AccessibilityElement] = []) {
            ref = (elements.map(\.ref.count).max() ?? 0) + Self.gutter
            kind = (elements.map(\.kind.rawValue.count).max() ?? 0) + Self.gutter
            label = (elements.map { $0.label.count + 2 }.max() ?? 0) + Self.gutter
        }

        func pad(_ text: String, to width: Int) -> String {
            text + String(repeating: " ", count: max(width - text.count, Self.gutter))
        }
    }

    /// The three vertical regions a caller thinks in: chrome at the top, content, chrome at
    /// the bottom.
    private enum Band: CaseIterable {
        case top, content, bottom

        func contains(_ y: Int, screenHeight: Int) -> Bool {
            switch self {
            case .top: return y < FramesRunner.topBandHeight
            case .bottom: return y >= Self.bottomEdge(screenHeight)
            case .content:
                return y >= FramesRunner.topBandHeight && y < Self.bottomEdge(screenHeight)
            }
        }

        func header(screenHeight: Int) -> String {
            switch self {
            case .top: return "[Top y<\(FramesRunner.topBandHeight)]"
            case .content: return "[Content]"
            case .bottom: return "[Bottom y≥\(Self.bottomEdge(screenHeight))]"
            }
        }

        private static func bottomEdge(_ screenHeight: Int) -> Int {
            max(screenHeight - FramesRunner.bottomBandHeight, FramesRunner.topBandHeight)
        }
    }

    private struct Report: Encodable {
        let ref: String
        let type: String
        let label: String
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        init(_ element: AccessibilityElement) {
            ref = element.ref
            type = element.kind.rawValue
            label = element.label
            x = element.frame.x
            y = element.frame.y
            w = element.frame.width
            h = element.frame.height
        }
    }
}
