import SwiftUI

// SpeedSettingsSection.swift
// 「速度控制」设置区块从 SettingsView 拆出，满足 file_length <= 400。
struct SpeedSettingsSection: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("速度控制")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 12) {
                toggle(binding: $settings.rememberSpeedPerProcess, label: "记住速度设置", desc: "恢复上次速度")
                Divider()
                toggle(binding: $settings.speedSmoothingEnabled, label: "平滑过渡", desc: "改速时渐变到新倍率")
                if settings.speedSmoothingEnabled {
                    HStack {
                        Text("渐变时长：").font(.system(size: 13))
                        Slider(value: $settings.speedSmoothingDuration, in: 0.05...1.0, step: 0.05)
                        Text(String(format: "%.2fs", settings.speedSmoothingDuration))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 56)
                    }
                }
            }
            .padding()
            .glassCardBackground(cornerRadius: 8)
        }
    }

    private func toggle(binding: Binding<Bool>, label: String, desc: String) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13))
                Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}
