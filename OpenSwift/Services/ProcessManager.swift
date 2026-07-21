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
    private let stateQueue = DispatchQueue(label: "com.openswift.processmanager.state", qos: .userInitiated)
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
    func getProcessByPID(_ pid: pid_t) -> ProcessInfo? {
        return stateQueue.sync { processes.first { $0.pid == pid } }
    }
    
    func isProcessInjected(_ process: ProcessInfo) -> Bool {
        return stateQueue.sync { injectedProcesses.contains { $0.pid == process.pid } }
    }
    
    func isProcessInjected(pid: pid_t) -> Bool {
        return stateQueue.sync { injectedProcesses.contains { $0.pid == pid } }
    }

    func injectSpeedControl(into process: ProcessInfo) { injectSpeedControl(into: process, autoInject: false) }

    func injectSpeedControl(into process: ProcessInfo, autoInject: Bool) {
        let pid = process.pid
        
        stateQueue.sync {
            guard !injectedProcesses.contains(where: { $0.pid == pid }) else { return }
            
            let dylibPath = "/usr/lib/SpeedPatch.dylib"
            switch ProcessInjector.shared.inject(pid: pid, dylibPath: dylibPath) {
            case .success:
                let injectedProcess = InjectedProcess(
                    pid: pid,
                    processInfo: process,
                    speedRatio: 1.0,
                    isEnabled: false
                )
                injectedProcesses.append(injectedProcess)
                ProcessHistory.shared.addToHistory(injectedProcess)
                if let lastSpeed = ProcessHistory.shared.getLastSpeedRatio(for: pid) {
                    updateInjectedProcessInternal(pid: pid, speedRatio: lastSpeed)
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self.handleInjectionError(error, for: process)
                }
            }
        }
    }

    func removeInjectedProcess(_ injected: InjectedProcess) {
        let pid = injected.pid
        let wasSelected = selectedProcess?.pid == pid
        
        _ = ProcessInjector.shared.eject(pid: pid)
        cleanupSharedMemory(for: pid)
        
        stateQueue.sync {
            injectedProcesses.removeAll { $0.id == injected.id }
        }
        
        if wasSelected {
            selectedProcess = nil
        }
    }

    func removeInjectedProcess(_ process: ProcessInfo) {
        stateQueue.sync {
            if let injected = injectedProcesses.first(where: { $0.pid == process.pid }) {
                DispatchQueue.main.async {
                    self.removeInjectedProcess(injected)
                }
            }
        }
    }

    func updateInjectedProcess(pid: pid_t, speedRatio: Double) {
        stateQueue.sync {
            updateInjectedProcessInternal(pid: pid, speedRatio: speedRatio)
        }
    }

    func updateInjectedProcess(pid: pid_t, isEnabled: Bool) {
        stateQueue.sync {
            updateInjectedProcessEnabledInternal(pid: pid, isEnabled: isEnabled)
        }
    }
    
    private func updateInjectedProcessInternal(pid: pid_t, speedRatio: Double) {
        if let index = injectedProcesses.firstIndex(where: { $0.pid == pid }) {
            injectedProcesses[index].speedRatio = speedRatio
            let controller = controllerQueue.sync {
                if let existing = speedControllers[pid] { return existing }
                let controller = SpeedControlManager(pid: pid)
                speedControllers[pid] = controller
                return controller
            }
            if !controller.isConnected { _ = controller.attachToProcess(pid: pid) }
            _ = controller.setSpeedRatio(Float(speedRatio))
        }
    }
    
    private func updateInjectedProcessEnabledInternal(pid: pid_t, isEnabled: Bool) {
        if let index = injectedProcesses.firstIndex(where: { $0.pid == pid }) {
            injectedProcesses[index].isEnabled = isEnabled
            let controller = controllerQueue.sync {
                if let existing = speedControllers[pid] { return existing }
                let controller = SpeedControlManager(pid: pid)
                speedControllers[pid] = controller
                return controller
            }
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
        let activePIDs = stateQueue.sync {
            injectedProcesses.filter { $0.isActive }.map { $0.pid }
        }
        activePIDs.forEach { updateInjectedProcess(pid: $0, speedRatio: speed) }
    }
    
    func enableAllProcesses() {
        let activePIDs = stateQueue.sync {
            injectedProcesses.filter { $0.isActive }.map { $0.pid }
        }
        activePIDs.forEach { updateInjectedProcess(pid: $0, isEnabled: true) }
    }
    
    func disableAllProcesses() {
        let pids = stateQueue.sync {
            injectedProcesses.map { $0.pid }
        }
        pids.forEach { updateInjectedProcess(pid: $0, isEnabled: false) }
    }

    func cleanupAll() {
        let pids = stateQueue.sync {
            let pids = injectedProcesses.map { $0.pid }
            injectedProcesses.removeAll()
            return pids
        }
        
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
        stateQueue.sync {
            if let injectedIndex = injectedProcesses.firstIndex(where: { $0.pid == pid }) {
                injectedProcesses[injectedIndex].isActive = false
                cleanupSharedMemory(for: pid)
                if selectedProcess?.pid == pid {
                    DispatchQueue.main.async {
                        self.selectedProcess = nil
                    }
                }
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
        stateQueue.sync {
            let activePIDs = Set(processes.map { $0.pid })
            injectedProcesses.indices.forEach {
                injectedProcesses[$0].isActive = activePIDs.contains(injectedProcesses[$0].pid)
            }
        }
    }
    
    private func loadSavedGroups() {
        if let data = UserDefaults.standard.data(forKey: "ProcessGroups"),
           let groupsData = try? JSONDecoder().decode([ProcessGroupData].self, from: data) {
            processGroups = groupsData.map { $0.toProcessGroup() }
        }
    }
    
    func createGroup(name: String, processes: [InjectedProcess]) -> ProcessGroup {
        let group = ProcessGroup(name: name, processes: processes)
        stateQueue.sync {
            processGroups.append(group)
            saveGroups()
        }
        return group
    }

    func deleteGroup(_ group: ProcessGroup) {
        stateQueue.sync {
            processGroups.removeAll { $0.id == group.id }
            saveGroups()
        }
    }
    
    func addToGroup(_ group: ProcessGroup, process: InjectedProcess) {
        stateQueue.sync {
            if let index = processGroups.firstIndex(where: { $0.id == group.id }) {
                processGroups[index].addProcess(process)
                saveGroups()
            }
        }
    }
    
    func removeFromGroup(_ group: ProcessGroup, pid: pid_t) {
        stateQueue.sync {
            if let index = processGroups.firstIndex(where: { $0.id == group.id }) {
                processGroups[index].removeProcess(pid: pid)
                saveGroups()
            }
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

    func getInjectedProcess(pid: pid_t) -> InjectedProcess? {
        return stateQueue.sync { injectedProcesses.first { $0.pid == pid } }
    }
    
    func validateInjection(pid: pid_t) -> Bool { ProcessInjector.shared.isInjected(pid: pid) }
}
