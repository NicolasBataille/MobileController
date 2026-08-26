import Foundation

/// Single source of truth for every accessibility identifier exposed by DemoApp.
///
/// These strings are a public contract: `bench/flows/demoapp-*.sh` and the skill
/// examples address the app exclusively through them. Renaming one is a breaking
/// change for the bench, so treat this file as API.
enum AXID {
    // Tab bar
    static let tabHome = "tabBar.home"
    static let tabList = "tabBar.list"
    static let tabForm = "tabBar.form"

    // Home
    static let homeRoot = "home.root"
    static let animateButton = "home.animateButton"
    static let animatedCard = "home.animatedCard"
    static let animationStateLabel = "home.animationStateLabel"
    static let microAnimationToggle = "home.microAnimationToggle"
    static let microAnimationDot = "home.microAnimationDot"

    // List
    static let listRoot = "list.root"
    /// Rows are 1-based: `list.row.1` … `list.row.40`.
    static func listRow(_ index: Int) -> String { "list.row.\(index)" }

    // Form
    static let formRoot = "form.root"
    static let textField = "form.textField"
    static let clearButton = "form.clearButton"
    static let echoLabel = "form.echoLabel"
    static let characterCountLabel = "form.characterCountLabel"
}
