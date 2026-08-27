import Foundation

/// What `tap` was asked to do.
public struct TapOptions: Equatable, Sendable {

    public let udid: String
    public let target: TapTarget

    /// Whether to wait for the screen to settle after the tap.
    public let waitStable: Bool
    public let json: Bool

    public init(udid: String, target: TapTarget, waitStable: Bool = false, json: Bool = false) {
        self.udid = udid
        self.target = target
        self.waitStable = waitStable
        self.json = json
    }
}

/// Resolves a target, taps it through the warm daemon, and says where the tap landed.
///
/// Saying *where* matters more here than in a CLI that echoes its own arguments: `#id` and
/// `@index` are resolved against a tree the caller has not seen, and a ref that silently matched
/// the wrong row would be indistinguishable from an app bug.
public struct TapRunner {

    private let options: TapOptions

    public init(options: TapOptions) {
        self.options = options
    }

    public func run(
        through client: any DaemonClient,
        in environment: ProbeEnvironment
    ) throws -> Int32 {
        let (point, label) = try aim(through: client)
        let response = try client.call(.tap(x: Double(point.x), y: Double(point.y)))
        try report(point: point, label: label, ms: response.ms ?? 0, to: environment.output)
        guard options.waitStable else { return 0 }
        let waiting = WaitStableOptions(udid: options.udid, json: options.json)
        return try WaitStableRunner(options: waiting).run(in: environment)
    }

    /// Where the tap goes, and what to call it in the result line.
    private func aim(through client: any DaemonClient) throws -> (ElementPoint, String) {
        guard options.target.needsTree else {
            guard case .point(let point) = options.target else {
                throw ProbeError.invalidArgument("a coordinate target carries no point")
            }
            return (point, "")
        }
        let snapshot = try DaemonElementDescriber(client: client).describeAll(udid: options.udid)
        let element = try options.target.resolve(in: snapshot)
        return (element.frame.centre, element.ref)
    }

    private func report(
        point: ElementPoint,
        label: String,
        ms: Double,
        to output: any OutputWriting
    ) throws {
        if options.json {
            output.writeLine(
                try JSONLine.encode(
                    Report(ms: ms, ref: label.isEmpty ? nil : label, x: point.x, y: point.y)))
            return
        }
        let named = label.isEmpty ? "" : "\(label) "
        output.writeLine("tapped \(named)(\(point.x),\(point.y)) \(ms) ms")
    }

    private struct Report: Encodable {
        let ms: Double
        let ref: String?
        let x: Int
        let y: Int
    }
}
