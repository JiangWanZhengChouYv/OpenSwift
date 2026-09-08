import SwiftUI

// SpeedControlPanel+Statistics.swift
// 变速统计入口卡片从主文件拆出，满足 file_length <= 400。
extension SpeedControlPanel {
    var speedStatisticsSection: some View {
        VStack(spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { showStatistics.toggle() }
            }) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)

                    Text("变速统计")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    accumulatedText
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showStatistics ? 180 : 0))
                }
                .padding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showStatistics {
                Divider()
                SpeedStatisticsView()
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }
        }
        .glassCardBackground(cornerRadius: 12)
    }

    private var accumulatedText: some View {
        let total = statistics.totalAccumulatedSeconds
        if total >= 60 {
            let minutes = Int(total / 60)
            let seconds = Int(total.truncatingRemainder(dividingBy: 60))
            return Text("累计加速 \(minutes)分\(seconds)秒")
        } else {
            return Text("累计加速 \(Int(total))秒")
        }
    }
}
