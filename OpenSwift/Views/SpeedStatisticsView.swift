import SwiftUI
import AppKit

// 变速统计面板：默认一个「变速统计」卡片，点击展开显示横向条形统计图。
// 每一根对应一个进程，长度为累计加速时长，旁标进程名、次数与当前倍率。
struct SpeedStatisticsView: View {
    @ObservedObject var statistics = SpeedStatistics.shared
    @State private var metric: Metric = .duration

    enum Metric: String, CaseIterable, Identifiable {
        case duration = "时长"
        case changes = "次数"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if statistics.items.isEmpty {
                emptyView
            } else {
                metricPicker
                chart
            }
        }
        .padding()
        .glassCardBackground(cornerRadius: 12)
    }

    private var header: some View {
        HStack {
            Text("变速统计")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("累计加速 \(formatShort(statistics.totalAccumulatedSeconds))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var metricPicker: some View {
        Picker("统计项", selection: $metric) {
            ForEach(Metric.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
    }

    private var emptyView: some View {
        Text("暂无加速数据")
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    @ViewBuilder
    private var chart: some View {
        let ordered = statistics.items.sorted { value(of: $0) > value(of: $1) }
        let maxValue = max(ordered.map(value).max() ?? 1, 1)
        VStack(spacing: 12) {
            ForEach(ordered) { item in
                barRow(for: item, maxValue: maxValue)
            }
        }
    }

    private func value(of item: SpeedStatItem) -> Double {
        switch metric {
        case .duration: return item.accumulatedSeconds
        case .changes: return Double(item.changeCount)
        }
    }

    private func barRow(for item: SpeedStatItem, maxValue: Double) -> some View {
        HStack(spacing: 10) {
            Text(item.processName)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.accentColor.opacity(0.6), .accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(6, proxy.size.width * CGFloat(min(value(of: item) / maxValue, 1))))
                }
            }
            .frame(height: 10)

            Text(formatValue(value(of: item)))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 64, alignment: .trailing)

            Text("\(item.changeCount) 次 · 当前 \(String(format: "%.1fx", item.currentRatio))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .trailing)
                .lineLimit(1)
        }
        .frame(height: 20)
        .animation(.easeInOut(duration: 0.2), value: value(of: item))
    }

    private func formatShort(_ seconds: Double) -> String {
        if seconds >= 60 {
            return String(format: "%.0f分%.0f秒", seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
        }
        return String(format: "%.0f秒", seconds)
    }

    private func formatValue(_ value: Double) -> String {
        if metric == .duration {
            return formatShort(value)
        }
        return "\(Int(value))"
    }
}
