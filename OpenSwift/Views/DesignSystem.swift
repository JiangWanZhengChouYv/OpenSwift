import SwiftUI

/// 统一视觉常量：间距 / 圆角 / 阴影 / 背景。
/// 供各视图复用，避免散落魔法数值；配色自动适配浅色与深色模式。
enum Design {
    // MARK: - 圆角

    static let cornerRadius: CGFloat = 12
    static let cornerRadiusSmall: CGFloat = 8
    static let cornerRadiusLarge: CGFloat = 16

    // MARK: - 间距

    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 20

    // MARK: - 阴影（轻、柔和）

    static let cardShadowColor = Color.black.opacity(0.06)
    static let cardShadowRadius: CGFloat = 6
    static let cardShadowY: CGFloat = 2

    // MARK: - 背景（自动适配深浅色）

    /// 卡片/分区背景：比窗口色略高一档，制造轻微悬浮层次。
    static var cardBackground: Color { Color(nsColor: .underPageBackgroundColor) }

    /// 面板/工具栏背景。
    static var panelBackground: Color { Color(nsColor: .controlBackgroundColor) }

    /// 卡片悬停高亮。
    static var hoverAccent: Color { Color.accentColor.opacity(0.08) }
}

extension View {
    /// 给卡片/分区统一应用的现代化外观：背景 + 圆角 + 柔和阴影。
    func designCard() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .fill(Design.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.cornerRadius)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .shadow(
            color: Design.cardShadowColor,
            radius: Design.cardShadowRadius,
            x: 0,
            y: Design.cardShadowY
        )
    }
}
