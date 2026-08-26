import Foundation

/// Reading a simulator's accessibility elements with their on-screen frames.
public protocol ElementDescribing {

    func describeAll(udid: String) throws -> ElementSnapshot

    /// - Returns: the element under the point, or `nil` when there is none.
    func element(atX x: Int, y: Int, udid: String) throws -> AccessibilityElement?
}

/// Locating `idb`, and saying how to get it when it is not there.
///
/// `idb` is the only thing on this machine that will hand over accessibility frames without a
/// private framework: `simctl` has no equivalent, and loading Apple's private translator at
/// runtime is exactly the mechanism this repository refuses to use — see
/// `scripts/hygiene-check.sh`, which fails the build on it.
public enum Idb {

    /// What to run to get `idb`. Both halves are needed — the companion is the native side,
    /// `fb-idb` is the client that talks to it.
    public static let installHint =
        "brew install facebook/fb/idb-companion && pip3 install fb-idb"

    /// How long a `describe` call gets. Generous next to `simctl`'s 15 s because idb may have
    /// to spawn its companion first, which on a cold simulator costs several seconds.
    public static let describeDeadlineMs = 30_000

    /// - Throws: `ProbeError.dependencyMissing` (exit 2), carrying `installHint`.
    public static func locate(runner: any ProcessRunning = SystemProcessRunner()) throws -> String {
        let result = try? runner.run("/usr/bin/which", ["idb"])
        let path = result?.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let result, result.status == 0, !path.isEmpty else {
            throw ProbeError.dependencyMissing(tool: "idb", hint: installHint)
        }
        return path
    }
}

/// Describes elements through `idb ui describe-all` / `describe-point`.
public struct IdbElementDescriber: ElementDescribing {

    private let idb: String
    private let runner: any ProcessRunning

    public init(idb: String, runner: any ProcessRunning = SystemProcessRunner()) {
        self.idb = idb
        self.runner = runner
    }

    public func describeAll(udid: String) throws -> ElementSnapshot {
        try AccessibilityElementParser.parseAll(
            try describe(["ui", "describe-all", "--udid", udid, "--json"], udid: udid))
    }

    public func element(atX x: Int, y: Int, udid: String) throws -> AccessibilityElement? {
        try AccessibilityElementParser.parseOne(
            try describe(
                ["ui", "describe-point", "\(x)", "\(y)", "--udid", udid, "--json"], udid: udid))
    }

    /// Runs a describe call, and retries it **once** through an explicit `idb connect`.
    ///
    /// idb's companion auto-spawns, but the first call after a simulator boots reliably fails
    /// with "No translation object returned for simulator" — the companion is up, the bridge
    /// to the simulator is not. An explicit `connect` establishes it, and the same call then
    /// succeeds. The retry is not conditioned on that message: idb's wording is not part of
    /// any contract, and reconnecting is harmless whatever the failure was.
    ///
    /// A failing `connect` is not itself reported: what the caller needs to hear about is the
    /// second describe, whose error is the one that actually stopped the verb.
    private func describe(_ arguments: [String], udid: String) throws -> Data {
        let first = try runner.run(idb, arguments, deadlineMs: Idb.describeDeadlineMs)
        if first.status == 0 { return first.standardOutput }
        _ = try? runner.run(idb, ["connect", udid], deadlineMs: Idb.describeDeadlineMs)
        let second = try runner.run(idb, arguments, deadlineMs: Idb.describeDeadlineMs)
        guard second.status == 0 else {
            throw ProbeError.idbFailed(
                command: arguments.joined(separator: " "),
                detail: second.failureDetail
            )
        }
        return second.standardOutput
    }
}
