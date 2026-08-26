import Foundation

/// One row of the List tab.
///
/// Values are derived arithmetically from the row number — no dates, no random
/// numbers, no locale-dependent formatting — so the rendered list is byte-for-byte
/// the same on every machine, on every launch, forever.
struct DemoItem: Identifiable, Equatable {
    /// 1-based row number. Also the `<n>` in the `list.row.<n>` identifier.
    let number: Int
    let title: String
    let subtitle: String
    let symbolName: String

    var id: Int { number }

    var accessibilityIdentifier: String { AXID.listRow(number) }
}

enum DemoItemCatalog {
    /// Row count used by the bench as a dense-but-bounded accessibility tree.
    static let count = 40

    /// Deterministic, non-personal vocabulary. Index selection is `n % words.count`.
    private static let words = [
        "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf",
        "Hotel", "India", "Juliett", "Kilo", "Lima", "Mike",
    ]

    private static let symbols = [
        "circle", "square", "triangle", "diamond", "hexagon",
    ]

    private static let categories = ["Stable", "Pending", "Archived", "Draft"]

    /// The full, fixed list of rows: numbers 1 through `count`, inclusive.
    static let items: [DemoItem] = (1...count).map(makeItem)

    static func makeItem(number: Int) -> DemoItem {
        let word = words[(number - 1) % words.count]
        let category = categories[(number - 1) % categories.count]
        let symbol = symbols[(number - 1) % symbols.count]
        let padded = String(format: "%02d", number)
        return DemoItem(
            number: number,
            title: "Row \(padded) \(word)",
            subtitle: "\(category) / value \(number * 7 % 100)",
            symbolName: symbol
        )
    }
}
