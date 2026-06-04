import Foundation

enum ProcessInjectorError: Error, LocalizedError {
    case taskPortFailed
    case memoryAllocationFailed
    case memoryWriteFailed
    case threadCreationFailed
    case permissionDenied
    case invalidProcess
    case alreadyInjected
    case notInjected
    case dyldLoadFailed(String)
    case dylibNotFound
    case injectionFailed(String)
    case notSupported
    
    var errorDescription: String? {
        switch self {
        case .taskPortFailed:
            return "无法获取进程的任务端口 - 请确认 SIP 已禁用"
        case .memoryAllocationFailed:
            return "无法分配内存"
        case .memoryWriteFailed:
            return "无法写入内存"
        case .threadCreationFailed:
            return "无法创建线程"
        case .permissionDenied:
            return "权限不足 - 请使用 sudo 运行或禁用 SIP"
        case .invalidProcess:
            return "无效的进程"
        case .alreadyInjected:
            return "进程已被注入"
        case .notInjected:
            return "进程未被注入"
        case .dyldLoadFailed(let message):
            return "动态库加载失败: \(message)"
        case .dylibNotFound:
            return "找不到 SpeedPatch 动态库"
        case .injectionFailed(let message):
            return "注入失败: \(message)"
        case .notSupported:
            return "Mach 注入功能暂不支持，请使用应用启动器 (AppLauncher)"
        }
    }
}

class ProcessInjector {
    static let shared = ProcessInjector()
    
    private var injectedPIDs: Set<pid_t> = []
    private let injectQueue = DispatchQueue(label: "com.openswift.injector", qos: .userInitiated)
    
    private init() {}
    
    func inject(pid: pid_t, dylibPath: String) -> Result<Void, ProcessInjectorError> {
        return injectQueue.sync {
            if injectedPIDs.contains(pid) {
                return .failure(.alreadyInjected)
            }
            
            print("[ProcessInjector] ⚠️  Mach 注入功能暂不支持")
            print("[ProcessInjector] 💡 请使用应用启动器 (AppLauncher) 来启动和加速应用")
            
            // 标记为成功但提示用户使用其他方法
            injectedPIDs.insert(pid)
            
            return .failure(.notSupported)
        }
    }
    
    func eject(pid: pid_t) -> Result<Void, ProcessInjectorError> {
        return injectQueue.sync {
            if !injectedPIDs.contains(pid) {
                return .failure(.notInjected)
            }
            
            print("[ProcessInjector] 从 PID \(pid) 卸载")
            injectedPIDs.remove(pid)
            
            print("[ProcessInjector] ✅ 成功从 PID \(pid) 卸载")
            
            return .success(())
        }
    }
    
    func isInjected(pid: pid_t) -> Bool {
        return injectedPIDs.contains(pid)
    }
    
    func getInjectedPIDs() -> Set<pid_t> {
        return injectedPIDs
    }
}
