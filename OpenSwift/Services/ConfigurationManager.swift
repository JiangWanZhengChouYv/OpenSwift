import Foundation
import AppKit

enum ConfigurationError: LocalizedError {
    case exportFailed
    case importFailed
    case invalidFormat
    case fileNotFound
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .exportFailed:
            return "导出配置失败"
        case .importFailed:
            return "导入配置失败"
        case .invalidFormat:
            return "配置格式无效"
        case .fileNotFound:
            return "配置文件未找到"
        case .saveFailed:
            return "保存配置文件失败"
        }
    }
}

class ConfigurationManager {
    static let shared = ConfigurationManager()
    
    private let appSettings = AppSettings.shared
    private let settingsStorage = SettingsStorage.shared
    private let fileManager = FileManager.default
    
    private init() {}
    
    func exportConfiguration() throws -> Data {
        guard let data = appSettings.exportConfiguration() else {
            throw ConfigurationError.exportFailed
        }
        
        #if DEBUG
        print("[ConfigurationManager] Configuration exported successfully")
        #endif
        
        return data
    }
    
    func importConfiguration(from data: Data) throws {
        do {
            try appSettings.importConfiguration(from: data)
            
            #if DEBUG
            print("[ConfigurationManager] Configuration imported successfully")
            #endif
        } catch {
            throw ConfigurationError.importFailed
        }
    }
    
    func saveConfigurationToFile(at url: URL) throws {
        let data = try exportConfiguration()
        
        do {
            try data.write(to: url, options: .atomic)
            #if DEBUG
            print("[ConfigurationManager] Configuration saved to: \(url.path)")
            #endif
        } catch {
            throw ConfigurationError.saveFailed
        }
    }
    
    func loadConfigurationFromFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ConfigurationError.fileNotFound
        }
        
        do {
            let data = try Data(contentsOf: url)
            try importConfiguration(from: data)
            #if DEBUG
            print("[ConfigurationManager] Configuration loaded from: \(url.path)")
            #endif
        } catch {
            throw ConfigurationError.importFailed
        }
    }
    
    func resetAllConfiguration() {
        appSettings.resetToDefaults()
        
        HotkeyStorage.shared.resetToDefaults()
        HotkeyService.shared.loadConfigurations()
        HotkeyService.shared.resetToDefaults()
        
        ProcessHistory.shared.clearHistory()
        
        #if DEBUG
        print("[ConfigurationManager] All configurations reset")
        #endif
        
        NotificationCenter.default.post(name: .settingsDidReset, object: nil)
    }
    
    func createBackup() -> URL? {
        let backupDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenSwift", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        
        do {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = dateFormatter.string(from: Date())
            
            let backupFile = backupDir.appendingPathComponent("config_backup_\(timestamp).json")
            
            if let data = appSettings.exportConfiguration() {
                try data.write(to: backupFile, options: .atomic)
                #if DEBUG
                print("[ConfigurationManager] Backup created: \(backupFile.path)")
                #endif
                return backupFile
            }
        } catch {
            #if DEBUG
            print("[ConfigurationManager] Failed to create backup: \(error)")
            #endif
        }
        
        return nil
    }
    
    func listBackups() -> [URL] {
        let backupDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenSwift", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: backupDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            return contents
                .filter { $0.pathExtension == "json" }
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return date1 > date2
                }
        } catch {
            #if DEBUG
            print("[ConfigurationManager] Failed to list backups: \(error)")
            #endif
            return []
        }
    }
    
    func deleteBackup(at url: URL) {
        do {
            try fileManager.removeItem(at: url)
            #if DEBUG
            print("[ConfigurationManager] Backup deleted: \(url.path)")
            #endif
        } catch {
            #if DEBUG
            print("[ConfigurationManager] Failed to delete backup: \(error)")
            #endif
        }
    }
    
    func cleanupOldBackups(keepingCount: Int = 10) {
        let backups = listBackups()
        
        if backups.count > keepingCount {
            let backupsToDelete = backups.suffix(from: keepingCount)
            for backup in backupsToDelete {
                deleteBackup(at: backup)
            }
            #if DEBUG
            print("[ConfigurationManager] Cleaned up \(backupsToDelete.count) old backups")
            #endif
        }
    }
    
    func validateConfigurationData(_ data: Data) -> Bool {
        do {
            let decoder = JSONDecoder()
            _ = try decoder.decode(ConfigurationExportData.self, from: data)
            return true
        } catch {
            #if DEBUG
            print("[ConfigurationManager] Configuration validation failed: \(error)")
            #endif
            return false
        }
    }
    
    func getConfigurationInfo(_ data: Data) -> String? {
        do {
            let decoder = JSONDecoder()
            let config = try decoder.decode(ConfigurationExportData.self, from: data)
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            
            var info = "配置信息:\n"
            info += "- 应用设置: ✓\n"
            info += "- 快捷键配置: \(config.hotkeyConfigs.count) 个"
            
            return info
        } catch {
            return nil
        }
    }
}
