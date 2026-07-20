import SwiftUI
import AppKit

struct AppSelectorView: View {
    @StateObject private var viewModel = AppSelectorViewModel()
    @Environment(\.presentationMode) var presentationMode
    let onSelectApp: (URL) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            
            Divider()
            
            searchSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            
            Divider()
            
            if viewModel.isLoading {
                loadingView
            } else {
                appListSection
            }
            
            Divider()
            
            bottomSection
        }
        .frame(width: 700, height: 500)
        .sheet(isPresented: Binding(
            get: { viewModel.showError },
            set: { viewModel.showError = $0 }
        )) {
            ErrorAlertView(
                title: "启动失败",
                message: viewModel.errorMessage,
                onDismiss: {
                    viewModel.showError = false
                }
            )
        }
    }
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择应用")
                    .font(.system(size: 18, weight: .bold))
                Text("选择一个应用，OpenSwift 将使用 DYLD 注入方式启动它")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                close()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    private var searchSection: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            
            TextField("搜索应用名称或 Bundle ID...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
            
            if !viewModel.searchText.isEmpty {
                Button(action: {
                    viewModel.searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }
    
    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("正在扫描应用...")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }
    
    private var appListSection: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.filteredApps.isEmpty {
                    emptyStateView
                } else {
                    ForEach(viewModel.filteredApps) { app in
                        AppRowView(
                            app: app,
                            isSelected: viewModel.selectedApp?.id == app.id,
                            onSelect: {
                                viewModel.selectedApp = app
                            },
                            onLaunch: {
                                launchApp(app)
                            }
                        )
                        
                        if app.id != viewModel.filteredApps.last?.id {
                            Divider()
                                .padding(.leading, 72)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 60)
            
            Image(systemName: "app.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(viewModel.searchText.isEmpty ? "未找到应用" : "未找到匹配 \"\(viewModel.searchText)\" 的应用")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            
            if !viewModel.searchText.isEmpty {
                Button("清除搜索") {
                    viewModel.searchText = ""
                }
                .buttonStyle(.link)
            }
            
            Spacer()
        }
    }
    
    private var bottomSection: some View {
        HStack(spacing: 12) {
            Button(action: {
                openCustomApp()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("选择其他应用...")
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Button(action: {
                close()
            }) {
                Text("取消")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            
            Button(action: {
                if let app = viewModel.selectedApp {
                    launchApp(app)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("启动并加速")
                }
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .disabled(viewModel.selectedApp == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    private func close() {
        presentationMode.wrappedValue.dismiss()
    }
    
    private func launchApp(_ app: AppInfo) {
        onSelectApp(app.url)
        close()
    }
    
    private func openCustomApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle, .executable]
        panel.allowsOtherFileTypes = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "选择应用或可执行文件"
        panel.message = "选择要启动并加速的应用（.app）或可执行文件"
        
        if panel.runModal() == .OK, let url = panel.url {
            onSelectApp(url)
            close()
        }
    }
}

struct ErrorAlertView: View {
    let title: String
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text(title)
                .font(.system(size: 18, weight: .bold))
            
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("确定") {
                onDismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 300)
    }
}

struct AppRowView: View {
    let app: AppInfo
    let isSelected: Bool
    let onSelect: () -> Void
    let onLaunch: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                    .frame(width: 48, height: 48)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 14, weight: .medium))
                
                if let bundleId = app.bundleIdentifier {
                    Text(bundleId)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Text(app.url.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button(action: onLaunch) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("启动")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

#if DEBUG
struct AppSelectorView_Previews: PreviewProvider {
    static var previews: some View {
        AppSelectorView { _ in }
    }
}
#endif
