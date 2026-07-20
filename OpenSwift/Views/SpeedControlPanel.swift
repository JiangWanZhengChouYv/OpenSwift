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
    
}
// MARK: - Launched Process Components
extension SpeedControlPanel {
    private func launchedProcessHeader(_ process: LaunchedProcess) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            launchedProcessHeaderContent(process)
            launchedProcessPathRow(process)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private func launchedProcessHeaderContent(_ process: LaunchedProcess) -> some View {
        HStack(spacing: 16) {
            launchedAppIcon(for: process)
            launchedProcessInfoLabels(process)
            
            Spacer()
            
            SpeedIndicator(
                speed: process.currentSpeed,
                isEnabled: process.isSpeedControlEnabled
            )
        }
    }
    
    private func launchedAppIcon(for process: LaunchedProcess) -> some View {
        Group {
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
        }
    }
    
    private func launchedProcessInfoLabels(_ process: LaunchedProcess) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(process.appName)
                .font(.system(size: 18, weight: .bold))
            
            launchedProcessMetadataRow(process)
        }
    }
    
    private func launchedProcessMetadataRow(_ process: LaunchedProcess) -> some View {
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
    
    private func launchedProcessPathRow(_ process: LaunchedProcess) -> some View {
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
    private var dyldModeStatusColor: Color {
        let hasRunningProcess = appLauncherViewModel.launchedProcesses.contains { $0.isRunning }
        return hasRunningProcess ? Color(hex: "34C759") : Color(NSColor.systemGray)
    }
    
    private var statusBarSection: some View {
        HStack(spacing: 16) {
            // 只显示 DYLD 模式相关信息
            HStack(spacing: 6) {
                Circle()
                    .fill(dyldModeStatusColor)
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
