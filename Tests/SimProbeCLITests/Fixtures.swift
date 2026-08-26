import Foundation

/// Values shared by every CLI test.
///
/// The identifiers here are deliberately **not** UDID-shaped. `simctl` treats a UDID as an
/// opaque string and nothing in this codebase validates the shape, while the repository's
/// hygiene gate rejects anything matching the UDID regex in a tracked file — including a
/// convincing-looking all-zero placeholder. A placeholder that cannot be mistaken for a real
/// device is both safer and more readable in a failure message.
enum Fixtures {
    static let udid = "SIM-UDID-PLACEHOLDER-A"
    static let otherUdid = "SIM-UDID-PLACEHOLDER-B"
}
