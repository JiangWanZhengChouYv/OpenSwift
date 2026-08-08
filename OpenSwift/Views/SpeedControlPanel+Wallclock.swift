import SwiftUI

// MARK: - Wallclock Toggle Section
extension SpeedControlPanel {
    @ViewBuilder
    func wallclockToggleSection(for process: LaunchedProcess) -> some View {
        HStack {
            Image(systemName: "clock.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 13))
            Toggle("挂钟时间加速", isOn: Binding(
                get: { process.isWallclockHooked },
                set: { newValue in
                    appLauncherViewModel.updateWallclockHook(newValue, for: process)
                }
            ))
            .toggleStyle(.switch)
            .font(.system(size: 13))
            Spacer()
        }
        Text("关闭可避免网络/证书问题，但部分应用可能无法加速")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpeedControlPanel_Previews: PreviewProvider {
    static var previews: some View {
        SpeedControlPanel(
            speedControlState: SpeedControlState.shared,
            processManager: ProcessManager(),
            appLauncherViewModel: AppLauncherViewModel.shared,
            selectedTab: .constant(0)
        )
        .frame(width: 600, height: 800)
    }
}
