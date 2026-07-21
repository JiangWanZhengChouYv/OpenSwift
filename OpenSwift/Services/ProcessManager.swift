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
    private var speedControllers: [pid_t: SpeedControlManager] = [:]
    private let controllerQueue = DispatchQueue(label: "com.openswift.processmanager.controllers", qos: .userInitiated)
    private var lastRefreshTime: Date = .distantPast
    private let minimumRefreshInterval: TimeInterval = 1.0

    init() {}

    func setup() {
        guard !isSetup else { return }
        isSetup = true
        processObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] in self?.handleProcessTermination($0) }
        setupBindings()
        refreshProcesses()
        loadSavedGroups()
    }

    func shutdown() {
        if let observer = processObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            processObserver = nil
        }
    }

    private func setupBindings() {
        Publishers.CombineLatest3($processes, $searchText, $sortOption)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates { $0.0.count == $1.0.count && $0.1 == $1.1 && $0.2 == $1.2 }
            .map { processes, searchText, sortOption in
                var filtered = processes
                if !searchText.isEmpty {
                    let lowercasedSearch = searchText.lowercased()
                    filtered = filtered.filter {
                        $0.name.lowercased().contains(lowercasedSearch) || String($0.pid).contains(searchText)
                    }
                }
                filtered.sort(by: sortOption.comparator)
                return filtered
            }
            .sink { [weak self] in self?.filteredProcesses = $0 }
            .store(in: &cancellables)
    }

    func refreshProcesses() {
        let now = Date()
        guard now.timeIntervalSince(lastRefreshTime) >= minimumRefreshInterval else { return }
        lastRefreshTime = now
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let processInfos = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
                .map { ProcessInfo.from(runningApp: $0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self?.processes = processInfos
                self?.updateInjectedProcessesStatus()
                self?.isLoading = false
            }
        }
    }

    func selectProcess(_ process: ProcessInfo) { selectedProcess = process }
    func clearSelection() { selectedProcess = nil }
    func updateSearchText(_ text: String) { searchText = text }
    func updateSortOption(_ option: ProcessSortOption) { sortOption = option }
    func getProcessByPID(_ pid: pid_t) -> ProcessInfo? { processes.first { $0.pid == pid } }
    func isProcessInjected(_ process: ProcessInfo) -> Bool { injectedProcesses.contains { $0.pid == process.pid } }
    func isProcessInjected(pid: pid_t) -> Bool { injectedProcesses.contains { $0.pid == pid } }

    func injectSpeedControl(into process: ProcessInfo) { injectSpeedControl(into: process, autoInject: false) }

    func injectSpeedControl(into process: ProcessInfo, autoInject: Bool) {
        guard !isProcessInjected(process) else { return }
        let dylibPath = "/usr/lib/SpeedPatch.dylib"
        switch ProcessInjector.shared.inject(pid: process.pid, dylibPath: dylibPath) {
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
        case .failure(let error): handleInjectionError(error, for: process)
        }
    }

    func removeInjectedProcess(_ injected: InjectedProcess) {
        _ = ProcessInjector.shared.eject(pid: injected.pid)
        cleanupSharedMemory(for: injected.pid)
        injectedProcesses.removeAll { $0.id == injected.id }
        if selectedProcess?.pid == injected.pid { selectedProcess = nil }
    }

    func removeInjectedProcess(_ process: ProcessInfo) {
        if let injected = injectedProcesses.first(where: { $0.pid == process.pid }) { removeInjectedProcess(injected) }
    }

    func updateInjectedProcess(pid: pid_t, speedRatio: Double) {
        if let index = injectedProcesses.firstIndex(where: { $0.pid == pid }) {
            injectedProcesses[index].speedRatio = speedRatio
            let controller = controller(for: pid)
            if !controller.isConnected { _ = controller.attachToProcess(pid: pid) }
            _ = controller.setSpeedRatio(Float(speedRatio))
        }
    }

    func updateInjectedProcess(pid: pid_t, isEnabled: Bool) {
        if let index = injectedProcesses.firstIndex(where: { $0.pid == pid }) {
            injectedProcesses[index].isEnabled = isEnabled
            let controller = controller(for: pid)
            if !controller.isConnected { _ = controller.attachToProcess(pid: pid) }
            _ = controller.setEnabled(isEnabled)
        }
    }

    private func controller(for pid: pid_t) -> SpeedControlManager {
        controllerQueue.sync {
            if let existing = speedControllers[pid] { return existing }
            let controller = SpeedControlManager(pid: pid)
            speedControllers[pid] = controller
            return controller
        }
    }

    func setSpeedForAllProcesses(_ speed: Double) {
        injectedProcesses.filter { $0.isActive }
            .forEach { updateInjectedProcess(pid: $0.pid, speedRatio: speed) }
    }
    
    func enableAllProcesses() {
        injectedProcesses.filter { $0.isActive }
            .forEach { updateInjectedProcess(pid: $0.pid, isEnabled: true) }
    }
    
    func disableAllProcesses() {
        injectedProcesses.forEach { updateInjectedProcess(pid: $0.pid, isEnabled: false) }
    }

    func cleanupAll() {
        let pids = injectedProcesses.map { $0.pid }
        injectedProcesses.removeAll()
        
        pids.forEach { pid in
            _ = ProcessInjector.shared.eject(pid: pid)
            cleanupQueue.sync {
                let controller = self.controllerQueue.sync {
                    self.speedControllers.removeValue(forKey: pid) ?? SpeedControlManager(pid: pid)
                }
                controller.detachAndCleanup()
            }
        }
    }

    func handleProcessTermination(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            cleanupQueue.async { [weak self] in
                self?.cleanupTerminatedProcess(pid: app.processIdentifier)
            }
        }
    }

    private func cleanupTerminatedProcess(pid: pid_t) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let injectedIndex = self.injectedProcesses.firstIndex(where: { $0.pid == pid }) {
                self.injectedProcesses[injectedIndex].isActive = false
                self.cleanupSharedMemory(for: pid)
                if self.selectedProcess?.pid == pid { self.selectedProcess = nil }
            }
        }
    }

    private func cleanupSharedMemory(for pid: pid_t) {
        cleanupQueue.async { [weak self] in
            guard let self else { return }
            let controller = self.controllerQueue.sync {
                self.speedControllers.removeValue(forKey: pid) ?? SpeedControlManager(pid: pid)
            }
            controller.detachAndCleanup()
        }
    }

    private func updateInjectedProcessesStatus() {
        let activePIDs = Set(processes.map { $0.pid })
        injectedProcesses.indices.forEach {
            injectedProcesses[$0].isActive = activePIDs.contains(injectedProcesses[$0].pid)
        }
    }
}

extension ProcessManager {
    private func handleInjectionError(_ error: ProcessInjectorError, for process: ProcessInfo) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "注入失败"
            alert.informativeText = "无法将 SpeedPatch 注入到 \(process.name)。\n\n错误: \(error.localizedDescription)"
            alert.alertStyle = .warning
            if case .permissionDenied = error {
                alert.informativeText += "\n\n可能需要 root 权限或特殊 entitlement。"
            } else if case .alreadyInjected = error {
                alert.informativeText = "\(process.name) 已被注入。"
                alert.alertStyle = .informational
            }
            alert.addButton(withTitle: "确定")
        }
    }

    func getInjectedProcess(pid: pid_t) -> InjectedProcess? { injectedProcesses.first { $0.pid == pid } }
    func validateInjection(pid: pid_t) -> Bool { ProcessInjector.shared.isInjected(pid: pid) }

    func createGroup(name: String, processes: [InjectedProcess]) -> ProcessGroup {
        let group = ProcessGroup(name: name, processes: processes)
        processGroups.append(group)
        saveGroups()
        return group
    }

    func deleteGroup(_ group: ProcessGroup) { processGroups.removeAll { $0.id == group.id }; saveGroups() }
    func addToGroup(_ group: ProcessGroup, process: InjectedProcess) {
        if let index = processGroups.firstIndex(where: { $0.id == group.id }) {
            processGroups[index].addProcess(process)
            saveGroups()
        }
    }
    
    func removeFromGroup(_ group: ProcessGroup, pid: pid_t) {
        if let index = processGroups.firstIndex(where: { $0.id == group.id }) {
            processGroups[index].removeProcess(pid: pid)
            saveGroups()
        }
    }

    func applyGroup(_ group: ProcessGroup) {
        group.processes.filter { $0.isActive }.forEach {
            if !isProcessInjected(pid: $0.pid) { injectSpeedControl(into: $0.processInfo) }
            updateInjectedProcess(pid: $0.pid, speedRatio: $0.speedRatio)
            updateInjectedProcess(pid: $0.pid, isEnabled: $0.isEnabled)
        }
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
        }
    }

    func showInContextMenu(for process: ProcessInfo, at location: NSPoint, in view: NSView) {
        createContextMenu(for: process).popUp(positioning: nil, at: location, in: view)
    }

    func createContextMenu(for process: ProcessInfo) -> NSMenu {
        let menu = NSMenu()
        if isProcessInjected(process) {
            addInjectedProcessMenuItems(to: menu, for: process)
        } else {
            addInjectMenuItem(to: menu, for: process)
        }
        menu.addItem(NSMenuItem.separator())
        addCommonMenuItems(to: menu, for: process)
        return menu
    }

    private func addInjectedProcessMenuItems(to menu: NSMenu, for process: ProcessInfo) {
        menu.addItem(menuItem(title: "卸载 SpeedPatch", action: #selector(ejectSpeedPatch(_:)), object: process))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(title: "启用加速", action: #selector(enableSpeedControl(_:)), object: process))
        menu.addItem(menuItem(title: "禁用加速", action: #selector(disableSpeedControl(_:)), object: process))
        menu.addItem(NSMenuItem.separator())
        addSpeedSubmenu(to: menu, for: process)
    }

    private func addInjectMenuItem(to menu: NSMenu, for process: ProcessInfo) {
        menu.addItem(menuItem(title: "注入 SpeedPatch", action: #selector(injectSpeedPatch(_:)), object: process))
    }

    private func addSpeedSubmenu(to menu: NSMenu, for process: ProcessInfo) {
        let speedSubmenu = NSMenu()
        [(0.5, "0.5x (慢速)"), (1.0, "1.0x (正常)"), (1.5, "1.5x (加速)"), (2.0, "2.0x (快速)"), (5.0, "5.0x (超速)")]
            .forEach { speedSubmenu.addItem(createSpeedMenuItem(title: $1, speed: $0, process: process)) }
        let speedMenuItem = NSMenuItem(title: "快速设置速度", action: nil, keyEquivalent: "")
        speedMenuItem.submenu = speedSubmenu
        menu.addItem(speedMenuItem)
    }

    private func addCommonMenuItems(to menu: NSMenu, for process: ProcessInfo) {
        menu.addItem(menuItem(title: "复制进程信息", action: #selector(copyProcessInfo(_:)), object: process))
        if let path = process.path {
            menu.addItem(menuItem(title: "在 Finder 中显示", action: #selector(showInFinder(_:)), object: path))
        }
    }

    private func menuItem(title: String, action: Selector, object: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = object; item.target = self; return item
    }

    private func createSpeedMenuItem(title: String, speed: Double, process: ProcessInfo) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(setQuickSpeed(_:)), keyEquivalent: "")
        item.representedObject = (process, speed); item.target = self; return item
    }

    @objc private func injectSpeedPatch(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ProcessInfo { injectSpeedControl(into: p) }
    }
    
    @objc private func ejectSpeedPatch(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ProcessInfo { removeInjectedProcess(p) }
    }
    
    @objc private func enableSpeedControl(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ProcessInfo {
            updateInjectedProcess(pid: p.pid, isEnabled: true)
        }
    }
    
    @objc private func disableSpeedControl(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ProcessInfo {
            updateInjectedProcess(pid: p.pid, isEnabled: false)
        }
    }
    
    @objc private func setQuickSpeed(_ sender: NSMenuItem) {
        if let (p, s) = sender.representedObject as? (ProcessInfo, Double) {
            updateInjectedProcess(pid: p.pid, speedRatio: s)
        }
    }

    @objc private func copyProcessInfo(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ProcessInfo else { return }
        var info = "进程名称: \(process.name)\nPID: \(process.pid)\n"
        if let id = process.bundleIdentifier { info += "Bundle ID: \(id)\n" }
        if let path = process.path { info += "路径: \(path)" }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info, forType: .string)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}
