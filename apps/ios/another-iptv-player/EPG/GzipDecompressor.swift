import Foundation
import Compression

/// Inflates gzip (RFC 1952) data. Apple's Compression framework decodes *raw*
/// DEFLATE (`COMPRESSION_ZLIB`) with no gzip wrapper, so the gzip header is parsed
/// and skipped manually and the trailing CRC32/ISIZE is ignored (the DEFLATE
/// end-of-stream marker terminates decoding before it).
///
/// XMLTV `.xml.gz` feeds are served as `application/gzip` and are *not*
/// auto-inflated by URLSession, so we sniff `1f 8b` and inflate ourselves.
nonisolated enum GzipDecompressor {

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Byte offset where the DEFLATE stream begins, or nil if `bytes` is not a
    /// valid gzip header. `bytes` must contain the full header (a 64 KB prefix is
    /// always sufficient for real feeds).
    static func gzipHeaderLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 10, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flg = bytes[3]
        let fhcrc  = flg & 0x02 != 0
        let fextra = flg & 0x04 != 0
        let fname  = flg & 0x08 != 0
        let fcomment = flg & 0x10 != 0
        var idx = 10   // fixed header

        if fextra {
            guard idx + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if fname {
            while idx < bytes.count, bytes[idx] != 0 { idx += 1 }
            idx += 1  // consume the NUL terminator
        }
        if fcomment {
            while idx < bytes.count, bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if fhcrc { idx += 2 }
        guard idx <= bytes.count else { return nil }
        return idx
    }

    // MARK: - In-memory (tests / small inputs)

    /// Inflates a full gzip blob in memory. For large feeds prefer `inflateFile`.
    static func inflate(_ gzip: Data, maxInflatedBytes: Int64 = EPGConstants.maxInflatedBytes) throws -> Data {
        let bytes = [UInt8](gzip.prefix(64 * 1024))
        guard let headerLen = gzipHeaderLength(bytes) else { throw EPGError.decompression }
        let deflate = gzip.subdata(in: gzip.index(gzip.startIndex, offsetBy: headerLen)..<gzip.endIndex)

        var output = Data()
        try streamInflate(
            readChunk: { nil },
            maxInflatedBytes: maxInflatedBytes,
            singleShotSource: deflate,
            write: { output.append($0) }
        )
        return output
    }

    // MARK: - Streaming file → file

    /// Inflates a gzip file to `destination`, streaming in chunks so a multi-hundred-MB
    /// guide never fully resides in RAM. Throws `.tooLarge` past `maxInflatedBytes`.
    static func inflateFile(source: URL, destination: URL,
                            maxInflatedBytes: Int64 = EPGConstants.maxInflatedBytes) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw EPGError.decompression
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let readSize = EPGConstants.inflateChunkSize

        // Buffer enough of the front to parse the (variable-length) gzip header.
        var pending = Data()
        while pending.count < 64 * 1024 {
            guard let more = try input.read(upToCount: readSize), !more.isEmpty else { break }
            pending.append(more)
            if pending.count >= 18 && GzipDecompressor.gzipHeaderLength([UInt8](pending)) != nil { break }
        }
        let prefixBytes = [UInt8](pending)
        guard let headerLen = gzipHeaderLength(prefixBytes), headerLen <= pending.count else {
            throw EPGError.decompression
        }
        var carry = pending.subdata(in: pending.index(pending.startIndex, offsetBy: headerLen)..<pending.endIndex)
        var sourceEOF = false

        try streamInflate(
            readChunk: {
                if !carry.isEmpty { defer { carry = Data() }; return carry }
                if sourceEOF { return nil }
                if let more = try input.read(upToCount: readSize), !more.isEmpty { return more }
                sourceEOF = true
                return nil
            },
            maxInflatedBytes: maxInflatedBytes,
            singleShotSource: nil,
            write: { output.write($0) }
        )
    }

    // MARK: - Core

    /// Drives a `compression_stream` decode loop. Either `singleShotSource` (whole
    /// DEFLATE payload) or `readChunk` (incremental) supplies input.
    private static func streamInflate(readChunk: () throws -> Data?,
                                      maxInflatedBytes: Int64,
                                      singleShotSource: Data?,
                                      write: (Data) -> Void) throws {
        let dstCapacity = EPGConstants.inflateChunkSize
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        streamPtr.initialize(to: compression_stream(dst_ptr: dstBuffer, dst_size: dstCapacity,
                                                    src_ptr: dstBuffer, src_size: 0, state: nil))
        defer { streamPtr.deinitialize(count: 1); streamPtr.deallocate() }

        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw EPGError.decompression
        }
        defer { compression_stream_destroy(streamPtr) }

        streamPtr.pointee.dst_ptr = dstBuffer
        streamPtr.pointee.dst_size = dstCapacity

        var inflatedTotal: Int64 = 0
        var current: Data
        if let s = singleShotSource {
            current = s
        } else {
            current = (try readChunk()) ?? Data()
        }
        var exhausted = false

        while true {
            if current.isEmpty && !exhausted {
                if singleShotSource != nil {
                    exhausted = true
                } else if let next = try readChunk() {
                    current = next
                } else {
                    exhausted = true
                }
            }

            let flags = exhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            var consumed = 0
            let status: compression_status = current.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> compression_status in
                if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                    streamPtr.pointee.src_ptr = UnsafePointer(base)
                } else {
                    streamPtr.pointee.src_ptr = UnsafePointer(dstBuffer)  // placeholder; src_size is 0
                }
                streamPtr.pointee.src_size = current.count
                let s = compression_stream_process(streamPtr, flags)
                consumed = current.count - streamPtr.pointee.src_size
                return s
            }
            if consumed > 0 { current.removeFirst(consumed) }

            let produced = dstCapacity - streamPtr.pointee.dst_size
            if produced > 0 {
                inflatedTotal += Int64(produced)
                if inflatedTotal > maxInflatedBytes { throw EPGError.tooLarge }
                write(Data(bytes: dstBuffer, count: produced))
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = dstCapacity
            }

            switch status {
            case COMPRESSION_STATUS_OK:
                continue
            case COMPRESSION_STATUS_END:
                return
            default:
                throw EPGError.decompression
            }
        }
    }
}
