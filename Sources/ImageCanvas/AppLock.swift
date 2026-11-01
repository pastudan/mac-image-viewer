import AppKit
import LocalAuthentication
import Observation

/// Optional privacy lock: when the Mac sleeps (and, optionally, when the screen locks or the
/// screen saver starts), the canvas is hidden and videos pause until the user unlocks with
/// Touch ID, or their Mac password as a fallback.
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
        static let requireOnWake = "lock.requireAuthAfterSleep"
        static let lockWithScreen = "lock.alsoWhenScreenLocks"
    }

    /// Settings > Require Touch ID after sleep. Off by default.
    var requireOnWake: Bool {
        didSet { UserDefaults.standard.set(requireOnWake, forKey: Key.requireOnWake) }
    }

    /// Also lock when the screen locks or the screen saver starts. On by default once the
    /// main setting is on, because closing the lid often locks the screen without a full sleep.
    var lockWithScreen: Bool {
        didSet { UserDefaults.standard.set(lockWithScreen, forKey: Key.lockWithScreen) }
    }

    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    private(set) var message: String?

    /// Replaceable for the self-test, which can't put a finger on the sensor.
    var authenticator: (String) async -> AuthResult = AppLock.systemAuthenticate
    /// Only prompt when Image Canvas is the app in front; replaceable for the self-test,
    /// which is launched from a shell and may not be allowed to come to the front.
    var isFrontmost: () -> Bool = { NSApp.isActive }

    private var suspendedVideos: Set<UUID> = []
    /// Prompt automatically once per lock. After a cancel, the app becoming active again
    /// (which happens when the system prompt closes) must not pop the prompt straight back up.
    private var autoPromptArmed = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let defaults = UserDefaults.standard
        requireOnWake = defaults.bool(forKey: Key.requireOnWake)
        lockWithScreen = defaults.object(forKey: Key.lockWithScreen) as? Bool ?? true
    }

    /// "Touch ID" on Macs that have it, otherwise "Password".
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Password"
    }

    // MARK: Watching for sleep

    func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        // Going to sleep: lock before the display goes dark so nothing shows on wake.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { $0.lockIfEnabled(screenEvent: false) }
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observe(distributed, Notification.Name(name)) { $0.lockIfEnabled(screenEvent: true) }
        }

        // Waking up: offer Touch ID straight away if the app is in front.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.promptIfFrontmost() }
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.promptIfFrontmost() }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { $0.promptIfFrontmost() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (AppLock) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func lockIfEnabled(screenEvent: Bool) {
        guard requireOnWake, !screenEvent || lockWithScreen else { return }
        lock()
    }

    // MARK: Locking

    /// Hides the canvas and pauses every playing video.
    func lock() {
        guard !isLocked else { return }
        let model = CanvasModel.shared
        isLocked = true // first, so nothing below can restart playback
        model.endScrub()
        model.hoveredID = nil
        for tile in model.tiles.values {
            guard let video = tile.video else { continue }
            video.suspend()
            suspendedVideos.insert(tile.id)
        }
        message = nil
        autoPromptArmed = true
    }

    /// A video that finished loading while locked must not play behind the lock screen.
    func didLoad(_ video: LoopingVideo, id: UUID) {
        guard isLocked else { return }
        video.suspend()
        suspendedVideos.insert(id)
    }

    func promptIfFrontmost() {
        guard isLocked, autoPromptArmed, isFrontmost(), !isAuthenticating else { return }
        autoPromptArmed = false
        // Give the window a moment to come forward so the prompt attaches to it.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await unlock()
        }
    }

    /// Asks for Touch ID (or the password) and reveals the canvas on success.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        message = nil
        let result = await authenticator("show your images again")
        isAuthenticating = false
        switch result {
        case .success:
            isLocked = false
            let model = CanvasModel.shared
            for id in suspendedVideos { model.tiles[id]?.video?.resume() }
            suspendedVideos.removeAll()
        case .cancelled:
            message = nil
        case .failed(let reason):
            message = reason
        }
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
