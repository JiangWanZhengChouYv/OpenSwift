import AppKit
import SwiftUI

/// 插件面板：展示已导入的插件列表，并支持从本地 zip 导入新插件。
struct PluginListView: View {
    @ObservedObject private var store = PluginStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isImporting: Bool = false
    @State private var showImportError: Bool = false
    @State private var importErrorMessage: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Group {
                if store.plugins.isEmpty {
                    emptyStateView
                } else {
                    pluginList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            PluginMarketSection()
        }
        .frame(minWidth: 520, minHeight: 460)
        .alert("导入插件失败", isPresented: $showImportError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importErrorMessage)
        }
    }

    // MARK: - 顶部栏

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("插件")
                .font(.system(size: 14, weight: .semibold))

            Text("共 \(store.count) 个")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()

            Button(action: {
                importPlugin()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    Text("导入插件")
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)

            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Design.panelBackground)
    }

    // MARK: - 列表

    private var pluginList: some View {
        List {
            ForEach(store.plugins) { plugin in
                PluginRow(
                    plugin: plugin,
                    onToggle: { enabled in
                        store.setEnabled(enabled, for: plugin.id)
                    },
                    onDelete: {
                        store.remove(id: plugin.id)
                    }
                )
            }
            .onDelete { indexSet in
                for index in indexSet {
                    store.remove(id: store.plugins[index].id)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 空态

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 44))
                .foregroundColor(.secondary)

            Text("暂无插件")
                .font(.system(size: 15, weight: .medium))

            Button(action: {
                importPlugin()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    Text("导入插件")
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 导入

    private func importPlugin() {
        let panel = NSOpenPanel()
        panel.title = "选择插件包"
        panel.message = "请选择一个包含 manifest.yml 的插件 zip 包"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        isImporting = true
        defer { isImporting = false }

        do {
            let directory = try PluginUnzipper.shared.unzip(at: url)
            let manifest = try PluginParser.parseManifest(at: directory.appendingPathComponent("manifest.yml"))
            let plugin = Plugin(manifest: manifest, sourceDirectory: directory)
            store.add(plugin)
        } catch {
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }
}

/// 单个插件的行视图。
private struct PluginRow: View {
    let plugin: Plugin
    let onToggle: (_ enabled: Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.fill")
                    .font(.system(size: 16))
                    .foregroundColor(plugin.isEnabled ? Color(hex: "34C759") : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name)
                        .font(.system(size: 13, weight: .medium))

                    if let description = plugin.manifest.descriptionText, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text("v\(plugin.version)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Toggle("", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            onToggle(newValue)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)

                Menu {
                    Button(action: onDelete) {
                        Text("删除插件")
                            .foregroundColor(.red)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
            }

            if plugin.isEnabled && !plugin.manifest.ui.isEmpty {
                Group {
                    Divider()
                        .padding(.vertical, 4)
                    controlsArea
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .padding(.vertical, 4)
    }

    /// 依据清单 ui 定义的动态控件区域。
    @ViewBuilder
    private var controlsArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(plugin.manifest.ui.filter { ($0.slot ?? "plugin") != "home" }) { element in
                PluginUIControlView(pluginID: plugin.id, element: element)
            }
        }
        .padding(.leading, 34)
    }
}
