import SwiftUI

/// Covers the canvas while the app is locked. Nothing from the canvas is drawn underneath.
struct LockScreenView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            CanvasView.lead
            VStack(spacing: 14) {
                Image(systemName: AppLock.methodName == "Touch ID" ? "touchid" : "lock.fill")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Image Canvas is locked")
                    .font(.title2.weight(.semibold))
                Text("Unlock to show your images again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Text(lock.isAuthenticating ? "Waiting…" : "Unlock with \(AppLock.methodName)")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(lock.isAuthenticating)
                if let message = lock.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(40)
        }
        .contentShape(Rectangle())
    }
}

/// Image Canvas > Settings… (Cmd-,).
struct SettingsView: View {
    @Bindable var lock: AppLock
    @Bindable var model: CanvasModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Trim picture edges up to")
                        Spacer()
                        Text("\(Int((model.maxCrop * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.maxCrop, in: 0...0.25, step: 0.01)
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Pictures are arranged to leave as little black space as possible. Trimming lets a picture grow slightly past its pane, cutting off a sliver of its edges to close the remaining gaps. 0% never trims. View > Crop to Fill Panes trims as much as needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Require \(AppLock.methodName) to show images after the Mac sleeps",
                       isOn: $lock.requireOnWake)
                Toggle("Also lock when the screen locks or the screen saver starts",
                       isOn: $lock.lockWithScreen)
                    .disabled(!lock.requireOnWake)
            } header: {
                Text("Privacy")
            } footer: {
                Text("While locked, the canvas is hidden and videos are paused. Your Mac password works if \(AppLock.methodName == "Touch ID" ? "Touch ID isn't accepted" : "this Mac has no Touch ID"). You can also lock right away with Image Canvas > Lock Now (Control-Command-L).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
