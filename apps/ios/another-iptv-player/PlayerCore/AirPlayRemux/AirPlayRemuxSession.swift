import Foundation

/// Bir AirPlay remux oturumunun yaşam döngüsü: temp dizin + FFmpeg remux yazıcısı +
/// yerel HTTP sunucusu. `localPlaylistURL` hazır olunca AVPlayer'a verilir; Apple TV
/// segmentleri telefonun LAN adresinden çeker.
final class AirPlayRemuxSession {
  let sourceURL: URL
  /// Remux'un kaynak içinde başladığı saniye — oynatma konumu = offset + yerel konum.
  let startOffsetSeconds: TimeInterval
  let isLive: Bool
  /// VOD'da oynatma başlamadan biriktirilecek içerik (sn). İlk başlatmada yüksek
  /// (tekleme koruması), seek yenilemesinde düşük (kullanıcı aktif bekliyor).
  let minimumBufferSeconds: Double

  private let directory: URL
  private let sessionPathComponent: String
  private let writer: RemuxHLSWriter
  private let server: LocalHTTPServer
  private(set) var localPlaylistURL: URL?

  var onError: ((Error) -> Void)?

  /// Yerel sunucuya erişim bir kez doğrulandıysa sonraki oturumlarda uzun retry gereksiz.
  private static var hasVerifiedLocalNetwork = false

  /// Bir önceki oturum: yeni writer, bunun kaynak bağlantısı kapanana dek beklemeli
  /// (bağlantı-limitli panelde çift açılış çakışması). start tamamlanınca serbest kalır.
  private var previousToDrain: AirPlayRemuxSession?

  /// Bu oturumun kaynak bağlantısı fiilen kapandı mı (writer döngüsü çözüldü)?
  var isSourceClosed: Bool { writer.isClosed }

  init(
    sourceURL: URL,
    startOffsetSeconds: TimeInterval,
    isLive: Bool,
    userAgent: String?,
    minimumBufferSeconds: Double = 12,
    openDelaySeconds: Double = 0,
    previousToDrain: AirPlayRemuxSession? = nil,
    subtitleFileURL: URL? = nil,
    subtitleName: String? = nil,
    subtitleLanguage: String? = nil
  ) throws {
    self.sourceURL = sourceURL
    self.startOffsetSeconds = isLive ? 0 : startOffsetSeconds
    self.isLive = isLive
    self.minimumBufferSeconds = minimumBufferSeconds
    self.previousToDrain = previousToDrain
    // Paylaşılan sunucunun kökü altında oturuma özel alt dizin: zapping'de listener ve
    // yerel-ağ doğrulaması yeniden kurulmaz.
    server = LocalHTTPServer.shared
    sessionPathComponent = "s\(UUID().uuidString.prefix(8))"
    directory = server.directory.appendingPathComponent(sessionPathComponent, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // `self` strong tutar; closure zayıf yakalar → döngü yok, ama beklerken canlı kalır.
    let readyToOpen: (() -> Bool)? = previousToDrain.map { prev in
      { [weak prev] in prev?.isSourceClosed ?? true }
    }
    writer = RemuxHLSWriter(
      sourceURL: sourceURL,
      outputDirectory: directory,
      startSeconds: self.startOffsetSeconds,
      isLive: isLive,
      userAgent: userAgent,
      openDelaySeconds: openDelaySeconds,
      readyToOpen: readyToOpen,
      subtitleFileURL: subtitleFileURL,
      subtitleName: subtitleName,
      subtitleLanguage: subtitleLanguage
    )
  }

  /// Güvenlik ağı: referans stop() çağrılmadan düşerse (state machine hatası vb.)
  /// başıboş writer'ın panel bağlantısını sonsuza dek tutması engellenir.
  deinit {
    writer.cancel()
  }

  /// Sunucu + remux'u başlatır; playlist ilk segmentiyle diske düşünce completion çağrılır.
  /// Playlist ~10 sn içinde oluşmazsa hata döner (kaynak açılamadı vb.).
  func start(completion: @escaping (Result<URL, Error>) -> Void) {
    do {
      try server.start()
    } catch {
      completion(.failure(error))
      return
    }
    guard let ip = LocalHTTPServer.lanIPv4Address(), server.port > 0 else {
      completion(
        .failure(
          NSError(
            domain: "AirPlayRemux", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No LAN IPv4 address (Wi-Fi off?)"]
          )))
      return
    }
    let playlistPath = writer.playlistURL.path
    let baseURL = "http://\(ip):\(server.port)/\(sessionPathComponent)"
    // Playlist üretimi ve erişilebilirlik doğrulaması PARALEL koşar; ikisi de bitince
    // tamamlanır. Canlıda ilk segment gerçek zamanlı dolduğundan süre payı geniş tutulur.
    // VOD'da tampon birikmesi beklenir (aşağıda) — 4K'da indirme ~gerçek zamanlı olabilir.
    let deadline = Date().addingTimeInterval(25)
    var playlistReady = false
    var serverVerified = false
    var finished = false
    let finishIfReady = {
      guard playlistReady, serverVerified, !finished else { return }
      finished = true
      self.previousToDrain = nil  // writer artık açtı; drenaj referansını bırak
      // If a subtitle rendition was requested, the writer has upgraded the client
      // playlist to the subtitle master by now (written on the first segment; readiness
      // needs many more). Otherwise this is still the raw video playlist.
      let localURL = URL(string: "\(baseURL)/\(self.writer.clientPlaylistFileName)")!
      self.localPlaylistURL = localURL
      completion(.success(localURL))
    }
    let failOnce = { (error: Error) in
      guard !finished else { return }
      finished = true
      self.previousToDrain = nil
      self.stop()
      completion(.failure(error))
    }
    // Writer errors during the start window fail the start immediately (a source
    // with incompatible codecs must not sit out the full playlist deadline);
    // errors after a successful start are forwarded to `onError`.
    writer.onError = { [weak self] (error: Error) in
      DispatchQueue.main.async {
        guard let self else { return }
        if finished {
          self.onError?(error)
        } else {
          failOnce(error)
        }
      }
    }
    writer.start()
    waitForPlaylist(path: playlistPath, deadline: deadline) { ready in
      if ready {
        playlistReady = true
        finishIfReady()
      } else {
        failOnce(
          NSError(
            domain: "AirPlayRemux", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Remux playlist not produced in time"]
          ))
      }
    }
    // /ping playlist'ten bağımsız hemen 200 döner; ilk istek iOS "Yerel Ağ" izin
    // diyaloğunu tetikleyebilir — kullanıcı yanıtlayana kadar retry gerekir.
    let attempts = Self.hasVerifiedLocalNetwork ? 5 : 20
    verifyReachable(
      url: URL(string: "http://\(ip):\(server.port)/ping")!,
      attemptsLeft: attempts
    ) { reachable in
      if reachable {
        Self.hasVerifiedLocalNetwork = true
        serverVerified = true
        finishIfReady()
      } else {
        failOnce(
          NSError(
            domain: "AirPlayRemux", code: 3,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Local server unreachable (local network permission denied?)"
            ]
          ))
      }
    }
  }

  var sourceDurationSeconds: TimeInterval { writer.sourceDurationSeconds }

  /// Girdi seek'inin gerçekte düştüğü konum; seek edilemeyen kaynakta 0'a düşer.
  /// Zaman çizelgesi muhasebesi istenen offset yerine bunu kullanmalı.
  var effectiveStartOffsetSeconds: TimeInterval { writer.effectiveStartSeconds }

  /// Cast oynatıcısının kaynak-zamanı konumu — yazıcının VOD pacing kapısını besler.
  func updatePlaybackPosition(_ seconds: TimeInterval) {
    writer.updatePlaybackPosition(seconds)
  }

  private func verifyReachable(
    url: URL,
    attemptsLeft: Int,
    completion: @escaping (Bool) -> Void
  ) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    let task = URLSession.shared.dataTask(with: request) { _, response, _ in
      if (response as? HTTPURLResponse)?.statusCode == 200 {
        DispatchQueue.main.async { completion(true) }
      } else if attemptsLeft > 1 {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
          self.verifyReachable(url: url, attemptsLeft: attemptsLeft - 1, completion: completion)
        }
      } else {
        DispatchQueue.main.async { completion(false) }
      }
    }
    task.resume()
  }

  func stop() {
    writer.cancel()
    // Paylaşılan sunucu durdurulmaz; yalnız bu oturumun dizini temizlenir. Silme
    // GECİKMELİ: içerik değişiminde Apple TV eski playlist'i bir süre daha
    // yoklayabiliyor — dizin 1 sn'de silinince 404'ler item'ı .failed'a itip
    // sağlıklı devri öldürüyordu. Pacing sayesinde dizin ~25-35 sn medya kadar.
    let dir = directory
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
      try? FileManager.default.removeItem(at: dir)
    }
  }

  /// Cast'in başlamasına yetecek içerik playlist'te birikti mi? Canlı: 3 segment
  /// yeter (gerçek zamanlı dolar). VOD: AVPlayer yazıcının dibinde koşmasın diye
  /// tampon biriksin — 4K'da indirme gerçek zamana yakınken tampon olmadan TV'de
  /// tekleme kaçınılmaz. ENDLIST (kısa içerik/remux bitti) her durumda yeterlidir.
  /// Saf fonksiyon: 13-14. tur düzeltmelerinin (tampon kapıları) regresyon kilidi.
  static func playlistReady(
    content: String,
    isLive: Bool,
    minimumBufferSeconds: Double
  ) -> Bool {
    if content.contains("#EXT-X-ENDLIST") { return true }
    let durations = content.split(separator: "\n")
      .filter { $0.hasPrefix("#EXTINF:") }
      .compactMap { Double($0.dropFirst("#EXTINF:".count).dropLast()) }
    return isLive
      ? durations.count >= 3
      : durations.reduce(0, +) >= minimumBufferSeconds
  }

  private func waitForPlaylist(
    path: String,
    deadline: Date,
    completion: @escaping (Bool) -> Void
  ) {
    let isLive = self.isLive
    DispatchQueue.global(qos: .userInitiated).async {
      while Date() < deadline {
        if let content = try? String(contentsOfFile: path, encoding: .utf8),
           Self.playlistReady(
             content: content, isLive: isLive, minimumBufferSeconds: self.minimumBufferSeconds
           )
        {
          DispatchQueue.main.async { completion(true) }
          return
        }
        Thread.sleep(forTimeInterval: 0.25)
      }
      DispatchQueue.main.async { completion(false) }
    }
  }
}
