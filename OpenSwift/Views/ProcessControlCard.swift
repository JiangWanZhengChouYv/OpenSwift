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
