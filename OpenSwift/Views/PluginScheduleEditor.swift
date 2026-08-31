import SwiftUI
import AppKit

/// 「定时调整倍率」插件的方案列表编辑器（对应 L1 UI `list` 控件）。
/// 绑定一段 JSON 字符串配置，增删方案行并实时把整个模型序列化回写。
struct PluginScheduleEditor: View {
    let pluginID: String
    let key: String
    let label: String?

    @State private var plans: [SchedulePlan] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label ?? key)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: { addPlan() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("添加方案")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
            }

            if plans.isEmpty {
                Text("暂无方案，点击右上角「添加方案」")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($plans) { $plan in
                            planEditor(plan: $plan)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear(perform: load)
    }

    // MARK: - 单条方案编辑

    @ViewBuilder
    private func planEditor(plan: Binding<SchedulePlan>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            planHeader(plan: plan)

            planSegments(plan: plan)
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func planHeader(plan: Binding<SchedulePlan>) -> some View {
        HStack(spacing: 8) {
            TextField("进程名（如 TimerTestApp）", text: plan.process)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onChange(of: plan.process.wrappedValue) { _ in persist() }

            TextField("方案名称", text: plan.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 120)
                .onChange(of: plan.name.wrappedValue) { _ in persist() }

            Toggle("保存", isOn: plan.save)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
                .onChange(of: plan.save.wrappedValue) { _ in persist() }

            Button(action: { removePlan(plan: plan.wrappedValue) }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private func planSegments(plan: Binding<SchedulePlan>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(plan.wrappedValue.segments.enumerated()), id: \.offset) { offset, _ in
                HStack(spacing: 8) {
                    TextField("倍率", text: ratioBinding(plan: plan, segmentIndex: offset))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 80)

                    Text("×")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    TextField("时长(秒)", text: durationBinding(plan: plan, segmentIndex: offset))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 80)

                    Spacer()

                    Button(action: { removeSegment(plan: plan, segmentIndex: offset) }) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }

            Button(action: { addSegment(plan: plan) }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                    Text("添加分段")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
    }

    // MARK: - 数据操作

    private func load() {
        if case .string(let json)? = PluginStore.shared.configValue(pluginID: pluginID, key: key) {
            plans = SchedulePlan.decode(json)
        } else {
            plans = []
        }
    }

    private func persist() {
        let json = SchedulePlan.encode(plans)
        PluginStore.shared.setConfig(.string(json), forKey: key, pluginID: pluginID)
    }

    private func addPlan() {
        plans.append(SchedulePlan())
        persist()
    }

    private func removePlan(plan: SchedulePlan) {
        plans.removeAll { $0.id == plan.id }
        persist()
    }

    private func addSegment(plan: Binding<SchedulePlan>) {
        plan.wrappedValue.segments.append(ScheduleSegment(ratio: 1.0, duration: 60))
        persist()
    }

    private func removeSegment(plan: Binding<SchedulePlan>, segmentIndex: Int) {
        guard plan.wrappedValue.segments.indices.contains(segmentIndex) else { return }
        plan.wrappedValue.segments.remove(at: segmentIndex)
        persist()
    }

    private func ratioBinding(plan: Binding<SchedulePlan>, segmentIndex: Int) -> Binding<String> {
        Binding<String>(
            get: {
                guard plan.wrappedValue.segments.indices.contains(segmentIndex) else { return "" }
                return String(format: "%.1f", plan.wrappedValue.segments[segmentIndex].ratio)
            },
            set: { newValue in
                guard plan.wrappedValue.segments.indices.contains(segmentIndex),
                      let value = Double(newValue), value > 0 else { return }
                plan.wrappedValue.segments[segmentIndex].ratio = value
                persist()
            }
        )
    }

    private func durationBinding(plan: Binding<SchedulePlan>, segmentIndex: Int) -> Binding<String> {
        Binding<String>(
            get: {
                guard plan.wrappedValue.segments.indices.contains(segmentIndex) else { return "" }
                return String(plan.wrappedValue.segments[segmentIndex].duration)
            },
            set: { newValue in
                guard plan.wrappedValue.segments.indices.contains(segmentIndex),
                      let value = Int(newValue), value >= 0 else { return }
                plan.wrappedValue.segments[segmentIndex].duration = value
                persist()
            }
        )
    }
}
