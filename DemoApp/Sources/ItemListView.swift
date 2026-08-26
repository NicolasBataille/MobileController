import SwiftUI

/// List tab — a dense but bounded accessibility tree to snapshot.
///
/// Exactly `DemoItemCatalog.count` (40) rows, each carrying a stable
/// `list.row.<n>` identifier with `n` 1-based, so a flow can scroll to and tap
/// any row by name without reading pixels.
struct ItemListView: View {
    private let items = DemoItemCatalog.items

    @State private var selectedNumber: Int?

    var body: some View {
        NavigationStack {
            List(items) { item in
                row(for: item)
            }
            .listStyle(.plain)
            .navigationTitle("List")
            .accessibilityIdentifier(AXID.listRoot)
        }
    }

    private func row(for item: DemoItem) -> some View {
        Button {
            selectedNumber = item.number
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbolName)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selectedNumber == item.number {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(item.accessibilityIdentifier)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.subtitle)
    }
}

#Preview {
    ItemListView()
}
