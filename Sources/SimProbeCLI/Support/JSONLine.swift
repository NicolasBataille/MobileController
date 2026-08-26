import Foundation

/// Encodes a payload as one line of JSON.
///
/// Keys are sorted so that output is byte-stable across runs and diffable in a test, and
/// slashes are left unescaped so a file path stays readable.
enum JSONLine {

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw ProbeError.invalidArgument("could not encode the result as JSON")
        }
        return text
    }
}
