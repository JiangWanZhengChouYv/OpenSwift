import SwiftUI

struct SpeedToggle: View {
    @Binding var isEnabled: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isEnabled)
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
                .scaleEffect(1.1)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isEnabled ? "已启用" : "已禁用")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isEnabled ? Color(hex: "34C759") : .secondary)
                
                Text(isEnabled ? "速度控制已激活" : "点击启用速度控制")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            statusIndicator
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .animation(.easeInOut(duration: 0.3), value: isEnabled)
    }
    
    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isEnabled ? Color(hex: "34C759") : Color(NSColor.systemGray))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(isEnabled ? Color(hex: "34C759") : Color(NSColor.systemGray))
                        .frame(width: 8, height: 8)
                        .opacity(isEnabled ? 1 : 0.5)
                        .scaleEffect(isEnabled ? 1.2 : 1.0)
                        .animation(
                            isEnabled ? 
                                Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true) : 
                                .default,
                            value: isEnabled
                        )
                )
            
            Text(isEnabled ? "运行中" : "停止")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isEnabled ? Color(hex: "34C759") : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isEnabled ? Color(hex: "34C759").opacity(0.1) : Color(NSColor.controlBackgroundColor))
        )
    }
}

struct SpeedToggle_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            SpeedToggle(isEnabled: .constant(false))
            SpeedToggle(isEnabled: .constant(true))
        }
        .padding()
    }
}
