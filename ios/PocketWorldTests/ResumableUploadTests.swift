import CryptoKit
import XCTest
@testable import PocketWorld

/// Resumable original-video upload. The unit tests drive the resume loop against an in-memory
/// server; the integration test (only when `POCKETWORLD_TEST_SERVER` is set) uploads a synthetic
/// container through the real `APIClient` to a local PocketWorld server and drops the first transfer.
@MainActor
final class ResumableUploadTests: XCTestCase {
    private func capture(_ sha: String, _ size: Int) -> CaptureV2Status {
        CaptureV2Status(id: "11111111-1111-4111-8111-111111111111", environment: "indoor",
            consentVersion: "research-preview-v1", status: "rgb_uploaded",
            rgb: .init(sha256: sha, byteSize: size, mime: "video/quicktime"), metadata: nil, receipt: nil)
    }
    private func file(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-test-\(UUID().uuidString)")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    nonisolated private static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// In-memory stand-in for the server's offset bookkeeping.
    private final class FakeServer {
        let source: Data
        var received = Data()
        var sends: [Int64] = []
        init(_ source: Data) { self.source = source }
        var status: RGBUploadStatus {
            RGBUploadStatus(sha256: ResumableUploadTests.hex(source), byteSize: Int64(source.count), mime: "video/quicktime",
                            offset: Int64(received.count), complete: received == source)
        }
    }

    func testRemainderFileHoldsExactlyTheMissingBytes() throws {
        let bytes = Data((0..<10_000).map { UInt8($0 % 251) })
        let url = try file(bytes)
        XCTAssertEqual(try ResumableUpload.body(of: url, from: 0, in: FileManager.default.temporaryDirectory), url)
        let rest = try ResumableUpload.body(of: url, from: 4_321, in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: rest) }
        XCTAssertEqual(try Data(contentsOf: rest), bytes.subdata(in: 4_321..<10_000))
    }

    func testResumesFromTheServerOffsetAfterADroppedConnection() async throws {
        let source = Data((0..<1_000).map { UInt8($0 % 256) })
        let server = FakeServer(source)
        let result = try await ResumableUpload.run(byteSize: Int64(source.count),
            declare: { RGBUploadEnvelope(upload: server.status, capture: nil) },
            send: { offset in
                server.sends.append(offset)
                if server.sends.count == 1 {
                    // The connection drops after 400 bytes; the server keeps them.
                    server.received.append(source.subdata(in: Int(offset)..<400))
                    throw URLError(.networkConnectionLost)
                }
                server.received.append(source.subdata(in: Int(offset)..<source.count))
                return RGBUploadEnvelope(upload: server.status, capture: self.capture(Self.hex(source), source.count))
            },
            pause: { _ in })
        XCTAssertEqual(server.sends, [0, 400], "the second attempt continues at the kept offset")
        XCTAssertEqual(server.received, source)
        XCTAssertEqual(result.rgb?.sha256, Self.hex(source))
    }

    func testAlreadyCompleteUploadSendsNothing() async throws {
        var sent = false
        let done = capture(String(repeating: "a", count: 64), 10)
        let complete = RGBUploadStatus(sha256: String(repeating: "a", count: 64), byteSize: 10, mime: "video/quicktime",
                                       offset: 10, complete: true)
        let result = try await ResumableUpload.run(byteSize: 10,
            declare: { RGBUploadEnvelope(upload: complete, capture: done) },
            send: { _ in sent = true; throw URLError(.unknown) }, pause: { _ in })
        XCTAssertFalse(sent)
        XCTAssertEqual(result.id, done.id)
    }

    func testValidationErrorsStopAndStalledUploadsGiveUpWithProgress() async throws {
        let status = RGBUploadStatus(sha256: String(repeating: "b", count: 64), byteSize: 100, mime: "video/quicktime",
                                     offset: 40, complete: false)
        var attempts = 0
        do {
            _ = try await ResumableUpload.run(byteSize: 100, declare: { RGBUploadEnvelope(upload: status, capture: nil) },
                send: { _ in attempts += 1; throw APIError.server(422, "hash_mismatch") }, pause: { _ in })
            XCTFail("a validation failure must not be retried")
        } catch APIError.server(422, _) { XCTAssertEqual(attempts, 1) }

        attempts = 0
        do {
            _ = try await ResumableUpload.run(byteSize: 100, maxStalls: 3,
                declare: { RGBUploadEnvelope(upload: status, capture: nil) },
                send: { _ in attempts += 1; throw URLError(.timedOut) }, pause: { _ in })
            XCTFail("no progress must eventually stop")
        } catch ResumableUploadError.stalled(let sent, let total) {
            XCTAssertEqual(sent, 40); XCTAssertEqual(total, 100); XCTAssertEqual(attempts, 3)
        }
        // A server that reports a different file size is never trusted.
        do {
            _ = try await ResumableUpload.run(byteSize: 99, declare: { RGBUploadEnvelope(upload: status, capture: nil) },
                send: { _ in throw URLError(.unknown) }, pause: { _ in })
            XCTFail("size mismatch")
        } catch ResumableUploadError.serverStateMismatch {}
    }

    // MARK: - Integration with a local server

    /// The first transfer is a raw HTTP request that promises the whole remainder but sends only
    /// `dropAfter` bytes before the connection closes (what the server sees when the phone loses
    /// signal). Later transfers are ordinary uploads with progress.
    private final class DroppingSender: NSObject, UploadBodySending, URLSessionTaskDelegate, @unchecked Sendable {
        let dropAfter: Int
        var offsets: [Int64] = []
        private var progress: (@Sendable (Int64) -> Void)?
        private lazy var session = URLSession(configuration: .ephemeral)
        init(dropAfter: Int) { self.dropAfter = dropAfter }

        func send(_ request: URLRequest, fromFile file: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, URLResponse) {
            offsets.append(Int64(request.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? -1)
            if offsets.count == 1 {
                try await dropMidway(request, file: file)
                throw URLError(.networkConnectionLost)
            }
            self.progress = progress
            return try await session.upload(for: request, fromFile: file, delegate: self)
        }

        private func dropMidway(_ request: URLRequest, file: URL) async throws {
            guard let url = request.url, let host = url.host, let port = url.port else { throw URLError(.badURL) }
            let body = try Data(contentsOf: file)
            var head = "\(request.httpMethod ?? "PATCH") \(url.path) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
            for (name, value) in request.allHTTPHeaderFields ?? [:] { head += "\(name): \(value)\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let stream = URLSession.shared.streamTask(withHostName: host, port: port)
            stream.resume()
            try await stream.write(Data(head.utf8), timeout: 10)
            try await stream.write(body.prefix(dropAfter), timeout: 10)
            try await Task.sleep(nanoseconds: 300_000_000) // let the server store what arrived
            stream.cancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            progress?(totalBytesSent)
        }
    }

    func testRealServerKeepsBytesAcrossADroppedTransferAndFinishesTheCapture() async throws {
        guard let server = ProcessInfo.processInfo.environment["POCKETWORLD_TEST_SERVER"] else {
            throw XCTSkip("Set POCKETWORLD_TEST_SERVER to a local PocketWorld server to run this test.")
        }
        // Synthetic QuickTime container (box structure only; not a camera video).
        func box(_ type: String, _ payload: Data) -> Data {
            var size = UInt32(payload.count + 8).bigEndian
            return Data(bytes: &size, count: 4) + Data(type.utf8) + payload
        }
        var payload = Data(count: 24 * 1024 * 1024)
        payload.withUnsafeMutableBytes { raw in for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) } }
        let video = box("ftyp", Data("qt  \0\0\0\0".utf8)) + box("moov", Data("SYNTHETIC_TEST".utf8)) + box("mdat", payload)
        let url = try file(video)

        let api = APIClient()
        _ = try await api.connect(to: server)
        let id = UUID().uuidString.lowercased()
        struct Create: Encodable { let captureId: String; let environment: String; let consentVersion: String }
        struct Created: Decodable { let capture: CaptureV2Status }
        let _: Created = try await api.json("/v2/captures",
            body: Create(captureId: id, environment: "indoor", consentVersion: "research-preview-v1"))
        let sender = DroppingSender(dropAfter: 2 * 1024 * 1024)
        final class Progress: @unchecked Sendable { var value = 0.0 }
        let progress = Progress()
        let capture = try await api.uploadCaptureVideo(capturePath: "/v2/captures/" + id, file: url,
            mime: "video/quicktime", sha256: Self.hex(video), sender: sender) { progress.value = max(progress.value, $0) }

        XCTAssertEqual(capture.rgb?.sha256, Self.hex(video))
        XCTAssertEqual(capture.rgb?.byteSize, video.count)
        XCTAssertEqual(sender.offsets.count, 2, "one dropped transfer, one resumed transfer")
        XCTAssertEqual(sender.offsets.first, 0)
        XCTAssertGreaterThan(sender.offsets.last ?? 0, 0, "the resumed transfer starts after the bytes the server kept")
        XCTAssertGreaterThan(progress.value, 0.9)
    }

    /// The deployed A10 may predate `/rgb-upload`; the app must still upload with the old single PUT.
    func testOlderServerWithoutResumableUploadFallsBackToSingleRequest() async throws {
        guard let server = ProcessInfo.processInfo.environment["POCKETWORLD_LEGACY_TEST_SERVER"] else {
            throw XCTSkip("Set POCKETWORLD_LEGACY_TEST_SERVER to a server without /rgb-upload to run this test.")
        }
        let video = Data("SYNTHETIC".utf8)
        func box(_ type: String, _ payload: Data) -> Data {
            var size = UInt32(payload.count + 8).bigEndian
            return Data(bytes: &size, count: 4) + Data(type.utf8) + payload
        }
        let container = box("ftyp", Data("qt  \0\0\0\0".utf8)) + box("moov", video) + box("mdat", video)
        let url = try file(container)
        let api = APIClient()
        _ = try await api.connect(to: server)
        let id = UUID().uuidString.lowercased()
        struct Create: Encodable { let captureId: String; let environment: String; let consentVersion: String }
        struct Created: Decodable { let capture: CaptureV2Status }
        let _: Created = try await api.json("/v2/captures",
            body: Create(captureId: id, environment: "indoor", consentVersion: "research-preview-v1"))
        let sender = DroppingSender(dropAfter: 1)
        let capture = try await api.uploadCaptureVideo(capturePath: "/v2/captures/" + id, file: url,
            mime: "video/quicktime", sha256: Self.hex(container), sender: sender) { _ in }
        XCTAssertEqual(capture.rgb?.sha256, Self.hex(container))
        XCTAssertTrue(sender.offsets.isEmpty, "the resumable path is never used against an older server")
    }
}
