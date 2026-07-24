import AVFoundation
import Combine
import Foundation
import MediaPlayer
import SwiftUI
import UIKit
import os

struct TrackMenuOption: Identifiable, Hashable {
  let id: Int
  let title: String
  let detail: String?
  let langCode: String?
  /// mpv `track-list/N/external`: external file track added via `sub-add`.
  let isExternal: Bool
  /// Başlık gerçek metadata değil, index'ten türetilmiş ("Parça 2" gibi). Tercih olarak
  /// SAKLANMAMALI — bir sonraki videoda pozisyonu aynı olan alakasız parçayı seçtirir.
  let isSyntheticTitle: Bool

  init(id: Int, title: String, detail: String? = nil, langCode: String? = nil, isExternal: Bool = false, isSyntheticTitle: Bool = false) {
    self.id = id
    self.title = title
    self.detail = detail
    self.langCode = langCode
    self.isExternal = isExternal
    self.isSyntheticTitle = isSyntheticTitle
  }
}

enum VideoPlayerState: Int {
  case idle = 0
  case loading = 1
  case buffering = 2
  case playing = 3
  case paused = 4
  case stopped = 5
  case ended = 6
  case error = 7
}

enum VideoAspectMode: String, CaseIterable {
  case ratio16x9
  case ratio4x3
  case center
  case bestFit
  case ratio16x10

  var preferredAspectRatio: CGFloat? {
    switch self {
    case .ratio16x9: return 16.0 / 9.0
    case .ratio4x3: return 4.0 / 3.0
    case .ratio16x10: return 16.0 / 10.0
    case .center, .bestFit: return nil
    }
  }

  var iconName: String {
    switch self {
    case .ratio16x9: return "rectangle"
    case .ratio4x3: return "rectangle.portrait"
    case .center: return "dot.square"
    case .bestFit: return "aspectratio"
    case .ratio16x10: return "rectangle.compress.vertical"
    }
  }

  var title: String {
    switch self {
    case .ratio16x9: return "16:9"
    case .ratio4x3: return "4:3"
    case .center: return "Center"
    case .bestFit: return "Best Fit"
    case .ratio16x10: return "16:10"
    }
  }

  var accessibilityLabel: String {
    "Aspect ratio: \(title)"
  }

  var viewportContentMode: UIView.ContentMode {
    // Tüm modlarda .scaleAspectFit: video frame içinde doğal oranında gösterilir.
    // Fixed ratio modlarda (16:9, 4:3) SwiftUI frame zorlu oran boyutuna getirilir;
    // UIImageView içeriği pillarbox/letterbox ile doğal oranında sığar — MPV'nin varsayılan
    // davranışıyla aynı sonuç. .scaleToFill kullanılırsa video yanlış uzatılır.
    return .scaleAspectFit
  }
}

/// `PlayerView` köprüsü: `KSPlayerEngine` + Now Playing / uzaktan kumanda.
final class VideoPlayerController: ObservableObject {
  /// SwiftUI may construct the incoming player before the outgoing player's
  /// `onDisappear` runs. Weak process-level registration lets the new controller
  /// see and claim an active AirPlay owner during that overlap window.
  private final class WeakControllerReference {
    weak var value: VideoPlayerController?
    init(_ value: VideoPlayerController) { self.value = value }
  }

  private static var activeControllerReferences: [WeakControllerReference] = []

  private static func register(_ controller: VideoPlayerController) {
    activeControllerReferences.removeAll { $0.value == nil }
    activeControllerReferences.append(WeakControllerReference(controller))
  }

  private static func unregister(_ controller: VideoPlayerController) {
    activeControllerReferences.removeAll { $0.value == nil || $0.value === controller }
  }

  private static func engagedCastController() -> CastController? {
    activeControllerReferences.removeAll { $0.value == nil }
    return activeControllerReferences.lazy
      .compactMap(\.value)
      .filter { !$0.isTornDown }
      .compactMap(\.castController)
      .first { $0.isEngaged }
  }

  private static func hasNativeExternalPlayback(excluding controller: VideoPlayerController) -> Bool {
    activeControllerReferences.removeAll { $0.value == nil }
    return activeControllerReferences.lazy
      .compactMap(\.value)
      .contains { other in
        other !== controller && !other.isTornDown
          && (other.engine.isExternalPlaybackActive
              || other.isAirPlayPlaybackActive)
      }
  }

  /// AVAudioSession is process-wide while VideoPlayerController is screen-scoped.
  /// A newly opened player claims a newer lease so an older controller's delayed
  /// teardown cannot deactivate the session underneath current playback.
  nonisolated private static let audioSessionLeaseLock = NSLock()
  nonisolated(unsafe) private static var audioSessionLeaseSerial: UInt64 = 0
  nonisolated(unsafe) private static var currentAudioSessionLease: UInt64?

  nonisolated private static func claimAudioSessionLease() -> (token: UInt64, previous: UInt64?) {
    audioSessionLeaseLock.lock()
    defer { audioSessionLeaseLock.unlock() }
    let previous = currentAudioSessionLease
    audioSessionLeaseSerial &+= 1
    currentAudioSessionLease = audioSessionLeaseSerial
    return (audioSessionLeaseSerial, previous)
  }

  nonisolated private static func rollBackAudioSessionLease(
    _ token: UInt64, previous: UInt64?
  ) {
    audioSessionLeaseLock.lock()
    defer { audioSessionLeaseLock.unlock() }
    if currentAudioSessionLease == token {
      currentAudioSessionLease = previous
    }
  }

  nonisolated private static func deactivateAudioSessionIfCurrent(_ token: UInt64) {
    audioSessionLeaseLock.lock()
    defer { audioSessionLeaseLock.unlock() }
    guard currentAudioSessionLease == token else { return }
    currentAudioSessionLease = nil
    try? AVAudioSession.sharedInstance().setActive(
      false, options: .notifyOthersOnDeactivation
    )
  }

  private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "another-iptv-player",
    category: "VideoPlayer"
  )

  let engine: KSPlayerEngine
  /// AirPlay cast orkestratörü. Cast oturumu aktifken motor tamamen durdurulur;
  /// sunum ve transport bu nesne üzerinden akar.
  let castController: CastController?
  private let castOwnerToken = UUID()

  @Published var state: VideoPlayerState = .idle
  @Published var isPlaying: Bool = false
  @Published var isSeekable: Bool = false
  @Published var position: Float = 0
  @Published var durationMs: Int64 = 0
  @Published var timeMs: Int64 = 0
  @Published var bufferingProgress: Float = 0
  @Published var rate: Float = 1.0
  @Published var videoWidth: Int = 0
  @Published var videoHeight: Int = 0
  @Published var streamFPS: Double = 0
  @Published var renderFPS: Double = 0
  @Published var videoBitrate: Double = 0
  @Published var droppedFrameCount: Int64 = 0
  @Published var delayedFrameCount: Int64 = 0
  @Published var cacheBufferingState: Double = 0
  @Published var cacheDurationSeconds: Double = 0
  @Published var cacheAheadSeconds: Double = 0
  @Published var avSyncSeconds: Double = 0
  @Published var networkSpeedBps: Double = 0
  @Published var hwdecCurrent: String = ""
  @Published var videoCodecName: String = ""
  @Published var seekLatencyMs: Int = -1
  /// Ağ / yükleme hatası (`KSPlayerEngine.playbackFailureMessage` yansıması).
  @Published var playbackFailureMessage: String?

  @Published var videoTracks: [TrackMenuOption] = []
  @Published var audioTracks: [TrackMenuOption] = []
  @Published var subtitleTracks: [TrackMenuOption] = [TrackMenuOption(id: -1, title: L("player.subtitle_off"))]
  @Published var currentVideoTrackId: Int = -1
  @Published var currentAudioTrackId: Int = -1
  @Published var currentSubtitleTrackId: Int = -1

  @Published var isPiPActive: Bool = false
  /// Yalnız KSPlayer/AVPlayer yolunda true: gerçek AirPlay external playback mümkün.
  @Published private(set) var isAirPlayVideoCapable: Bool = false
  /// Debug overlay için: aktif ses codec'i (AirPlay adaylığı teşhisi).
  @Published private(set) var audioCodecName: String = ""
  /// FFmpeg yolunda: AirPlay butonu önce remux hazırlar, sonra sistem seçiciyi açar.
  @Published private(set) var needsAirPlayPreparation: Bool = false
  /// Cast oturumu sunumda: transport/scrubber cast'e akar, track menüsü pasif.
  @Published private(set) var isCastPresenting: Bool = false
  /// Video şu anda AirPlay hedefinde oynuyor (native external ya da remux cast);
  /// yerel yüzeyde "AirPlay'de oynatılıyor" placeholder'ı gösterilir.
  @Published private(set) var isAirPlayPlaybackActive: Bool = false
  @Published var aspectMode: VideoAspectMode = .bestFit
  /// Canlı yayın bayrağı: `setPlaybackPresentation` üzerinden güncellenir. PiP sample buffer
  /// delegesi skip kontrollerini gizlemek için bu değeri okur (mpv duration canlıda 0 dönmeyebilir).
  @Published var isLiveStream: Bool = false

  /// Sistem ekran parlaklığı (0…1). Kontrol Merkezi vb. dış değişimler `brightnessDidChange` ile güncellenir.
  @Published private(set) var screenBrightness: CGFloat

  var hdrAvailable: Bool = false

  private struct PendingLoadRequest {
    let url: URL
    let startSeconds: TimeInterval?
    let isLiveStream: Bool
    let userAgent: String?
  }

  private var pendingLoadRequest: PendingLoadRequest?
  /// Son `play(url:)` isteği — AirPlay hazırlığı ve cast devri buradan içerik kurar.
  private var currentLoadRequest: PendingLoadRequest?
  private var isTornDown = false
  private var audioSessionActivated = false
  private var audioSessionLease: UInt64?
  /// System brightness before the app's first in-player adjustment; restored on teardown
  /// so leaving the player never strands the whole device at the in-video level.
  private var brightnessToRestore: CGFloat?
  private var playbackPresentation: PlaybackPresentation?
  private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
  private var seriesEpisodeOnPrevious: (() -> Void)?
  private var seriesEpisodeOnNext: (() -> Void)?
  /// Remote-command'lar yeniden kurulduğunda enable durumunu geri uygulamak için.
  private var episodeNavCanPrevious = false
  private var episodeNavCanNext = false
  private var episodeNavSwapSkip = true
  private var cancellables = Set<AnyCancellable>()

  private var nowPlayingArtwork: UIImage?
  private var artworkFetchTask: URLSessionDataTask?
  private var artworkFetchURL: URL?
  private var seekRequestStartedAt: Date?
  private var seekSourceTimeMs: Int64?
  /// `play` sonrası ilk `isPlaybackEstablished` olayında kayıtlı parça tercihleri uygulanır.
  private var pendingPreferredTrackSelection = false

  /// Imported external subtitles (`ImportedSubtitleStore`): the content key comes from
  /// PlayerView; once playback is established the stored files are re-added to mpv.
  @Published private(set) var importedSubtitleFiles: [URL] = []
  private var importedSubtitleContentKey: String?

  init() {
    engine = KSPlayerEngine()
    castController = CastController.takeCrossScreenHandoff()
      ?? Self.engagedCastController()
      ?? CastController()
    screenBrightness = UIScreen.main.brightness
    wireEngine()
    wireCastController()
    Self.register(self)
  }

  deinit {
    teardown()
  }

  /// Kenar tespiti için son görülen motor durumları (`changePublisher` toplu yayınlar).
  private var lastEngineIsReady = false
  private var lastEngineEstablished = false

  private func wireEngine() {
    // DispatchQueue scheduler'ı her zaman async planlar; objectWillChange değişimden
    // ÖNCE ateşlense de sink koşarken değerler güncellenmiş olur.
    engine.changePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        self?.handleEngineChange()
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        // Dosyanın zorunlu kıldığı `if current != new` koruması: @Published aynı
        // değerde bile objectWillChange yakar, sürükleme boyunca PlayerView'ı boşa
        // invalidate ediyordu.
        let b = UIScreen.main.brightness
        if self.screenBrightness != b { self.screenBrightness = b }
      }
      .store(in: &cancellables)

    // Phone call / Siri / alarm: iOS deactivates our session and mpv's audio output
    // stops. Without this observer the player stays silent until fully reopened.
    NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        self?.handleAudioSessionInterruption(note)
      }
      .store(in: &cancellables)

    // Kulaklık çıkarma / Bluetooth kopması: platform geleneği (AVPlayer davranışı)
    // oynatmayı duraklatmaktır — aksi halde ses aniden hoparlörden devam eder.
    // Cast aktifken bu kural İŞLEMEZ: oynatma TV'de, AirPlay rota kararları
    // CastController'ındır (iki gözlemcinin çelişmesi saha bulgusuydu).
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] note in
        guard let self,
              let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: reasonRaw) == .oldDeviceUnavailable,
              self.isPlaying,
              self.castController?.isEngaged != true
        else { return }
        self.engine.pause()
      }
      .store(in: &cancellables)
  }

  private func wireCastController() {
    guard let cast = castController else { return }
    cast.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        self?.handleEngineChange()
      }
      .store(in: &cancellables)
    cast.attachOwner(
      token: castOwnerToken,
      stopDirectPlayback: { [weak self] in
      guard let self else { return }
      self.engine.stopPlayback()
      // KSPlayerLayer.deinit removeTarget(nil) ile TÜM remote-command hedeflerini
      // siler; kilit ekranı kontrolleri her layer yıkımından sonra yeniden kurulur.
      self.reinstallRemoteCommands()
      },
      resumeDirectPlayback: { [weak self] content, at in
      guard let self, !self.isTornDown else { return }
      self.play(
        url: content.url,
        startSeconds: content.isLive || at < 2 ? nil : at,
        isLiveStream: content.isLive,
        userAgent: content.userAgent
      )
      },
      onTimeTick: { [weak self] seconds in
        self?.engine.updateSubtitleCue(at: seconds)
      }
    )
    // A controller taken from the cross-screen handoff is already presenting;
    // publish that state immediately instead of waiting for its next time tick.
    handleEngineChange()
  }

  private func handleEngineChange() {
    let established = engine.isPlaybackEstablished
    if established != lastEngineEstablished {
      lastEngineEstablished = established
      if established, pendingPreferredTrackSelection {
        pendingPreferredTrackSelection = false
        // If an imported subtitle is selected, the global subtitle preference must not override it.
        let importedSelected = restoreImportedSubtitles()
        updateTracks(applyPreferences: true, skipSubtitleSelection: importedSelected)
      }
    }
    let ready = engine.isReady
    if ready != lastEngineIsReady {
      lastEngineIsReady = ready
      if ready { tryFlushPendingLoad() }
    }
    let castPresenting = castController?.isPresenting ?? false
    let failure = castPresenting ? nil : engine.playbackFailureMessage
    if playbackFailureMessage != failure { playbackFailureMessage = failure }
    let ks = engine
    if isPiPActive != ks.isPiPActive { isPiPActive = ks.isPiPActive }
    if audioCodecName != ks.audioCodecName { audioCodecName = ks.audioCodecName }
    // Remux adaylığı: FFmpeg yolu + uyumlu codec'ler.
    let remuxCandidate = ks.isFFmpegBackendActive
      && !ks.videoCodecName.isEmpty
      && RemuxHLSWriter.isCompatible(
        videoFourCC: ks.videoCodecName,
        audioFourCC: ks.audioCodecName.isEmpty ? nil : ks.audioCodecName
      )
    let capable = castPresenting || ks.isAirPlayVideoCapable || remuxCandidate
    if isAirPlayVideoCapable != capable { isAirPlayVideoCapable = capable }
    let needsPrep = !castPresenting && !ks.isAirPlayVideoCapable && remuxCandidate
    if needsAirPlayPreparation != needsPrep { needsAirPlayPreparation = needsPrep }
    let airPlayActive = castPresenting
      ? (castController?.isExternalPlaybackActive ?? false)
      : ks.isExternalPlaybackActive
    if isAirPlayPlaybackActive != airPlayActive { isAirPlayPlaybackActive = airPlayActive }
    if isCastPresenting != castPresenting { isCastPresenting = castPresenting }
    syncFromEngine()
  }

  private func handleAudioSessionInterruption(_ note: Notification) {
    guard let info = note.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }
    switch type {
    case .began:
      // The session is already deactivated by the system; clear the flag so the
      // next setupAudioSession() call is not short-circuited.
      audioSessionActivated = false
      if isPlaying { routedPause() }
    case .ended:
      let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      setupAudioSession()
      if options.contains(.shouldResume), !isTornDown {
        routedPlay()
      }
    @unknown default:
      break
    }
  }

  // MARK: - Transport routing (engine ↔ cast)

  /// Cast oturumu sunumdayken transport cast player'a, aksi halde motora gider.
  private var castPresentingNow: Bool { castController?.isPresenting ?? false }

  private func routedPlay() {
    if let cast = castController, cast.isPresenting {
      cast.play()
    } else {
      engine.play()
    }
  }

  private func routedPause() {
    if let cast = castController, cast.isPresenting {
      cast.pause()
    } else {
      engine.pause()
    }
  }

  /// Mutlak (kaynak-zamanı) seek; uzaktan kumanda ve scrubber buradan geçer.
  func seekAbsolute(to seconds: TimeInterval) {
    markSeekRequestStart()
    if let cast = castController, cast.isPresenting {
      cast.seek(toSource: seconds)
    } else {
      engine.seek(to: seconds)
    }
  }

  /// Sunum kaynağı: cast oturumu aktifken cast, değilse motor. Tek anahtar noktası —
  /// aşağıdaki tüm @Published eşlemeleri bu anlık görüntüden beslenir.
  private struct PresentationSnapshot {
    var position: TimeInterval
    var duration: TimeInterval
    var isPaused: Bool
    var isBuffering: Bool
    var isCompleted: Bool
    var isSeekable: Bool
    var isEstablished: Bool
    var isReady: Bool
    var failureMessage: String?
    var rate: Double
  }

  private func presentationSnapshot() -> PresentationSnapshot {
    if let cast = castController, cast.isPresenting {
      return PresentationSnapshot(
        position: cast.position,
        duration: cast.duration,
        isPaused: cast.isPaused,
        isBuffering: cast.isBuffering,
        isCompleted: cast.isCompleted,
        isSeekable: cast.isSeekable,
        isEstablished: cast.isPlaybackEstablished,
        isReady: true,
        failureMessage: nil,
        rate: Double(rate)
      )
    }
    return PresentationSnapshot(
      position: engine.position,
      duration: engine.duration,
      isPaused: engine.isPaused,
      isBuffering: engine.isBuffering,
      isCompleted: engine.isCompleted,
      isSeekable: engine.isSeekable,
      isEstablished: engine.isPlaybackEstablished,
      isReady: engine.isReady,
      failureMessage: engine.playbackFailureMessage,
      rate: engine.playbackRate
    )
  }

  /// Her @Published atama `objectWillChange` fire eder — Swift @Published eşitlik kontrolü yapmaz.
  /// Tüm atamaları `if current != new` ile koru; aksi halde saniyede 8×22 = ~176 gereksiz SwiftUI invalidation olur.
  private func syncFromEngine() {
    let snapshot = presentationSnapshot()
    let pos = snapshot.position
    let dur = snapshot.duration
    let posMs = Int64((pos.isFinite ? pos : 0) * 1000)
    let durMs = Int64((dur.isFinite ? dur : 0) * 1000)
    if timeMs != posMs { timeMs = posMs }
    if durationMs != durMs { durationMs = durMs }

    let newPosition: Float
    if dur > 0, pos.isFinite {
      newPosition = Float(min(max(pos / dur, 0), 1))
    } else {
      newPosition = 0
    }
    if position != newPosition { position = newPosition }

    let failed = !(snapshot.failureMessage ?? "").isEmpty
    let newIsPlaying =
      !failed && snapshot.isEstablished && snapshot.isReady
      && !snapshot.isPaused && !snapshot.isCompleted
    if isPlaying != newIsPlaying { isPlaying = newIsPlaying }

    let newRate = Float(snapshot.rate)
    if rate != newRate { rate = newRate }

    if isSeekable != snapshot.isSeekable { isSeekable = snapshot.isSeekable }

    let newBuf: Float = snapshot.isBuffering ? 0.35 : 0
    if bufferingProgress != newBuf { bufferingProgress = newBuf }

    if videoWidth != engine.videoDisplayWidth { videoWidth = engine.videoDisplayWidth }
    if videoHeight != engine.videoDisplayHeight { videoHeight = engine.videoDisplayHeight }
    if streamFPS != engine.streamFPS { streamFPS = engine.streamFPS }
    if renderFPS != engine.renderFPS { renderFPS = engine.renderFPS }
    if videoBitrate != engine.videoBitrate { videoBitrate = engine.videoBitrate }
    if droppedFrameCount != engine.droppedFrameCount {
      droppedFrameCount = engine.droppedFrameCount
    }
    if delayedFrameCount != engine.delayedFrameCount {
      delayedFrameCount = engine.delayedFrameCount
    }
    if cacheBufferingState != engine.cacheBufferingState {
      cacheBufferingState = engine.cacheBufferingState
    }
    if cacheDurationSeconds != engine.cacheDurationSeconds {
      cacheDurationSeconds = engine.cacheDurationSeconds
    }
    let newAhead = max(engine.bufferTimelineEnd - (Double(timeMs) / 1000.0), 0)
    if cacheAheadSeconds != newAhead { cacheAheadSeconds = newAhead }
    if avSyncSeconds != engine.avSyncSeconds { avSyncSeconds = engine.avSyncSeconds }
    if networkSpeedBps != engine.networkSpeedBps { networkSpeedBps = engine.networkSpeedBps }
    let newHwdec = castPresentingNow ? "airplay-cast" : engine.hwdecCurrent
    if hwdecCurrent != newHwdec { hwdecCurrent = newHwdec }
    if videoCodecName != engine.videoCodecName { videoCodecName = engine.videoCodecName }

    updateSeekLatencyIfNeeded(currentTimeMs: timeMs)

    let newState: VideoPlayerState
    if failed {
      newState = .error
    } else if !snapshot.isReady {
      newState = .idle
    } else if snapshot.isCompleted {
      newState = .ended
    } else if snapshot.isBuffering {
      newState = .buffering
    } else if snapshot.isPaused {
      newState = .paused
    } else {
      newState = .playing
    }
    if state != newState { state = newState }

    applyIdleTimerPolicy()
    updateNowPlayingInfo()
  }

  /// Oynatma sırasında ekranın otomatik kapanmasını engeller; duraklatınca veya ekrandan çıkınca normale döner.
  private func applyIdleTimerPolicy() {
    let disableIdleTimer = isPlaying
    if Thread.isMainThread {
      UIApplication.shared.isIdleTimerDisabled = disableIdleTimer
    } else {
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = disableIdleTimer
      }
    }
  }

  private func tryFlushPendingLoad() {
    guard let request = pendingLoadRequest else { return }
    pendingLoadRequest = nil
    log.info("Loading URL into engine: \(request.url.absoluteString, privacy: .public)")
    engine.load(
      request.url,
      play: true,
      startSeconds: request.startSeconds,
      liveLowLatency: request.isLiveStream,
      userAgent: request.userAgent
    )
    // Yeni KSPlayerLayer kurulurken eskisinin deinit'i tüm remote-command
    // hedeflerini sildi; kilit ekranı kontrollerini geri kur.
    reinstallRemoteCommands()
    let saved = SubtitleAppearancePersistence.load()
    engine.applySubtitleAppearanceFromSettings(saved)
    engine.setSubDelay(seconds: saved.delaySeconds)
    engine.setAudioDelay(seconds: AudioDelayPersistence.load())
  }

  func setupAudioSession() {
    if audioSessionActivated { return }
    let lease = Self.claimAudioSessionLease()
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
      try session.setActive(true, options: [])
      audioSessionActivated = true
      audioSessionLease = lease.token
    } catch {
      Self.rollBackAudioSessionLease(lease.token, previous: lease.previous)
      log.error("AVAudioSession: \(error.localizedDescription)")
    }
  }

  func play(
    url: URL,
    startSeconds: TimeInterval? = nil,
    isLiveStream: Bool = false,
    userAgent: String? = nil
  ) {
    guard !isTornDown else { return }
    currentLoadRequest = PendingLoadRequest(
      url: url,
      startSeconds: startSeconds,
      isLiveStream: isLiveStream,
      userAgent: userAgent
    )
    // Cast oturumu aktifken (zap / auto-next) içerik cast hattından akar; motor
    // AÇILMAZ — panele ikinci bağlantı açmak bağlantı-limitli panellerde devir
    // hatalarının kök nedeniydi. Native-external oynatma sırasında FFmpeg'lik
    // içeriğe zap da doğrudan remux devriyle sürer. Üçüncü yol: önceki oynatıcı
    // ekranı cast ortasında kapandıysa (film kapat → canlı aç) CastController'ın
    // kendisi yeni ekrana devredilir; `cast.isEngaged` bu yolu doğrudan seçer.
    if let cast = castController {
      let nativeNext = !KSPlayerEngine.prefersFFmpegFirst(for: url)
      let overlapsNativeExternalPlayback =
        !cast.isEngaged && Self.hasNativeExternalPlayback(excluding: self)
      if overlapsNativeExternalPlayback {
        CastController.claimNativeExternalPlaybackFromActiveController()
      }
      let hasNativeExternalContinuation = overlapsNativeExternalPlayback
        || (!cast.isEngaged && CastController.takeNativeExternalPlaybackContinuation())
      let continueNativeExternalPlayback = hasNativeExternalContinuation
      let crossoverToRemux =
        engine.isExternalPlaybackActive
        && !nativeNext
      if cast.isEngaged || crossoverToRemux || continueNativeExternalPlayback {
        pendingPreferredTrackSelection = false
        setupAudioSession()
        // Motor durdurulmuş; altyazı modeli önceki içeriğin seçimini taşıyor.
        // Cast tikleri cue araması yapmaya devam ettiğinden yanlış içerik altyazısı
        // basılmasın diye seçim temizlenir.
        engine.selectSubtitleTrack(id: -1)
        let content = CastController.Content(
          url: url,
          isLive: isLiveStream,
          userAgent: userAgent,
          startAt: isLiveStream ? 0 : (startSeconds ?? 0),
          knownDuration: 0,
          nativelyPlayable: nativeNext
        )
        if cast.isEngaged {
          cast.playContent(content)
        } else if continueNativeExternalPlayback {
          cast.continueNativeExternalPlayback(with: content)
        } else {
          cast.startRemuxCast(content: content) { _ in }
        }
        return
      }
    }
    pendingPreferredTrackSelection = true
    setupAudioSession()
    pendingLoadRequest = currentLoadRequest
    tryFlushPendingLoad()
  }

  func setupAudioHandler() {
    setupAudioSession()
    setupRemoteCommands()
  }

  func setPlaybackPresentation(_ presentation: PlaybackPresentation) {
    playbackPresentation = presentation
    if isLiveStream != presentation.isLive {
      isLiveStream = presentation.isLive
    }
    scheduleNowPlayingArtworkFetch(for: presentation)
    updateNowPlayingInfo(force: true)
  }

  func togglePlayPause() {
    if isPlaying {
      routedPause()
    } else {
      routedPlay()
    }
  }

  func jump(seconds: Int) {
    if castPresentingNow {
      seekAbsolute(to: Double(timeMs) / 1000.0 + Double(seconds))
      return
    }
    markSeekRequestStart()
    engine.jumpRelative(seconds: seconds)
  }

  func seek(to pos: Float) {
    if castPresentingNow {
      let dur = Double(durationMs) / 1000.0
      guard dur > 0 else { return }
      seekAbsolute(to: dur * Double(min(max(pos, 0), 1)))
      return
    }
    markSeekRequestStart()
    engine.seekToFraction(pos)
  }

  func setRate(_ newRate: Float) {
    if let cast = castController, cast.isPresenting {
      cast.setRate(newRate)
    } else {
      engine.setPlaybackRate(Double(newRate))
    }
    rate = newRate
  }

  func setVolume(_ value: Double) {
    let clamped = min(max(value, 0), 125)
    if let cast = castController, cast.isPresenting {
      cast.setVolume(clamped)
    } else {
      engine.setVolume(clamped)
    }
  }

  /// `UIScreen` parlaklığı; ana iş parçacığında uygulanır.
  func setScreenBrightness(_ value: CGFloat) {
    let clamped = min(max(value, 0), 1)
    let apply = { [weak self] in
      guard let self else { return }
      if self.brightnessToRestore == nil {
        self.brightnessToRestore = UIScreen.main.brightness
      }
      UIScreen.main.brightness = clamped
      if self.screenBrightness != clamped { self.screenBrightness = clamped }
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  func setAspectMode(_ mode: VideoAspectMode, force: Bool = false) {
    if !force, aspectMode == mode { return }
    aspectMode = mode
  }

  func cycleAspectMode() {
    let all = VideoAspectMode.allCases
    guard let idx = all.firstIndex(of: aspectMode) else {
      setAspectMode(.bestFit)
      return
    }
    let next = all[(idx + 1) % all.count]
    setAspectMode(next)
  }

  func updateTracks(applyPreferences: Bool = false, skipSubtitleSelection: Bool = false) {
    engine.reloadTrackList { [weak self] video, audio, subs, vid, aid, sid in
      guard let self else { return }
      self.videoTracks = video
      self.audioTracks = audio
      self.subtitleTracks = subs
      self.currentVideoTrackId = vid
      self.currentAudioTrackId = aid
      self.currentSubtitleTrackId = sid
      guard applyPreferences else { return }
      let prefs = PlaybackTrackPreferences.load()
      if let pick = PlaybackTrackPreferences.pickVideo(from: video, prefs: prefs) {
        self.engine.selectVideoTrack(id: pick)
        self.currentVideoTrackId = pick
      }
      if let pick = PlaybackTrackPreferences.pickAudio(from: audio, prefs: prefs) {
        self.engine.selectAudioTrack(id: pick)
        self.currentAudioTrackId = pick
      }
      if !skipSubtitleSelection,
         let pick = PlaybackTrackPreferences.pickSubtitle(from: subs, prefs: prefs)
      {
        self.engine.selectSubtitleTrack(id: pick)
        self.currentSubtitleTrackId = pick
      }
    }
  }

  func selectVideoTrack(id: Int) {
    engine.selectVideoTrack(id: id)
    currentVideoTrackId = id
    if let opt = videoTracks.first(where: { $0.id == id }) {
      PlaybackTrackPreferences.saveVideo(from: opt)
    }
  }

  func selectAudioTrack(id: Int) {
    engine.selectAudioTrack(id: id)
    currentAudioTrackId = id
    if let opt = audioTracks.first(where: { $0.id == id }) {
      PlaybackTrackPreferences.saveAudio(from: opt)
    }
  }

  func selectSubtitleTrack(id: Int) {
    engine.selectSubtitleTrack(id: id)
    currentSubtitleTrackId = id
    if let opt = subtitleTracks.first(where: { $0.id == id }) {
      PlaybackTrackPreferences.saveSubtitle(from: opt)
      if let key = importedSubtitleContentKey {
        // Remember external track selection per content; picking embedded / off resets it.
        let importedName = opt.isExternal && importedFileNames.contains(opt.title) ? opt.title : nil
        ImportedSubtitleStore.setSelectedFileName(importedName, for: key)
      }
    }
  }

  // MARK: - Imported subtitles (issue #98)

  private var importedFileNames: Set<String> {
    Set(importedSubtitleFiles.map(\.lastPathComponent))
  }

  /// Identity of the playing content; set by PlayerView before every `play` call.
  func setImportedSubtitleContext(contentKey: String) {
    importedSubtitleContentKey = contentKey
    importedSubtitleFiles = ImportedSubtitleStore.subtitleFiles(for: contentKey)
  }

  /// Adds the stored files to mpv; returns whether the saved selection was applied.
  private func restoreImportedSubtitles() -> Bool {
    guard let key = importedSubtitleContentKey else { return false }
    let files = ImportedSubtitleStore.subtitleFiles(for: key)
    importedSubtitleFiles = files
    guard !files.isEmpty else { return false }
    let selectedName = ImportedSubtitleStore.selectedFileName(for: key)
    var didSelect = false
    for file in files {
      let name = file.lastPathComponent
      let select = name == selectedName
      didSelect = didSelect || select
      engine.addExternalSubtitle(filePath: file.path, title: name, select: select)
    }
    return didSelect
  }

  func importSubtitleFile(at pickedURL: URL) throws {
    guard let key = importedSubtitleContentKey else { return }
    let saved = try ImportedSubtitleStore.importFile(at: pickedURL, for: key)
    let name = saved.lastPathComponent
    // If a track with the same name was added before, drop the old one (file was overwritten).
    if let existing = subtitleTracks.first(where: { $0.isExternal && $0.title == name }) {
      engine.removeExternalSubtitle(id: existing.id)
    }
    ImportedSubtitleStore.setSelectedFileName(name, for: key)
    importedSubtitleFiles = ImportedSubtitleStore.subtitleFiles(for: key)
    engine.addExternalSubtitle(filePath: saved.path, title: name, select: true)
    updateTracks()
  }

  func deleteImportedSubtitle(_ url: URL) {
    guard let key = importedSubtitleContentKey else { return }
    let name = url.lastPathComponent
    ImportedSubtitleStore.removeFile(url, for: key)
    importedSubtitleFiles = ImportedSubtitleStore.subtitleFiles(for: key)
    if let existing = subtitleTracks.first(where: { $0.isExternal && $0.title == name }) {
      engine.removeExternalSubtitle(id: existing.id)
      updateTracks()
    }
  }

  func applySubtitleAppearanceSettings(_ settings: SubtitleAppearanceSettings) {
    SubtitleAppearancePersistence.save(settings)
    engine.applySubtitleAppearanceFromSettings(settings)
    engine.setSubDelay(seconds: settings.delaySeconds)
  }

  func applySubtitleDelaySeconds(_ seconds: Double) {
    engine.setSubDelay(seconds: seconds)
  }

  /// UHF akışı: remux'u kur, hazır olunca completion(true) — UI sistem seçiciyi o anda açar.
  func prepareAirPlay(completion: @escaping (Bool) -> Void) {
    guard let cast = castController else {
      completion(false)
      return
    }
    let ks = engine
    guard needsAirPlayPreparation else {
      completion(true)  // native yol ya da cast zaten sunumda — seçici direkt açılabilir
      return
    }
    guard let request = currentLoadRequest else {
      completion(false)
      return
    }
    // Resume edilmiş içerikte ilk zaman tiki henüz gelmediyse motor 0 raporlar;
    // istekteki başlangıç saniyesine düş (cast 0:00'dan başlamasın).
    let at: TimeInterval
    if ks.isPlaybackEstablished, ks.position > 0.5 {
      at = ks.position
    } else {
      at = request.startSeconds ?? 0
    }
    let content = CastController.Content(
      url: request.url,
      isLive: request.isLiveStream,
      userAgent: request.userAgent,
      startAt: request.isLiveStream ? 0 : at,
      knownDuration: ks.duration,
      nativelyPlayable: false,
      startPaused: ks.isPlaybackEstablished && ks.isPaused
    )
    cast.startRemuxCast(content: content, completion: completion)
  }

  func applyAudioDelaySeconds(_ seconds: Double) {
    AudioDelayPersistence.save(seconds)
    engine.setAudioDelay(seconds: seconds)
  }

  func teardown() {
    if isTornDown { return }
    isTornDown = true
    Self.unregister(self)
    seriesEpisodeOnPrevious = nil
    seriesEpisodeOnNext = nil
    MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = false
    MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = false
    let restoreBrightness = brightnessToRestore
    brightnessToRestore = nil
    let restoreSystemState = {
      UIApplication.shared.isIdleTimerDisabled = false
      if let restoreBrightness {
        UIScreen.main.brightness = restoreBrightness
      }
    }
    if Thread.isMainThread {
      restoreSystemState()
    } else {
      DispatchQueue.main.async(execute: restoreSystemState)
    }
    cancellables.removeAll()
    removeRemoteCommands()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    playbackPresentation = nil
    cancelNowPlayingArtworkFetch(clearImage: true)
    pendingLoadRequest = nil
    let wasActivated = audioSessionActivated
    let leaseToRelease = audioSessionLease
    audioSessionActivated = false
    audioSessionLease = nil
    if wasActivated, let leaseToRelease {
      // Non-mixable .playback oturumu açık bırakılırsa, oynatıcı kapandıktan sonra
      // kestiğimiz uygulama (Music/Spotify) hiçbir zaman devam sinyali alamaz.
      // mpv'nin audio unit'i async dispose olduğundan kısa bir gecikmeyle kapat.
      // A newer controller may claim the process-wide session during this delay;
      // the lease guard then turns this teardown into a no-op.
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
        Self.deactivateAudioSessionIfCurrent(leaseToRelease)
      }
    }
    seekRequestStartedAt = nil
    seekSourceTimeMs = nil
    seekLatencyMs = -1
    playbackFailureMessage = nil
    // Native AirPlay belongs to KSPlayer's screen-scoped AVPlayer. Capture the
    // selected route before disposing that engine so the next screen can promote
    // its item to the long-lived cast player instead of continuing audio-only.
    if castController?.isEngaged != true,
       engine.isExternalPlaybackActive || isAirPlayPlaybackActive {
      CastController.markNativeExternalPlaybackForNextLoad()
    }
    // Keep one external-playback AVPlayer alive while the user leaves a series
    // and opens a live channel. Recreating it here flaps the route and strands
    // the next FFmpeg stream as audio-only AirPlay.
    if castController?.parkForCrossScreenHandoff(owner: castOwnerToken) != true {
      castController?.dispose()
    }
    engine.dispose()
  }

  private func markSeekRequestStart() {
    seekRequestStartedAt = Date()
    seekSourceTimeMs = timeMs
    seekLatencyMs = -1
  }

  private func updateSeekLatencyIfNeeded(currentTimeMs: Int64) {
    guard seekLatencyMs < 0 else { return }
    guard let startedAt = seekRequestStartedAt, let sourceTimeMs = seekSourceTimeMs else { return }
    let shifted = abs(currentTimeMs - sourceTimeMs) >= 900
    let stalledTooLong = Date().timeIntervalSince(startedAt) >= 5.0
    guard shifted || stalledTooLong else { return }
    seekLatencyMs = max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)
    seekRequestStartedAt = nil
    seekSourceTimeMs = nil
  }

  // MARK: - Now Playing

  private var lastNowPlayingUpdate: TimeInterval = 0

  private func updateNowPlayingInfo(force: Bool = false) {
    guard let p = playbackPresentation else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if !force, now - lastNowPlayingUpdate < 0.8 { return }
    lastNowPlayingUpdate = now

    let durationSec = max(Double(durationMs) / 1000.0, 0)
    let elapsedSec = max(Double(timeMs) / 1000.0, 0)

    // On live channels with EPG, show the programme as the title and the channel
    // as the artist; otherwise the channel/content title.
    let displayTitle: String
    let displayArtist: String
    if p.isLive, let programme = p.programmeTitle, !programme.isEmpty {
      displayTitle = programme
      displayArtist = p.title
    } else {
      displayTitle = p.title
      displayArtist = p.subtitle ?? "Another IPTV Player"
    }

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: displayTitle,
      MPMediaItemPropertyArtist: displayArtist,
      MPMediaItemPropertyPlaybackDuration: durationSec,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSec,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if p.isLive {
      // Keep the system LIVE badge and no scrubber — do not synthesize a duration
      // from the programme interval (it would misrepresent the transport).
      info[MPNowPlayingInfoPropertyIsLiveStream] = true
      info[MPMediaItemPropertyPlaybackDuration] = 0
    }
    if let img = nowPlayingArtwork {
      // Sistem istenen boyutta tekrar çağırır; tek `UIImage` yeterli.
      let b = img.size
      let bounds = CGSize(width: max(b.width, 1), height: max(b.height, 1))
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: bounds) { _ in img }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func cancelNowPlayingArtworkFetch(clearImage: Bool) {
    artworkFetchTask?.cancel()
    artworkFetchTask = nil
    artworkFetchURL = nil
    if clearImage { nowPlayingArtwork = nil }
  }

  /// Now Playing yalnızca bitmap kabul eder (`MPMediaItemArtwork`); URL’yi biz indiriyoruz.
  private func scheduleNowPlayingArtworkFetch(for presentation: PlaybackPresentation) {
    guard let url = presentation.artworkURL else {
      cancelNowPlayingArtworkFetch(clearImage: true)
      return
    }
    if artworkFetchURL == url, nowPlayingArtwork != nil { return }
    if artworkFetchURL == url, artworkFetchTask != nil { return }

    cancelNowPlayingArtworkFetch(clearImage: true)
    artworkFetchURL = url

    let capturedURL = url
    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data, let image = UIImage(data: data) else {
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          if self.artworkFetchURL == capturedURL {
            self.nowPlayingArtwork = nil
            self.artworkFetchTask = nil
            self.artworkFetchURL = nil
            self.updateNowPlayingInfo(force: true)
          }
        }
        return
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.artworkFetchURL == capturedURL else { return }
        self.nowPlayingArtwork = image
        self.artworkFetchTask = nil
        self.updateNowPlayingInfo(force: true)
      }
    }
    artworkFetchTask = task
    task.resume()
  }

  private func setupRemoteCommands() {
    guard remoteCommandTargets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()

    center.playCommand.isEnabled = true
    let t1 = center.playCommand.addTarget { [weak self] _ in
      self?.routedPlay()
      return .success
    }
    remoteCommandTargets.append((center.playCommand, t1))

    center.pauseCommand.isEnabled = true
    let t2 = center.pauseCommand.addTarget { [weak self] _ in
      self?.routedPause()
      return .success
    }
    remoteCommandTargets.append((center.pauseCommand, t2))

    center.togglePlayPauseCommand.isEnabled = true
    let t3 = center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.togglePlayPause()
      return .success
    }
    remoteCommandTargets.append((center.togglePlayPauseCommand, t3))

    center.changePlaybackPositionCommand.isEnabled = true
    let tSeek = center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self,
            let e = event as? MPChangePlaybackPositionCommandEvent,
            self.durationMs > 0
      else { return .commandFailed }
      self.seekAbsolute(to: e.positionTime)
      return .success
    }
    remoteCommandTargets.append((center.changePlaybackPositionCommand, tSeek))

    center.skipForwardCommand.isEnabled = true
    center.skipForwardCommand.preferredIntervals = [15]
    let t4 = center.skipForwardCommand.addTarget { [weak self] _ in
      self?.jump(seconds: 15)
      return .success
    }
    remoteCommandTargets.append((center.skipForwardCommand, t4))

    center.skipBackwardCommand.isEnabled = true
    center.skipBackwardCommand.preferredIntervals = [15]
    let t5 = center.skipBackwardCommand.addTarget { [weak self] _ in
      self?.jump(seconds: -15)
      return .success
    }
    remoteCommandTargets.append((center.skipBackwardCommand, t5))

    center.previousTrackCommand.isEnabled = false
    let t6 = center.previousTrackCommand.addTarget { [weak self] _ in
      guard let cb = self?.seriesEpisodeOnPrevious else { return .commandFailed }
      cb()
      return .success
    }
    remoteCommandTargets.append((center.previousTrackCommand, t6))

    center.nextTrackCommand.isEnabled = false
    let t7 = center.nextTrackCommand.addTarget { [weak self] _ in
      guard let cb = self?.seriesEpisodeOnNext else { return .commandFailed }
      cb()
      return .success
    }
    remoteCommandTargets.append((center.nextTrackCommand, t7))
  }

  /// Kontrol Merkezi / kilit ekranından önceki–sonraki bölüm (yalnızca dizi oynatırken).
  /// - swapSkipForNav: true → skip komutları kapatılır, prev/next gösterilir (dizi & canlı TV).
  ///                   false → skip aktif kalır; filmler için her zaman false.
  func configureSeriesEpisodeSkipping(
    canPrevious: Bool,
    canNext: Bool,
    onPrevious: (() -> Void)?,
    onNext: (() -> Void)?,
    swapSkipForNav: Bool = true
  ) {
    seriesEpisodeOnPrevious = canPrevious ? onPrevious : nil
    seriesEpisodeOnNext = canNext ? onNext : nil
    episodeNavCanPrevious = canPrevious && onPrevious != nil
    episodeNavCanNext = canNext && onNext != nil
    episodeNavSwapSkip = swapSkipForNav
    applyEpisodeNavCommandEnablement()
  }

  private func applyEpisodeNavCommandEnablement() {
    let center = MPRemoteCommandCenter.shared()
    let hasEpisodeNav = episodeNavCanPrevious || episodeNavCanNext
    // iOS hides previousTrack/nextTrack buttons when skipForward/skipBackward are enabled.
    // For series & live TV: swap skip → prev/next. For movies: keep skip enabled.
    let disableSkip = episodeNavSwapSkip && hasEpisodeNav
    center.skipForwardCommand.isEnabled = !disableSkip
    center.skipBackwardCommand.isEnabled = !disableSkip
    center.previousTrackCommand.isEnabled = episodeNavSwapSkip && episodeNavCanPrevious
    center.nextTrackCommand.isEnabled = episodeNavSwapSkip && episodeNavCanNext
  }

  /// `KSPlayerLayer.deinit` koşulsuz `removeTarget(nil)` çağırır ve Now Playing'i
  /// siler — her layer yıkımından (yeni load, cast devri) sonra kendi komutlarımız
  /// ve Now Playing yeniden kurulmalı; aksi halde kilit ekranı ilk zap'tan sonra ölür.
  private func reinstallRemoteCommands() {
    guard !remoteCommandTargets.isEmpty else { return }
    removeRemoteCommands()
    setupRemoteCommands()
    applyEpisodeNavCommandEnablement()
    updateNowPlayingInfo(force: true)
  }

  private func removeRemoteCommands() {
    for (cmd, token) in remoteCommandTargets {
      cmd.removeTarget(token)
    }
    remoteCommandTargets.removeAll()
  }
}
