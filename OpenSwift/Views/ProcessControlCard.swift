import SwiftUI
import AppKit

struct ProcessControlCard: View {
    let process: ProcessInfo
    @Binding var speed: Double
    @Binding var isEnabled: Bool
    let onRemove: () -> Void
    
    @State private var isHovering: Bool = false
    @State private var showRemoveConfirmation: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            
            Divider()
            
            speedControlSection
            
            Divider()
            
            footerSection
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovering ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .alert(isPresented: $showRemoveConfirmation) {
            Alert(
                title: Text("确认卸载"),
                message: Text("确定要从进程 \(process.name) 卸载速度控制吗？"),
                primaryButton: .destructive(Text("卸载")) {
                    onRemove()
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
            } else {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(process.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Text("PID: \(process.pid)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isEnabled)
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
                .scaleEffect(0.8)
        }
    }
    
    private var speedControlSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("当前速度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                SpeedIndicatorCompact(speed: speed, isEnabled: isEnabled)
            }
            
            Slider(value: $speed, in: 0.1...10.0, step: 0.1)
                .disabled(!isEnabled)
        }
    }
    
    private var footerSection: some View {
        HStack {
            Button(action: {
                speed = 1.0
            }) {
                Text("重置")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            
            Spacer()
            
            Button(action: {
                showRemoveConfirmation = true
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                    Text("卸载")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ProcessControlCard_Previews: PreviewProvider {
    static var previews: some View {
        ProcessControlCard(
            process: ProcessInfo(pid: 12345, name: "Test Application"),
            speed: .constant(1.5),
            isEnabled: .constant(true),
            onRemove: {}
        )
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Injected Process Card
struct InjectedProcessCard: View {
    let injected: InjectedProcess
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onSpeedChange: (Double) -> Void
    let onEnabledChange: (Bool) -> Void
    
    @State private var isHovering: Bool = false
    @State private var showRemoveConfirmation: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            
            if isSelected {
                Divider()
                speedControlSection
            }
            
            if !injected.isActive {
                Divider()
                terminatedBanner
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selectionStrokeColor, lineWidth: isSelected ? 2 : 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            onSelect()
        }
        .alert(isPresented: $showRemoveConfirmation) {
            Alert(
                title: Text("确认卸载"),
                message: Text("确定要从进程 \(injected.processInfo.name) 卸载速度控制吗？"),
                primaryButton: .destructive(Text("卸载")) {
                    onRemove()
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            if let icon = injected.processInfo.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
            } else {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(injected.processInfo.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    statusIndicator
                }
                
                HStack(spacing: 8) {
                    Text("PID: \(injected.pid)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Text("运行时间: \(injected.formattedRuntime)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { injected.isEnabled },
                set: { onEnabledChange($0) }
            ))
            .toggleStyle(SwitchToggleStyle())
            .labelsHidden()
            .scaleEffect(0.8)
            .disabled(!injected.isActive)
            
            Button(action: {
                showRemoveConfirmation = true
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            
            Text(injected.statusDescription)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(statusColor.opacity(0.1)))
    }
    
    private var statusColor: Color {
        if !injected.isActive {
            return Color.gray
        } else if injected.isEnabled {
            return Color(hex: "34C759")
        } else {
            return Color.orange
        }
    }
    
    private var selectionStrokeColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.5)
        } else if isHovering {
            return Color.accentColor.opacity(0.3)
        }
        return Color.clear
    }
    
    private var speedControlSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("当前速度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(injected.speedDescription)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(speedColor)
            }
            
            Slider(
                value: Binding(
                    get: { injected.speedRatio },
                    set: { onSpeedChange($0) }
                ),
                in: 0.1...10.0,
                step: 0.1
            )
            .disabled(!injected.isEnabled)
        }
    }
    
    private var terminatedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            
            Text("此进程已终止")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.orange)
            
            Spacer()
            
            Button(action: onRemove) {
                Text("清理")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }
    
    private var speedColor: Color {
        if injected.speedRatio < 0.9 {
            return Color(hex: "007AFF")
        } else if injected.speedRatio > 1.1 {
            return Color(hex: "FF9500")
        } else {
            return Color(hex: "34C759")
        }
    }
}
