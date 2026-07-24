import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

/// FFmpeg remux: kaynak URL (mkv/ts/avi…) → HLS segmentleri. Video daima passthrough
/// (H.264/HEVC); ses uyumluysa passthrough, değilse (MP2/DTS/TrueHD…) AAC'ye transcode
/// edilir. Arka plan kuyruğunda koşar.
///
/// İki segment biçimi:
/// - H.264 → MPEG-TS segmentleri (FFmpegKit'te `hls` muxer'ı derli değil; mpegts muxer
///   ile segmentasyon + m3u8 üretimi elle yapılır, cihazda doğrulandı).
/// - HEVC → fMP4 segmentleri (HLS spec'i HEVC'yi TS'te kabul etmez): tek `mp4` muxer,
///   `frag_custom` ile bizim sınırlarımızda fragment üretir; custom AVIO ile byte'lar
///   yakalanıp init.mp4 + segNNNNN.m4s dosyalarına bölünür.
final class RemuxHLSWriter {
  enum RemuxError: LocalizedError {
    case openInputFailed(Int32)
    case noCompatibleStreams
    case openOutputFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)

    var errorDescription: String? {
      switch self {
      case let .openInputFailed(code): return "remux: input open failed (\(code))"
      case .noCompatibleStreams: return "remux: no AVPlayer-compatible streams"
      case let .openOutputFailed(code): return "remux: output open failed (\(code))"
      case let .writeFailed(code): return "remux: write failed (\(code))"
      case let .readFailed(code): return "remux: source read failed (\(code))"
      }
    }
  }

  /// AVERROR_EOF — FFERRTAG('E','O','F',' '); the function-like C macro is not
  /// imported into Swift.
  private static let avErrorEOF: Int32 = -541_478_725

  enum SegmentFormat {
    case mpegTS
    case fmp4
  }

  static let compatibleVideoCodecs: Set<UInt32> = [
    AV_CODEC_ID_H264.rawValue, AV_CODEC_ID_HEVC.rawValue,
  ]
  /// Passthrough'a uygun ses; biçime göre değişir. Liste dışındaki her ses AAC'ye
  /// transcode edilir (decoder varsa; yoksa ses düşürülür, video sessiz gider).
  private static let fmp4AudioPassthrough: Set<UInt32> = [
    AV_CODEC_ID_AAC.rawValue, AV_CODEC_ID_AC3.rawValue, AV_CODEC_ID_EAC3.rawValue,
  ]
  private static let tsAudioPassthrough: Set<UInt32> = [
    AV_CODEC_ID_AAC.rawValue, AV_CODEC_ID_AC3.rawValue, AV_CODEC_ID_EAC3.rawValue,
    AV_CODEC_ID_MP3.rawValue,
  ]

  private let sourceURL: URL
  private let outputDirectory: URL
  private let startSeconds: TimeInterval
  private let isLive: Bool
  private let userAgent: String?
  /// Girdi açılmadan önce beklenecek süre: az önce kapatılmış bir bağlantının
  /// (önceki oturum / telefon oynatıcısı) panelde ölmesine fırsat verir —
  /// bağlantı-limitli panellerde ilk açılış çakışması kalıcı hataya dönüyordu.
  /// `readyToOpen` verilmişse bu değer sabit gecikme değil ÜST SINIRDIR.
  private let openDelaySeconds: Double
  /// Verilirse: girdi açmadan önce bu koşul true olana (ya da `openDelaySeconds`
  /// sınırına) kadar bekle. Zap'ta önceki oturumun kaynak bağlantısı fiilen
  /// kapanana dek bekleyip panelin slotu boşaltmasını garantiler.
  private let readyToOpen: (() -> Bool)?
  private let targetSegmentSeconds: Double
  /// Canlıda playlist'te tutulan segment sayısı (kayan pencere). VOD event-playlist
  /// kullanır (tüm segmentler kalır): kayan-pencere/canlı-görünüm denemesi sahada
  /// tekleme ve pencere-kaçması sorunları üretti, kullanıcı kararıyla geri alındı.
  private let liveWindowSize = 8
  /// Test için biçimi zorlamaya izin verir; nil = codec'e göre otomatik.
  let forcedFormat: SegmentFormat?

  private let queue = DispatchQueue(label: "AirPlayRemux.writer", qos: .userInitiated)
  /// Interrupt callback okur; blocking av_read_frame'i iptalde kırar.
  private let cancelled = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
  /// Remux döngüsü tamamen çözülüp kaynak bağlantısı (avformat_close_input) kapandı.
  /// Sonraki oturum, panel slotunun boşaldığını buradan anlar.
  private let closedLock = NSLock()
  private var sourceClosed = false
  var isClosed: Bool {
    closedLock.lock()
    defer { closedLock.unlock() }
    return sourceClosed
  }
  private(set) var playlistURL: URL
  /// Kaynağın toplam süresi (girdi açılınca yazılır; canlıda 0 kalır).
  private(set) var sourceDurationSeconds: TimeInterval = 0
  /// Girdi seek'inin GERÇEKTE düştüğü konum. `av_seek_frame` başarısız olursa
  /// (seek edilemeyen kaynak) 0'a döner — zaman çizelgesi muhasebesi buna bakmalı,
  /// aksi halde UI istenen konumu gösterirken cast 0:00'dan oynar.
  private(set) var effectiveStartSeconds: TimeInterval

  var onError: ((Error) -> Void)?

  // MARK: - VOD pacing (round-16 leaky bucket)

  /// VOD'da yazıcı, oynatma konumunun en fazla bu kadar ilerisine yazar. Sınırsız
  /// bırakılırsa tüm film hat hızında iner: panelin bağlantı sınırı doyar
  /// (devir hataları), disk/pil boşa gider.
  private let pacingAheadSeconds: Double = 25
  private let positionLock = NSLock()
  private var playbackPositionSeconds: Double = 0

  /// Cast oynatıcısının kaynak-zamanı konumu; pacing kapısını besler.
  func updatePlaybackPosition(_ seconds: TimeInterval) {
    positionLock.lock()
    playbackPositionSeconds = seconds
    positionLock.unlock()
  }

  private func currentPlaybackPosition() -> Double {
    positionLock.lock()
    defer { positionLock.unlock() }
    return playbackPositionSeconds
  }

  /// Yazılan medya zamanı izin verilen pencerenin ilerisindeyse bekler (iptal duyarlı).
  /// Oynatma başlamadan önce taban gerçek başlangıç konumudur (seek başarısızsa 0):
  /// oturum, başlangıç tamponunu (12 sn < 25 sn pencere) engellenmeden biriktirir.
  private func waitForPacing(mediaSeconds: Double) {
    guard !isLive else { return }
    while cancelled.pointee == 0 {
      let floorPosition = max(currentPlaybackPosition(), effectiveStartSeconds)
      if mediaSeconds <= floorPosition + pacingAheadSeconds { return }
      Thread.sleep(forTimeInterval: 0.2)
    }
  }

  init(
    sourceURL: URL,
    outputDirectory: URL,
    startSeconds: TimeInterval,
    isLive: Bool,
    userAgent: String?,
    openDelaySeconds: Double = 0,
    readyToOpen: (() -> Bool)? = nil,
    forcedFormat: SegmentFormat? = nil
  ) {
    self.sourceURL = sourceURL
    self.outputDirectory = outputDirectory
    self.startSeconds = startSeconds
    self.isLive = isLive
    self.userAgent = userAgent
    self.openDelaySeconds = openDelaySeconds
    self.readyToOpen = readyToOpen
    self.forcedFormat = forcedFormat
    effectiveStartSeconds = startSeconds
    targetSegmentSeconds = isLive ? 1.5 : 4
    cancelled.pointee = 0
    playlistURL = outputDirectory.appendingPathComponent("stream.m3u8")
  }

  deinit {
    cancelled.deallocate()
  }

  func start() {
    queue.async { [self] in
      do {
        try runRemuxLoop()
      } catch {
        if cancelled.pointee == 0 {
          Log.error("AirPlayRemux", "remux failed: \(error.localizedDescription)")
          DispatchQueue.main.async { [weak self] in self?.onError?(error) }
        }
      }
      // Döngü çözüldü → defer'daki avformat_close_input koştu → kaynak bağlantısı
      // kapandı. Sonraki oturum bunu bekliyor olabilir.
      closedLock.lock()
      sourceClosed = true
      closedLock.unlock()
    }
  }

  func cancel() {
    cancelled.pointee = 1
  }

  // MARK: - Ses transcode (MP2/DTS/… → AAC)

  /// Decode → swresample (FLTP) → FIFO → AAC encode zinciri. Zaman damgaları girdinin
  /// mutlak zaman çizelgesine oturtulur (ilk decode edilen frame'in PTS'inden başlar).
  private final class AudioTranscoder {
    let decoder: UnsafeMutablePointer<AVCodecContext>
    let encoder: UnsafeMutablePointer<AVCodecContext>
    /// Encoder çıkış paketlerinin time base'i: 1/sampleRate.
    var encoderTimeBase: AVRational { AVRational(num: 1, den: sampleRate) }
    private var swr: OpaquePointer?
    private let fifo: OpaquePointer
    private let sampleRate: Int32
    private let decodedFrame = av_frame_alloc()
    private let convertedFrame = av_frame_alloc()
    private let encodeFrame = av_frame_alloc()
    private let encodedPacket = av_packet_alloc()
    /// Bir sonraki encode frame'inin PTS'i (örnek biriminde); ilk frame'de kurulur.
    private var nextPts: Int64 = .min

    init?(inStream: UnsafeMutablePointer<AVStream>) {
      guard let codecpar = inStream.pointee.codecpar,
            let decCodec = avcodec_find_decoder(codecpar.pointee.codec_id),
            let decCtx = avcodec_alloc_context3(decCodec)
      else { return nil }
      avcodec_parameters_to_context(decCtx, codecpar)
      decCtx.pointee.pkt_timebase = inStream.pointee.time_base
      guard avcodec_open2(decCtx, decCodec, nil) >= 0 else {
        var freeing: UnsafeMutablePointer<AVCodecContext>? = decCtx
        avcodec_free_context(&freeing)
        return nil
      }
      decoder = decCtx

      guard let encCodec = avcodec_find_encoder(AV_CODEC_ID_AAC),
            let encCtx = avcodec_alloc_context3(encCodec)
      else {
        var freeing: UnsafeMutablePointer<AVCodecContext>? = decCtx
        avcodec_free_context(&freeing)
        return nil
      }
      let rate = decCtx.pointee.sample_rate > 0 ? decCtx.pointee.sample_rate : 48000
      sampleRate = rate
      encCtx.pointee.sample_rate = rate
      av_channel_layout_copy(&encCtx.pointee.ch_layout, &decCtx.pointee.ch_layout)
      if encCtx.pointee.ch_layout.nb_channels <= 0 || encCtx.pointee.ch_layout.nb_channels > 6 {
        av_channel_layout_uninit(&encCtx.pointee.ch_layout)
        av_channel_layout_default(&encCtx.pointee.ch_layout, 2)
      }
      encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
      encCtx.pointee.bit_rate = 160_000
      encCtx.pointee.time_base = AVRational(num: 1, den: rate)
      // mp4/fMP4 için extradata (AudioSpecificConfig) global header'da olmalı.
      encCtx.pointee.flags |= 1 << 22  // AV_CODEC_FLAG_GLOBAL_HEADER (makro import edilmiyor)
      guard avcodec_open2(encCtx, encCodec, nil) >= 0 else {
        var f1: UnsafeMutablePointer<AVCodecContext>? = decCtx
        avcodec_free_context(&f1)
        var f2: UnsafeMutablePointer<AVCodecContext>? = encCtx
        avcodec_free_context(&f2)
        return nil
      }
      encoder = encCtx

      guard let fifoPtr = av_audio_fifo_alloc(
        AV_SAMPLE_FMT_FLTP, encCtx.pointee.ch_layout.nb_channels, rate
      ) else { return nil }
      fifo = fifoPtr
    }

    deinit {
      var d: UnsafeMutablePointer<AVCodecContext>? = decoder
      avcodec_free_context(&d)
      var e: UnsafeMutablePointer<AVCodecContext>? = encoder
      avcodec_free_context(&e)
      swr_free(&swr)
      av_audio_fifo_free(fifo)
      var f1 = decodedFrame
      av_frame_free(&f1)
      var f2 = convertedFrame
      av_frame_free(&f2)
      var f3 = encodeFrame
      av_frame_free(&f3)
      var p = encodedPacket
      av_packet_free(&p)
    }

    /// Girdi ses paketini işler; üretilen her AAC paketi için `emit` çağrılır.
    func process(
      packet: UnsafeMutablePointer<AVPacket>?,
      emit: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
      guard let decodedFrame, let convertedFrame else { return }
      _ = avcodec_send_packet(decoder, packet)
      while avcodec_receive_frame(decoder, decodedFrame) == 0 {
        defer { av_frame_unref(decodedFrame) }
        let tb = decoder.pointee.pkt_timebase
        let framePts = decodedFrame.pointee.pts
        if framePts != Int64.min, tb.den > 0 {
          let framePtsSamples = av_rescale_q(framePts, tb, AVRational(num: 1, den: sampleRate))
          if nextPts == .min {
            nextPts = framePtsSamples
          } else {
            // Kaynakta zaman sıçraması (reconnect/gap): sentetik PTS düz devam ederse
            // ses her sıçramada videodan biraz daha kayar (birikimli desync). 200 ms'den
            // büyük sapmada senkronu kaynağın zamanına yeniden kilitle.
            let expected = nextPts + Int64(av_audio_fifo_size(fifo))
            if abs(framePtsSamples - expected) > Int64(sampleRate / 5) {
              nextPts = framePtsSamples - Int64(av_audio_fifo_size(fifo))
            }
          }
        } else if nextPts == .min {
          nextPts = 0
        }
        if swr == nil {
          swr_alloc_set_opts2(
            &swr,
            &encoder.pointee.ch_layout, AV_SAMPLE_FMT_FLTP, sampleRate,
            &decodedFrame.pointee.ch_layout,
            AVSampleFormat(rawValue: decodedFrame.pointee.format), decodedFrame.pointee.sample_rate,
            0, nil
          )
          guard swr != nil, swr_init(swr) >= 0 else {
            throw RemuxError.openOutputFailed(-1)
          }
        }
        // Dönüştür ve FIFO'ya yaz.
        convertedFrame.pointee.sample_rate = sampleRate
        convertedFrame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        av_channel_layout_copy(&convertedFrame.pointee.ch_layout, &encoder.pointee.ch_layout)
        convertedFrame.pointee.nb_samples =
          swr_get_out_samples(swr, decodedFrame.pointee.nb_samples)
        guard av_frame_get_buffer(convertedFrame, 0) >= 0 else {
          throw RemuxError.writeFailed(-1)
        }
        defer { av_frame_unref(convertedFrame) }
        let outData = UnsafeMutableRawPointer(convertedFrame.pointee.extended_data)
          .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
        let inData = UnsafeMutableRawPointer(decodedFrame.pointee.extended_data)
          .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let converted = swr_convert(
          swr, outData, convertedFrame.pointee.nb_samples,
          inData, decodedFrame.pointee.nb_samples
        )
        guard converted >= 0 else { throw RemuxError.writeFailed(converted) }
        if converted > 0 {
          let raw = UnsafeMutableRawPointer(convertedFrame.pointee.extended_data)
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
          av_audio_fifo_write(fifo, raw, converted)
        }
        try drainEncoder(flush: false, emit: emit)
      }
    }

    /// Kaynak bitti/iptal: kalan örnekleri encode edip encoder'ı boşaltır.
    func finish(emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
      try? process(packet: nil, emit: emit)  // decoder drain
      try drainEncoder(flush: true, emit: emit)
    }

    private func drainEncoder(
      flush: Bool,
      emit: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
      guard let encodeFrame, let encodedPacket else { return }
      let frameSize = encoder.pointee.frame_size > 0 ? encoder.pointee.frame_size : 1024
      while av_audio_fifo_size(fifo) >= frameSize
        || (flush && av_audio_fifo_size(fifo) > 0)
      {
        let take = min(av_audio_fifo_size(fifo), frameSize)
        encodeFrame.pointee.nb_samples = take
        encodeFrame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        encodeFrame.pointee.sample_rate = sampleRate
        av_channel_layout_copy(&encodeFrame.pointee.ch_layout, &encoder.pointee.ch_layout)
        guard av_frame_get_buffer(encodeFrame, 0) >= 0 else { return }
        let raw = UnsafeMutableRawPointer(encodeFrame.pointee.extended_data)
          .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        av_audio_fifo_read(fifo, raw, take)
        encodeFrame.pointee.pts = nextPts == .min ? 0 : nextPts
        nextPts = encodeFrame.pointee.pts + Int64(take)
        _ = avcodec_send_frame(encoder, encodeFrame)
        av_frame_unref(encodeFrame)
        while avcodec_receive_packet(encoder, encodedPacket) == 0 {
          try emit(encodedPacket)
          av_packet_unref(encodedPacket)
        }
        if flush, av_audio_fifo_size(fifo) <= 0 { break }
      }
      if flush {
        _ = avcodec_send_frame(encoder, nil)
        while avcodec_receive_packet(encoder, encodedPacket) == 0 {
          try emit(encodedPacket)
          av_packet_unref(encodedPacket)
        }
      }
    }
  }

  // MARK: - Zaman damgası onarımı

  /// MKV/HEVC konteyner dts'i güvenilmez: çoğu karede yok, olanlarda eşit/geri
  /// gelebiliyor. Muxer'ın tahmini mp4'te -22, TS'te SESSİZ HİZA KAYMASI üretir
  /// (sahadaki ses kaymasının kökü — 18. tur). dts konteynerden beklenmeden
  /// deterministik üretilir: decode-sırası saati = önceki dts + kare süresi.
  /// İki segment döngüsü de bu tek implementasyonu paylaşır; saf değer tipi
  /// olduğu için tablo-testlenebilir.
  struct TimestampRepair {
    private var lastDTS: Int64?
    private var lastDuration: Int64 = 0

    /// Video: dts daima sentezlenir. nil = paket atlanmalı (ilk karede pts yok).
    mutating func repairVideo(pts: Int64, duration: Int64) -> (pts: Int64, dts: Int64)? {
      let dur = max(duration > 0 ? duration : lastDuration, 1)
      let outPts: Int64
      let outDts: Int64
      if let last = lastDTS {
        var dts = last + dur
        if pts != Int64.min, dts > pts { dts = pts }
        if dts <= last { dts = last + 1 }
        // Geriye zaman sıçramasında monotonluk bump'ı dts'i pts'in üstüne
        // itebilir; muxer EINVAL ile ölmesin diye pts kaldırılır.
        outPts = (pts != Int64.min && pts < dts) ? dts : pts
        outDts = dts
      } else {
        guard pts != Int64.min else { return nil }
        // İlk kare (keyframe): decode saati pts'in ~4 kare gerisinden başlar ki
        // B-frame'lerde dts ≤ pts hep sağlansın (mp4 edit list telafi eder).
        outPts = pts
        outDts = pts - dur * 4
      }
      lastDTS = outDts
      if duration > 0 { lastDuration = duration }
      return (outPts, outDts)
    }

    /// Ses: konteyner ts'i güvenilir; yalnız eksik/geri durumda düzeltilir.
    /// nil = paket atlanmalı (henüz referans yokken iki damga da eksik).
    mutating func repairAudio(
      pts: Int64, dts: Int64, duration: Int64
    ) -> (pts: Int64, dts: Int64)? {
      var outPts = pts
      var outDts = dts
      if outPts == Int64.min, outDts == Int64.min {
        guard let last = lastDTS else { return nil }
        outDts = last + max(duration > 0 ? duration : lastDuration, 1)
        outPts = outDts
      } else if outDts == Int64.min {
        outDts = outPts
      }
      if let last = lastDTS, outDts <= last {
        let bumped = last + 1
        if outPts != Int64.min, outPts < bumped { outPts = bumped }
        outDts = bumped
      }
      lastDTS = outDts
      if duration > 0 { lastDuration = duration }
      return (outPts, outDts)
    }
  }

  // MARK: - Ortak durum

  private struct SegmentRecord {
    let index: Int
    let fileName: String
    let duration: Double
  }

  private var segments: [SegmentRecord] = []
  /// Playlist penceresinden çıkmış ama dosyası henüz silinmemiş segmentler:
  /// pencerenin ucundan okuyan (geciken) TV, playlist güncellemesini görmeden
  /// istek atarsa 404 yememeli — birkaç segmentlik silme payı bırakılır.
  private var retiredSegments: [SegmentRecord] = []

  private func recordSegment(index: Int, fileName: String, duration: Double, final: Bool) {
    // İleri süreksizlikte (kaynak zaman sıçraması) lastSeconds-startSeconds saçma
    // büyür; absürt EXTINF, AVPlayer'ın seekable haritasını bozar — makul tavana kırp.
    let clamped = min(duration, targetSegmentSeconds * 4)
    segments.append(SegmentRecord(index: index, fileName: fileName, duration: clamped))
    if isLive {
      while segments.count > liveWindowSize {
        retiredSegments.append(segments.removeFirst())
      }
      while retiredSegments.count > 3 {
        let old = retiredSegments.removeFirst()
        try? FileManager.default.removeItem(
          at: outputDirectory.appendingPathComponent(old.fileName)
        )
      }
    }
    writePlaylist(final: final)
  }

  /// İlk segment kısa tutulur ki playlist (ve TV'deki ilk kare) erken hazır olsun.
  private func targetDuration(forSegmentIndex index: Int) -> Double {
    index == 0 ? min(1.5, targetSegmentSeconds) : targetSegmentSeconds
  }


  private enum AudioMode {
    case none
    case copy(inputIndex: Int)
    case transcode(inputIndex: Int, AudioTranscoder)

    var inputIndex: Int? {
      switch self {
      case .none: return nil
      case let .copy(index), let .transcode(index, _): return index
      }
    }
  }

  // MARK: - Remux loop (queue üzerinde)

  private func runRemuxLoop() throws {
    if let readyToOpen {
      // Önceki oturumun kaynak bağlantısı kapanana kadar bekle (panel slotu boşalsın);
      // openDelaySeconds üst sınır. Kapanınca kısa bir yerleşme payı bırak.
      let cap = Date().addingTimeInterval(openDelaySeconds > 0 ? openDelaySeconds : 3.0)
      var drained = false
      while cancelled.pointee == 0, Date() < cap {
        if readyToOpen() {
          drained = true
          break
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
      if cancelled.pointee != 0 { return }
      if drained { Thread.sleep(forTimeInterval: 0.3) }
    } else if openDelaySeconds > 0 {
      let deadline = Date().addingTimeInterval(openDelaySeconds)
      while cancelled.pointee == 0, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if cancelled.pointee != 0 { return }
    }
    var inputCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
    inputCtx?.pointee.interrupt_callback.callback = { opaque in
      opaque?.assumingMemoryBound(to: Int32.self).pointee ?? 0
    }
    inputCtx?.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(cancelled)

    var inputOpts: OpaquePointer?
    defer { av_dict_free(&inputOpts) }
    if let userAgent, !userAgent.isEmpty {
      av_dict_set(&inputOpts, "user_agent", userAgent, 0)
    }
    av_dict_set(&inputOpts, "reconnect", "1", 0)
    av_dict_set(&inputOpts, "reconnect_streamed", "1", 0)
    av_dict_set(&inputOpts, "rw_timeout", "15000000", 0)
    if isLive {
      av_dict_set(&inputOpts, "analyzeduration", "2000000", 0)
      av_dict_set(&inputOpts, "probesize", "1500000", 0)
      // Canlı yayın EOF'lamaz: panel resetleri temiz EOF olarak görünebiliyor.
      // Protokol katmanında yeniden bağlan — aksi halde EOF üst katmanda kopma
      // sayılır ve cast düşer (canlı zap'ta "görüntü kesiliyor").
      av_dict_set(&inputOpts, "reconnect_at_eof", "1", 0)
    }

    var openResult = avformat_open_input(&inputCtx, sourceURL.absoluteString, nil, &inputOpts)
    guard openResult >= 0, let input = inputCtx else {
      throw RemuxError.openInputFailed(openResult)
    }
    defer {
      var closing: UnsafeMutablePointer<AVFormatContext>? = input
      avformat_close_input(&closing)
    }
    openResult = avformat_find_stream_info(input, nil)
    guard openResult >= 0 else { throw RemuxError.openInputFailed(openResult) }
    if input.pointee.duration > 0 {
      sourceDurationSeconds = Double(input.pointee.duration) / Double(AV_TIME_BASE)
    }

    if !isLive, startSeconds > 1 {
      // stream_index=-1 → zaman damgası paketlerle aynı orijinde olmalı: start_time
      // sıfır olmayan kaynaklarda (TS catchup kayıtları) eklenmezse yanlış yere düşer.
      var ts = Int64(startSeconds * Double(AV_TIME_BASE))
      if input.pointee.start_time != Int64.min {
        ts += input.pointee.start_time
      }
      let seekResult = av_seek_frame(input, -1, ts, AVSEEK_FLAG_BACKWARD)
      if seekResult < 0 {
        // Seek edilemeyen kaynak: 0:00'dan yazılacak — zaman çizelgesi muhasebesi
        // bunu bilmezse UI istenen konumu gösterirken cast baştan oynar.
        Log.error("AirPlayRemux", "input seek failed (\(seekResult)); remuxing from 0:00")
        effectiveStartSeconds = 0
      }
    }

    // Stream seçimi: ilk uyumlu video + ilk ses (uyumsuzsa transcode).
    let streamCount = Int(input.pointee.nb_streams)
    var videoInputIndex = -1
    var videoIsHEVC = false
    var firstAudioIndex = -1
    var audioCodecId: UInt32 = 0
    for i in 0..<streamCount {
      guard let inStream = input.pointee.streams[i],
            let codecpar = inStream.pointee.codecpar
      else { continue }
      let codecId = codecpar.pointee.codec_id.rawValue
      switch codecpar.pointee.codec_type {
      case AVMEDIA_TYPE_VIDEO:
        if videoInputIndex < 0, Self.compatibleVideoCodecs.contains(codecId) {
          videoInputIndex = i
          videoIsHEVC = codecId == AV_CODEC_ID_HEVC.rawValue
        }
      case AVMEDIA_TYPE_AUDIO:
        if firstAudioIndex < 0 {
          firstAudioIndex = i
          audioCodecId = codecId
        }
      default:
        break
      }
    }
    guard videoInputIndex >= 0 else { throw RemuxError.noCompatibleStreams }

    let format = forcedFormat ?? (videoIsHEVC ? .fmp4 : .mpegTS)
    let passthrough = format == .fmp4 ? Self.fmp4AudioPassthrough : Self.tsAudioPassthrough

    var audioMode: AudioMode = .none
    if firstAudioIndex >= 0, let audioStream = input.pointee.streams[firstAudioIndex] {
      if passthrough.contains(audioCodecId) {
        audioMode = .copy(inputIndex: firstAudioIndex)
      } else if let transcoder = AudioTranscoder(inStream: audioStream) {
        Log.info("AirPlayRemux", "audio transcode to AAC (source codec id \(audioCodecId))")
        audioMode = .transcode(inputIndex: firstAudioIndex, transcoder)
      } else {
        Log.error("AirPlayRemux", "audio codec \(audioCodecId) not decodable; dropping audio")
        audioMode = .none
      }
    }

    switch format {
    case .mpegTS:
      try runTSLoop(
        input: input, videoInputIndex: videoInputIndex, audioMode: audioMode
      )
    case .fmp4:
      try runFMP4Loop(
        input: input, videoInputIndex: videoInputIndex, audioMode: audioMode
      )
    }
  }

  /// Paket zaman damgası → saniye (girdi time base'inde). Int64.min == AV_NOPTS_VALUE.
  private func packetSeconds(
    _ packet: AVPacket,
    inStream: UnsafeMutablePointer<AVStream>,
    fallback: Double
  ) -> Double {
    let rawTS = packet.dts != Int64.min ? packet.dts : packet.pts
    return rawTS != Int64.min ? Double(rawTS) * av_q2d(inStream.pointee.time_base) : fallback
  }

  /// Çıkış ctx'ine video(0) + varsa ses(1) stream'lerini kurar.
  private func addOutputStreams(
    to output: UnsafeMutablePointer<AVFormatContext>,
    input: UnsafeMutablePointer<AVFormatContext>,
    videoInputIndex: Int,
    audioMode: AudioMode
  ) throws {
    guard let videoIn = input.pointee.streams[videoInputIndex],
          let videoOut = avformat_new_stream(output, nil)
    else { throw RemuxError.openOutputFailed(-1) }
    var result = avcodec_parameters_copy(videoOut.pointee.codecpar, videoIn.pointee.codecpar)
    guard result >= 0 else { throw RemuxError.openOutputFailed(result) }
    if videoOut.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
      // Apple, HLS'te HEVC için yalnız 'hvc1' sample entry kabul eder ('hev1' → -12848).
      videoOut.pointee.codecpar.pointee.codec_tag =
        UInt32(UInt8(ascii: "h")) | UInt32(UInt8(ascii: "v")) << 8
        | UInt32(UInt8(ascii: "c")) << 16 | UInt32(UInt8(ascii: "1")) << 24
    } else {
      videoOut.pointee.codecpar.pointee.codec_tag = 0
    }

    switch audioMode {
    case .none:
      break
    case let .copy(inputIndex):
      guard let audioIn = input.pointee.streams[inputIndex],
            let audioOut = avformat_new_stream(output, nil)
      else { throw RemuxError.openOutputFailed(-1) }
      result = avcodec_parameters_copy(audioOut.pointee.codecpar, audioIn.pointee.codecpar)
      guard result >= 0 else { throw RemuxError.openOutputFailed(result) }
      audioOut.pointee.codecpar.pointee.codec_tag = 0
    case let .transcode(_, transcoder):
      guard let audioOut = avformat_new_stream(output, nil) else {
        throw RemuxError.openOutputFailed(-1)
      }
      result = avcodec_parameters_from_context(audioOut.pointee.codecpar, transcoder.encoder)
      guard result >= 0 else { throw RemuxError.openOutputFailed(result) }
      audioOut.pointee.codecpar.pointee.codec_tag = 0
    }
  }

  // MARK: - MPEG-TS segment yolu (H.264)

  private final class TSSegmentContext {
    let ctx: UnsafeMutablePointer<AVFormatContext>
    let index: Int
    var startSeconds: Double
    var lastSeconds: Double

    init(ctx: UnsafeMutablePointer<AVFormatContext>, index: Int, startSeconds: Double) {
      self.ctx = ctx
      self.index = index
      self.startSeconds = startSeconds
      lastSeconds = startSeconds
    }
  }

  private func runTSLoop(
    input: UnsafeMutablePointer<AVFormatContext>,
    videoInputIndex: Int,
    audioMode: AudioMode
  ) throws {
    var current: TSSegmentContext?
    var nextSegmentIndex = 0

    func openSegment(startSeconds: Double) throws {
      let fileName = String(format: "seg%05d.ts", nextSegmentIndex)
      let path = outputDirectory.appendingPathComponent(fileName).path
      var outCtx: UnsafeMutablePointer<AVFormatContext>?
      var result = avformat_alloc_output_context2(&outCtx, nil, "mpegts", path)
      guard result >= 0, let out = outCtx else { throw RemuxError.openOutputFailed(result) }
      do {
        try addOutputStreams(
          to: out, input: input, videoInputIndex: videoInputIndex, audioMode: audioMode
        )
      } catch {
        avformat_free_context(out)
        throw error
      }
      result = avio_open(&out.pointee.pb, path, AVIO_FLAG_WRITE)
      guard result >= 0 else {
        avformat_free_context(out)
        throw RemuxError.openOutputFailed(result)
      }
      result = avformat_write_header(out, nil)
      guard result >= 0 else {
        avio_closep(&out.pointee.pb)
        avformat_free_context(out)
        throw RemuxError.openOutputFailed(result)
      }
      current = TSSegmentContext(ctx: out, index: nextSegmentIndex, startSeconds: startSeconds)
      nextSegmentIndex += 1
    }

    func closeSegment(final: Bool) {
      guard let segment = current else { return }
      current = nil
      av_write_trailer(segment.ctx)
      avio_closep(&segment.ctx.pointee.pb)
      let fileName = String(format: "seg%05d.ts", segment.index)
      avformat_free_context(segment.ctx)
      recordSegment(
        index: segment.index,
        fileName: fileName,
        duration: max(segment.lastSeconds - segment.startSeconds, 0.5),
        final: final
      )
    }

    // Transcoded AAC paketleri: encoder tb → mevcut segmentin ses stream tb'sine.
    func writeTranscodedPacket(
      _ encoded: UnsafeMutablePointer<AVPacket>, transcoder: AudioTranscoder
    ) throws {
      guard let segment = current,
            let outStream = segment.ctx.pointee.streams[1]
      else { return }
      encoded.pointee.stream_index = 1
      av_packet_rescale_ts(
        encoded, transcoder.encoderTimeBase, outStream.pointee.time_base
      )
      let result = av_interleaved_write_frame(segment.ctx, encoded)
      if result < 0 { throw RemuxError.writeFailed(result) }
    }

    var videoClock = TimestampRepair()
    var audioClock = TimestampRepair()
    var packet = AVPacket()
    // Yazılan son video medya zamanı (kaynak zaman çizelgesinde) — pacing kapısı
    // ve erken-EOF tespiti buna bakar.
    var paceClock = effectiveStartSeconds
    while cancelled.pointee == 0 {
      waitForPacing(mediaSeconds: paceClock)
      if cancelled.pointee != 0 { break }
      let readResult = av_read_frame(input, &packet)
      if readResult == Self.avErrorEOF {
        // Canlı yayın "bitmez": EOF = kaynak koptu. VOD'da sürenin belirgin
        // gerisindeki EOF de kopmadır (panel bağlantıyı temiz kapatmış olabilir) —
        // ikisi de tamamlanma DEĞİL hatadır; ENDLIST yazılırsa film ortasında
        // sahte "bitti" + auto-next tetiklenir.
        if isLive { throw RemuxError.readFailed(readResult) }
        if sourceDurationSeconds > 0, paceClock < sourceDurationSeconds - 30 {
          throw RemuxError.readFailed(readResult)
        }
        break
      }
      if readResult < 0 { throw RemuxError.readFailed(readResult) }
      defer { av_packet_unref(&packet) }
      let inIndex = Int(packet.stream_index)
      guard let inStream = input.pointee.streams[inIndex] else { continue }
      let isVideo = inIndex == videoInputIndex
      let isAudio = inIndex == audioMode.inputIndex
      guard isVideo || isAudio else { continue }

      let seconds = packetSeconds(packet, inStream: inStream, fallback: current?.lastSeconds ?? 0)
      if isVideo, seconds > paceClock { paceClock = seconds }
      let isKeyframe = (packet.flags & AV_PKT_FLAG_KEY) != 0
      if let segment = current, isVideo, isKeyframe,
         seconds - segment.startSeconds >= targetDuration(forSegmentIndex: segment.index)
      {
        closeSegment(final: false)
      }
      if current == nil {
        guard isVideo, isKeyframe else { continue }
        try openSegment(startSeconds: seconds)
      }
      guard let segment = current else { continue }
      if isVideo || audioMode.inputIndex == inIndex, seconds > segment.lastSeconds {
        segment.lastSeconds = seconds
      }

      if isAudio, case let .transcode(_, transcoder) = audioMode {
        try transcoder.process(packet: &packet) { encoded in
          try writeTranscodedPacket(encoded, transcoder: transcoder)
        }
        continue
      }

      let outIndex = isVideo ? 0 : 1
      guard let outStream = segment.ctx.pointee.streams[outIndex] else { continue }
      packet.stream_index = Int32(outIndex)
      av_packet_rescale_ts(&packet, inStream.pointee.time_base, outStream.pointee.time_base)
      if isVideo {
        guard let repaired = videoClock.repairVideo(pts: packet.pts, duration: packet.duration)
        else { continue }
        packet.pts = repaired.pts
        packet.dts = repaired.dts
      } else {
        guard let repaired = audioClock.repairAudio(
          pts: packet.pts, dts: packet.dts, duration: packet.duration
        ) else { continue }
        packet.pts = repaired.pts
        packet.dts = repaired.dts
      }
      packet.pos = -1
      let writeResult = av_interleaved_write_frame(segment.ctx, &packet)
      if writeResult < 0 {
        closeSegment(final: false)
        throw RemuxError.writeFailed(writeResult)
      }
    }
    // İptalde final flush atlanır: yarım muxer'ı boşaltmak hem gürültü ("Cannot write
    // moov…") hem panelin bağlantı sınırını meşgul eden gereksiz kapanış işi üretir.
    if cancelled.pointee == 0, case let .transcode(_, transcoder) = audioMode, current != nil {
      try? transcoder.finish { encoded in
        try writeTranscodedPacket(encoded, transcoder: transcoder)
      }
    }
    if cancelled.pointee == 0 {
      closeSegment(final: !isLive)
    } else if let segment = current {
      current = nil
      avio_closep(&segment.ctx.pointee.pb)
      avformat_free_context(segment.ctx)
    }
  }

  // MARK: - fMP4 segment yolu (HEVC)

  /// Custom AVIO'nun yazdığı byte'ları biriktirir; fragment sınırında dosyaya bölünür.
  private final class ByteSink {
    var data = Data()
  }

  private func runFMP4Loop(
    input: UnsafeMutablePointer<AVFormatContext>,
    videoInputIndex: Int,
    audioMode: AudioMode
  ) throws {
    let sink = ByteSink()
    let sinkRef = Unmanaged.passRetained(sink)
    defer { sinkRef.release() }

    let bufferSize: Int32 = 1 << 16
    guard let avioBuffer = av_malloc(Int(bufferSize)) else {
      throw RemuxError.openOutputFailed(-1)
    }
    let writeCallback: @convention(c) (
      UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32 = { opaque, buf, size in
      guard let opaque, let buf, size > 0 else { return size }
      let sink = Unmanaged<ByteSink>.fromOpaque(opaque).takeUnretainedValue()
      sink.data.append(buf, count: Int(size))
      return size
    }
    var avio = avio_alloc_context(
      avioBuffer.assumingMemoryBound(to: UInt8.self), bufferSize, 1,
      sinkRef.toOpaque(), nil, writeCallback, nil
    )
    guard avio != nil else {
      av_free(avioBuffer)
      throw RemuxError.openOutputFailed(-1)
    }

    var outCtx: UnsafeMutablePointer<AVFormatContext>?
    var result = avformat_alloc_output_context2(&outCtx, nil, "mp4", nil)
    guard result >= 0, let out = outCtx else {
      avioFree(&avio)
      throw RemuxError.openOutputFailed(result)
    }
    out.pointee.pb = avio
    defer {
      out.pointee.pb = nil
      avioFree(&avio)
      avformat_free_context(out)
    }

    try addOutputStreams(
      to: out, input: input, videoInputIndex: videoInputIndex, audioMode: audioMode
    )

    var headerOpts: OpaquePointer?
    // frag_custom: fragment sınırlarını biz belirleriz (NULL-frame flush);
    // delay_moov: moov ilk flush'ta yazılır — EAC3 gibi codec'ler moov'daki kutular için
    // önce paket görmek ister; skip_trailer: mfra üretme.
    av_dict_set(
      &headerOpts, "movflags",
      "+empty_moov+default_base_moof+frag_custom+delay_moov+skip_trailer", 0
    )
    result = avformat_write_header(out, &headerOpts)
    av_dict_free(&headerOpts)
    guard result >= 0 else { throw RemuxError.openOutputFailed(result) }

    var segmentIndex = 0
    var segmentStart: Double = 0
    var segmentLast: Double = 0
    var segmentHasData = false
    var initWritten = false

    func emitFragment(final: Bool) throws {
      // Önce interleave kuyruğu boşaltılır; sonra av_write_frame(NULL) muxer'ı flush eder —
      // frag_custom'da fragment (moof+mdat) ancak bununla üretilir (interleaved NULL yetmez).
      // delay_moov ile ilk flush moov'u da üretir; kutu sınırından bölünür.
      _ = av_interleaved_write_frame(out, nil)
      _ = av_write_frame(out, nil)
      if !initWritten {
        _ = av_write_frame(out, nil)
      }
      avio_flush(out.pointee.pb)
      guard !sink.data.isEmpty else { return }
      if !initWritten {
        let (initData, fragmentData) = Self.splitAtFirstFragmentBox(sink.data)
        guard !initData.isEmpty else { return }
        // Disk hatası (dolu disk vb.) yutulursa TV sessizce donar; hata olarak yüzer.
        try initData.write(to: outputDirectory.appendingPathComponent("init.mp4"))
        Log.info(
          "AirPlayRemux",
          "fmp4 init: \(initData.count)B, first fragment: \(fragmentData.count)B"
        )
        initWritten = true
        sink.data = fragmentData
      }
      guard segmentHasData, !sink.data.isEmpty else { return }
      let fileName = String(format: "seg%05d.m4s", segmentIndex)
      try sink.data.write(to: outputDirectory.appendingPathComponent(fileName))
      sink.data.removeAll(keepingCapacity: true)
      recordSegment(
        index: segmentIndex,
        fileName: fileName,
        duration: max(segmentLast - segmentStart, 0.5),
        final: final
      )
      segmentIndex += 1
      segmentHasData = false
    }

    func writeTranscodedPacket(
      _ encoded: UnsafeMutablePointer<AVPacket>, transcoder: AudioTranscoder
    ) throws {
      guard let outStream = out.pointee.streams[1] else { return }
      encoded.pointee.stream_index = 1
      av_packet_rescale_ts(encoded, transcoder.encoderTimeBase, outStream.pointee.time_base)
      let writeResult = av_interleaved_write_frame(out, encoded)
      if writeResult < 0 { throw RemuxError.writeFailed(writeResult) }
      segmentHasData = true
    }

    var videoClock = TimestampRepair()
    var audioClock = TimestampRepair()
    var packet = AVPacket()
    var startedAtKeyframe = false
    var paceClock = effectiveStartSeconds
    while cancelled.pointee == 0 {
      waitForPacing(mediaSeconds: paceClock)
      if cancelled.pointee != 0 { break }
      let readResult = av_read_frame(input, &packet)
      if readResult == Self.avErrorEOF {
        // Bkz. TS döngüsündeki not: canlıda ve sürenin belirgin gerisindeki VOD'da
        // EOF kopmadır — tamamlanma değil.
        if isLive { throw RemuxError.readFailed(readResult) }
        if sourceDurationSeconds > 0, paceClock < sourceDurationSeconds - 30 {
          throw RemuxError.readFailed(readResult)
        }
        break
      }
      if readResult < 0 { throw RemuxError.readFailed(readResult) }
      defer { av_packet_unref(&packet) }
      let inIndex = Int(packet.stream_index)
      guard let inStream = input.pointee.streams[inIndex] else { continue }
      let isVideo = inIndex == videoInputIndex
      let isAudio = inIndex == audioMode.inputIndex
      guard isVideo || isAudio else { continue }

      let seconds = packetSeconds(packet, inStream: inStream, fallback: segmentLast)
      if isVideo, seconds > paceClock { paceClock = seconds }
      let isKeyframe = (packet.flags & AV_PKT_FLAG_KEY) != 0
      if !startedAtKeyframe {
        guard isVideo, isKeyframe else { continue }
        startedAtKeyframe = true
        segmentStart = seconds
        segmentLast = seconds
      }
      if segmentHasData, isVideo, isKeyframe,
         seconds - segmentStart >= targetDuration(forSegmentIndex: segmentIndex)
      {
        try emitFragment(final: false)
        segmentStart = seconds
      }
      if seconds > segmentLast { segmentLast = seconds }

      if isAudio, case let .transcode(_, transcoder) = audioMode {
        try transcoder.process(packet: &packet) { encoded in
          try writeTranscodedPacket(encoded, transcoder: transcoder)
        }
        continue
      }

      let outIndex = isVideo ? 0 : 1
      guard let outStream = out.pointee.streams[outIndex] else { continue }
      packet.stream_index = Int32(outIndex)
      av_packet_rescale_ts(&packet, inStream.pointee.time_base, outStream.pointee.time_base)
      if isVideo {
        guard let repaired = videoClock.repairVideo(pts: packet.pts, duration: packet.duration)
        else { continue }
        packet.pts = repaired.pts
        packet.dts = repaired.dts
      } else {
        guard let repaired = audioClock.repairAudio(
          pts: packet.pts, dts: packet.dts, duration: packet.duration
        ) else { continue }
        packet.pts = repaired.pts
        packet.dts = repaired.dts
      }
      packet.pos = -1
      let logPTS = packet.pts
      let logDTS = packet.dts
      let writeResult = av_interleaved_write_frame(out, &packet)
      if writeResult < 0 {
        Log.error(
          "AirPlayRemux",
          "fmp4 write failed \(writeResult): out=\(outIndex) pts=\(logPTS) dts=\(logDTS) key=\(isKeyframe)"
        )
        throw RemuxError.writeFailed(writeResult)
      }
      segmentHasData = true
    }
    if cancelled.pointee == 0 {
      if case let .transcode(_, transcoder) = audioMode, startedAtKeyframe {
        try? transcoder.finish { encoded in
          try writeTranscodedPacket(encoded, transcoder: transcoder)
        }
      }
      try emitFragment(final: !isLive)
      av_write_trailer(out)
    }
  }

  /// MP4 kutu akışını ilk 'moof'/'styp' kutusunda böler: öncesi init (ftyp+moov),
  /// sonrası ilk media fragment'ı.
  static func splitAtFirstFragmentBox(_ data: Data) -> (initData: Data, fragmentData: Data) {
    var offset = data.startIndex
    while offset + 8 <= data.endIndex {
      let size = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
      let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
      if type == "moof" || type == "styp" {
        return (Data(data[data.startIndex..<offset]), Data(data[offset...]))
      }
      guard size >= 8, offset + size <= data.endIndex else { break }
      offset += size
    }
    return (Data(data), Data())
  }

  private func avioFree(_ avio: inout UnsafeMutablePointer<AVIOContext>?) {
    guard let ctx = avio else { return }
    av_free(ctx.pointee.buffer)
    ctx.pointee.buffer = nil
    avio_context_free(&avio)
  }

  // MARK: - Playlist

  /// m3u8 atomik yazım: AVPlayer yarım playlist okumasın.
  private func writePlaylist(final: Bool) {
    guard !segments.isEmpty else { return }
    let usesFMP4 = segments[0].fileName.hasSuffix(".m4s")
    // Taban targetSegmentSeconds: ilk (kısa) segmentte TD'nin 2'den başlayıp sonra
    // büyümesi yerine kararlı başlar; seyrek keyframe'li kaynakta yine büyüyebilir.
    let target = max(
      Int(segments.map(\.duration).max()!.rounded(.up)),
      Int(targetSegmentSeconds.rounded(.up))
    )
    var lines: [String] = [
      "#EXTM3U",
      "#EXT-X-VERSION:\(usesFMP4 ? 7 : 3)",
      "#EXT-X-INDEPENDENT-SEGMENTS",
      "#EXT-X-TARGETDURATION:\(max(target, 1))",
      "#EXT-X-MEDIA-SEQUENCE:\(segments[0].index)",
    ]
    if !isLive {
      // Büyüyen event playlist'i taze bir istemci canlı sanıp YAYIN UCUNDAN katılır.
      // AirPlay'de Apple TV playlist'i KENDİSİ çektiğinden telefon tarafındaki seek
      // düzeltmesi TV'nin katılımını koruyamaz — ilk açılıştaki donma + sessiz ileri
      // sıçramanın kökü. EVENT + START=0 her taze istemciyi baştan başlatır.
      lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
      lines.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
    }
    if usesFMP4 {
      lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
    }
    for segment in segments {
      lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
      lines.append(segment.fileName)
    }
    if final {
      lines.append("#EXT-X-ENDLIST")
    }
    let content = lines.joined(separator: "\n") + "\n"
    do {
      try content.write(to: playlistURL, atomically: true, encoding: .utf8)
    } catch {
      // Bayat playlist TV'yi sessizce dondurur (disk dolu/sandbox): hata olarak yüz.
      Log.error("AirPlayRemux", "playlist write failed: \(error.localizedDescription)")
      if cancelled.pointee == 0 {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
      }
    }
  }

  /// Motor tarafında hızlı codec ön-kontrolü: adaylık artık yalnız videoya bakar —
  /// uyumsuz ses AAC'ye transcode edilir. Profil ekli adlar normalize edilir.
  static func isCompatible(videoFourCC: String, audioFourCC _: String? = nil) -> Bool {
    ["avc1", "h264", "hvc1", "hev1", "hevc"].contains(normalizeCodec(videoFourCC))
  }

  static func normalizeCodec(_ raw: String) -> String {
    raw.lowercased()
      .split(separator: " ").first.map(String.init)?
      .trimmingCharacters(in: .whitespaces) ?? ""
  }
}
