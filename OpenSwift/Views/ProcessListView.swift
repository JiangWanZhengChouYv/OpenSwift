import SwiftUI
import AppKit

struct ProcessListView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var speedControlState: SpeedControlState
    @ObservedObject var appLauncherViewModel: AppLauncherViewModel
    @State private var selectedProcessId: UUID?
    
    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            
            Divider()
            
            sortOptionsBar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            
            Divider()
            
            if processManager.isLoading {
                loadingView
            } else if processManager.filteredProcesses.isEmpty {
                emptyStateView
            } else {
                processList
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var searchBar: some View {
        HStack {
            Image(nsImage: NSImage(named: NSImage.quickLookTemplateName) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(.secondary)
            
            TextField("搜索进程名称或 PID...", text: Binding(
                get: { processManager.searchText },
                set: { processManager.updateSearchText($0) }
            ))
            .textFieldStyle(.plain)
            
            if !processManager.searchText.isEmpty {
                Button(action: {
                    processManager.updateSearchText("")
                }) {
                    Image(nsImage: NSImage(named: NSImage.stopProgressFreestandingTemplateName) ?? NSImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }
    
    private var sortOptionsBar: some View {
        HStack {
            Text("排序: ")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            ForEach(ProcessSortOption.allCases, id: \.self) { option in
                Button(action: {
                    processManager.updateSortOption(option)
                }) {
                    Text(option.rawValue)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            processManager.sortOption == option
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                injectedCountBadge
                
                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenAppSelector"), object: nil)
                }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("启动并加速应用")
                
                Button(action: {
                    processManager.refreshProcesses()
                }) {
                    Image(nsImage: NSImage(named: NSImage.refreshFreestandingTemplateName) ?? NSImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .help("刷新进程列表")
            }
        }
    }
    
    private var injectedCountBadge: some View {
        Group {
            if processManager.injectedProcesses.count > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(hex: "34C759"))
                        .frame(width: 6, height: 6)
                    
                    Text("\(processManager.injectedProcesses.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                )
            }
        }
    }
    
    private var loadingView: some View {
        VStack {
            Spacer()
            NSProgressIndicatorRepresentable()
                .frame(width: 32, height: 32)
            Text("加载进程列表...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSImage(named: NSImage.statusAvailableName) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .foregroundColor(.secondary)
            
            if processManager.searchText.isEmpty {
                Text("暂无运行中的进程")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            } else {
                Text("未找到匹配 \"\(processManager.searchText)\" 的进程")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Button("清除搜索") {
                    processManager.updateSearchText("")
                }
                .buttonStyle(.link)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    private var processList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(processManager.filteredProcesses) { process in
                    ProcessRowViewWithContextMenu(
                        process: process,
                        isSelected: selectedProcessId == process.id,
                        processManager: processManager,
                        appLauncherViewModel: appLauncherViewModel
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if selectedProcessId == process.id {
                                selectedProcessId = nil
                                processManager.clearSelection()
                                speedControlState.selectedProcess = nil
                            } else {
                                selectedProcessId = process.id
                                processManager.selectProcess(process)
                                speedControlState.selectedProcess = process
                            }
                        }
                        provideHapticFeedback()
                    }
                    .id(process.id)
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    private func provideHapticFeedback() {
        // Haptic feedback is not available on macOS
        // This is a placeholder for future macOS haptic support
    }
}

struct NSProgressIndicatorRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)
        return indicator
    }
    
    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
    }
}

struct ProcessListView_Previews: PreviewProvider {
    static var previews: some View {
        ProcessListView(
            processManager: ProcessManager(),
            speedControlState: SpeedControlState.shared,
            appLauncherViewModel: AppLauncherViewModel.shared
        )
        .frame(width: 300, height: 500)
    }
}

// MARK: - Group Management Views
struct GroupManagerView: View {
    @ObservedObject var processManager: ProcessManager
    @State private var newGroupName: String = ""
    @State private var showNewGroupDialog: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("进程组管理")
                    .font(.system(size: 18, weight: .bold))
                
                Spacer()
                
                Button(action: {
                    showNewGroupDialog = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            if processManager.processGroups.isEmpty {
                emptyGroupsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(processManager.processGroups) { group in
                            GroupCard(
                                group: group,
                                onApply: {
                                    processManager.applyGroup(group)
                                },
                                onDelete: {
                                    processManager.deleteGroup(group)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
            
            Spacer()
        }
        .frame(width: 500, height: 400)
        .alert(isPresented: $showNewGroupDialog) {
            Alert(
                title: Text("创建新进程组"),
                message: Text("输入新进程组的名称"),
                primaryButton: .default(Text("创建")) {
                    if !newGroupName.isEmpty {
                        _ = processManager.createGroup(
                            name: newGroupName,
                            processes: processManager.injectedProcesses
                        )
                        newGroupName = ""
                    }
                },
                secondaryButton: .cancel() {
                    newGroupName = ""
                }
            )
        }
    }
    
    private var emptyGroupsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("暂无进程组")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
            
            Text("点击 + 按钮创建新的进程组")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GroupCard: View {
    let group: ProcessGroup
    let onApply: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.system(size: 14, weight: .semibold))
                
                Text("\(group.processCount) 个进程")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onApply) {
                Text("应用")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(group.processCount == 0)
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}
