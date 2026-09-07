import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

/// 「设置 → 界面」页中的「外观」设置区。
/// 提供深色模式选择、界面背景类型配置与实时预览。
struct AppearanceSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @State private var showImageImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("外观")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            contentView
                .padding()
                .glassCardBackground(cornerRadius: 8)
        }
        .fileImporter(
            isPresented: $showImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImageImport(result: result)
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder private var contentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            darkModePicker
            backgroundStylePicker
            backgroundControlView
            if settings.backgroundStyle != .none {
                opacitySlider
            }
            previewView
        }
    }

    private var darkModePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("深色模式").font(.system(size: 13))
            Picker("深色模式", selection: $settings.darkMode) {
                ForEach(DarkModePreference.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var backgroundStylePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("背景类型").font(.system(size: 13))
            Picker("背景类型", selection: $settings.backgroundStyle) {
                ForEach(BackgroundStyle.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var backgroundControlView: some View {
        switch settings.backgroundStyle {
        case .color:
            ColorPicker("背景颜色", selection: colorBinding(for: $settings.backgroundColorHex))
        case .gradient:
            ColorPicker("起始色", selection: colorBinding(for: $settings.gradientStartHex))
            ColorPicker("结束色", selection: colorBinding(for: $settings.gradientEndHex))
        case .image:
            imageControls
        case .remoteImage:
            remoteControls
        case .none:
            EmptyView()
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("选择图片") { showImageImporter = true }
                .buttonStyle(.bordered)
            if !settings.backgroundImagePath.isEmpty {
                Button("移除图片") { settings.backgroundImagePath = "" }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var remoteControls: some View {
        HStack(spacing: 8) {
            TextField("粘贴在线图片链接", text: $settings.remoteBackgroundURL)
                .textFieldStyle(.roundedBorder)
            Button("下载") { downloadRemoteImage() }
                .buttonStyle(.bordered)
        }
    }

    private var opacitySlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("背景透明度").font(.system(size: 13))
                Spacer()
                Text("\(Int(round(settings.backgroundTransparency * 100)))%")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.backgroundTransparency, in: 0...1, step: 0.05)
        }
    }

    private var previewView: some View {
        ZStack {
            previewBackground
                .opacity(1 - settings.backgroundTransparency)
            if settings.backgroundStyle == .none {
                Text("无背景")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 200, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .glassCardBackground(cornerRadius: 8)
    }

    @ViewBuilder private var previewBackground: some View {
        switch settings.backgroundStyle {
        case .none:
            Color.gray.opacity(0.15)
        case .color:
            Color(hex: settings.backgroundColorHex)
        case .gradient:
            LinearGradient(
                colors: [
                    Color(hex: settings.gradientStartHex),
                    Color(hex: settings.gradientEndHex)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .image, .remoteImage:
            if let image = loadPreviewImage() {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.15)
            }
        }
    }

    private func loadPreviewImage() -> NSImage? {
        let path = settings.backgroundImagePath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private func handleImageImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let path = BackgroundImageManager.shared.cacheLocalImage(from: url) {
            settings.backgroundImagePath = path
        } else {
            showErrorMessage("图片缓存失败，请重试")
        }
    }

    private func downloadRemoteImage() {
        let url = settings.remoteBackgroundURL
        guard !url.isEmpty else { return }
        Task { @MainActor in
            do {
                let path = try await BackgroundImageManager.shared.downloadRemoteImage(from: url)
                settings.backgroundImagePath = path
            } catch {
                showErrorMessage("下载失败：\(error.localizedDescription)")
            }
        }
    }

    private func showErrorMessage(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

private extension Color {
    /// 转成 #RRGGBB 十六进制字符串（供设置持久化用）。
    /// 经 CGColor 转 sRGB 取 components，保证 Color(hex:) 可近似还原。
    var hexString: String {
        guard let cgColor = self.cgColor,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else {
            return ""
        }
        let red = Int(round(components[0] * 255))
        let green = Int(round(components[1] * 255))
        let blue = Int(round(components[2] * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private func colorBinding(for hex: Binding<String>) -> Binding<Color> {
    Binding(
        get: { Color(hex: hex.wrappedValue) },
        set: { hex.wrappedValue = $0.hexString }
    )
}
