import AppKit
@testable import PulseApp
@testable import PulseKit

/// `--assert-tray`: open the real tray (the status item's popover, as a
/// click does), walk its accessibility tree in process and check what
/// VoiceOver and a keyboard user get — every row's body is a button, its
/// "›" Details control is a separate button beside it, and the popover's
/// window becomes key (the tray is a keyboard surface). Prints the tree
/// and exits 1 on any failure, 0 otherwise. No Accessibility permission is
/// asked: the process reads its own elements.
///
/// Run with a fixture (`--tray-fixture=status-waiting`) so the tray has
/// rows whatever this Mac runs (`scripts/qa_captures.sh tray-a11y`).
@MainActor
enum TrayAccessibilityCheck {
    /// Long enough for the popover to open and SwiftUI to lay its rows out.
    static let settle: TimeInterval = 2.5

    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            StatusItemController.shared?.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            let (failures, tree) = TrayAccessibilityCheck.check()
            print(tree.joined(separator: "\n"))
            for failure in failures { print("assert-tray FAIL \(failure)") }
            print(failures.isEmpty ? "assert-tray OK" : "assert-tray FAILED")
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    /// One accessibility attribute of an element, read by name: SwiftUI's
    /// elements are not views, and the getters are the same selectors
    /// whatever class answers them.
    private static func attribute(_ element: AnyObject, _ name: String) -> AnyObject? {
        guard let object = element as? NSObject else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func role(_ element: AnyObject) -> String {
        attribute(element, "accessibilityRole") as? String ?? ""
    }

    private static func label(_ element: AnyObject) -> String {
        let label = attribute(element, "accessibilityLabel") as? String ?? ""
        return label.isEmpty ? (attribute(element, "accessibilityTitle") as? String ?? "") : label
    }

    static func check() -> (failures: [String], tree: [String]) {
        guard let controller = StatusItemController.shared else { return (["no status item"], []) }
        guard controller.popover.isShown, let window = controller.popover.contentViewController?.view.window else {
            return (["the tray popover is not shown"], [])
        }
        var failures: [String] = []
        if !window.isKeyWindow { failures.append("the tray's window is not key") }
        let details = L10n.t(.details, AppServices.store.lang)
        let button = NSAccessibility.Role.button.rawValue
        var tree: [String] = []
        var rows = 0
        var detailButtons = 0

        func walk(_ element: AnyObject, depth: Int) {
            guard depth < 48 else { return }
            let children = attribute(element, "accessibilityChildren") as? [AnyObject] ?? []
            let labels = children.filter { role($0) == button }.map(label)
            let detailsHere = labels.filter { $0 == details }.count
            if detailsHere > 0 {
                detailButtons += detailsHere
                // The row's own button: a button beside "Details" that says
                // which session it is.
                if labels.contains(where: { !$0.isEmpty && $0 != details }) {
                    rows += 1
                } else {
                    failures.append("a Details button with no row button beside it (depth \(depth))")
                }
            }
            for child in children {
                tree.append(String(repeating: "  ", count: depth) + "\(role(child)) \"\(label(child))\"")
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)

        let listed = AppServices.store.rows.count
        if rows == 0 { failures.append("no row is a button beside its own Details button (\(listed) rows listed)") }
        if detailButtons > listed { failures.append("\(detailButtons) Details buttons for \(listed) rows") }
        return (failures, tree)
    }
}
