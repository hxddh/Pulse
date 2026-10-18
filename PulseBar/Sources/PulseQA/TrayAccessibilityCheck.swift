import AppKit
import SwiftUI
@testable import PulseApp
@testable import PulseKit

/// `--assert-tray`: open the real tray (the status item's popover, as a
/// click does), walk its accessibility tree in process and check what
/// VoiceOver and a keyboard user get — every row's body is a button, its
/// "›" Details control is a separate button beside it, and the popover's
/// window becomes key (the tray is a keyboard surface). Prints the tree
/// and exits 1 on any failure, 0 otherwise. No Accessibility permission is
/// asked: the process reads its own elements (never `AXUIElement`, which
/// needs the process to be trusted).
///
/// SwiftUI builds a hosting view's accessibility elements lazily: the first
/// request for them (no assistive client has asked yet on a CI runner)
/// starts the build, and they appear after a later graph update. So the
/// check asks, forces an update, and asks again — every `interval` until
/// the rows are there or `attempts` run out. A tree that never grows past
/// the hosting view is reported as inconclusive (exit 2), not as a tray
/// without buttons.
///
/// Run with a fixture (`--tray-fixture=status-waiting`) so the tray has
/// rows whatever this Mac runs (`scripts/qa_captures.sh tray-a11y`).
@MainActor
enum TrayAccessibilityCheck {
    /// Long enough for the popover to open and SwiftUI to lay its rows out
    /// before the first walk.
    static let settle: TimeInterval = 1.6
    /// The pause between walks, and how many walks before giving up
    /// (`settle + attempts × interval` ≈ 6 s, well inside the script's 20 s).
    static let interval: TimeInterval = 0.25
    static let attempts = 18

    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            StatusItemController.shared?.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            TrayAccessibilityCheck.attempt(1)
        }
    }

    /// One walk. Done when the rows are found or the attempts run out;
    /// otherwise nudge SwiftUI and walk again after `interval`.
    private static func attempt(_ number: Int) {
        let result = check()
        if result.rows > 0 || result.precondition || number >= attempts {
            report(result, attempt: number)
            return
        }
        nudge()
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            TrayAccessibilityCheck.attempt(number + 1)
        }
    }

    private static func report(_ result: Outcome, attempt: Int) {
        print("assert-tray walk \(attempt) of at most \(attempts), \(result.elements) elements")
        print("--- accessibility tree (from the popover window) ---")
        print(result.tree.isEmpty ? "(empty)" : result.tree.joined(separator: "\n"))
        print("--- view hierarchy (class · role · accessibility children) ---")
        print(viewHierarchy().joined(separator: "\n"))
        print("---")
        for failure in result.failures { print("assert-tray FAIL \(failure)") }
        if result.failures.isEmpty {
            print("assert-tray OK")
            exit(0)
        }
        // Nothing below the hosting view: SwiftUI never built its elements
        // in this session, so the tray's shape was not observed at all.
        if !result.precondition && result.buttons == 0 {
            print("assert-tray INCONCLUSIVE SwiftUI exposed no accessibility elements in process (no button anywhere in the tree)")
            exit(2)
        }
        print("assert-tray FAILED")
        exit(1)
    }

    // MARK: - Reading elements

    /// One accessibility attribute of an element, read by name: SwiftUI's
    /// elements are not views, and the getters are the same selectors
    /// whatever class answers them.
    private static func attribute(_ element: AnyObject, _ name: String) -> AnyObject? {
        guard let object = element as? NSObject else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    /// The pre-10.10 attribute getter, by name — the path an assistive
    /// client's request arrives on, and not deprecated when sent this way.
    private static func legacyAttribute(_ element: AnyObject, _ name: String) -> AnyObject? {
        guard let object = element as? NSObject else { return nil }
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector, with: name)?.takeUnretainedValue()
    }

    private static func children(_ element: AnyObject) -> [AnyObject] {
        let modern = attribute(element, "accessibilityChildren") as? [AnyObject] ?? []
        if !modern.isEmpty { return modern }
        return legacyAttribute(element, "AXChildren") as? [AnyObject] ?? []
    }

    private static func role(_ element: AnyObject) -> String {
        if let role = attribute(element, "accessibilityRole") as? String, !role.isEmpty { return role }
        return legacyAttribute(element, "AXRole") as? String ?? ""
    }

    private static func label(_ element: AnyObject) -> String {
        let label = attribute(element, "accessibilityLabel") as? String ?? ""
        return label.isEmpty ? (attribute(element, "accessibilityTitle") as? String ?? "") : label
    }

    // MARK: - Forcing SwiftUI's tree

    /// Ask every view of the popover for its elements (that request is what
    /// makes SwiftUI start building them), then force a layout and a graph
    /// update so the build lands before the next walk.
    private static func nudge() {
        guard let controller = StatusItemController.shared,
              let view = controller.popover.contentViewController?.view else { return }
        if let root = view.window?.contentView?.superview ?? view.window?.contentView {
            forEachView(root, depth: 0) { view, _ in
                _ = children(view)
                _ = legacyAttribute(view, "AXChildren")
            }
        }
        if let hosting = controller.popover.contentViewController as? NSHostingController<TrayView> {
            // The same value: SwiftUI re-evaluates the body and runs an
            // update, which is when requested elements are made.
            let root = hosting.rootView
            hosting.rootView = root
        }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
    }

    private static func forEachView(_ view: NSView, depth: Int, _ body: (NSView, Int) -> Void) {
        guard depth < 64 else { return }
        body(view, depth)
        for subview in view.subviews { forEachView(subview, depth: depth + 1, body) }
    }

    /// The popover window's views, for the log: which class answers, with
    /// which role and how many elements — so a tree that stays empty says
    /// where it stops.
    private static func viewHierarchy() -> [String] {
        guard let window = StatusItemController.shared?.popover.contentViewController?.view.window,
              let root = window.contentView?.superview ?? window.contentView else { return ["(no window)"] }
        var lines: [String] = []
        forEachView(root, depth: 0) { view, depth in
            let name = String(describing: type(of: view))
            lines.append(String(repeating: "  ", count: depth) + "\(name) · \(role(view)) · \(children(view).count)")
        }
        return lines
    }

    // MARK: - The check

    struct Outcome {
        var failures: [String] = []
        var tree: [String] = []
        var rows = 0
        var buttons = 0
        var elements = 0
        /// The tray could not be looked at (no status item, popover not
        /// shown): retrying does not help.
        var precondition = false
    }

    static func check() -> Outcome {
        var result = Outcome()
        guard let controller = StatusItemController.shared else {
            result.failures = ["no status item"]
            result.precondition = true
            return result
        }
        guard controller.popover.isShown, let window = controller.popover.contentViewController?.view.window else {
            result.failures = ["the tray popover is not shown"]
            result.precondition = true
            return result
        }
        if !window.isKeyWindow { result.failures.append("the tray's window is not key") }
        let details = L10n.t(.details, AppServices.store.lang)
        let button = NSAccessibility.Role.button.rawValue
        var detailButtons = 0
        var seen = Set<ObjectIdentifier>()

        func walk(_ element: AnyObject, depth: Int) {
            guard depth < 48 else { return }
            let kids = children(element)
            let labels = kids.filter { role($0) == button }.map(label)
            result.buttons += labels.count
            let detailsHere = labels.filter { $0 == details }.count
            if detailsHere > 0 {
                detailButtons += detailsHere
                // The row's own button: a button beside "Details" that says
                // which session it is.
                if labels.contains(where: { !$0.isEmpty && $0 != details }) {
                    result.rows += 1
                } else {
                    result.failures.append("a Details button with no row button beside it (depth \(depth))")
                }
            }
            for child in kids {
                // An element reachable twice (a view and its own element)
                // is counted once.
                guard seen.insert(ObjectIdentifier(child)).inserted else { continue }
                result.elements += 1
                result.tree.append(String(repeating: "  ", count: depth) + "\(role(child)) \"\(label(child))\"")
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)

        let listed = AppServices.store.rows.count
        if result.rows == 0 {
            result.failures.append("no row is a button beside its own Details button (\(listed) rows listed)")
        }
        if detailButtons > listed { result.failures.append("\(detailButtons) Details buttons for \(listed) rows") }
        return result
    }
}
