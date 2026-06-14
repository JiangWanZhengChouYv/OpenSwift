import SwiftUI
import AppKit

struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @State private var isRecording: Bool = false
    @State private var localKeyCode: UInt32 = 0
    @State private var localModifiers: UInt32 = 0
    @State private var eventMonitor: Any?

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            hotkeyDisplay

            recordButton
        }
        .onAppear {
            localKeyCode = keyCode
            localModifiers = modifiers
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var hotkeyDisplay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isRecording ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            HStack(spacing: 4) {
                if isRecording {
                    Text("按下快捷键...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Text(HotkeyConfig.modifiersToString(localModifiers))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(hex: "FF9500"))

                    Text(HotkeyConfig.keyCodeToString(localKeyCode))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 120)
    }

    private var recordButton: some View {
        Button(action: {
            if isRecording {
                cancelRecording()
            } else {
                startRecording()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isRecording ? "xmark" : "pencil")
                    .font(.system(size: 10))
                Text(isRecording ? "取消" : "修改")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .foregroundColor(isRecording ? Color.red : Color.accentColor)
    }

    private func startRecording() {
        isRecording = true
        localKeyCode = keyCode
        localModifiers = modifiers

        let selfCopy = self
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            selfCopy.handleKeyEvent(event)
            return nil
        }

        logDebug("Started recording", log: .hotkey)
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
        logDebug("Stopped recording", log: .hotkey)
    }

    private func cancelRecording() {
        stopRecording()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags

        if keyCode == 53 {
            DispatchQueue.main.async {
                self.cancelRecording()
            }
            return
        }

        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let hasControl = flags.contains(.control)
        let hasShift = flags.contains(.shift)

        guard hasCommand || hasOption || hasControl || hasShift else {
            return
        }

        var newModifiers: UInt32 = 0
        if hasCommand {
            newModifiers |= UInt32(NSEvent.ModifierFlags.command.rawValue)
        }
        if hasOption {
            newModifiers |= UInt32(NSEvent.ModifierFlags.option.rawValue)
        }
        if hasControl {
            newModifiers |= UInt32(NSEvent.ModifierFlags.control.rawValue)
        }
        if hasShift {
            newModifiers |= UInt32(NSEvent.ModifierFlags.shift.rawValue)
        }

        DispatchQueue.main.async {
            self.localKeyCode = keyCode
            self.localModifiers = newModifiers
            self.keyCode = keyCode
            self.modifiers = newModifiers
            self.stopRecording()
        }
    }
}

struct HotkeyRecorderView_Previews: PreviewProvider {
    static var previews: some View {
        HotkeyRecorderView(
            keyCode: .constant(126),
            modifiers: .constant(UInt32(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue))
        )
        .padding()
        .frame(width: 300)
    }
}
