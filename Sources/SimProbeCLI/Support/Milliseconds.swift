import Foundation

/// Parses the durations the CLI accepts: `60ms`, `4s`, `1.5s`, or a bare count of milliseconds.
///
/// A suffix-free number means milliseconds because that is the unit every output is printed in;
/// a caller who writes `--timeout 4` and means four seconds is better served by an obviously
/// wrong `4ms` result than by a guess.
public enum Milliseconds {

    /// The largest duration accepted: 24 hours.
    ///
    /// A ceiling is not cosmetic. Every parsed duration is added to and subtracted from clock
    /// readings (`nowMs - startedAtMs`, `min(interval, remaining)`), so a value anywhere near
    /// `Int.max` overflows and traps on the first such addition. And `Int(hugeDouble)` traps
    /// outright: `--timeout 1e300` used to take the process down with SIGILL rather than
    /// printing a message. A day is already orders of magnitude beyond any real budget.
    public static let maximum = 24 * 60 * 60 * 1_000

    /// - Throws: `ProbeError.invalidArgument` (exit 1) for anything unparseable, negative,
    ///   or beyond `maximum`.
    public static func parse(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let (digits, factor) = split(trimmed)
        guard !digits.isEmpty, let value = Double(digits), value.isFinite, value >= 0 else {
            throw ProbeError.invalidArgument(
                "could not read '\(text)' as a duration: expected e.g. 250, 60ms or 1.5s"
            )
        }
        guard let milliseconds = Int(exactly: (value * factor).rounded()),
            milliseconds <= maximum
        else {
            throw ProbeError.invalidArgument(
                "'\(text)' is out of range: a duration must be between 0 and \(maximum) ms"
            )
        }
        return milliseconds
    }

    private static func split(_ text: String) -> (digits: Substring, factor: Double) {
        if text.hasSuffix("ms") { return (text.dropLast(2), 1) }
        if text.hasSuffix("s") { return (text.dropLast(1), 1_000) }
        return (text[...], 1)
    }
}
