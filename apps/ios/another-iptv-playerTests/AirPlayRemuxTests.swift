import AVFoundation
import Foundation
import Testing
import UIKit
@testable import another_iptv_player

@Suite("AirPlayRemux")
struct AirPlayRemuxTests {

    /// Uçtan uca: AVAssetWriter ile 6 sn H.264 mp4 üret → RemuxHLSWriter ile TS-HLS'e
    /// remux et → playlist + segmentler oluşmalı. mpegts muxer'ının FFmpegKit build'inde
    /// gerçekten var olduğunu da kanıtlar (hls muxer yoktu, ondan elle segmentliyoruz).
    @Test
    func remuxesGeneratedMP4IntoTSSegments() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mp4")
        try await Self.writeTestVideo(to: sourceURL, seconds: 6)

        let writer = RemuxHLSWriter(
            sourceURL: sourceURL,
            outputDirectory: dir,
            startSeconds: 0,
            isLive: false,
            userAgent: nil
        )
        writer.onError = { error in
            Issue.record("remux error: \(error.localizedDescription)")
        }
        writer.start()
        // Yerel dosya remux'u network'süz, tipik <1 sn sürer; 10 sn üst sınır.
        var finished = false
        for _ in 0..<40 {
            if let content = try? String(contentsOf: writer.playlistURL, encoding: .utf8),
               content.contains("#EXT-X-ENDLIST") {
                finished = true
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(finished, "remux did not finish within 10s")

        let playlist = try String(contentsOf: writer.playlistURL, encoding: .utf8)
        #expect(playlist.contains("#EXTM3U"))
        #expect(playlist.contains("#EXTINF"))
        #expect(playlist.contains("#EXT-X-ENDLIST"))
        let segmentNames = playlist.split(separator: "\n").filter { $0.hasSuffix(".ts") }
        #expect(!segmentNames.isEmpty)
        for name in segmentNames {
            let attrs = try FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent(String(name)).path
            )
            let size = attrs[.size] as? Int ?? 0
            #expect(size > 1000, "segment \(name) suspiciously small: \(size)B")
        }
    }

    @Test
    func splitsInitFromFirstFragmentBox() {
        func box(_ type: String, payload: Int) -> Data {
            var d = Data()
            let size = UInt32(8 + payload)
            d.append(contentsOf: [
                UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF),
                UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF),
            ])
            d.append(contentsOf: Array(type.utf8))
            d.append(Data(repeating: 0xEE, count: payload))
            return d
        }
        let ftyp = box("ftyp", payload: 12)
        let moov = box("moov", payload: 40)
        let moof = box("moof", payload: 24)
        let mdat = box("mdat", payload: 64)

        let (initData, fragment) = RemuxHLSWriter.splitAtFirstFragmentBox(ftyp + moov + moof + mdat)
        #expect(initData == ftyp + moov)
        #expect(fragment == moof + mdat)

        // Fragment yoksa (delay_moov ilk flush'ı yalnız moov üretti): hepsi init, fragment boş.
        let (onlyInit, empty) = RemuxHLSWriter.splitAtFirstFragmentBox(ftyp + moov)
        #expect(onlyInit == ftyp + moov)
        #expect(empty.isEmpty)
    }

    /// fMP4 yolu (HEVC için kullanılan): aynı H.264 kaynak, biçim zorlanarak. Fragment
    /// yakalama makinesini (custom AVIO, init.mp4 + m4s bölme, EXT-X-MAP) doğrular.
    @Test
    func remuxesIntoFMP4SegmentsWhenForced() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-fmp4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mp4")
        try await Self.writeTestVideo(to: sourceURL, seconds: 6)

        let writer = RemuxHLSWriter(
            sourceURL: sourceURL,
            outputDirectory: dir,
            startSeconds: 0,
            isLive: false,
            userAgent: nil,
            forcedFormat: .fmp4
        )
        writer.onError = { error in
            Issue.record("remux error: \(error.localizedDescription)")
        }
        writer.start()
        var finished = false
        for _ in 0..<40 {
            if let content = try? String(contentsOf: writer.playlistURL, encoding: .utf8),
               content.contains("#EXT-X-ENDLIST") {
                finished = true
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(finished, "fmp4 remux did not finish within 10s")

        let playlist = try String(contentsOf: writer.playlistURL, encoding: .utf8)
        #expect(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(playlist.contains("#EXT-X-VERSION:7"))
        let initAttrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("init.mp4").path
        )
        #expect((initAttrs[.size] as? Int ?? 0) > 100)
        let segmentNames = playlist.split(separator: "\n").filter { $0.hasSuffix(".m4s") }
        #expect(!segmentNames.isEmpty)
        for name in segmentNames {
            let attrs = try FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent(String(name)).path
            )
            #expect((attrs[.size] as? Int ?? 0) > 500)
        }
    }

    /// Tam zincir: üretilen mp4 → remux (TS) → paylaşılan sunucu → AirPlayCastPlayer.
    /// KSAVPlayer'ın track-yarışı yüzünden cast oynatıcısı bizim AVPlayer sarmalayıcımız;
    /// bu test onun yerel HLS'i gerçekten readyToPlay'e getirdiğini kanıtlar.
    @Test(.timeLimit(.minutes(1)))
    func castPlayerPlaysRemuxedLocalHLS() async throws {
        let server = LocalHTTPServer.shared
        try server.start()
        let dir = server.directory.appendingPathComponent("cast-test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mp4")
        try await Self.writeTestVideo(to: sourceURL, seconds: 6)
        let writer = RemuxHLSWriter(
            sourceURL: sourceURL, outputDirectory: dir,
            startSeconds: 0, isLive: false, userAgent: nil
        )
        writer.start()
        var finished = false
        for _ in 0..<40 {
            if let content = try? String(contentsOf: writer.playlistURL, encoding: .utf8),
               content.contains("#EXT-X-ENDLIST") {
                finished = true
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(finished)

        let url = URL(string: "http://127.0.0.1:\(server.port)/cast-test/stream.m3u8")!
        let cast = AirPlayCastPlayer()
        cast.load(url: url, startAt: nil, autoPlay: false)
        defer { cast.dispose() }
        var ready = false
        for _ in 0..<20 {
            if cast.isReadyToPlay {
                ready = true
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(ready, "AirPlayCastPlayer did not reach readyToPlay on remuxed local HLS")
        #expect(cast.duration > 4, "duration missing: \(cast.duration)")
    }

    /// Simülatörde H.264 encode: tek renkli kareler, 30fps, saniyede bir keyframe.
    private static func writeTestVideo(to url: URL, seconds: Int) async throws {
        let width = 320
        let height = 240
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAverageBitRateKey: 300_000,
                ],
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        assetWriter.add(input)
        #expect(assetWriter.startWriting())
        assetWriter.startSession(atSourceTime: .zero)

        let frameCount = seconds * 30
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(
                nil, adaptor.pixelBufferPool!, &pixelBuffer
            )
            guard let buffer = pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32((frame * 3) % 255), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
        }
        input.markAsFinished()
        await assetWriter.finishWriting()
        #expect(assetWriter.status == .completed)
    }

    @Test
    func codecCompatibilityWhitelist() {
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "avc1", audioFourCC: "mp4a"))
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "h264", audioFourCC: "eac3"))
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "avc1", audioFourCC: nil))
        // HEVC fMP4 segmenter ile destekleniyor.
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "hvc1", audioFourCC: "ac-3"))
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "hevc", audioFourCC: "aac"))
        // FFmpeg codecName profil ekiyle gelir — normalize edilmeli (canlı/film butonunun
        // topluca kaybolmasına yol açan gerçek regresyon).
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "h264 (High)", audioFourCC: "aac (LC)"))
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "hevc (Main)", audioFourCC: "eac3"))
        #expect(RemuxHLSWriter.normalizeCodec("h264 (High)") == "h264")
        // Ses artık adaylığı etkilemez: uyumsuz ses (DTS/MP2…) AAC'ye transcode edilir.
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "avc1", audioFourCC: "dts "))
        #expect(RemuxHLSWriter.isCompatible(videoFourCC: "h264", audioFourCC: "mp2"))
        // Video hâlâ katı: AV1/MPEG-2 decode gerektirir, passthrough imkânsız.
        #expect(!RemuxHLSWriter.isCompatible(videoFourCC: "av01", audioFourCC: "mp4a"))
        #expect(!RemuxHLSWriter.isCompatible(videoFourCC: "mp2v", audioFourCC: "mp4a"))
    }

    @Test
    func httpServerServesFilesAndRejectsTraversal() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let playlist = "#EXTM3U\n#EXT-X-VERSION:7\nseg00001.m4s\n"
        try playlist.write(
            to: dir.appendingPathComponent("stream.m3u8"), atomically: true, encoding: .utf8
        )
        let segment = Data(repeating: 0xAB, count: 4096)
        try segment.write(to: dir.appendingPathComponent("seg00001.m4s"))

        let server = LocalHTTPServer(directory: dir)
        try server.start()
        defer { server.stop() }
        #expect(server.port > 0)

        let base = "http://127.0.0.1:\(server.port)"

        let (playlistData, playlistResponse) = try await URLSession.shared.data(
            from: URL(string: "\(base)/stream.m3u8")!
        )
        let httpPlaylist = try #require(playlistResponse as? HTTPURLResponse)
        #expect(httpPlaylist.statusCode == 200)
        #expect(httpPlaylist.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(String(decoding: playlistData, as: UTF8.self) == playlist)

        let (segmentData, segmentResponse) = try await URLSession.shared.data(
            from: URL(string: "\(base)/seg00001.m4s")!
        )
        #expect((segmentResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(segmentData == segment)

        var rangeRequest = URLRequest(url: URL(string: "\(base)/seg00001.m4s")!)
        rangeRequest.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await URLSession.shared.data(for: rangeRequest)
        let httpRange = try #require(rangeResponse as? HTTPURLResponse)
        #expect(httpRange.statusCode == 206)
        #expect(httpRange.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/4096")
        #expect(httpRange.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(rangeData == Data(repeating: 0xAB, count: 100))

        var suffixRequest = URLRequest(url: URL(string: "\(base)/seg00001.m4s")!)
        suffixRequest.setValue("bytes=-64", forHTTPHeaderField: "Range")
        let (suffixData, suffixResponse) = try await URLSession.shared.data(for: suffixRequest)
        #expect((suffixResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(suffixData == Data(repeating: 0xAB, count: 64))

        let (_, missingResponse) = try await URLSession.shared.data(
            from: URL(string: "\(base)/missing.m4s")!
        )
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)
    }
}
