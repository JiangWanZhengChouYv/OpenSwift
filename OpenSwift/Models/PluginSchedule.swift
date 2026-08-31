import Foundation

/// 定时调整倍率的一段：以指定倍率持续指定时长（秒）。
struct ScheduleSegment: Codable, Equatable, Identifiable {
    var ratio: Double
    var duration: Int

    var id: String { "\(ratio)-\(duration)" }
}

/// 定时调整倍率的一条完整方案：命中目标进程后按分段序列自动变速。
struct SchedulePlan: Codable, Equatable, Identifiable {
    var process: String
    var save: Bool
    var name: String
    var segments: [ScheduleSegment]
    var id: UUID

    init(process: String = "", save: Bool = true, name: String = "", segments: [ScheduleSegment] = []) {
        self.process = process
        self.save = save
        self.name = name
        self.segments = segments
        self.id = UUID()
    }

    /// 从 JSON 字符串解码方案数组；失败时返回空数组，保证不崩溃。
    static func decode(_ json: String) -> [SchedulePlan] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([SchedulePlan].self, from: data)) ?? []
    }

    /// 将方案数组编码为 JSON 字符串，供 list 控件持久化到配置。
    static func encode(_ plans: [SchedulePlan]) -> String {
        let json = (try? JSONEncoder().encode(plans)) ?? Data()
        return String(data: json, encoding: .utf8) ?? "[]"
    }
}
