import SwiftUI

struct SpeedSliderView: View {
    @Binding var speed: Double
    let isEnabled: Bool
    let range: ClosedRange<Double> = 0.1...15.0
    
    // 拖动状态用 @GestureState：由 gesture 的 .updating 驱动，
    // 避免在 onChanged/onEnded 里给 @State 赋值（严格并发下会报 self immutable）。
    @GestureState private var isDragging: Bool = false
    
    private let tickMarks: [Double] = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0]

    /// 倍率采用对数刻度：低速区间拉开、高速区间压缩，刻度均匀且拖动平滑。
    private func fraction(for value: Double) -> Double {
        let lo = log(0.1)
        let hi = log(15.0)
        return (log(value) - lo) / (hi - lo)
    }

    private func value(for fraction: Double) -> Double {
        let lo = log(0.1)
        let hi = log(15.0)
        return exp(lo + fraction * (hi - lo))
    }
    
    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    trackFill()
                    
                    let progress = calculateProgress()
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isEnabled ? speedColor : Color.secondary.opacity(0.18))
                        .frame(width: geometry.size.width * progress, height: 8)
                        .opacity(isEnabled ? 1.0 : 0.3)
                    
                    Circle()
                        .fill(Color.white)
                        .overlay(
                            Circle()
                                .stroke(glassSliderStroke(), lineWidth: 1)
                        )
                        .frame(width: isDragging ? 20 : 16, height: isDragging ? 20 : 16)
                        .shadow(color: Color.black.opacity(isEnabled ? 0.2 : 0.1), radius: 2, x: 0, y: 1)
                        .offset(x: geometry.size.width * progress - (isDragging ? 10 : 8))
                        .opacity(isEnabled ? 1.0 : 0.5)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .updating($isDragging) { _, state, _ in
                                    state = isEnabled
                                }
                                .onChanged { drag in
                                    guard isEnabled else { return }

                                    let newProgress = drag.location.x / geometry.size.width
                                    let clampedProgress = min(max(newProgress, 0), 1)
                                    // 平滑拖动：按对数标尺取连续值，不做刻度吸附。
                                    let rawSpeed = value(for: clampedProgress)
                                    speed = min(max(rawSpeed, range.lowerBound), range.upperBound)
                                }
                        )
                }
            }
            .frame(height: 20)
            
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    // 按对数比例定位每个刻度，与拖动摇杆同标尺，保证刻度、标签与真实倍率位置对齐且不重叠。
                    ForEach(Array(tickMarks.enumerated()), id: \.element) { _, tick in
                        let fraction = fraction(for: tick)
                        let rawX = fraction * width
                        let clampedX = min(max(rawX, 16), width - 16)
                        VStack(spacing: 4) {
                            Rectangle()
                                .fill(tickColor(for: tick))
                                .frame(width: 2, height: 6)

                            Text(formatSpeed(tick))
                                .font(.system(size: 10))
                                .foregroundColor(tickColor(for: tick))
                        }
                        .position(x: clampedX, y: 14)
                    }
                }
            }
            .frame(height: 28)
        }
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
    
    /// 轨道背景：macOS 26+ 使用半透明玻璃/材质质感；更早系统保留不透明灰带（视觉零变化）。
    @ViewBuilder
    private func trackFill() -> some View {
        Group {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isEnabled ? Color.secondary.opacity(0.10) : Color.secondary.opacity(0.18).opacity(0.3))
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.ultraThinMaterial)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isEnabled ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.18).opacity(0.3))
            }
        }
        .frame(height: 8)
        .allowsHitTesting(false)
    }

    /// 滑块描边：macOS 26+ 加一圈细玻璃高亮边；更早系统为透明（零变化）。
    private func glassSliderStroke() -> some ShapeStyle {
        if #available(macOS 26.0, *) {
            return Color.white.opacity(0.55)
        } else {
            return Color.clear
        }
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
        return fraction(for: speed)
    }
    
    private func formatSpeed(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0fx", value)
        }
        return String(format: "%.1fx", value)
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
