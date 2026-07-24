import Foundation
import Network

/// Minimal statik dosya sunucusu: Apple TV, AirPlay sırasında HLS playlist/segmentleri
/// buradan çeker. Yalnız GET, kök dizin altı (bir seviye oturum alt dizini dahil),
/// range'siz — HLS istemcileri için yeterli.
final class LocalHTTPServer {
  /// Zapping'de oturum başına listener kurup yıkmamak için süreç boyu paylaşılan örnek;
  /// oturumlar kök altında kendi alt dizinlerini kullanır. Port ve yerel-ağ doğrulaması
  /// böylece bir kez yapılır.
  static let shared: LocalHTTPServer = {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("airplay-remux", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // App kill ile yarım kalan önceki oturum dizinleri (segment yığınları) süpürülür;
    // ilk cast anında süreçte hiçbir oturum yok, kökün tamamı güvenle temizlenir.
    if let leftovers = try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    ) {
      for item in leftovers {
        try? FileManager.default.removeItem(at: item)
      }
    }
    return LocalHTTPServer(directory: root)
  }()

  let directory: URL
  private let listenerQueue = DispatchQueue(label: "AirPlayRemux.http.listener")
  /// Apple TV may request the playlist, init segment and media segments in
  /// parallel. Serving them on the listener's serial queue made one large
  /// segment read block every other request and caused avoidable startup stalls.
  private let connectionQueue = DispatchQueue(
    label: "AirPlayRemux.http.connections", attributes: .concurrent
  )
  /// listener/port farklı thread'lerden okunur (main'den start, queue'dan state
  /// callback'leri) — kilitle korunur.
  private let stateLock = NSLock()
  private var listener: NWListener?
  private var listenerPort: UInt16 = 0

  var port: UInt16 {
    stateLock.lock()
    defer { stateLock.unlock() }
    return listenerPort
  }

  init(directory: URL) {
    self.directory = directory
  }

  /// Idempotent: listener zaten ayaktaysa hızla döner. Ölmüş (failed/cancelled)
  /// listener state callback'inde kendini temizler — bir sonraki start() yeniden
  /// kurar; süreç ömrü boyu "ölü sunucu" durumu kalıcı olamaz.
  func start() throws {
    stateLock.lock()
    let alreadyRunning = listener != nil && listenerPort > 0
    stateLock.unlock()
    if alreadyRunning { return }

    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let newListener = try NWListener(using: params, on: .any)
    let ready = DispatchSemaphore(value: 0)
    newListener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    newListener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.stateLock.lock()
        self.listenerPort = newListener.port?.rawValue ?? 0
        let port = self.listenerPort
        self.stateLock.unlock()
        Log.info("AirPlayRemux", "http server ready on :\(port)")
        ready.signal()
      case let .failed(error):
        Log.error("AirPlayRemux", "http listener failed: \(error.localizedDescription)")
        newListener.cancel()
        self.clearIfCurrent(newListener)
        ready.signal()
      case .cancelled:
        self.clearIfCurrent(newListener)
        ready.signal()
      default:
        break
      }
    }
    stateLock.lock()
    listener = newListener
    listenerPort = 0
    stateLock.unlock()
    newListener.start(queue: listenerQueue)
    // Çağıran port'u senkron bekler (en fazla 1 sn); polling yerine state sinyali.
    _ = ready.wait(timeout: .now() + 1)
  }

  private func clearIfCurrent(_ candidate: NWListener) {
    stateLock.lock()
    if listener === candidate {
      listener = nil
      listenerPort = 0
    }
    stateLock.unlock()
  }

  func stop() {
    stateLock.lock()
    let current = listener
    listener = nil
    listenerPort = 0
    stateLock.unlock()
    current?.cancel()
  }

  /// Telefonun, Apple TV'nin erişebileceği IPv4 adresi. Tercih sırası: en0 (Wi-Fi) →
  /// bridge* (hotspot: TV telefonun hotspot'undaysa) → diğer en* arayüzleri.
  /// lo/utun(VPN)/pdp_ip(hücresel)/awdl-llw adresleri TV'den erişilemez, atlanır;
  /// 169.254.* link-local adresler de (DHCP yokken) elenir.
  static func lanIPv4Address() -> String? {
    var addrList: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrList) == 0, let first = addrList else { return nil }
    defer { freeifaddrs(addrList) }
    var best: (rank: Int, address: String)?
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      let ifa = entry.pointee
      cursor = ifa.ifa_next
      guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: ifa.ifa_name)
      let rank: Int
      if name == "en0" {
        rank = 0
      } else if name.hasPrefix("bridge") {
        rank = 1
      } else if name.hasPrefix("en") {
        rank = 2
      } else {
        continue
      }
      if let bestSoFar = best, bestSoFar.rank <= rank { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(
        sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
        nil, 0, NI_NUMERICHOST
      ) == 0 {
        let address = String(cString: host)
        guard !address.hasPrefix("169.254.") else { continue }
        best = (rank, address)
      }
    }
    return best?.address
  }

  // MARK: - Request handling

  private func handle(_ connection: NWConnection) {
    connection.start(queue: connectionQueue)
    receiveRequest(connection, buffer: Data())
  }

  private func receiveRequest(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] data, _, _, error in
      guard let self, error == nil, let data else {
        connection.cancel()
        return
      }
      var accumulated = buffer
      accumulated.append(data)
      if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
        self.respond(connection, requestHead: head)
      } else if accumulated.count < 64 * 1024 {
        self.receiveRequest(connection, buffer: accumulated)
      } else {
        connection.cancel()
      }
    }
  }

  private func respond(_ connection: NWConnection, requestHead: String) {
    guard let requestLine = requestHead.components(separatedBy: "\r\n").first,
          requestLine.hasPrefix("GET ")
    else {
      send(connection, status: "405 Method Not Allowed", body: Data(), contentType: "text/plain")
      return
    }
    let rawPath = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    let cleanPath = rawPath.split(separator: "?").first.map(String.init) ?? "/"
    if cleanPath == "/ping" {
      // Erişilebilirlik/izin ön-doğrulaması: playlist hazır olmadan da 200 verir.
      send(connection, status: "200 OK", body: Data("ok".utf8), contentType: "text/plain")
      return
    }
    // Yol atlatmaya kapalı: kök altında en fazla iki bileşen (oturum-dizini/dosya),
    // ".." ve boş bileşen reddedilir.
    let components = cleanPath.split(separator: "/").map(String.init)
    guard !components.isEmpty, components.count <= 2,
          components.allSatisfy({ !$0.isEmpty && $0 != ".." && !$0.hasPrefix(".") })
    else {
      send(connection, status: "404 Not Found", body: Data(), contentType: "text/plain")
      return
    }
    let fileURL = components.reduce(directory) { $0.appendingPathComponent($1) }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
          let number = attributes[.size] as? NSNumber
    else {
      send(connection, status: "404 Not Found", body: Data(), contentType: "text/plain")
      return
    }
    let fileSize = number.intValue
    let fileName = components.last!
    let contentType = Self.contentType(for: fileName)
    let rangeHeader = requestHead.components(separatedBy: "\r\n")
      .first { $0.lowercased().hasPrefix("range:") }
      .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }

    if let rangeHeader {
      guard let range = Self.byteRange(from: rangeHeader, fileSize: fileSize),
            let data = Self.read(fileURL, range: range)
      else {
        send(
          connection, status: "416 Range Not Satisfiable", body: Data(),
          contentType: contentType,
          additionalHeaders: ["Content-Range": "bytes */\(fileSize)"]
        )
        return
      }
      send(
        connection, status: "206 Partial Content", body: data,
        contentType: contentType, noCache: fileName.hasSuffix(".m3u8"),
        additionalHeaders: [
          "Accept-Ranges": "bytes",
          "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)",
        ]
      )
      return
    }

    guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
      send(connection, status: "404 Not Found", body: Data(), contentType: "text/plain")
      return
    }
    send(
      connection, status: "200 OK", body: data,
      contentType: contentType, noCache: fileName.hasSuffix(".m3u8"),
      additionalHeaders: ["Accept-Ranges": "bytes"]
    )
  }

  /// Parses a single RFC 7233 byte range. AVPlayer commonly uses both open-ended
  /// (`bytes=1024-`) and suffix (`bytes=-1024`) forms for fMP4 resources.
  private static func byteRange(from header: String, fileSize: Int) -> ClosedRange<Int>? {
    guard fileSize > 0, header.lowercased().hasPrefix("bytes=") else { return nil }
    let value = header.dropFirst("bytes=".count)
    guard !value.contains(",") else { return nil }  // multipart ranges unsupported
    let bounds = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2 else { return nil }

    if bounds[0].isEmpty {
      guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }
      let length = min(suffix, fileSize)
      return (fileSize - length)...(fileSize - 1)
    }

    guard let start = Int(bounds[0]), start >= 0, start < fileSize else { return nil }
    let requestedEnd = bounds[1].isEmpty ? fileSize - 1 : Int(bounds[1])
    guard let requestedEnd, requestedEnd >= start else { return nil }
    return start...min(requestedEnd, fileSize - 1)
  }

  private static func read(_ url: URL, range: ClosedRange<Int>) -> Data? {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(range.lowerBound))
      return try handle.read(upToCount: range.count)
    } catch {
      return nil
    }
  }

  private static func contentType(for fileName: String) -> String {
    if fileName.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
    if fileName.hasSuffix(".ts") { return "video/mp2t" }
    if fileName.hasSuffix(".m4s") { return "video/iso.segment" }
    if fileName.hasSuffix(".mp4") { return "video/mp4" }
    return "application/octet-stream"
  }

  private func send(
    _ connection: NWConnection,
    status: String,
    body: Data,
    contentType: String,
    noCache: Bool = false,
    additionalHeaders: [String: String] = [:]
  ) {
    var header = "HTTP/1.1 \(status)\r\n"
    header += "Content-Type: \(contentType)\r\n"
    header += "Content-Length: \(body.count)\r\n"
    header += "Access-Control-Allow-Origin: *\r\n"
    if noCache { header += "Cache-Control: no-cache\r\n" }
    for (name, value) in additionalHeaders {
      header += "\(name): \(value)\r\n"
    }
    header += "Connection: close\r\n\r\n"
    var response = Data(header.utf8)
    response.append(body)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in
        connection.cancel()
      }
    )
  }
}
