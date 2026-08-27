import Foundation

/// What a client can ask the warm daemon to do.
///
/// Four operations and no more: the daemon exists to make the *hot* path cheap, and every verb
/// that is not on a tap-observe loop is better served by the `simctl` path that needs no daemon
/// at all.
public enum DaemonOperation: String, Codable, Sendable, CaseIterable {

    /// Liveness, and the answer `daemon status` prints.
    case ping

    /// The accessibility tree, as idb's own JSON.
    case tree

    /// One HID tap at a point in logical points.
    case tap

    /// Exit after answering.
    case stop
}

/// One request line.
///
/// `x`/`y` belong to `tap` alone rather than to a per-operation payload type: a flat object is
/// what a shell can write by hand while debugging (`echo '{"op":"tap","x":1,"y":2}' | nc -U …`),
/// and that has already paid for itself once.
public struct DaemonRequest: Codable, Equatable, Sendable {

    public let op: DaemonOperation
    public let x: Double?
    public let y: Double?

    public init(op: DaemonOperation, x: Double? = nil, y: Double? = nil) {
        self.op = op
        self.x = x
        self.y = y
    }

    public static let ping = DaemonRequest(op: .ping)
    public static let tree = DaemonRequest(op: .tree)
    public static let stop = DaemonRequest(op: .stop)

    public static func tap(x: Double, y: Double) -> DaemonRequest {
        DaemonRequest(op: .tap, x: x, y: y)
    }
}

/// One response line.
///
/// A single flat shape for every operation, with everything optional, rather than a union per
/// operation: the client already knows which question it asked, and one `Codable` type is one
/// place for the encoding to be wrong.
public struct DaemonResponse: Codable, Equatable, Sendable {

    public let ok: Bool

    /// How long the daemon spent on the call itself, excluding the socket round-trip.
    public let ms: Double?

    /// idb's accessibility JSON, carried **as a string**.
    ///
    /// Not as a nested object: as a string it round-trips through `Codable` byte for byte and
    /// is parsed in exactly one place, `AccessibilityElementParser`, which is the same parser
    /// `frames` uses against the same payload from the `idb` CLI.
    public let treeJSON: String?

    public let pid: Int32?
    public let udid: String?
    public let uptimeMs: Int?

    /// `ProbeError.kind` of the failure, when `ok` is false.
    public let kind: String?
    public let message: String?

    public init(
        ok: Bool,
        ms: Double? = nil,
        treeJSON: String? = nil,
        pid: Int32? = nil,
        udid: String? = nil,
        uptimeMs: Int? = nil,
        kind: String? = nil,
        message: String? = nil
    ) {
        self.ok = ok
        self.ms = ms
        self.treeJSON = treeJSON
        self.pid = pid
        self.udid = udid
        self.uptimeMs = uptimeMs
        self.kind = kind
        self.message = message
    }

    public static func failure(_ error: ProbeError) -> DaemonResponse {
        DaemonResponse(ok: false, kind: error.kind, message: error.description)
    }
}

/// Newline-delimited JSON, one line each way.
///
/// Deliberately not protobuf: the whole point of the two-product split is that `simprobe` links
/// neither gRPC nor SwiftProtobuf, and a hand-written frame format would be a third thing to
/// get wrong when `JSONEncoder` already produces exactly one line.
public enum DaemonProtocol {

    /// The frame terminator. A payload can never contain a bare newline, because `JSONEncoder`
    /// escapes them inside strings.
    public static let terminator: UInt8 = 0x0A

    public static func encode(_ request: DaemonRequest) throws -> String {
        try JSONLine.encode(request)
    }

    public static func encode(_ response: DaemonResponse) throws -> String {
        try JSONLine.encode(response)
    }

    /// - Throws: `ProbeError.idbFailed` (exit 2) on anything that is not one readable request.
    ///   A malformed line is a broken peer, not a user mistake.
    public static func decodeRequest(_ line: String) throws -> DaemonRequest {
        try decode(DaemonRequest.self, from: line, what: "request")
    }

    public static func decodeResponse(_ line: String) throws -> DaemonResponse {
        try decode(DaemonResponse.self, from: line, what: "response")
    }

    /// Unwraps a response, turning `ok: false` back into the error it was made from.
    ///
    /// The daemon reports failures in-band so that a failed tap and a dead socket stay
    /// distinguishable; this is where the in-band half becomes a `throw` again.
    @discardableResult
    public static func unwrap(_ response: DaemonResponse, op: DaemonOperation) throws
        -> DaemonResponse
    {
        guard response.ok else {
            throw ProbeError.idbFailed(
                command: "daemon \(op.rawValue)",
                detail: response.message ?? "the daemon reported a failure with no message"
            )
        }
        return response
    }

    private static func decode<T: Decodable>(_ type: T.Type, from line: String, what: String)
        throws -> T
    {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProbeError.idbFailed(command: "daemon", detail: "empty \(what) line")
        }
        do {
            return try JSONDecoder().decode(type, from: Data(trimmed.utf8))
        } catch {
            throw ProbeError.idbFailed(
                command: "daemon",
                detail: "unreadable \(what): \(error.localizedDescription)"
            )
        }
    }
}
