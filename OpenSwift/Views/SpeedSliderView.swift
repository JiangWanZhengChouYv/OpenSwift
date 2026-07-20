import SwiftUI

struct SpeedSliderView: View {
    @Binding var speed: Double
    let isEnabled: Bool
    let range: ClosedRange<Double> = 0.1...10.0
    
    @State private var isDragging: Bool = false
    @State private var dragStartSpeed: Double = 1.0
    
    private let tickMarks: [Double] = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0]
    
    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isEnabled ? Color(NSColor.lightGray) : Color(NSColor.lightGray).opacity(0.3))
                        .frame(height: 8)
                    
                    let progress = calculateProgress()
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isEnabled ? speedColor : Color(NSColor.lightGray))
                        .frame(width: geometry.size.width * progress, height: 8)
                        .opacity(isEnabled ? 1.0 : 0.3)
                    
                    Circle()
                        .fill(Color.white)
                        .frame(width: isDragging ? 20 : 16, height: isDragging ? 20 : 16)
                        .shadow(color: Color.black.opacity(isEnabled ? 0.2 : 0.1), radius: 2, x: 0, y: 1)
                        .offset(x: geometry.size.width * progress - (isDragging ? 10 : 8))
                        .opacity(isEnabled ? 1.0 : 0.5)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard isEnabled else { return }
                                    if !isDragging {
                                        isDragging = true
                                        dragStartSpeed = speed
                                    }
                                    
                                    let newProgress = value.location.x / geometry.size.width
                                    let clampedProgress = min(max(newProgress, 0), 1)
                                    let rangeSpan = range.upperBound - range.lowerBound
                                    let newSpeed = range.lowerBound + clampedProgress * rangeSpan
                                    
                                    speed = snapToNearestTick(newSpeed)
                                }
                                .onEnded { _ in
                                    isDragging = false
                                }
                        )
                }
            }
            .frame(height: 20)
            
            HStack {
                ForEach(tickMarks, id: \.self) { tick in
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(tickColor(for: tick))
                            .frame(width: 2, height: 6)
                        
                        Text(formatSpeed(tick))
                            .font(.system(size: 10))
                            .foregroundColor(tickColor(for: tick))
                    }
                    
                    if tick != tickMarks.last {
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
    
    private var speedColor: Color {
        if speed < 0.9 {
            return Color(hex: "007AFF")
        } else if speed > 1.1 {
            return Color(hex: "FF9500")
        } else {
            return Color(hex: "34C759")
        }
    }
    
    private func calculateProgress() -> Double {
        return (speed - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
    
    private func snapToNearestTick(_ value: Double) -> Double {
        let closest = tickMarks.min(by: { abs($0 - value) < abs($1 - value) })
        if let tick = closest, abs(tick - value) < 0.15 {
            return tick
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }
    
    private func formatSpeed(_ value: Double) -> String {
        if value == 1.0 {
            return "1x"
        } else if value == range.lowerBound || value == range.upperBound {
            return String(format: "%.1fx", value)
        } else {
            return String(format: "%.1fx", value)
        }
    }
    
    private func tickColor(for tick: Double) -> Color {
        if abs(tick - speed) < 0.05 {
            return speedColor
        } else {
            return Color(NSColor.systemGray)
        }
    }
}

struct SpeedSliderView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SpeedSliderView(speed: .constant(1.0), isEnabled: true)
                .padding()
                .frame(width: 400)
                .previewDisplayName("Enabled")
            
            SpeedSliderView(speed: .constant(1.0), isEnabled: false)
                .padding()
                .frame(width: 400)
                .previewDisplayName("Disabled")
        }
    }
}
