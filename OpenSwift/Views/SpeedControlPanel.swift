import SwiftUI

struct SpeedControlPanel: View {
    @ObservedObject var speedControlState: SpeedControlState
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var appLauncherViewModel: AppLauncherViewModel
    
    @Binding var selectedTab: Int
    
    @State private var showProcessList: Bool = true
    @State private var showGroupManager: Bool = false
    @State private var showSettings: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            toolbarSection
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    // 只显示已启动进程，Mach 注入代码保留但隐藏
                    launchedProcessesView
                }
                .padding()
            }
            
            Divider()
            
            statusBarSection
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    @ViewBuilder
    private var injectedProcessesView: some View {
        if let selectedProcess = speedControlState.selectedProcess {
            selectedProcessHeader(selectedProcess)
            
            mainControlSection
            
            batchOperationsSection
            
            processCardsSection
        } else {
            emptyStateView
        }
    }
    
    @ViewBuilder
    private var launchedProcessesView: some View {
        if let selectedProcess = appLauncherViewModel.selectedLaunchedProcess {
            launchedProcessHeader(selectedProcess)
            
            launchedProcessControlSection
            
            launchedProcessCardsSection
        } else if appLauncherViewModel.launchedProcesses.isEmpty {
            launchedProcessEmptyView
        } else {
            launchedProcessCardsSection
        }
    }
    
    private var toolbarSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("速度控制")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                // 暂时只显示"已启动"标签页，Mach 注入代码保留但隐藏
                Text("已启动")
                    .font(.system(size: 14, weight: .semibold))
                
                Spacer()
                
                // 只显示已启动进程相关的操作按钮
                Button(action: {
                    appLauncherViewModel.refreshLaunchedProcesses()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("刷新已启动进程")
                
                Button(action: {
                    showSettings = true
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("设置")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .sheet(isPresented: $showGroupManager) {
            GroupManagerView(processManager: processManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onDismiss: {
                showSettings = false
            })
        }
    }
    
    private func selectedProcessHeader(_ process: ProcessInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if let icon = process.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .cornerRadius(12)
                } else {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .cornerRadius(12)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(process.name)
                        .font(.system(size: 18, weight: .bold))
                    
                    HStack(spacing: 12) {
                        Label("PID: \(process.pid)", systemImage: "number")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        if let bundleId = process.bundleIdentifier {
                            Label(bundleId, systemImage: "app.badge")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                
                Spacer()
                
                SpeedIndicator(
                    speed: speedControlState.currentSpeed,
                    isEnabled: speedControlState.isEnabled
                )
            }
            
            if let path = process.path {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private var mainControlSection: some View {
        VStack(spacing: 16) {
            SpeedToggle(isEnabled: $speedControlState.isEnabled)
            
            SpeedInputField(speed: $speedControlState.currentSpeed, isEnabled: speedControlState.isEnabled)
            
            QuickSpeedButtons(speed: $speedControlState.currentSpeed, isEnabled: speedControlState.isEnabled)
            
            SpeedSliderView(speed: $speedControlState.currentSpeed, isEnabled: speedControlState.isEnabled)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private var batchOperationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("批量操作")
                    .font(.system(size: 14, weight: .semibold))
                
                Spacer()
                
                if processManager.injectedProcesses.count > 0 {
                    Text("\(processManager.injectedProcesses.filter { $0.isActive }.count) 个活跃进程")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }
            }
            
            HStack(spacing: 12) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        processManager.enableAllProcesses()
                    }
                    provideHapticFeedback()
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("启用全部")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(processManager.injectedProcesses.isEmpty)
                
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        processManager.disableAllProcesses()
                    }
                    provideHapticFeedback()
                }) {
                    HStack {
                        Image(systemName: "pause.fill")
                        Text("禁用全部")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(processManager.injectedProcesses.isEmpty)
                
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        processManager.setSpeedForAllProcesses(1.0)
                    }
                    provideHapticFeedback()
                }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重置全部")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(processManager.injectedProcesses.isEmpty)
                
                Spacer()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .animation(.easeInOut(duration: 0.2), value: processManager.injectedProcesses.count)
    }
    
    private var processCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已注入进程")
                    .font(.system(size: 14, weight: .semibold))
                
                Spacer()
                
                if !processManager.injectedProcesses.isEmpty {
                    Button(action: {
                        cleanupInactiveProcesses()
                    }) {
                        Text("清理已终止")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if processManager.injectedProcesses.isEmpty {
                emptyProcessesView
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(processManager.injectedProcesses) { injected in
                        InjectedProcessCard(
                            injected: injected,
                            isSelected: speedControlState.selectedProcess?.pid == injected.pid,
                            onSelect: {
                                speedControlState.selectedProcess = injected.processInfo
                                processManager.selectProcess(injected.processInfo)
                            },
                            onRemove: {
                                processManager.removeInjectedProcess(injected)
                            },
                            onSpeedChange: { speed in
                                processManager.updateInjectedProcess(pid: injected.pid, speedRatio: speed)
                            },
                            onEnabledChange: { enabled in
                                processManager.updateInjectedProcess(pid: injected.pid, isEnabled: enabled)
                            }
                        )
                    }
                }
            }
        }
    }
    
    private var emptyProcessesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            
            Text("暂无已注入的进程")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            
            Text("选择一个进程并注入 SpeedPatch")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "speedometer")
                .font(.system(size: 80))
                .foregroundColor(.secondary)
            
            Text("未选择进程")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.secondary)
            
            Text("请从左侧进程列表中选择一个进程\n以开始速度控制")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }
    

    
    private func cleanupInactiveProcesses() {
        let inactiveProcesses = processManager.injectedProcesses.filter { !$0.isActive }
        for inactive in inactiveProcesses {
            processManager.removeInjectedProcess(inactive)
        }
    }
    
    private func provideHapticFeedback() {
        // Haptic feedback is not available on macOS
        // This is a placeholder for future macOS haptic support
    }
}

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
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.5) : (isHovering ? Color.accentColor.opacity(0.3) : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
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
        .background(
            Capsule()
                .fill(statusColor.opacity(0.1))
        )
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
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.1))
        )
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

struct GroupManagerView: View {
    @ObservedObject var processManager: ProcessManager
    @State private var newGroupName: String = ""
    @State private var showNewGroupDialog: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("进程组管理")
                    .font(.system(size: 18, weight: .bold))
                
                Spacer()
                
                Button(action: {
                    showNewGroupDialog = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            if processManager.processGroups.isEmpty {
                emptyGroupsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(processManager.processGroups) { group in
                            GroupCard(
                                group: group,
                                onApply: {
                                    processManager.applyGroup(group)
                                },
                                onDelete: {
                                    processManager.deleteGroup(group)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
            
            Spacer()
        }
        .frame(width: 500, height: 400)
        .alert(isPresented: $showNewGroupDialog) {
            Alert(
                title: Text("创建新进程组"),
                message: Text("输入新进程组的名称"),
                primaryButton: .default(Text("创建")) {
                    if !newGroupName.isEmpty {
                        _ = processManager.createGroup(
                            name: newGroupName,
                            processes: processManager.injectedProcesses
                        )
                        newGroupName = ""
                    }
                },
                secondaryButton: .cancel() {
                    newGroupName = ""
                }
            )
        }
    }
    
    private var emptyGroupsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("暂无进程组")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
            
            Text("点击 + 按钮创建新的进程组")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GroupCard: View {
    let group: ProcessGroup
    let onApply: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.system(size: 14, weight: .semibold))
                
                Text("\(group.processCount) 个进程")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onApply) {
                Text("应用")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(group.processCount == 0)
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - Launched Process Components
extension SpeedControlPanel {
    private func launchedProcessHeader(_ process: LaunchedProcess) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if let icon = getAppIcon(for: process.appURL) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .cornerRadius(12)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                        .frame(width: 56, height: 56)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(process.appName)
                        .font(.system(size: 18, weight: .bold))
                    
                    HStack(spacing: 12) {
                        Label("PID: \(process.pid)", systemImage: "number")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        Label("DYLD 注入", systemImage: "cube.box.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                        
                        if process.isSharedMemoryConnected {
                            Label("已连接", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "34C759"))
                        }
                    }
                }
                
                Spacer()
                
                SpeedIndicator(
                    speed: process.currentSpeed,
                    isEnabled: process.isSpeedControlEnabled
                )
            }
            
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text(process.appURL.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private var launchedProcessControlSection: some View {
        VStack(spacing: 16) {
            if let process = appLauncherViewModel.selectedLaunchedProcess, 
               let index = appLauncherViewModel.launchedProcesses.firstIndex(where: { $0.id == process.id }) {
                
                let currentProcess = appLauncherViewModel.launchedProcesses[index]
                
                SpeedToggle(isEnabled: Binding(
                    get: { currentProcess.isSpeedControlEnabled },
                    set: { newValue in
                        appLauncherViewModel.toggleSpeedControl(newValue, for: currentProcess)
                    }
                ))
                
                SpeedInputField(
                    speed: Binding(
                        get: { currentProcess.currentSpeed },
                        set: { newValue in
                            appLauncherViewModel.updateSpeed(newValue, for: currentProcess)
                        }
                    ),
                    isEnabled: currentProcess.isSpeedControlEnabled
                )
                
                QuickSpeedButtons(
                    speed: Binding(
                        get: { currentProcess.currentSpeed },
                        set: { newValue in
                            appLauncherViewModel.updateSpeed(newValue, for: currentProcess)
                        }
                    ),
                    isEnabled: currentProcess.isSpeedControlEnabled
                )
                
                SpeedSliderView(
                    speed: Binding(
                        get: { currentProcess.currentSpeed },
                        set: { newValue in
                            appLauncherViewModel.updateSpeed(newValue, for: currentProcess)
                        }
                    ),
                    isEnabled: currentProcess.isSpeedControlEnabled
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private var launchedProcessCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已启动的应用")
                    .font(.system(size: 14, weight: .semibold))
                
                Spacer()
                
                if !appLauncherViewModel.launchedProcesses.isEmpty {
                    Button(action: {
                        appLauncherViewModel.cleanupTerminatedProcesses()
                    }) {
                        Text("清理已停止")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if appLauncherViewModel.launchedProcesses.isEmpty {
                launchedProcessEmptyView
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(appLauncherViewModel.launchedProcesses) { process in
                        LaunchedProcessCard(
                            process: process,
                            appLauncherViewModel: appLauncherViewModel,
                            onTerminate: { proc in
                                appLauncherViewModel.terminateProcess(proc)
                            },
                            onForceTerminate: { proc in
                                appLauncherViewModel.forceTerminateProcess(proc)
                            },
                            onRemove: { proc in
                                appLauncherViewModel.removeProcess(proc)
                                if appLauncherViewModel.selectedLaunchedProcess?.id == proc.id {
                                    appLauncherViewModel.disconnectFromProcess()
                                }
                            },
                            onSelect: { proc in
                                appLauncherViewModel.selectProcess(proc)
                            },
                            isSelected: appLauncherViewModel.selectedLaunchedProcess?.id == process.id
                        )
                    }
                }
            }
        }
    }
    
    private var launchedProcessEmptyView: some View {
        VStack(spacing: 20) {
            Spacer()
                .frame(height: 60)
            
            Image(systemName: "play.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("还没有已启动的应用")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
            
            Text("从左侧进程列表中选择应用\n然后点击\"DYLD 重启\"按钮启动加速")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    private func getAppIcon(for url: URL) -> NSImage? {
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Status Bar Update
extension SpeedControlPanel {
    private var statusBarSection: some View {
        HStack(spacing: 16) {
            // 只显示 DYLD 模式相关信息
            HStack(spacing: 6) {
                Circle()
                    .fill(appLauncherViewModel.launchedProcesses.contains { $0.isRunning } ? Color(hex: "34C759") : Color(NSColor.systemGray))
                    .frame(width: 8, height: 8)
                
                Text("DYLD 模式")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Divider()
                .frame(height: 12)
            
            HStack(spacing: 6) {
                Image(systemName: "app.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text("已启动: \(appLauncherViewModel.launchedProcesses.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if HotkeyService.shared.isEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "34C759"))
                    
                    Text("快捷键")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                    .frame(height: 12)
            }
            
            if appLauncherViewModel.launchedProcesses.count > 0 {
                HStack(spacing: 4) {
                    Text("运行中:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Text("\(appLauncherViewModel.launchedProcesses.filter { $0.isRunning }.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "34C759"))
                }
            }
            
            Spacer()
            
            Text("OpenSwift v1.0")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct SpeedControlPanel_Previews: PreviewProvider {
    static var previews: some View {
        SpeedControlPanel(
            speedControlState: SpeedControlState.shared,
            processManager: ProcessManager(),
            appLauncherViewModel: AppLauncherViewModel.shared,
            selectedTab: .constant(0)
        )
        .frame(width: 600, height: 800)
    }
}
