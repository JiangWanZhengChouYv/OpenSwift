import SwiftUI
import AppKit

struct ContentView: View {
    @State private var isRunning = false
    @State private var startTime: Date?
    @State private var accumulatedTime: TimeInterval = 0
    @State private var displayedTime: TimeInterval = 0

    private let updateTimer = Timer.publish(every: 0.01, on: .main, in: .common)
        .autoconnect()

    private func formattedTime(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let milliseconds = Int((interval.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    var body: some View {
        VStack(spacing: 24) {
            Text(formattedTime(displayedTime))
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)

            HStack(spacing: 20) {
                Button(action: toggleTimer) {
                    Text(isRunning ? "暂停" : "开始")
                        .font(.title2)
                        .frame(width: 100, height: 40)
                }
                .keyboardShortcut(.space, modifiers: [])

                Button(action: resetTimer) {
                    Text("重置")
                        .font(.title2)
                        .frame(width: 100, height: 40)
                }
                .keyboardShortcut(.defaultAction)
            }

            Text("OpenSwift 速度控制测试")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(updateTimer) { _ in
            updateDisplayedTime()
        }
    }

    private func toggleTimer() {
        if isRunning {
            accumulatedTime += Date().timeIntervalSince(startTime!)
            isRunning = false
        } else {
            startTime = Date()
            isRunning = true
        }
    }

    private func resetTimer() {
        isRunning = false
        startTime = nil
        accumulatedTime = 0
        displayedTime = 0
    }

    private func updateDisplayedTime() {
        if isRunning, let start = startTime {
            displayedTime = accumulatedTime + Date().timeIntervalSince(start)
        }
    }
}
