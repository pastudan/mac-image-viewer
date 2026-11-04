import AppKit
import LocalAuthentication
import Observation

/// Privacy: when the Mac locks, sleeps, starts the screen saver or switches user, the
/// current view is saved and then the canvas and strip are emptied. Nothing stays in
/// memory to be revealed. Getting it back is File > Restore Last View (Shift-Cmd-R),
/// which asks for Touch ID. On by default; Settings > Privacy turns it off.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    enum AuthResult: Equatable {
        case success
        case cancelled
        case failed(String)
    }

    private enum Key {
        static let clearOnLock = "privacy.clearOnLock"
        /// Settings from the earlier lock-screen design; removed on launch.
        static let legacy = ["lock.requireAuthAfterSleep", "lock.alsoWhenScreenLocks"]
    }

    /// Settings > Privacy: clear the canvas and strip when the Mac locks or sleeps.
    var clearOnLock: Bool {
        didSet { UserDefaults.standard.set(clearOnLock, forKey: Key.clearOnLock) }
    }

    /// When the canvas was last cleared for privacy (for the self-test and diagnostics).
    private(set) var lastClearedAt: Date?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// The system events that clear the canvas, as (centre, name) pairs.
    static var triggers: [(isDistributed: Bool, name: Notification.Name)] {
        [
            (false, NSWorkspace.willSleepNotification),
            (false, NSWorkspace.screensDidSleepNotification),
            (false, NSWorkspace.sessionDidResignActiveNotification),
            (true, Notification.Name("com.apple.screenIsLocked")),
            (true, Notification.Name("com.apple.screensaver.didstart")),
        ]
    }

    init() {
        let defaults = UserDefaults.standard
        for key in Key.legacy { defaults.removeObject(forKey: key) }
        clearOnLock = defaults.object(forKey: Key.clearOnLock) as? Bool ?? true
    }

    /// "Touch ID" on Macs that have it, otherwise "Password".
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Password"
    }

    // MARK: Watching for lock and sleep

    func startObserving() {
        guard observers.isEmpty else { return }
        for trigger in Self.triggers {
            let center: NotificationCenter = trigger.isDistributed
                ? DistributedNotificationCenter.default()
                : NSWorkspace.shared.notificationCenter
            let token = center.addObserver(forName: trigger.name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillHide() }
            }
            observers.append((center, token))
        }
    }

    var isObserving: Bool { observers.count == Self.triggers.count }

    /// The Mac is locking, sleeping or handing over to another user.
    func systemWillHide() {
        guard clearOnLock else { return }
        clearNow()
    }

    /// Saves the current view (so Restore Last View can bring it back behind Touch ID),
    /// then empties the canvas and closes the strip, dropping its folder and thumbnails.
    func clearNow() {
        LastView.shared.saveNow()
        CanvasModel.shared.removeAll()
        LayoutStore.shared.forgetCurrent()
        MediaStrip.shared.close()
        ThumbnailCache.shared.removeAll()
        lastClearedAt = Date()
    }

    // MARK: Authentication

    /// Touch ID, falling back to the account password (also used on Macs without Touch ID).
    static func systemAuthenticate(_ reason: String) async -> AuthResult {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password…"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .failed(error?.localizedDescription ?? "Authentication isn't available on this Mac.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? .success : .failed("Authentication failed.")
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
