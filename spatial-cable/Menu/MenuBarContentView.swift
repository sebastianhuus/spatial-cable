import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var processController: AudioProcessController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appDelegate.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Menu("Source: \(sourceLabel)") {
                Button {
                    appDelegate.selectAllSystemAudio()
                } label: {
                    checkmarkLabel("All System Audio", isSelected: appDelegate.relaySource == .allSystemAudio)
                }

                Divider()

                if processController.processes.isEmpty {
                    Text("No audio-capable processes found")
                }
                ForEach(processController.processes) { process in
                    Button {
                        appDelegate.selectProcess(process)
                    } label: {
                        checkmarkLabel(process.name, isSelected: appDelegate.relaySource == .process(process))
                    }
                }
            }

            Menu("Output: \(appDelegate.selectedOutputDevice?.name ?? "None")") {
                if appDelegate.outputDevices.isEmpty {
                    Text("No output devices found")
                }
                ForEach(appDelegate.outputDevices) { device in
                    Button {
                        appDelegate.selectOutputDevice(device)
                    } label: {
                        checkmarkLabel(device.name, isSelected: device.uid == appDelegate.selectedOutputDevice?.uid)
                    }
                }
            }

            Divider()

            Button(appDelegate.isRelaying ? "Stop Relaying" : "Start Relaying") {
                appDelegate.toggleRelay()
            }
            .disabled(appDelegate.relaySource == nil || appDelegate.selectedOutputDevice == nil)

            Button("Refresh Devices") {
                appDelegate.refreshOutputDevices()
                processController.refresh()
            }

            Divider()

            Button("Quit spatial-cable") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    private var sourceLabel: String {
        switch appDelegate.relaySource {
        case .process(let process):
            return process.name
        case .allSystemAudio:
            return "All System Audio"
        case nil:
            return "None"
        }
    }

    /// Menu items rendered via SwiftUI's `Menu`/`Button` don't get the native checkmark
    /// styling automatically, and device/process names can collide (two "AirPods Pro"
    /// entries, several helper processes with the same name) — so selection state needs to
    /// be visible on the item itself, not inferred from the label text.
    @ViewBuilder
    private func checkmarkLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
