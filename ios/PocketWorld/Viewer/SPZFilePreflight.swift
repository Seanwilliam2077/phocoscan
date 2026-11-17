import Foundation
import zlib

/// SPZ v1–v3 packed layout used by the pinned SplatIO/spz-swift reader.
/// Check gzip integrity, declared count and expanded size with bounded scratch
/// memory before the decoder allocates Gaussian arrays. No coordinate conversion.
enum SPZFilePreflight {
    struct Info: Equatable { let version: Int; let pointCount: Int; let shDegree: Int; let expandedSize: Int }
    enum Failure: LocalizedError, Equatable {
        case invalid, unsupportedVersion, tooManyPoints
        var errorDescription: String? {
            switch self {
            case .invalid: return "3DGS 文件不完整或已损坏，请重新下载结果。"
            case .unsupportedVersion: return "此 3DGS 文件的压缩版本暂不受支持。"
            case .tooManyPoints: return "模型超过 100 万高斯点，请使用较小的展示版本。"
            }
        }
    }
    static func inspect(_ url: URL, maxPoints: Int = 1_000_000) throws -> Info {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid }
        defer { inflateEnd(&stream) }
        var header = Data(), info: Info?, total = 0, ended = false
        var output = [UInt8](repeating: 0, count: 65_536)
        while !ended {
            try Task.checkCancellation()
            guard let input = try file.read(upToCount: 65_536), !input.isEmpty else { throw Failure.invalid }
            try input.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                repeat {
                    let remainingInput = stream.avail_in
                    let result = output.withUnsafeMutableBytes { destination in
                        stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                        stream.avail_out = uInt(destination.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    guard result == Z_OK || result == Z_STREAM_END else { throw Failure.invalid }
                    let produced = output.count - Int(stream.avail_out)
                    if header.count < 16 { header.append(contentsOf: output.prefix(min(produced, 16-header.count))) }
                    if info == nil, header.count == 16 { info = try parse(header, maxPoints: maxPoints) }
                    total += produced
                    // At most one scratch block can be emitted before the header is checked.
                    guard total <= (info?.expandedSize ?? 16) else { throw Failure.invalid }
                    if result == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw Failure.invalid }
                        ended = true
                    } else if produced == 0, remainingInput == stream.avail_in { throw Failure.invalid }
                } while !ended && (stream.avail_in > 0 || stream.avail_out == 0)
            }
        }
        guard let info, total == info.expandedSize,
              (try file.read(upToCount: 1) ?? Data()).isEmpty else { throw Failure.invalid }
        return info
    }
    private static func parse(_ header: Data, maxPoints: Int) throws -> Info {
        func uint32(_ start: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(header[start+$1]) << (8*$1) }
        }
        guard uint32(0) == 0x5053474e else { throw Failure.invalid } // NGSP
        let version = Int(uint32(4)), count = Int(uint32(8)), degree = Int(header[12])
        guard (1...3).contains(version) else { throw Failure.unsupportedVersion }
        guard count > 0, degree <= 3, header[13] <= 24 else { throw Failure.invalid }
        guard count <= maxPoints else { throw Failure.tooManyPoints }
        let shComponents = [0, 3, 8, 15][degree] * 3
        let perPoint = (version == 1 ? 6 : 9) + 1 + 3 + 3 + (version == 3 ? 4 : 3) + shComponents
        return Info(version:version, pointCount:count, shDegree:degree, expandedSize:16 + count*perPoint)
    }
}
