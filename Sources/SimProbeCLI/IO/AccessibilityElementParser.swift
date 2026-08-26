import Foundation

/// Reads what `idb ui describe-all --json` and `idb ui describe-point --json` actually emit.
///
/// The real shape is a **flat** array — not a tree — of objects carrying `AXLabel`,
/// `AXUniqueId`, `AXValue`, `type`, `enabled` and a `frame` of four `Double`s, with the keys in
/// no particular order and every one of them nullable. `describe-point` answers with a single
/// object rather than an array.
public enum AccessibilityElementParser {

    /// - Throws: `ProbeError.idbFailed` (exit 2) when the payload is not the expected shape.
    ///   Unreadable output from a dependency is an environment problem, not a usage error.
    public static func parseAll(_ data: Data) throws -> ElementSnapshot {
        let raw: [RawElement] = try decode(data, command: "ui describe-all --json")
        let application = raw.first { $0.type == "Application" }
        return ElementSnapshot(
            appLabel: application?.AXLabel ?? "",
            screen: application?.frame.rounded ?? bounds(of: raw),
            elements: raw.enumerated()
                .filter { $0.element.type != "Application" }
                .map { $0.element.element(at: $0.offset) }
        )
    }

    /// - Returns: `nil` when idb reported no element under the point.
    public static func parseOne(_ data: Data) throws -> AccessibilityElement? {
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return nil }
        let raw: RawElement = try decode(data, command: "ui describe-point --json")
        return raw.element(at: nil)
    }

    private static func decode<T: Decodable>(_ data: Data, command: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProbeError.idbFailed(
                command: command,
                detail: "unreadable JSON: \(error.localizedDescription)"
            )
        }
    }

    /// The union of every frame, used when no application element was reported.
    ///
    /// Without it a screen height of zero would put every element in the bottom band; a
    /// bounding box is wrong only in the rare case where nothing reaches the screen edge.
    private static func bounds(of raw: [RawElement]) -> ElementFrame {
        let frames = raw.map(\.frame)
        let width = frames.map { $0.x + $0.width }.max() ?? 0
        let height = frames.map { $0.y + $0.height }.max() ?? 0
        return ElementFrame(
            x: 0, y: 0, width: Int(width.rounded()), height: Int(height.rounded()))
    }

    // Key names are idb's, not this codebase's, so they are spelled the way idb spells them.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    private struct RawElement: Decodable {
        let type: String?
        let AXLabel: String?
        let AXValue: String?
        let AXUniqueId: String?
        let enabled: Bool?
        let frame: RawFrame

        func element(at index: Int?) -> AccessibilityElement {
            AccessibilityElement(
                index: index,
                identifier: AXUniqueId.flatMap { $0.isEmpty ? nil : $0 },
                kind: ElementKind(idbType: type ?? ""),
                label: AccessibilityElement.truncate(
                    AXLabel.flatMap { $0.isEmpty ? nil : $0 } ?? AXValue ?? ""),
                frame: frame.rounded,
                isEnabled: enabled ?? true
            )
        }
    }

    private struct RawFrame: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var rounded: ElementFrame {
            ElementFrame(
                x: Int(x.rounded()),
                y: Int(y.rounded()),
                width: Int(width.rounded()),
                height: Int(height.rounded())
            )
        }
    }
}
