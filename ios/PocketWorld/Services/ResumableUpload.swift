import Foundation

// Resumable upload of a capture's original video (server: `/v2/captures/:id/rgb-upload`).
// The phone declares the file's SHA-256, size and type; the server answers with how many bytes it
// already holds; the phone sends the rest with `PATCH` + `Upload-Offset`. A dropped connection
// keeps the bytes that arrived, so the next attempt continues from there instead of restarting.
// Integrity is decided by the server's SHA-256 of the complete file.

struct RGBUploadDeclaration: Encodable, Sendable {
    let sha256: String
    let byteSize: Int64
    let mime: String
}

struct RGBUploadStatus: Decodable, Equatable, Sendable {
    let sha256: String
    let byteSize: Int64
    let mime: String
    let offset: Int64
    let complete: Bool
}

struct RGBUploadEnvelope: Decodable, Sendable {
    let upload: RGBUploadStatus?
    let capture: CaptureV2Status?
}

enum ResumableUploadError: LocalizedError {
    case serverStateMismatch
    case stalled(sent: Int64, total: Int64)

    var errorDescription: String? {
        switch self {
        case .serverStateMismatch:
            return "服务器上的上传记录与本机原片不一致，请重新提交。"
        case .stalled(let sent, let total):
            let percent = total > 0 ? Int(Double(sent) / Double(total) * 100) : 0
            return "网络多次中断，已上传 \(percent)%。已收到的部分保留在服务器上，再次提交会从断点继续。"
        }
    }
}

/// Sends one request body from a file. Production uses a background session, so iOS keeps
/// uploading while the app is suspended or the screen is locked.
protocol UploadBodySending: AnyObject {
    func send(_ request: URLRequest, fromFile file: URL,
              progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, URLResponse)
}

enum ResumableUpload {
    static let offsetContentType = "application/offset+octet-stream"

    /// A file holding `file`'s bytes from `offset` to the end; the original file when offset is 0.
    static func body(of file: URL, from offset: Int64, in directory: URL) throws -> URL {
        guard offset > 0 else { return file }
        let output = directory.appendingPathComponent("remainder-\(offset)-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let reader = try FileHandle(forReadingFrom: file)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? reader.close(); try? writer.close() }
        try reader.seek(toOffset: UInt64(offset))
        while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        return output
    }

    /// Network failures, timeouts, an offset race (409) and server-side errors are worth retrying;
    /// validation failures (wrong hash, wrong type, ownership) are not.
    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .backgroundSessionWasDisconnected,
                    .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed].contains(error.code)
        }
        if case APIError.server(let status, _) = error { return status == 409 || status == 408 || status == 429 || status >= 500 }
        return false
    }

    /// Declare → send the remainder → after an interruption ask again and continue. Gives up only
    /// after `maxStalls` consecutive attempts that made no progress.
    @MainActor
    static func run(byteSize: Int64, maxStalls: Int = 6,
                    declare: () async throws -> RGBUploadEnvelope,
                    send: (_ offset: Int64) async throws -> RGBUploadEnvelope,
                    pause: (_ stalls: Int) async throws -> Void) async throws -> CaptureV2Status {
        let envelope = try await transfer(byteSize: byteSize, maxStalls: maxStalls, declare: declare, send: send, pause: pause)
        guard let capture = envelope.capture else { throw ResumableUploadError.serverStateMismatch }
        return capture
    }

    @MainActor
    static func transfer(byteSize: Int64, maxStalls: Int = 6,
                         declare: () async throws -> RGBUploadEnvelope,
                         send: (_ offset: Int64) async throws -> RGBUploadEnvelope,
                         pause: (_ stalls: Int) async throws -> Void) async throws -> RGBUploadEnvelope {
        var bestOffset: Int64 = -1
        var stalls = 0
        while true {
            try Task.checkCancellation()
            let declared = try await declare()
            guard let status = declared.upload, status.byteSize == byteSize,
                  status.offset >= 0, status.offset <= byteSize else { throw ResumableUploadError.serverStateMismatch }
            if status.complete { guard status.offset == byteSize else { throw ResumableUploadError.serverStateMismatch }; return declared }
            if status.offset > bestOffset { bestOffset = status.offset; stalls = 0 } else { stalls += 1 }
            if stalls >= maxStalls { throw ResumableUploadError.stalled(sent: status.offset, total: byteSize) }
            do {
                let result = try await send(status.offset)
                if result.upload?.complete == true {
                    guard result.upload?.byteSize == byteSize, result.upload?.offset == byteSize else { throw ResumableUploadError.serverStateMismatch }
                    return result
                }
                // The server kept a shorter prefix (e.g. its request timeout); continue from there.
            } catch {
                guard isRetryable(error) else { throw error }
            }
            try await pause(stalls)
        }
    }
}

/// Background-session sender: uploads continue while the app is suspended, and iOS relaunches the
/// app in the background to deliver the result. Tasks left over from an earlier launch are ignored
/// (the server's offset is the truth and the next submission resumes from it).
final class BackgroundUploadSender: NSObject, UploadBodySending, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "com.pocketworld.mvp.capture-upload"
    static let shared = BackgroundUploadSender()

    private final class Pending {
        var data = Data()
        let progress: @Sendable (Int64) -> Void
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        init(progress: @escaping @Sendable (Int64) -> Void, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            self.progress = progress
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var finishEvents: (() -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Reconnects to the background session (call at launch).
    func activate() { _ = session }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func handleEvents(completion: @escaping () -> Void) {
        lock.withLock { finishEvents = completion }
        activate()
    }

    func send(_ request: URLRequest, fromFile file: URL,
              progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: file)
            lock.withLock { pending[task.taskIdentifier] = Pending(progress: progress, continuation: continuation) }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let entry = lock.withLock { pending[task.taskIdentifier] }
        entry?.progress(totalBytesSent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { pending[dataTask.taskIdentifier]?.data.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { entry.continuation.resume(throwing: error) }
        else if let response = task.response { entry.continuation.resume(returning: (entry.data, response)) }
        else { entry.continuation.resume(throwing: URLError(.badServerResponse)) }
    }

    // The bearer token must never follow a redirect to another host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (() -> Void)? in
            defer { finishEvents = nil }
            return finishEvents
        }
        DispatchQueue.main.async { completion?() }
    }
}
