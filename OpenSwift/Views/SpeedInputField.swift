import SwiftUI

struct SpeedInputField: View {
    @Binding var speed: Double
    let isEnabled: Bool
    let range: ClosedRange<Double> = 0.1...10.0
    
    @State private var inputText: String = ""
    @State private var isEditing: Bool = false
    
    var body: some View {
        HStack(spacing: 8) {
            Text("速度:")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 4) {
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 80)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isEnabled ? (isEditing ? Color(NSColor.controlBackgroundColor) : Color(NSColor.textBackgroundColor)) : Color(NSColor.controlBackgroundColor).opacity(0.3))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: isEnabled && isEditing ? 2 : 0)
                    )
                    .disabled(!isEnabled)
                    .onTapGesture {
                        guard isEnabled else { return }
                        isEditing = true
                        inputText = formatSpeedForInput(speed)
                    }
                    .onChange(of: inputText) { newValue in
                        guard isEnabled else { return }
                        validateAndUpdateSpeed(newValue)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SpeedInputSubmit"))) { _ in
                        guard isEnabled else { return }
                        commitInput()
                    }
                
                Text("x")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
                
                incrementButtons
            }
        }
        .onAppear {
            inputText = formatSpeedForInput(speed)
        }
        .onChange(of: speed) { newSpeed in
            if !isEditing {
                inputText = formatSpeedForInput(newSpeed)
            }
        }
        .opacity(isEnabled ? 1.0 : 0.5)
    }
    
    private var incrementButtons: some View {
        HStack(spacing: 4) {
            Button(action: {
                guard isEnabled else { return }
                incrementSpeed(0.1)
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .disabled(!isEnabled)
            
            Button(action: {
                guard isEnabled else { return }
                decrementSpeed(0.1)
            }) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .disabled(!isEnabled)
        }
    }
    
    private func formatSpeedForInput(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }
    
    private func validateAndUpdateSpeed(_ value: String) {
        guard !value.isEmpty else { return }
        
        if let parsedValue = Double(value) {
            let clampedValue = min(max(parsedValue, range.lowerBound), range.upperBound)
            
            if abs(clampedValue - parsedValue) < 0.001 {
                speed = clampedValue
            }
        }
    }
    
    private func commitInput() {
        isEditing = false
        
        if let parsedValue = Double(inputText) {
            let clampedValue = min(max(parsedValue, range.lowerBound), range.upperBound)
            speed = clampedValue
        } else {
            inputText = formatSpeedForInput(speed)
        }
    }
    
    private func incrementSpeed(_ amount: Double) {
        let newSpeed = min(speed + amount, range.upperBound)
        speed = newSpeed
    }
    
    private func decrementSpeed(_ amount: Double) {
        let newSpeed = max(speed - amount, range.lowerBound)
        speed = newSpeed
    }
}

struct SpeedInputField_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SpeedInputField(speed: .constant(1.5), isEnabled: true)
                .padding()
                .previewDisplayName("Enabled")
            
            SpeedInputField(speed: .constant(1.5), isEnabled: false)
                .padding()
                .previewDisplayName("Disabled")
        }
    }
}
