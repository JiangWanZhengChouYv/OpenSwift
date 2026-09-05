import Foundation
import AppKit
import Carbon

/// 全局快捷键管理器。
///
/// 基于 Carbon `RegisterEventHotKey` 注册系统级热键，由 EventTap 拦截并回调，
/// 比 `NSEvent.addGlobalMonitorForEvents` 可靠（可拦截被系统抢占前的组合键，后台常驻触发）。
class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    /// 自定义 signature，用于标识本应用注册的 Carbon 热键（"OSWK"）。
    private let hotKeySignature: OSType = 0x4F53574B

    private var configurations: [HotkeyConfig] = []

    /// 已注册的热键引用，索引 pid = action 的注册序号，用于销毁。
    private var hotKeyRefs: [EventHotKeyRef] = []
    /// 注册序号 -> action 映射（尽量小整数，稳定映射）。
    private var actionByID: [UInt32: HotkeyAction] = [:]
    private var nextID: UInt32 = 1

    private var eventHandlerRef: EventHandlerRef?
    private var actionHandler: ((HotkeyAction) -> Void)?

    private init() {}

    func setActionHandler(_ handler: @escaping (HotkeyAction) -> Void) {
        self.actionHandler = handler
    }

    /// 注册所有启用的快捷键（每次调用会先注销旧的再重建）。
    func startMonitoring(with configurations: [HotkeyConfig]) {
        self.configurations = configurations
        stopMonitoring()
        installEventHandler()

        let enabled = configurations.filter { $0.isEnabled }
        for config in enabled {
            let id = register(config)
            if let id {
                hotKeyRefs.append(id)
            }
        }
        if !enabled.isEmpty {
            logInfo("Registered \(hotKeyRefs.count) global hotkeys", log: .hotkey)
        }
    }

    /// 注销全部热键与事件处理器。
    func stopMonitoring() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actionByID.removeAll()
        nextID = 1
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    /// 配置变更后完整重建，保证 Carbon 热键与最新配置一致（改键/启停即时生效）。
    func updateConfigurations(_ configurations: [HotkeyConfig]) {
        self.configurations = configurations
        startMonitoring(with: configurations)
    }

    // MARK: - Carbon 注册

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            globalHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    /// 注册单个热键，返回 EventHotKeyRef；失败返回 nil。
    private func register(_ config: HotkeyConfig) -> EventHotKeyRef? {
        let id = allocateID(config.action)
        var hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(config.keyCode),
            carbonModifiers(from: config.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            logError("Failed to register hotkey \(config.action.displayName), status=\(status)", log: .hotkey)
            return nil
        }
        return ref
    }

    private func allocateID(_ action: HotkeyAction) -> UInt32 {
        // 复用已存在的映射，保证 update 不重复分配。
        if let existing = actionByID.first(where: { $0.value == action })?.key {
            return existing
        }
        let id = nextID
        nextID += 1
        actionByID[id] = action
        return id
    }

    /// 供 Carbon 全局回调调用的入口（文件级回调经 EventHandlerUPP 访问）。
    fileprivate func handleHotKey(id: UInt32) {
        guard let action = actionByID[id] else { return }
        logDebug("Hotkey matched: \(action.displayName)", log: .hotkey)
        actionHandler?(action)
    }

    /// 把 AppKit 修饰符 flags 转成 Carbon 修饰符掩码。
    private func carbonModifiers(from appKitFlags: UInt32) -> UInt32 {
        var carbon: UInt32 = 0
        if appKitFlags & UInt32(NSEvent.ModifierFlags.control.rawValue) != 0 {
            carbon |= UInt32(controlKey)
        }
        if appKitFlags & UInt32(NSEvent.ModifierFlags.option.rawValue) != 0 {
            carbon |= UInt32(optionKey)
        }
        if appKitFlags & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 {
            carbon |= UInt32(shiftKey)
        }
        if appKitFlags & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 {
            carbon |= UInt32(cmdKey)
        }
        return carbon
    }

    // MARK: - 辅助功能权限

    var hasAccessibilityPermissions: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        logDebug("Accessibility permissions: \(isTrusted)", log: .hotkey)
    }

    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        logDebug("Requested accessibility permissions", log: .hotkey)
    }

    func shutdown() {
        stopMonitoring()
        logInfo("GlobalHotkeyManager shutdown complete", log: .hotkey)
    }
}

/// Carbon 事件回调 C 函数指针：解析 EventHotKeyID 并转发给单例处理。
private let globalHotKeyHandler: EventHandlerUPP = { _, eventRef, _ in
    guard let eventRef else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    GlobalHotkeyManager.shared.handleHotKey(id: hotKeyID.id)
    return noErr
}
