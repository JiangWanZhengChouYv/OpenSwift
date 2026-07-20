import SwiftUI
import AppKit

struct LaunchedProcessCard: View {
    let process: LaunchedProcess
    @ObservedObject var appLauncherViewModel: AppLauncherViewModel
    let onTerminate: (LaunchedProcess) -> Void
    let onForceTerminate: (LaunchedProcess) -> Void
    let onRemove: (LaunchedProcess) -> Void
    let onSelect: (LaunchedProcess) -> Void
    let isSelected: Bool
    
    @State private var showRemoveConfirmation = false
    @State private var isHovering = false
    @State private var currentSpeed: Double = 1.0
    @State private var isSpeedControlEnabled: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            
            if isSelected {
                Divider()
                detailsSection
            }
            
            if !process.isRunning {
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
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            onSelect(process)
        }
        .onAppear {
            currentSpeed = process.currentSpeed
            isSpeedControlEnabled = process.isSpeedControlEnabled
        }
        .alert(isPresented: $showRemoveConfirmation) {
            Alert(
                title: Text("确认移除"),
                message: Text("确定要从列表中移除 \(process.appName) 吗？"),
                primaryButton: .destructive(Text("移除")) {
                    onRemove(process)
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            if let icon = getAppIcon(for: process.appURL) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                    .frame(width: 40, height: 40)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(process.appName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    
                    statusIndicator
                    
                    launchMethodBadge
                    
                    if process.isSharedMemoryConnected {
                        sharedMemoryBadge
                    }
                }
                
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "number")
                            .font(.system(size: 10))
                        Text("PID: \(process.pid)")
                            .font(.system(size: 11))
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(process.formattedRuntime)
                            .font(.system(size: 11))
                    }
                }
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if process.isRunning {
                Menu {
                    Button(action: {
                        onTerminate(process)
                    }) {
                        Label("终止", systemImage: "stop.circle")
                    }
                    
                    Button(action: {
                        onForceTerminate(process)
                    }) {
                        Label("强制终止", systemImage: "exclamationmark.triangle")
                    }
                    
                    Divider()
                    
                    Button(action: {
                        showRemoveConfirmation = true
                    }) {
                        Label("从列表移除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
            } else {
                Button(action: {
                    showRemoveConfirmation = true
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            
            Text(process.isRunning ? "运行中" : "已停止")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.1))
        )
    }
    
    private var launchMethodBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "cube.box.fill")
                .font(.system(size: 8))
            
            Text("DYLD")
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.15))
        )
        .foregroundColor(.accentColor)
    }
    
    private var sharedMemoryBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "memorychip")
                .font(.system(size: 8))
            
            Text("已连接")
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color(hex: "34C759").opacity(0.15))
        )
        .foregroundColor(Color(hex: "34C759"))
    }
    
    private var statusColor: Color {
        if !process.isRunning {
            return Color.gray
        }
        return Color(hex: "34C759")
    }
    
    private var borderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.5)
        }
        return isHovering ? Color.accentColor.opacity(0.3) : Color.clear
    }
    
    private var borderWidth: CGFloat {
        return isSelected ? 2 : 1
    }
    
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("应用路径")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                
                Text(process.appURL.path)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            if process.isSharedMemoryConnected {
                Divider()
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("速度控制")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Toggle("", isOn: Binding(
                            get: { isSpeedControlEnabled },
                            set: { newValue in
                                isSpeedControlEnabled = newValue
                                appLauncherViewModel.toggleSpeedControl(newValue, for: process)
                            }
                        ))
                        .toggleStyle(SwitchToggleStyle())
                        .labelsHidden()
                        .scaleEffect(0.8)
                    }
                    
                    VStack(spacing: 6) {
                        HStack {
                            Text("速度")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Text("\(String(format: "%.1f", currentSpeed))x")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(speedColor)
                        }
                        
                        Slider(
                            value: Binding(
                                get: { currentSpeed },
                                set: { newValue in
                                    currentSpeed = newValue
                                    appLauncherViewModel.updateSpeed(newValue, for: process)
                                }
                            ),
                            in: 0.1...10.0,
                            step: 0.1
                        )
                        .disabled(!isSpeedControlEnabled)
                    }
                }
            }
        }
    }
    
    private var speedColor: Color {
        if currentSpeed < 0.9 {
            return Color(hex: "007AFF")
        } else if currentSpeed > 1.1 {
            return Color(hex: "FF9500")
        } else {
            return Color(hex: "34C759")
        }
    }
    
    private var terminatedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            
            Text("此进程已停止")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.orange)
            
            Spacer()
            
            Button(action: {
                onRemove(process)
            }) {
                Text("移除")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.1))
        )
    }
    
    private func getAppIcon(for url: URL) -> NSImage? {
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

#if DEBUG
struct LaunchedProcessCard_Previews: PreviewProvider {
    static var previews: some View {
        LaunchedProcessCard(
            process: LaunchedProcess(
                id: UUID(),
                pid: 1234,
                appURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                appName: "Safari",
                launchedAt: Date().addingTimeInterval(-3600),
                isRunning: true,
                currentSpeed: 1.0,
                isSpeedControlEnabled: false,
                isSharedMemoryConnected: true
            ),
            appLauncherViewModel: AppLauncherViewModel.shared,
            onTerminate: { _ in },
            onForceTerminate: { _ in },
            onRemove: { _ in },
            onSelect: { _ in },
            isSelected: true
        )
        .padding()
        .frame(width: 400)
    }
}
#endif
