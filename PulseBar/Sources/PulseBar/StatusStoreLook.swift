import Foundation
import AppKit

/// The tray's open / close lifecycle. 23.0 removed "while you were away"
/// (look continuity, the resolved-wait history and the blue "new" dot): the
/// list itself is what changed.
extension StatusStore {
    func trayWillAppear() {
        traySessionToken &+= 1
        // Store-owned, and just as much "last time's rummaging" as the folds.
        if showAllAgents {
            showAllAgents = false
            applyRowWindow()
        }
    }

    /// Tray panel appeared — probe faster while the user is looking at it.
    func trayDidAppear() {
        trayOpen = true
        rescheduleTimer()
        if !previewFixtureActive {
            refresh(reason: "trayOpen")
        }
    }

    func trayDidDisappear() {
        trayOpen = false
        rescheduleTimer()
    }
}
