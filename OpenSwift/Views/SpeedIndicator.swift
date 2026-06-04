import SwiftUI

struct SpeedIndicator: View {
    let speed: Double
    let isEnabled: Bool
    
    @State private var animatedSpeed: Double = 1.0
    @State private var pulseAnimation: Bool = false
    
    private let size: CGFloat = 150
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(NSColor.lightGray), lineWidth: 12)
                .frame(width: size, height: size)
            
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [speedColor.opacity(0.3), speedColor]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: animatedSpeed)
            
            if isEnabled {
                Circle()
                    .stroke(speedColor.opacity(0.3), lineWidth: 2)
                    .frame(width: size + 20, height: size + 20)
                    .scaleEffect(pulseAnimation ? 1.1 : 1.0)
                    .opacity(pulseAnimation ? 0 : 0.5)
                    .animation(
                        Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: false),
                        value: pulseAnimation
                    )
                    .onAppear {
                        pulseAnimation = true
                    }
            }
            
            VStack(spacing: 4) {
                Text(String(format: "%.1fx", animatedSpeed))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(speedColor)
                    .animation(.easeInOut(duration: 0.2), value: animatedSpeed)
                
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            animatedSpeed = speed
        }
        .onChange(of: speed) { newSpeed in
            withAnimation(.easeInOut(duration: 0.3)) {
                animatedSpeed = newSpeed
            }
        }
    }
    
    private var progress: Double {
        let range: ClosedRange<Double> = 0.1...10.0
        let normalized = (animatedSpeed - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(max(normalized, 0), 1)
    }
    
    private var speedColor: Color {
        if !isEnabled {
            return Color(NSColor.systemGray)
        }
        
        if animatedSpeed < 0.9 {
            return Color(hex: "007AFF")
        } else if animatedSpeed > 1.1 {
            return Color(hex: "FF9500")
        } else {
            return Color(hex: "34C759")
        }
    }
    
    private var statusText: String {
        if !isEnabled {
            return "已禁用"
        }
        
        if animatedSpeed < 0.9 {
            return "减速模式"
        } else if animatedSpeed > 1.1 {
            return "加速模式"
        } else {
            return "正常速度"
        }
    }
}

struct SpeedIndicatorCompact: View {
    let speed: Double
    let isEnabled: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isEnabled ? speedColor : Color(NSColor.systemGray))
                .frame(width: 10, height: 10)
            
            Text(String(format: "%.1fx", speed))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(isEnabled ? speedColor : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isEnabled ? speedColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        )
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
}

struct SpeedIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 40) {
            SpeedIndicator(speed: 0.5, isEnabled: true)
            SpeedIndicator(speed: 1.0, isEnabled: true)
            SpeedIndicator(speed: 2.0, isEnabled: true)
            SpeedIndicator(speed: 1.0, isEnabled: false)
            
            HStack(spacing: 20) {
                SpeedIndicatorCompact(speed: 0.5, isEnabled: true)
                SpeedIndicatorCompact(speed: 1.0, isEnabled: true)
                SpeedIndicatorCompact(speed: 2.0, isEnabled: true)
            }
        }
        .padding()
    }
}
