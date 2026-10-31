import AppKit
import UniformTypeIdentifiers

/// Registers Image Canvas as the default app for common image types.
@MainActor
enum DefaultHandler {
    static let types: [UTType] = [
        .jpeg, .png, .heic, .heif, .gif, .webP, .tiff, .bmp,
    ]

    private static let promptedKey = "didOfferDefaultViewer"

    /// True when every supported type already opens in this app.
    static var isDefault: Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL
        return types.allSatisfy {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL == me
        }
    }

    /// macOS may ask the user to confirm each change; that dialog is the system's, not ours.
    static func makeDefault() {
        let app = Bundle.main.bundleURL
        Task {
            var failures: [String] = []
            for type in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                } catch {
                    failures.append("\(type.preferredFilenameExtension ?? type.identifier): \(error.localizedDescription)")
                }
            }
            let alert = NSAlert()
            if failures.isEmpty {
                alert.messageText = "Image Canvas is now your default image viewer"
                alert.informativeText = "Double-clicking a JPEG, PNG, HEIC, GIF, WebP, TIFF or BMP in Finder will add it to the canvas."
            } else {
                alert.alertStyle = .warning
                alert.messageText = "Some file types could not be changed"
                alert.informativeText = failures.joined(separator: "\n")
                    + "\n\nYou can also do this in Finder: Get Info on an image > Open with > Image Canvas > Change All."
            }
            alert.runModal()
        }
    }

    /// Offers to become the default viewer once, the first time the app runs.
    static func offerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: promptedKey) else { return }
        defaults.set(true, forKey: promptedKey)
        // Running from `swift run` (no .app bundle) can't be registered as a handler.
        guard Bundle.main.bundleURL.pathExtension == "app", !isDefault else { return }

        let alert = NSAlert()
        alert.messageText = "Make Image Canvas your default image viewer?"
        alert.informativeText = "Images you double-click in Finder will open here and be added to the canvas. You can change this later from the Image Canvas menu."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            makeDefault()
        }
    }
}
