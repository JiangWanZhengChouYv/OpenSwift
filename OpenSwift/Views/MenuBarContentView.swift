import SwiftUI

struct MenuBarContentView: View {
    @Binding var showMenuBar: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("显示主界面") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Divider()

            Toggle("显示菜单栏图标", isOn: $showMenuBar)

            Divider()

            Button("退出") {
                AppState.shared.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding()
    }
}
