import SwiftUI

struct ContentView: View {
    @State private var showProcessList: Bool = true
    @State private var showHotkeySettings: Bool = false
    @State private var showMinimizeTip: Bool = false
    @State private var showFirstLaunch: Bool = false
    @State private var selectedTab: Int = 1
    
    @State private var showErrorAlert: Bool = false
    @State private var errorAlertMessage: String = ""
    @State private var showAppSelector: Bool = false
    @State private var appSelectorObserver: NSObjectProtocol?
    
    var body: some View {
        HSplitView {
            if showProcessList {
                processListSection
            }
            
            SpeedControlPanel(
                speedControlState: SpeedControlState.shared,
                processManager: ProcessManagerProvider.shared.manager,
                appLauncherViewModel: AppLauncherViewModel.shared,
                selectedTab: $selectedTab
            )
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    hotkeyStatusIndicator
                    
                    Button(action: {
                        showHotkeySettings = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "keyboard")
                            Text("快捷键")
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .help("打开快捷键设置")
                    
                    Button(action: {
                        showFirstLaunch = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "book.fill")
                            Text("新手引导")
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .help("查看新手引导")
                }
            }
        }
        .sheet(isPresented: $showHotkeySettings) {
            HotkeySettingsView(onDismiss: {
                showHotkeySettings = false
            })
        }
        .sheet(isPresented: $showFirstLaunch) {
            FirstLaunchView {
                AppSettings.shared.isFirstLaunch = false
                showFirstLaunch = false
            }
        }
        .sheet(isPresented: $showAppSelector) {
            AppSelectorView { url in
                if url.pathExtension == "app" {
                    AppLauncherViewModel.shared.launchApp(at: url)
                } else {
                    AppLauncherViewModel.shared.launchExecutable(at: url)
                }
            }
        }
        .sheet(isPresented: $showErrorAlert) {
            ErrorAlertView(title: "错误", message: errorAlertMessage) {
                showErrorAlert = false
            }
        }
        .onAppear {
            if AppSettings.shared.isFirstLaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showFirstLaunch = true
                }
            }
            
            appSelectorObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("OpenAppSelector"),
                object: nil,
                queue: .main
            ) { _ in
                showAppSelector = true
            }
        }
        .onDisappear {
            if let observer = appSelectorObserver {
                NotificationCenter.default.removeObserver(observer)
                appSelectorObserver = nil
            }
        }
        .onChange(of: AppLauncherViewModel.shared.showError) { newValue in
            if newValue {
                errorAlertMessage = AppLauncherViewModel.shared.errorMessage
                showErrorAlert = true
            }
        }
        .overlay(Group {
            if showMinimizeTip {
                VStack {
                    minimizeTipBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation {
                                    showMinimizeTip = false
                                }
                            }
                        }
                    Spacer()
                }
            }
            
            if AppLauncherViewModel.shared.showSuccess {
                VStack {
                    successBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
            }
        }, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: .windowMinimizedToTray)) { _ in
            withAnimation {
                showMinimizeTip = true
            }
        }
    }
    
    private var hotkeyStatusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(HotkeyService.shared.isEnabled ? Color(hex: "34C759") : Color.gray)
                .frame(width: 6, height: 6)
            
            Text(HotkeyService.shared.isEnabled ? "快捷键已启用" : "快捷键已禁用")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private var minimizeTipBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(hex: "34C759"))
            
            Text("窗口已最小化到菜单栏")
                .font(.system(size: 12, weight: .medium))
            
            Spacer()
            
            Button(action: {
                withAnimation {
                    showMinimizeTip = false
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
    
    private var successBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(hex: "34C759"))
            
            Text(AppLauncherViewModel.shared.successMessage)
                .font(.system(size: 12, weight: .medium))
            
            Spacer()
            
            Button(action: {
                withAnimation {
                    AppLauncherViewModel.shared.showSuccess = false
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "34C759").opacity(0.15))
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
    
    private var processListSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("进程列表")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                Button(action: {
                    withAnimation {
                        showProcessList = false
                    }
                }) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            ProcessListView(
                processManager: ProcessManagerProvider.shared.manager,
                speedControlState: SpeedControlState.shared,
                appLauncherViewModel: AppLauncherViewModel.shared
            )
        }
        .frame(minWidth: 280, maxWidth: 350)
    }
}

class ProcessManagerProvider {
    static let shared = ProcessManagerProvider()
    
    let manager: ProcessManager
    
    private init() {
        manager = ProcessManager()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
