import SwiftUI

/// 图形化更新界面。观察 `UpdateManager.shared`，按阶段渲染。
struct UpdatePanelView: View {
    @ObservedObject private var manager = UpdateManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 380, height: 340)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("检查更新")
                    .font(.system(size: 15, weight: .semibold))
                Text(versionLine)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var versionLine: String {
        switch manager.phase {
        case .updateAvailable:
            let current = AppVersion.short
            let latest = manager.manifest?.version ?? "?"
            return "当前 v\(current) → 最新 v\(latest)"
        case .downloading, .retrying:
            return "下载中…"
        case .installing:
            return "正在安装…"
        case .finished:
            return "下载完成"
        default:
            return "OpenSwift"
        }
    }

    // MARK: - 主内容

    @ViewBuilder
    private var content: some View {
        switch manager.phase {
        case .checking:
            statusRow(icon: "hourglass", color: .secondary, text: "正在检查更新…")
                .frame(maxHeight: .infinity)

        case .updateAvailable:
            VStack(alignment: .leading, spacing: 10) {
                Text("有新版本可用")
                    .font(.system(size: 13, weight: .semibold))
                if let notes = manager.manifest?.notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

        case .downloading:
            progressArea(text: "下载中…")

        case .retrying:
            progressArea(text: "连接中断，将在 3 秒后自动重试…")

        case .latest:
            statusRow(icon: "checkmark.circle", color: .green,
                      text: "当前已是最新版本 v\(AppVersion.short)")
                .frame(maxHeight: .infinity)

        case .finished:
            statusRow(icon: "checkmark.circle.fill", color: .green,
                      text: "新版本已下载")
                .frame(maxHeight: .infinity)

        case .installing:
            statusRow(icon: "arrow.triangle.2.circlepath.circle", color: .accentColor,
                      text: manager.statusMessage ?? "正在安装新版本并重启…")
                .frame(maxHeight: .infinity)

        case .failed:
            statusRow(icon: "exclamationmark.triangle", color: .orange,
                      text: manager.statusMessage ?? "检查更新失败")
                .frame(maxHeight: .infinity)

        case .idle:
            Color.clear.frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func progressArea(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: manager.progress)
                .tint(.accentColor)
            HStack {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(manager.progress * 100))%")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部按钮

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch manager.phase {
            case .checking, .idle:
                Button("关闭") { manager.cancel() }
            case .updateAvailable:
                Button("下载更新") { manager.startDownload() }.buttonStyle(.borderedProminent)
                Button("取消") { manager.cancel() }
            case .downloading, .retrying:
                Button("取消") { manager.cancel() }
            case .latest:
                Button("关闭") { manager.cancel() }
            case .finished:
                Button("在 Finder 中显示") { manager.revealDownloaded() }
                Button("关闭") { manager.cancel() }
            case .installing:
                Button("在 Finder 中显示") { manager.revealDownloaded() }
            case .failed:
                Button("重试") { manager.checkForUpdates() }
                Button("关闭") { manager.cancel() }
            }
        }
    }
}
