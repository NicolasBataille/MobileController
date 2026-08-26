import SwiftUI

/// DemoApp — a deterministic simulator-automation benchmark target.
///
/// No network access, no persistence, no personal data: every screen is derived
/// from constants in this bundle, so two runs on two machines render the same
/// pixels for the same sequence of taps.
@main
struct DemoAppApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

/// The tabs a bench flow can switch between. `rawValue` doubles as the
/// `TabView` selection tag, so the selected tab is inspectable from tests.
enum DemoTab: String, CaseIterable {
    case home
    case list
    case form

    var title: String {
        switch self {
        case .home: return "Home"
        case .list: return "List"
        case .form: return "Form"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .list: return "list.bullet"
        case .form: return "square.and.pencil"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .home: return AXID.tabHome
        case .list: return AXID.tabList
        case .form: return AXID.tabForm
        }
    }
}

struct RootTabView: View {
    @State private var selection: DemoTab = .home

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tag(DemoTab.home)
                .tabItem { tabLabel(for: .home) }

            ItemListView()
                .tag(DemoTab.list)
                .tabItem { tabLabel(for: .list) }

            FormView()
                .tag(DemoTab.form)
                .tabItem { tabLabel(for: .form) }
        }
    }

    private func tabLabel(for tab: DemoTab) -> some View {
        Label(tab.title, systemImage: tab.systemImage)
            .accessibilityIdentifier(tab.accessibilityIdentifier)
    }
}

#Preview {
    RootTabView()
}
