import Foundation

/// 断点续传下载器。
///
/// 基于 URLSessionDownloadDelegate 实时回报进度；下载失败时取出 `resumeData`，
/// 等待 3 秒后自动重连（续传优先，无 resumeData 则从头重试），直到成功或取消。
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onRetrying: (() -> Void)?
    var onSuccess: ((URL) -> Void)?
    var onFailed: ((String) -> Void)?

    private var url: URL?
    private var destination: URL?
    private var task: URLSessionDownloadTask?
    private var isCancelled = false
    private let queue = OperationQueue()

    override init() {
        super.init()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    func start(url: URL, destination: URL, version: String) {
        self.url = url
        self.destination = destination
        self.isCancelled = false
        launch(withResumeData: nil)
    }

    func cancel() {
        isCancelled = true
        task?.cancel(byProducingResumeData: { _ in })
        task = nil
    }

    // MARK: - 下载与重连

    private func launch(withResumeData resumeData: Data?) {
        let session = makeSession()
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else if let url {
            task = session.downloadTask(with: url)
        } else {
            return
        }
        task?.resume()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard !isCancelled, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(min(fraction, 1))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard !isCancelled, let destination else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async { [weak self] in
                self?.onSuccess?(destination)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onFailed?(error.localizedDescription)
            }
        }
    }
}

// MARK: - URLSessionTaskDelegate（放在 extension 以消除 "nearly matches" 警告）

extension UpdateDownloader {
    func urlSession(
        _ session: URLSession,
        task: URLSessionDownloadTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, !isCancelled else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.main.async { [weak self] in
            self?.onRetrying?()
        }
        // 等待 3 秒后自动重连。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isCancelled else { return }
                self.launch(withResumeData: resumeData)
            }
        }
    }
}
