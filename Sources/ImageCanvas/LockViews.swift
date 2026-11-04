import SwiftUI

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
                Toggle("Clear the canvas and strip when the Mac locks or sleeps", isOn: $lock.clearOnLock)
            } header: {
                Text("Privacy")
            } footer: {
                Text("When you lock the screen, close the lid, start the screen saver or the Mac sleeps, Image Canvas saves what was open and then empties the window. Bring it back with File > Restore Last View (Shift-Command-R), which asks for \(AppLock.methodName). You can also clear right away with Image Canvas > Clear for Privacy (Control-Command-L).")
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
