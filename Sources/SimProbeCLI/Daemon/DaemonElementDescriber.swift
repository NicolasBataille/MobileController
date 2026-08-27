import Foundation

/// Reads the accessibility tree through a warm daemon instead of through the `idb` CLI.
///
/// Conforms to the same `ElementDescribing` the `idb` path does, so `tree` is `frames`' runner
/// over a different transport and the two verbs cannot drift apart in output.
///
/// The payload the companion returns over gRPC is the same flat array `idb ui describe-all
/// --json` prints — same keys, same nullability — so the parsing is the existing parser, not a
/// second one that would have to be kept in step.
public struct DaemonElementDescriber: ElementDescribing {

    private let client: any DaemonClient

    public init(client: any DaemonClient) {
        self.client = client
    }

    public func describeAll(udid: String) throws -> ElementSnapshot {
        try AccessibilityElementParser.parseAll(Data(try treeJSON().utf8))
    }

    /// Hit-tests the tree locally rather than asking the daemon.
    ///
    /// `describe-point` is a second RPC for something the tree already contains, and at 70 ms a
    /// tree the round trip costs more than the search. The **smallest** containing element wins,
    /// because the application and its scroll view contain every point on screen and neither is
    /// ever the answer to "what is under my finger".
    public func element(atX x: Int, y: Int, udid: String) throws -> AccessibilityElement? {
        try describeAll(udid: udid).elements
            .filter { $0.frame.contains(x: x, y: y) }
            .min { $0.frame.area < $1.frame.area }
    }

    private func treeJSON() throws -> String {
        let response = try client.call(.tree)
        guard let json = response.treeJSON else {
            throw ProbeError.idbFailed(
                command: "daemon tree", detail: "the daemon answered with no tree")
        }
        return json
    }
}

extension ElementFrame {

    /// Whether a point in logical points falls inside this rectangle, top and left edges
    /// included and bottom and right excluded — the half-open convention that keeps two
    /// touching rectangles from both claiming the same point.
    public func contains(x candidateX: Int, y candidateY: Int) -> Bool {
        candidateX >= x && candidateX < x + width
            && candidateY >= y && candidateY < y + height
    }

    public var area: Int { max(width, 0) * max(height, 0) }

    /// The point a tap aims at. The centre and not the origin: an origin sits exactly on the
    /// boundary a hit test excludes, and on a rounded control it can miss entirely.
    public var centre: ElementPoint {
        ElementPoint(x: x + width / 2, y: y + height / 2)
    }
}
