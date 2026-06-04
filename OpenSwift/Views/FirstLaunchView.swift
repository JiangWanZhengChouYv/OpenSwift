import SwiftUI

struct FirstLaunchView: View {
    @Environment(\.presentationMode) var presentationMode
    let onComplete: () -> Void
    
    @State private var currentStep = 0
    
    private let steps = [
        FirstLaunchStep(
            icon: "speedometer",
            title: "欢迎使用 OpenSwift",
            description: "一个强大的进程速度控制工具，可以帮助您调整 macOS 上应用的运行速度。",
            features: [
                "实时速度调节",
                "多进程独立控制",
                "安全可靠的实现"
            ]
        ),
        FirstLaunchStep(
            icon: "bolt.fill",
            title: "两种加速方式",
            description: "OpenSwift 提供两种方式来控制进程速度，您可以根据需求选择。",
            features: [
                "方式一：DYLD 注入启动（推荐）",
                "方式二：注入已运行进程"
            ],
            details: [
                "• DYLD 注入启动：通过环境变量注入，无需 SIP，更安全",
                "• 注入已运行进程：需要禁用 SIP 或特殊权限"
            ]
        ),
        FirstLaunchStep(
            icon: "lock.shield.fill",
            title: "安全声明",
            description: "我们非常重视您的隐私和安全。",
            features: [
                "完全本地运行",
                "不收集任何用户信息",
                "不连接服务器",
                "开源透明"
            ],
            details: [
                "• 所有功能在您的 Mac 本地完成",
                "• 没有数据上报",
                "• 您的隐私完全受到保护"
            ]
        ),
        FirstLaunchStep(
            icon: "checkmark.circle.fill",
            title: "开始使用",
            description: "您已经准备好开始使用 OpenSwift 了！",
            features: [
                "点击下方按钮开始",
                "选择应用启动并加速",
                "或者选择已运行的进程注入"
            ]
        )
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            contentSection
            
            Divider()
            
            bottomSection
        }
        .frame(width: 600, height: 580)
    }
    
    private var contentSection: some View {
        VStack(spacing: 24) {
            stepIndicator
            
            Spacer()
            
            stepContent
            
            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }
    
    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(0..<steps.count, id: \.self) { index in
                Circle()
                    .fill(index < currentStep ? Color(hex: "34C759") : 
                          index == currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)
                
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < currentStep ? Color(hex: "34C759") : Color.gray.opacity(0.3))
                        .frame(height: 2)
                }
            }
        }
        .padding(.bottom, 8)
    }
    
    private var stepContent: some View {
        VStack(spacing: 20) {
            Image(systemName: steps[currentStep].icon)
                .font(.system(size: 60))
                .foregroundColor(currentStep == steps.count - 1 ? Color(hex: "34C759") : .accentColor)
            
            Text(steps[currentStep].title)
                .font(.system(size: 24, weight: .bold))
            
            Text(steps[currentStep].description)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps[currentStep].features, id: \.self) { feature in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(hex: "34C759"))
                            .font(.system(size: 12))
                        
                        Text(feature)
                            .font(.system(size: 13))
                    }
                }
                
                if let details = steps[currentStep].details {
                    Divider()
                        .padding(.vertical, 4)
                    
                    ForEach(details, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
    
    private var bottomSection: some View {
        HStack {
            // 上一步按钮 - 在步骤 1、2、3 显示
            if currentStep >= 1 {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep -= 1
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("上一步")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
            
            Spacer()
            
            // 下一步/开始使用按钮
            if currentStep == steps.count - 1 {
                // 最后一步（步骤3）：显示开始使用按钮
                Button(action: {
                    onComplete()
                    close()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("开始使用")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .background(Color(hex: "34C759"))
                .foregroundColor(.white)
                .keyboardShortcut(.defaultAction)
            } else {
                // 步骤0、1、2：显示下一步按钮
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep += 1
                    }
                }) {
                    HStack(spacing: 4) {
                        Text("下一步")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 16)
    }
    
    private func close() {
        presentationMode.wrappedValue.dismiss()
    }
}

struct FirstLaunchStep {
    let icon: String
    let title: String
    let description: String
    let features: [String]
    let details: [String]?
    
    init(icon: String, title: String, description: String, features: [String], details: [String]? = nil) {
        self.icon = icon
        self.title = title
        self.description = description
        self.features = features
        self.details = details
    }
}

#if DEBUG
struct FirstLaunchView_Previews: PreviewProvider {
    static var previews: some View {
        FirstLaunchView { }
    }
}
#endif
