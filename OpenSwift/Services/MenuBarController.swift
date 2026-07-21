import Foundation

class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    @Published var isVisible: Bool = false

    private var isSetup: Bool = false

    private init() {
    }

    func setup() {
        guard !isSetup else { return }
        isSetup = true

        isVisible = AppSettings.shared.showInMenuBar
    }

    func shutdown() {
        isVisible = false
    }
}
