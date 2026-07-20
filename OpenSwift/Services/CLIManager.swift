import Foundation
import CryptoKit
import os.log

extension OSLog {
    static let cli = OSLog(subsystem: "com.openswift.app", category: "CLI")
}

class CLIManager {
    static let shared = CLIManager()

    private init() {
        logDebug("CLIManager initialized", log: .cli)
    }

    func setup() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.installOrUpdateCLI()
        }
    }

    private let installPaths: [String] = [
        "/usr/local/bin/openswift",
        "/opt/homebrew/bin/openswift"
    ]

    private func installOrUpdateCLI() {
        let internalPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/openswift").path

        guard FileManager.default.fileExists(atPath: internalPath) else {
            logDebug("Internal CLI not found at: \(internalPath)", log: .cli)
            return
        }

        let targetPath = selectInstallPath()
        guard let target = targetPath else {
            logDebug("No writable install path found", log: .cli)
            return
        }

        do {
            let internalHash = try sha256Hash(ofFileAt: internalPath)

            if !FileManager.default.fileExists(atPath: target) {
                try FileManager.default.copyItem(atPath: internalPath, toPath: target)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: target
                )
                logInfo("CLI installed to \(target)", log: .cli)
                return
            }

            let targetHash = try sha256Hash(ofFileAt: target)

            if internalHash == targetHash {
                logDebug("CLI already up to date at \(target)", log: .cli)
                return
            }

            try FileManager.default.removeItem(atPath: target)
            try FileManager.default.copyItem(atPath: internalPath, toPath: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: target
            )
            logInfo("CLI updated at \(target)", log: .cli)
        } catch {
            logError("CLI install/update failed: \(error.localizedDescription)", log: .cli)
        }
    }

    private func selectInstallPath() -> String? {
        let fm = FileManager.default
        let testFileName = ".openswift_write_test"

        for fullPath in installPaths {
            let dirPath = (fullPath as NSString).deletingLastPathComponent
            var isDir: ObjCBool = false

            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            let testPath = (dirPath as NSString).appendingPathComponent(testFileName)
            if fm.createFile(atPath: testPath, contents: nil, attributes: nil) {
                try? fm.removeItem(atPath: testPath)
                return fullPath
            }
        }

        return nil
    }

    private func sha256Hash(ofFileAt path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
