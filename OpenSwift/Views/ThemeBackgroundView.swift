import AppKit
import SwiftUI

struct ThemeBackgroundView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        backgroundContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(1 - settings.backgroundTransparency)
    }

    @ViewBuilder private var backgroundContent: some View {
        switch settings.backgroundStyle {
        case .none:
            Color.clear
        case .color:
            Color(hex: settings.backgroundColorHex)
        case .gradient:
            LinearGradient(
                colors: [Color(hex: settings.gradientStartHex), Color(hex: settings.gradientEndHex)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .image, .remoteImage:
            if let path = imagePath, let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
    }

    private var imagePath: String? {
        let path = settings.backgroundImagePath
        return path.isEmpty ? nil : path
    }
}
