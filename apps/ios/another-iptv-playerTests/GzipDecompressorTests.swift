import Foundation
import Compression
import Testing
@testable import another_iptv_player

@Suite("GzipDecompressor")
struct GzipDecompressorTests {

    // MARK: - Helpers

    /// Raw DEFLATE encode (COMPRESSION_ZLIB produces a bare deflate stream).
    private func rawDeflate(_ input: Data) -> Data {
        let dstCap = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dst.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        stream.initialize(to: compression_stream(dst_ptr: dst, dst_size: dstCap, src_ptr: dst, src_size: 0, state: nil))
        defer { stream.deinitialize(count: 1); stream.deallocate() }
        _ = compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        defer { compression_stream_destroy(stream) }

        var out = Data()
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = input.count
            stream.pointee.dst_ptr = dst
            stream.pointee.dst_size = dstCap
            var status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            repeat {
                let produced = dstCap - stream.pointee.dst_size
                if produced > 0 { out.append(dst, count: produced) }
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = dstCap
                if status == COMPRESSION_STATUS_END { break }
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            } while status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END
        }
        return out
    }

    /// Wraps raw DEFLATE with a gzip header (optional FNAME/FEXTRA) + dummy trailer.
    private func makeGzip(_ payload: Data, fname: String? = nil, extra: Data? = nil) -> Data {
        var flg: UInt8 = 0
        if extra != nil { flg |= 0x04 }
        if fname != nil { flg |= 0x08 }
        var out = Data([0x1f, 0x8b, 0x08, flg, 0, 0, 0, 0, 0, 0xff])
        if let extra {
            var xlen = UInt16(extra.count).littleEndian
            withUnsafeBytes(of: &xlen) { out.append(contentsOf: $0) }
            out.append(extra)
        }
        if let fname {
            out.append(contentsOf: Array(fname.utf8))
            out.append(0)
        }
        out.append(rawDeflate(payload))
        out.append(Data([0, 0, 0, 0, 0, 0, 0, 0])) // CRC32 + ISIZE (ignored by decoder)
        return out
    }

    // MARK: - Header length

    @Test
    func headerLengthMinimal() {
        let bytes: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0,0,0,0, 0, 0xff]
        #expect(GzipDecompressor.gzipHeaderLength(bytes) == 10)
    }

    @Test
    func headerLengthWithFName() {
        var bytes: [UInt8] = [0x1f, 0x8b, 0x08, 0x08, 0,0,0,0, 0, 0xff]
        bytes.append(contentsOf: Array("guide.xml".utf8))
        bytes.append(0)
        #expect(GzipDecompressor.gzipHeaderLength(bytes) == 10 + 9 + 1)
    }

    @Test
    func headerLengthWithFExtra() {
        var bytes: [UInt8] = [0x1f, 0x8b, 0x08, 0x04, 0,0,0,0, 0, 0xff]
        bytes.append(contentsOf: [0x03, 0x00]) // XLEN = 3
        bytes.append(contentsOf: [0xAA, 0xBB, 0xCC])
        #expect(GzipDecompressor.gzipHeaderLength(bytes) == 10 + 2 + 3)
    }

    @Test
    func rejectsNonGzip() {
        #expect(GzipDecompressor.gzipHeaderLength([0x50, 0x4b, 0x03, 0x04]) == nil)
        #expect(!GzipDecompressor.isGzip(Data([0x50, 0x4b])))
        #expect(GzipDecompressor.isGzip(Data([0x1f, 0x8b])))
    }

    // MARK: - Round trip

    @Test
    func inflateRoundTrip() throws {
        let payload = Data("The quick brown fox jumps over the lazy dog. ".utf8) + Data(repeating: 0x41, count: 5000)
        let gz = makeGzip(payload)
        let out = try GzipDecompressor.inflate(gz)
        #expect(out == payload)
    }

    @Test
    func inflateRoundTripWithHeaderFields() throws {
        let payload = Data("<tv><programme/></tv>".utf8)
        let gz = makeGzip(payload, fname: "epg.xml", extra: Data([1, 2, 3, 4]))
        let out = try GzipDecompressor.inflate(gz)
        #expect(out == payload)
    }

    @Test
    func inflateFileRoundTrip() throws {
        let payload = Data((0..<20_000).map { UInt8($0 & 0xff) })
        let gz = makeGzip(payload)
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("gz-\(UUID().uuidString).gz")
        let dst = dir.appendingPathComponent("gz-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try gz.write(to: src)
        try GzipDecompressor.inflateFile(source: src, destination: dst)
        let out = try Data(contentsOf: dst)
        #expect(out == payload)
    }

    @Test
    func truncatedInputThrows() {
        #expect(throws: (any Error).self) {
            _ = try GzipDecompressor.inflate(Data([0x1f, 0x8b])) // header only, no deflate
        }
    }
}
