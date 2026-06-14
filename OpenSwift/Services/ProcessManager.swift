import Foundation
import AppKit
import Combine

class ProcessManager: ObservableObject {
    @Published var processes: [ProcessInfo] = []
    @Published var filteredProcesses: [ProcessInfo] = []
    @Published var selectedProcess: ProcessInfo?
    @Published var searchText: String = ""
    @Published var sortOption: ProcessSortOption = .name
    @Published var isLoading: Bool = false

    @Published var injectedProcesses: [InjectedProcess] = []
    @Published var processGroups: [ProcessGroup] = []

    private var cancellables = Set<AnyCancellable>()
    private var processObserver: NSObjectProtocol?
    private var isSetup: Bool = false

    private let cleanupQueue = DispatchQueue(label: "com.openswift.cleanup", qos: .utility)
    /// 为每个被注入进程维护一个独立的 SpeedControlManager，避免全局单例共享上下文。
    private var speedControllers: [pid_t: SpeedControlManager] = [:]
    private let controllerQueue = DispatchQueue(label: "com.openswift.processmanager.controllers", qos: .userInitiated)

    private var lastRefreshTime: Date = .distantPast
    private let minimumRefreshInterval: TimeInterval = 1.0
    
    enum LogLevel: String {
        case debug = "🔍"
        case info = "ℹ️"
        case warning = "⚠️"
        case error = "❌"
    }
    
    private func log(_ message: String, level: LogLevel = .info) {
        #if DEBUG
        print("[\(level.rawValue) ProcessManager] \(message)")
        #endif
    }
    
    init() {
        // init 只做最轻量操作，不访问任何其他 singleton
        // 所有重操作延迟到 setup()，由 AppDelegate 在窗口显示后调用
        log("ProcessManager initialized (lightweight)")
    }
    
    // 由 AppDelegate 在窗口显示后调用
    func setup() {
        guard !isSetup else { return }
        isSetup = true
        
        processObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleProcessTermination(notification)
        }
        
        setupBindings()
        refreshProcesses()
        loadSavedGroups()
        
        log("ProcessManager setup complete")
    }
    
    deinit {
        if let observer = processObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        cleanupAll()
    }
    
    private func setupBindings() {
        Publishers.CombineLatest3($processes, $searchText, $sortOption)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates { prev, curr in
                prev.0.count == curr.0.count &&
                prev.1 == curr.1 &&
                prev.2 == curr.2
            }
            .map { processes, searchText, sortOption in
                var filtered = processes
                
                if !searchText.isEmpty {
                    let lowercasedSearch = searchText.lowercased()
                    filtered = filtered.filter { process in
                        process.name.lowercased().contains(lowercasedSearch) ||
                        String(process.pid).contains(searchText)
                    }
                }
                
                filtered.sort(by: sortOption.comparator)
                
                return filtered
            }
            .sink { [weak self] filtered in
                self?.filteredProcesses = filtered
            }
            .store(in: &cancellables)
    }
    
    func refreshProcesses() {
        let now = Date()
        guard now.timeIntervalSince(lastRefreshTime) >= minimumRefreshInterval else {
            log("Refresh throttled, minimum interval not reached")
            return
        }
        
        lastRefreshTime = now
        isLoading = true
        log("Refreshing processes")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let runningApps = NSWorkspace.shared.runningApplications
            
            let processInfos = runningApps
                .filter { app in
                    app.activationPolicy == .regular || app.activationPolicy == .accessory
                }
                .map { app in
                    ProcessInfo.from(runningApp: app)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            DispatchQueue.main.async {
                self?.processes = processInfos
                self?.updateInjectedProcessesStatus()
                self?.isLoading = false
                self?.log("Found \(processInfos.count) processes")
            }
        }
    }
    
    func selectProcess(_ process: ProcessInfo) {
        selectedProcess = process
        log("Selected process: \(process.name) (PID: \(process.pid))", level: .debug)
    }
    
    func clearSelection() {
        selectedProcess = nil
        log("Selection cleared", level: .debug)
    }
    
    func updateSearchText(_ text: String) {
        searchText = text
    }
    
    func updateSortOption(_ option: ProcessSortOption) {
        sortOption = option
    }
    
    func getProcessByPID(_ pid: pid_t) -> ProcessInfo? {
        return processes.first { $0.pid == pid }
    }
    
    func isProcessInjected(_ process: ProcessInfo) -> Bool {
        return injectedProcesses.contains { $0.pid == process.pid }
    }
    
    func isProcessInjected(pid: pid_t) -> Bool {
        return injectedProcesses.contains { $0.pid == pid }
    }
    
    func injectSpeedControl(into process: ProcessInfo) {
        injectSpeedControl(into: process, autoInject: false)
    }
    
    func injectSpeedControl(into process: ProcessInfo, autoInject: Bool) {
        guard !isProcessInjected(process) else {
            log("Process \(process.name) (PID: \(process.pid)) already injected", level: .warning)
            return
        }
        
        log("Injecting SpeedControl into \(process.name) (PID: \(process.pid))")
        
        let dylibPath = "/usr/lib/SpeedPatch.dylib"
        
        let result = ProcessInjector.shared.inject(pid: process.pid, dylibPath: dylibPath)
        
        switch result {
        case .success:
            let injectedProcess = InjectedProcess(
                pid: process.pid,
                processInfo: process,
                speedRatio: 1.0,
                isEnabled: false
            )
            
            injectedProcesses.append(injectedProcess)
            ProcessHistory.shared.addToHistory(injectedProcess)
            
            if let lastSpeed = ProcessHistory.shared.getLastSpeedRatio(for: process.pid) {
                updateInjectedProcess(pid: process.pid, speedRatio: lastSpeed)
            }
            
            log("Successfully injected into \(process.name)", level: .info)
            
        case .failure(let error):
            log("Failed to inject: \(error.localizedDescription)", level: .error)
            handleInjectionError(error, for: process)
        }
    }
    
    func removeInjectedProcess(_ injected: InjectedProcess) {
        log("Removing injected process: \(injected.processInfo.name) (PID: \(injected.pid))")
        
        let result = ProcessInjector.shared.eject(pid: injected.pid)
        
        switch result {
        case .success:
            cleanupSharedMemory(for: injected.pid)
            injectedProcesses.removeAll { $0.id == injected.id }
            log("Successfully removed injection", level: .info)
            
        case .failure(let error):
            log("Failed to eject: \(error.localizedDescription)", level: .error)
            
            injectedProcesses.removeAll { $0.id == injected.id }
            cleanupSharedMemory(for: injected.pid)
        }
        
        if selectedProcess?.pid == injected.pid {
            selectedProcess = nil
        }
    }
    
    func removeInjectedProcess(_ process: ProcessInfo) {
        if let injected = injectedProcesses.first(where: { $0.pid == process.pid }) {
            removeInjectedProcess(injected)
        }
    }
    
    func updateInjectedProcess(pid: pid_t, speedRatio: Double) {
        if let index = injectedProcesses.firstIndex(where: { $0.pid == pid }) {
            injectedProcesses[index].speedRatio = speedRatio

            let controller = controller(for: pid)
            if !controller.isConnected {
                _ = controller.attachToProcess(pid: pid)
            }
            _ = controller.setSpeedRatio(Float(speedRatio))

            log("Updated speed ratio to \(speedRatio) for PID \(pid)", level: .debug)
        }
    }

    func updateInjectedProcess(pid: pid_t, isEnabled: Bool) {
        if let index = injectedProcesses.firstIndex(where: { $0.pid == pid }) {
            injectedProcesses[index].isEnabled = isEnabled

            let controller = controller(for: pid)
            if !controller.isConnected {
                _ = controller.attachToProcess(pid: pid)
            }
            _ = controller.setEnabled(isEnabled)

            log("Updated enabled state to \(isEnabled) for PID \(pid)", level: .debug)
        }
    }

    // MARK: - Internal controller management (per pid)

    private func controller(for pid: pid_t) -> SpeedControlManager {
        controllerQueue.sync {
            if let existing = speedControllers[pid] {
                return existing
            }
            let controller = SpeedControlManager(pid: pid)
            speedControllers[pid] = controller
            return controller
        }
    }

    private func removeController(for pid: pid_t) {
        controllerQueue.sync {
            if let controller = speedControllers.removeValue(forKey: pid) {
                controller.detachAndCleanup()
            }
        }
    }
    
    func setSpeedForAllProcesses(_ speed: Double) {
        for injected in injectedProcesses where injected.isActive {
            updateInjectedProcess(pid: injected.pid, speedRatio: speed)
        }
        log("Set speed \(speed) for all \(injectedProcesses.count) processes", level: .info)
    }
    
    func enableAllProcesses() {
        for injected in injectedProcesses where injected.isActive {
            updateInjectedProcess(pid: injected.pid, isEnabled: true)
        }
        log("Enabled all \(injectedProcesses.count) processes", level: .info)
    }
    
    func disableAllProcesses() {
        for injected in injectedProcesses {
            updateInjectedProcess(pid: injected.pid, isEnabled: false)
        }
        log("Disabled all processes", level: .info)
    }
    
    func cleanupAll() {
        log("Cleaning up all injected processes")
        
        for injected in injectedProcesses {
            let _ = ProcessInjector.shared.eject(pid: injected.pid)
            cleanupSharedMemory(for: injected.pid)
        }
        
        injectedProcesses.removeAll()
        log("Cleanup completed", level: .info)
    }
    
    func handleProcessTermination(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        let terminatedPID = app.processIdentifier
        let appName = app.localizedName ?? "Unknown"
        
        log("Process terminated: \(appName) (PID: \(terminatedPID))", level: .warning)
        
        cleanupQueue.async { [weak self] in
            self?.cleanupTerminatedProcess(pid: terminatedPID)
        }
    }
    
    private func cleanupTerminatedProcess(pid: pid_t) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let injectedIndex = self.injectedProcesses.firstIndex(where: { $0.pid == pid }) {
                var injected = self.injectedProcesses[injectedIndex]
                injected.isActive = false
                self.injectedProcesses[injectedIndex] = injected
                
                self.cleanupSharedMemory(for: pid)
                
                self.log("Cleaned up terminated process: PID \(pid)", level: .info)
                
                if self.selectedProcess?.pid == pid {
                    self.selectedProcess = nil
                }
            }
        }
    }
    
    private func cleanupSharedMemory(for pid: pid_t) {
        cleanupQueue.async { [weak self] in
            guard let self else { return }
            // 优先使用我们自己内部维护的控制器；否则创建一个临时控制器来按 key 删除共享内存
            let controller = self.controllerQueue.sync { () -> SpeedControlManager in
                if let existing = self.speedControllers.removeValue(forKey: pid) {
                    return existing
                }
                return SpeedControlManager(pid: pid)
            }
            controller.detachAndCleanup()
            logDebug("Cleaned up shared memory for PID \(pid)", log: .openswift)
        }
    }
    
    private func updateInjectedProcessesStatus() {
        let activePIDs = Set(processes.map { $0.pid })
        
        for index in injectedProcesses.indices {
            let pid = injectedProcesses[index].pid
            injectedProcesses[index].isActive = activePIDs.contains(pid)
        }
        
        let inactiveProcesses = injectedProcesses.filter { !$0.isActive }
        if !inactiveProcesses.isEmpty {
            log("\(inactiveProcesses.count) previously injected processes are no longer active", level: .warning)
        }
    }
    
    private func handleInjectionError(_ error: ProcessInjectorError, for process: ProcessInfo) {
        DispatchQueue.main.async {
            self.showInjectionErrorAlert(error: error, processName: process.name)
        }
    }
    
    private func showInjectionErrorAlert(error: ProcessInjectorError, processName: String) {
        let alert = NSAlert()
        alert.messageText = "注入失败"
        alert.informativeText = "无法将 SpeedPatch 注入到 \(processName)。\n\n错误: \(error.localizedDescription)"
        alert.alertStyle = .warning
        
        switch error {
        case .permissionDenied:
            alert.informativeText += "\n\n可能需要 root 权限或特殊 entitlement。"
        case .alreadyInjected:
            alert.informativeText = "\(processName) 已被注入。"
            alert.alertStyle = .informational
        default:
            break
        }
        
        alert.addButton(withTitle: "确定")
    }
    
    func createGroup(name: String, processes: [InjectedProcess]) -> ProcessGroup {
        let group = ProcessGroup(name: name, processes: processes)
        processGroups.append(group)
        saveGroups()
        log("Created process group: \(name)", level: .info)
        return group
    }
    
    func deleteGroup(_ group: ProcessGroup) {
        processGroups.removeAll { $0.id == group.id }
        saveGroups()
        log("Deleted process group: \(group.name)", level: .info)
    }
    
    func addToGroup(_ group: ProcessGroup, process: InjectedProcess) {
        if let index = processGroups.firstIndex(where: { $0.id == group.id }) {
            processGroups[index].addProcess(process)
            saveGroups()
            log("Added \(process.processInfo.name) to group \(group.name)", level: .debug)
        }
    }
    
    func removeFromGroup(_ group: ProcessGroup, pid: pid_t) {
        if let index = processGroups.firstIndex(where: { $0.id == group.id }) {
            processGroups[index].removeProcess(pid: pid)
            saveGroups()
        }
    }
    
    func applyGroup(_ group: ProcessGroup) {
        for injected in group.processes where injected.isActive {
            if !isProcessInjected(pid: injected.pid) {
                injectSpeedControl(into: injected.processInfo)
            }
            updateInjectedProcess(pid: injected.pid, speedRatio: injected.speedRatio)
            updateInjectedProcess(pid: injected.pid, isEnabled: injected.isEnabled)
        }
        log("Applied group: \(group.name)", level: .info)
    }
    
    func getInjectedProcess(pid: pid_t) -> InjectedProcess? {
        return injectedProcesses.first { $0.pid == pid }
    }
    
    func validateInjection(pid: pid_t) -> Bool {
        return ProcessInjector.shared.isInjected(pid: pid)
    }
    
    private func saveGroups() {
        if let data = try? JSONEncoder().encode(processGroups.map { ProcessGroupData(from: $0) }) {
            UserDefaults.standard.set(data, forKey: "ProcessGroups")
        }
    }
    
    private func loadSavedGroups() {
        if let data = UserDefaults.standard.data(forKey: "ProcessGroups"),
           let groupsData = try? JSONDecoder().decode([ProcessGroupData].self, from: data) {
            processGroups = groupsData.map { $0.toProcessGroup() }
            log("Loaded \(processGroups.count) saved process groups")
        }
    }
    
    func showInContextMenu(for process: ProcessInfo, at location: NSPoint, in view: NSView) {
        let menu = createContextMenu(for: process)
        menu.popUp(positioning: nil, at: NSPoint(x: location.x, y: location.y), in: view)
    }
    
    func createContextMenu(for process: ProcessInfo) -> NSMenu {
        let menu = NSMenu()
        
        let isInjected = isProcessInjected(process)
        
        if isInjected {
            let ejectItem = NSMenuItem(
                title: "卸载 SpeedPatch",
                action: #selector(ejectSpeedPatch(_:)),
                keyEquivalent: ""
            )
            ejectItem.representedObject = process
            ejectItem.target = self
            menu.addItem(ejectItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let enableItem = NSMenuItem(
                title: "启用加速",
                action: #selector(enableSpeedControl(_:)),
                keyEquivalent: ""
            )
            enableItem.representedObject = process
            enableItem.target = self
            menu.addItem(enableItem)
            
            let disableItem = NSMenuItem(
                title: "禁用加速",
                action: #selector(disableSpeedControl(_:)),
                keyEquivalent: ""
            )
            disableItem.representedObject = process
            disableItem.target = self
            menu.addItem(disableItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let speedSubmenu = NSMenu()
            speedSubmenu.addItem(createSpeedMenuItem(title: "0.5x (慢速)", speed: 0.5, process: process))
            speedSubmenu.addItem(createSpeedMenuItem(title: "1.0x (正常)", speed: 1.0, process: process))
            speedSubmenu.addItem(createSpeedMenuItem(title: "1.5x (加速)", speed: 1.5, process: process))
            speedSubmenu.addItem(createSpeedMenuItem(title: "2.0x (快速)", speed: 2.0, process: process))
            speedSubmenu.addItem(createSpeedMenuItem(title: "5.0x (超速)", speed: 5.0, process: process))
            
            let speedMenuItem = NSMenuItem(title: "快速设置速度", action: nil, keyEquivalent: "")
            speedMenuItem.submenu = speedSubmenu
            menu.addItem(speedMenuItem)
        } else {
            let injectItem = NSMenuItem(
                title: "注入 SpeedPatch",
                action: #selector(injectSpeedPatch(_:)),
                keyEquivalent: ""
            )
            injectItem.representedObject = process
            injectItem.target = self
            menu.addItem(injectItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let copyInfoItem = NSMenuItem(
            title: "复制进程信息",
            action: #selector(copyProcessInfo(_:)),
            keyEquivalent: ""
        )
        copyInfoItem.representedObject = process
        copyInfoItem.target = self
        menu.addItem(copyInfoItem)
        
        if let path = process.path {
            let showInFinderItem = NSMenuItem(
                title: "在 Finder 中显示",
                action: #selector(showInFinder(_:)),
                keyEquivalent: ""
            )
            showInFinderItem.representedObject = path
            showInFinderItem.target = self
            menu.addItem(showInFinderItem)
        }
        
        return menu
    }
    
    private func createSpeedMenuItem(title: String, speed: Double, process: ProcessInfo) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(setQuickSpeed(_:)), keyEquivalent: "")
        item.representedObject = (process, speed)
        item.target = self
        return item
    }
    
    @objc private func injectSpeedPatch(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ProcessInfo else { return }
        injectSpeedControl(into: process)
    }
    
    @objc private func ejectSpeedPatch(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ProcessInfo else { return }
        removeInjectedProcess(process)
    }
    
    @objc private func enableSpeedControl(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ProcessInfo else { return }
        updateInjectedProcess(pid: process.pid, isEnabled: true)
    }
    
    @objc private func disableSpeedControl(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ProcessInfo else { return }
        updateInjectedProcess(pid: process.pid, isEnabled: false)
    }
    
    @objc private func setQuickSpeed(_ sender: NSMenuItem) {
        guard let (process, speed) = sender.representedObject as? (ProcessInfo, Double) else { return }
        updateInjectedProcess(pid: process.pid, speedRatio: speed)
    }
    
    @objc private func copyProcessInfo(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ProcessInfo else { return }
        
        var info = "进程名称: \(process.name)\n"
        info += "PID: \(process.pid)\n"
        if let bundleId = process.bundleIdentifier {
            info += "Bundle ID: \(bundleId)\n"
        }
        if let path = process.path {
            info += "路径: \(path)"
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }
    
    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

struct ProcessGroupData: Codable {
    let id: UUID
    let name: String
    let createdAt: Date
    let isPreset: Bool
    let processes: [ProcessHistoryData]
    
    init(from group: ProcessGroup) {
        self.id = group.id
        self.name = group.name
        self.createdAt = group.createdAt
        self.isPreset = group.isPreset
        self.processes = group.processes.map { ProcessHistoryData(from: $0) }
    }
    
    func toProcessGroup() -> ProcessGroup {
        var group = ProcessGroup(
            id: id,
            name: name,
            createdAt: createdAt,
            isPreset: isPreset
        )
        
        for processData in processes {
            let process = processData.toInjectedProcess()
            group.addProcess(process)
        }
        
        return group
    }
}
