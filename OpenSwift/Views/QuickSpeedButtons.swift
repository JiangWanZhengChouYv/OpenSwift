import SwiftUI

struct QuickSpeedButtons: View {
    @Binding var speed: Double
    let isEnabled: Bool
    
    private let presets: [(speed: Double, label: String)] = [
        (0.5, "0.5x"),
        (1.0, "1x"),
        (2.0, "2x"),
        (5.0, "5x"),
        (10.0, "10x"),
        (15.0, "15x")
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷设置")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 8) {
                ForEach(presets, id: \.speed) { preset in
                    Button(action: {
                        guard isEnabled else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            speed = preset.speed
                        }
                        provideHapticFeedback()
                    }) {
                        Text(preset.label)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 50, minHeight: 32)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(buttonBackground(for: preset))
                            .foregroundColor(buttonForegroundColor(for: preset))
                            .shadow(color: buttonShadowColor(for: preset), radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(isEnabled && isSelected(preset.speed) ? 1.05 : 1.0)
                    .disabled(!isEnabled)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: speed)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
    
    private func isSelected(_ presetSpeed: Double) -> Bool {
        return abs(speed - presetSpeed) < 0.05
    }
    
    private func selectedColor(for preset: Double) -> Color {
        if preset < 1.0 {
            return Color(hex: "007AFF")
        } else if preset > 1.0 {
            return Color(hex: "FF9500")
        } else {
            return Color(hex: "34C759")
        }
    }
    
    private func buttonBackground(for preset: (speed: Double, label: String)) -> Color {
        if !isEnabled {
            return Color(NSColor.controlBackgroundColor).opacity(0.3)
        }
        return isSelected(preset.speed) ? selectedColor(for: preset.speed) : Color(NSColor.controlBackgroundColor)
    }
    
    private func buttonForegroundColor(for preset: (speed: Double, label: String)) -> Color {
        if !isEnabled {
            return Color.secondary.opacity(0.5)
        }
        return isSelected(preset.speed) ? .white : .primary
    }
    
    private func buttonShadowColor(for preset: (speed: Double, label: String)) -> Color {
        guard isEnabled && isSelected(preset.speed) else {
            return Color.clear
        }
        return selectedColor(for: preset.speed).opacity(0.4)
    }
    
    private func provideHapticFeedback() {
    }
}

struct QuickSpeedButtons_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            QuickSpeedButtons(speed: .constant(1.0), isEnabled: true)
                .padding()
                .previewDisplayName("Enabled")
            
            QuickSpeedButtons(speed: .constant(1.0), isEnabled: false)
                .padding()
                .previewDisplayName("Disabled")
        }
    }
}
