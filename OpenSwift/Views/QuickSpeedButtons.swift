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
            
            presetButtons
        }
        .animation(.easeInOut(duration: 0.2), value: speed)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
    
    /// 整组倍率按钮：macOS 26+ 用官方液态玻璃（GlassEffectContainer 包裹、相邻玻璃融合），更早系统回退 `.plain` + 原 background/shadow。
    @ViewBuilder
    private var presetButtons: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.speed) { preset in
                        liquidGlassPresetButton(for: preset)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ForEach(presets, id: \.speed) { preset in
                    legacyPresetButton(for: preset)
                }
            }
        }
    }
    
    /// macOS 26+ 玻璃按钮：选中态用 `tint` 玻璃强调，未选中用常规玻璃，禁用时弱化。
    @available(macOS 26.0, *)
    private func liquidGlassPresetButton(for preset: (speed: Double, label: String)) -> some View {
        Button(action: {
            handleTap(preset)
        }) {
            Text(preset.label)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 50, minHeight: 32)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundColor(buttonForegroundColor(for: preset))
                .modifier(
                    GlassTintEffect(
                        usesTint: isEnabled && isSelected(preset.speed),
                        tint: selectedColor(for: preset.speed)
                    )
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isEnabled && isSelected(preset.speed) ? 1.05 : 1.0)
        .disabled(!isEnabled)
    }
    
    /// 更早系统（<26）按钮：完整保持原 `.plain` + background/shadow 逻辑，外观零变化。
    @ViewBuilder
    private func legacyPresetButton(for preset: (speed: Double, label: String)) -> some View {
        Button(action: {
            handleTap(preset)
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
    
    /// macOS 26+ 液态玻璃效果修饰器：选中（且启用）用语义色 tint 强调，其余用常规玻璃；独立圆角形状供导入器融合。
    @available(macOS 26.0, *)
    private struct GlassTintEffect: ViewModifier {
        let usesTint: Bool
        let tint: Color
        
        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: Design.cornerRadiusSmall, style: .continuous)
            if usesTint {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        }
    }
    
    private func handleTap(_ preset: (speed: Double, label: String)) {
        guard isEnabled else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            speed = preset.speed
        }
        provideHapticFeedback()
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
