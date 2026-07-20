import SwiftUI
import AppKit

struct AppInfo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    
    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        return lhs.url == rhs.url
    }
}

class AppSelectorViewModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var selectedApp: AppInfo?
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    
    var filteredApps: [AppInfo] {
        if searchText.isEmpty {
            return apps
        }
        return apps.filter { app in
            app.name.localizedCaseInsensitiveContains(searchText) ||
            (app.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    init() {
        loadApplications()
    }
    
    func loadApplications() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = self?.scanApplications() ?? []
            DispatchQueue.main.async {
                self?.apps = apps
                self?.isLoading = false
            }
        }
    }
    
    private func scanApplications() -> [AppInfo] {
        var apps: [AppInfo] = []
        
        let applicationsDir = URL(fileURLWithPath: "/Applications")
        let systemApplicationsDir = URL(fileURLWithPath: "/System/Applications")
        let userApplicationsDir = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first
        
        let directories = [applicationsDir, systemApplicationsDir, userApplicationsDir].compactMap { $0 }
        
        for dir in directories {
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for appURL in contents where appURL.pathExtension == "app" {
                    if let appInfo = createAppInfo(from: appURL) {
                        apps.append(appInfo)
                    }
                }
            }
        }
        
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    private func createAppInfo(from url: URL) -> AppInfo? {
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? 
                   bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ??
                   url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = bundle?.bundleIdentifier
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        
        return AppInfo(
            url: url,
            name: name,
            bundleIdentifier: bundleIdentifier,
            icon: icon
        )
    }
}
