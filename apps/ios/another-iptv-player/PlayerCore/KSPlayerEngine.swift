import AVFoundation
import Combine
import Foundation
import KSPlayer
import UIKit

/// Playback engine over `KSPlayerLayer` (KSAVPlayer with KSMEPlayer fallback).
/// Only the core of KSPlayer is used — video view + delegate callbacks; all UI stays ours.
///
/// This class knows NOTHING about AirPlay casting. The cast lifecycle (remux
/// session, cast player, route observation) lives in `CastController`, owned by
/// `VideoPlayerController`; the engine is simply stopped while a cast engagement
/// is active and reloaded when it ends.
final class KSPlayerEngine: NSObject, ObservableObject {
  @Published private(set) var isReady = false
  @Published private(set) var isPaused = true
  @Published private(set) var isSeekable = false
  @Published private(set) var isBuffering = false
  @Published private(set) var isCompleted = false
  @Published private(set) var isPlaybackEstablished = false
  @Published private(set) var playbackFailureMessage: String?
  @Published private(set) var position: TimeInterval = 0
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var playbackRate: Double = 1
  @Published private(set) var bufferTimelineEnd: TimeInterval = 0

  @Published private(set) var videoDisplayWidth: Int = 0
  @Published private(set) var videoDisplayHeight: Int = 0
  @Published private(set) var streamFPS: Double = 0
  @Published private(set) var renderFPS: Double = 0
  @Published private(set) var videoBitrate: Double = 0
  @Published private(set) var droppedFrameCount: Int64 = 0
  @Published private(set) var delayedFrameCount: Int64 = 0
  @Published private(set) var cacheBufferingState: Double = 0
  @Published private(set) var cacheDurationSeconds: Double = 0
  @Published private(set) var avSyncSeconds: Double = 0
  @Published private(set) var networkSpeedBps: Double = 0
  @Published private(set) var hwdecCurrent: String = ""
  @Published private(set) var videoCodecName: String = ""

  /// Bumped whenever `videoView` may point to a new UIView (engine fallback swaps the
  /// player instance); the SwiftUI surface remounts on change.
  @Published private(set) var surfaceRevision = 0
  /// Gerçek AirPlay (external playback) yalnız AVPlayer motorunda mümkün; FFmpeg
  /// yolundaki remux adaylığını `VideoPlayerController` hesaplar.
  @Published private(set) var isAirPlayVideoCapable = false
  /// Aktif oynatıcı KSMEPlayer (FFmpeg yolu) mu? Remux adaylığının bir bileşeni.
  @Published private(set) var isFFmpegBackendActive = false
  /// Debug overlay teşhisi + remux adaylığı için aktif ses codec'i.
  @Published private(set) var audioCodecName: String = ""
  /// Current subtitle cue for the overlay (nil = hide).
  @Published private(set) var subtitleText: NSAttributedString?
  @Published private(set) var subtitleImage: UIImage?
  @Published private(set) var subtitleAppearance = SubtitleAppearancePersistence.load()
  @Published private(set) var isPiPActive = false

  var changePublisher: AnyPublisher<Void, Never> {
    objectWillChange.eraseToAnyPublisher()
  }

  var videoView: UIView? { layer?.player.view }
  var isExternalPlaybackActive: Bool { layer?.player.isExternalPlaybackActive ?? false }

  private(set) var layer: KSPlayerLayer?
  private let subtitleModel = SubtitleModel()
  /// Reported subtitle track id → info. Ids are stable per load (insertion order).
  private var subtitleInfosById: [Int: any SubtitleInfo] = [:]
  private var removedSubtitleIDs: Set<String> = []
  private var externalSubtitleIDs: Set<String> = []
  private var embeddedSubtitleSourceAttached = false
  private var pendingAudioDelay: Double = 0
  private var loadTimeoutWorkItem: DispatchWorkItem?
  private var lastPositionPublish: TimeInterval = 0
  private var isDisposed = false

  // MARK: - Load

  func load(
    _ url: URL,
    play: Bool,
    startSeconds: TimeInterval?,
    liveLowLatency: Bool,
    userAgent: String?
  ) {
    guard !isDisposed else { return }
    resetForNewLoad()
    subtitleModel.url = url
    // Motor sırası içerik türünden seçilir. AVPlayer'ın oynatamayacağı kaplarda
    // (mkv/avi/ts/uzantısız canlı TS) önce AVPlayer'ı deneyip başarısızlığını beklemek
    // açılışı saniyelerce uzatıyordu; doğrudan FFmpeg ile başla.
    if Self.prefersFFmpegFirst(for: url) {
      KSOptions.firstPlayerType = KSMEPlayer.self
      KSOptions.secondPlayerType = KSAVPlayer.self
    } else {
      KSOptions.firstPlayerType = KSAVPlayer.self
      KSOptions.secondPlayerType = KSMEPlayer.self
    }
    let options = Self.makeOptions(
      liveLowLatency: liveLowLatency,
      startSeconds: startSeconds,
      userAgent: userAgent
    )
    // Layer her yüklemede sıfırdan kurulur. `layer.set(url:)` yolu KULLANILMAZ:
    // KSPlayerLayer.url.didSet, herhangi bir kablosuz rota aktifken bizim motor
    // seçimimizi ezip KSAVPlayer'ı zorluyor (mkv/ts'te uzun başarısızlık + fallback
    // beklemesi — "içerik açılmıyor" şikayetinin ikinci kök nedeni). init yolu
    // statiklere sadık kalır.
    if let oldLayer = layer {
      oldLayer.delegate = nil
      oldLayer.stop()
    }
    layer = KSPlayerLayer(url: url, isAutoPlay: play, options: options, delegate: self)
    bumpSurfaceRevision()
    isReady = true
    scheduleLoadTimeoutWatchdog()
  }

  /// Non-terminal stop: releases the layer (and its source connection) but keeps
  /// the engine reusable. Used when a cast engagement takes over playback.
  /// NOTE: `KSPlayerLayer.deinit` calls `MPRemoteCommandCenter removeTarget(nil)`
  /// unconditionally — the owner must reinstall its remote commands after this.
  func stopPlayback() {
    guard !isDisposed else { return }
    cancelLoadTimeoutWatchdog()
    layer?.delegate = nil
    layer?.stop()
    layer = nil
    if !isBuffering { isBuffering = true }
  }

  private func resetForNewLoad() {
    cancelLoadTimeoutWatchdog()
    playbackFailureMessage = nil
    isPlaybackEstablished = false
    isCompleted = false
    isBuffering = true
    isPaused = true
    isSeekable = false
    position = 0
    duration = 0
    bufferTimelineEnd = 0
    subtitleText = nil
    subtitleImage = nil
    subtitleInfosById = [:]
    removedSubtitleIDs = []
    externalSubtitleIDs = []
    embeddedSubtitleSourceAttached = false
    // Codec/capability diagnostics belong to the previous content; a stale value
    // must not gate AirPlay/remux candidacy for the next one.
    videoCodecName = ""
    audioCodecName = ""
    isFFmpegBackendActive = false
    isAirPlayVideoCapable = false
  }

  /// AVPlayer'ın native oynatabildiği uzantılar; geri kalan her şey (mkv, avi, ts,
  /// uzantısız Xtream canlı) FFmpeg'e gider. mpv dönemindeki davranışla birebir —
  /// yalnızca HLS/mp4 ailesi AVPlayer'a (ve gerçek AirPlay'e) çıkar.
  private static let avPlayerExtensions: Set<String> = [
    "m3u8", "mp4", "m4v", "mov", "mp3", "m4a", "aac",
  ]

  static func prefersFFmpegFirst(for url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return !avPlayerExtensions.contains(ext)
  }

  private static func makeOptions(
    liveLowLatency: Bool,
    startSeconds: TimeInterval?,
    userAgent: String?
  ) -> KSOptions {
    let options = KSOptions()
    if let userAgent, !userAgent.isEmpty {
      options.userAgent = userAgent
    }
    if let startSeconds, startSeconds > 0 {
      options.startPlayTime = startSeconds
    }
    // isSecondOpen: yarım buffer dolunca oynatmaya başla — açılış süresini kısaltır.
    options.isSecondOpen = true
    if liveLowLatency {
      options.preferredForwardBufferDuration = 2
      options.maxBufferDuration = 16
    } else {
      options.preferredForwardBufferDuration = 3
      options.maxBufferDuration = 60
    }
    // Remote commands are ours (VideoPlayerController). KSPlayerLayer's own
    // registration would double-handle events; its deinit still wipes all
    // targets regardless of this flag, which the controller compensates for.
    options.registerRemoteControll = false
    let defaults = UserDefaults.standard
    let pipEnabled = defaults.object(forKey: "player.pipEnabled") as? Bool ?? true
    let backgroundEnabled =
      defaults.object(forKey: "player.continuePlayingInBackground") as? Bool ?? true
    options.canStartPictureInPictureAutomaticallyFromInline = pipEnabled && backgroundEnabled
    // KSPlayerLayer arka plan geçişini kendisi yönetir (PiP aktifse dokunmaz):
    // true → video decode durur ses sürer; false → pause.
    KSOptions.canBackgroundPlay = backgroundEnabled
    return options
  }

  // MARK: - Transport

  func play() {
    if isCompleted {
      layer?.seek(time: 0, autoPlay: true) { _ in }
      isCompleted = false
      return
    }
    layer?.play()
  }

  func pause() {
    layer?.pause()
  }

  func seek(to seconds: TimeInterval) {
    let target = max(seconds, 0)
    layer?.seek(time: target, autoPlay: !isPaused) { _ in }
  }

  func seekToFraction(_ pos: Float) {
    guard duration > 0 else { return }
    seek(to: duration * Double(min(max(pos, 0), 1)))
  }

  func jumpRelative(seconds: Int) {
    seek(to: position + Double(seconds))
  }

  func setVolume(_ value: Double) {
    layer?.player.playbackVolume = Float(min(max(value, 0), 125) / 100)
  }

  func setPlaybackRate(_ value: Double) {
    layer?.player.playbackRate = Float(value)
    if playbackRate != value { playbackRate = value }
  }

  /// Backgrounded without PiP: stop video decode, keep audio (KSPlayer built-in path).
  func setVideoDecodingSuspended(_ suspended: Bool) {
    guard let player = layer?.player else { return }
    if suspended {
      player.enterBackground()
    } else {
      player.enterForeground()
    }
  }

  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    cancelLoadTimeoutWatchdog()
    layer?.stop()
    layer = nil
  }

  // MARK: - PiP

  func setPictureInPictureActive(_ active: Bool) {
    layer?.isPipActive = active
    refreshPiPState()
  }

  func togglePictureInPicture() {
    setPictureInPictureActive(!(layer?.isPipActive ?? false))
  }

  private func refreshPiPState() {
    let active = layer?.isPipActive ?? false
    if isPiPActive != active { isPiPActive = active }
  }

  // MARK: - Tracks

  func reloadTrackList(
    completion: @escaping (
      [TrackMenuOption], [TrackMenuOption], [TrackMenuOption], Int, Int, Int
    ) -> Void
  ) {
    guard let player = layer?.player else {
      completion([], [], [TrackMenuOption(id: -1, title: L("player.subtitle_off"))], -1, -1, -1)
      return
    }
    attachEmbeddedSubtitleSourceIfNeeded()

    let videoTracks = player.tracks(mediaType: .video)
    let audioTracks = player.tracks(mediaType: .audio)

    let video = videoTracks.map { Self.menuOption(for: $0) }
    let audio = audioTracks.map { Self.menuOption(for: $0) }

    var subs: [TrackMenuOption] = [TrackMenuOption(id: -1, title: L("player.subtitle_off"))]
    subtitleInfosById = [:]
    var nextId = 0
    var currentSubId = -1
    for info in subtitleModel.subtitleInfos {
      if removedSubtitleIDs.contains(info.subtitleID) { continue }
      let id = nextId
      nextId += 1
      subtitleInfosById[id] = info
      subs.append(
        TrackMenuOption(
          id: id,
          title: info.name,
          isExternal: externalSubtitleIDs.contains(info.subtitleID)
        )
      )
      if subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID {
        currentSubId = id
      }
    }

    let currentVideo = videoTracks.first { $0.isEnabled }.map { Int($0.trackID) } ?? -1
    let currentAudio = audioTracks.first { $0.isEnabled }.map { Int($0.trackID) } ?? -1
    completion(video, audio, subs, currentVideo, currentAudio, currentSubId)
  }

  private static func menuOption(for track: MediaPlayerTrack) -> TrackMenuOption {
    let name = track.name.trimmingCharacters(in: .whitespaces)
    // FFmpeg often reports no title; "Track N" style fallbacks must not be stored
    // as a preference (see TrackMenuOption.isSyntheticTitle).
    let synthetic = name.isEmpty
    var detailParts: [String] = []
    if track.mediaType == .video {
      let size = track.formatDescription.map { CMVideoFormatDescriptionGetDimensions($0) }
      if let size, size.width > 0 {
        detailParts.append("\(size.width)×\(size.height)")
      }
    }
    if track.bitRate > 0 {
      detailParts.append("\(track.bitRate / 1000) kbps")
    }
    return TrackMenuOption(
      id: Int(track.trackID),
      title: synthetic ? L("player.tracks.fallback_title", Int(track.trackID)) : name,
      detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
      langCode: track.languageCode,
      isSyntheticTitle: synthetic
    )
  }

  func selectVideoTrack(id: Int) {
    guard let player = layer?.player,
          let track = player.tracks(mediaType: .video).first(where: { Int($0.trackID) == id })
    else { return }
    player.select(track: track)
  }

  func selectAudioTrack(id: Int) {
    guard let player = layer?.player,
          let track = player.tracks(mediaType: .audio).first(where: { Int($0.trackID) == id })
    else { return }
    player.select(track: track)
    applyAudioDelayToSelectedTrack()
  }

  func selectSubtitleTrack(id: Int) {
    if id < 0 {
      subtitleModel.selectedSubtitleInfo = nil
      subtitleText = nil
      subtitleImage = nil
      return
    }
    guard let info = subtitleInfosById[id] else { return }
    subtitleModel.selectedSubtitleInfo = info
  }

  // MARK: - Subtitles

  private func attachEmbeddedSubtitleSourceIfNeeded() {
    guard !embeddedSubtitleSourceAttached,
          let dataSource = layer?.player.subtitleDataSouce
    else { return }
    embeddedSubtitleSourceAttached = true
    subtitleModel.addSubtitle(dataSouce: dataSource)
  }

  func addExternalSubtitle(filePath: String, title: String, select: Bool) {
    let url = URL(fileURLWithPath: filePath)
    let info = URLSubtitleInfo(subtitleID: url.absoluteString, name: title, url: url)
    removedSubtitleIDs.remove(info.subtitleID)
    externalSubtitleIDs.insert(info.subtitleID)
    subtitleModel.addSubtitle(info: info)
    if select {
      subtitleModel.selectedSubtitleInfo = info
    }
  }

  func removeExternalSubtitle(id: Int) {
    guard let info = subtitleInfosById[id] else { return }
    // SubtitleModel has no removal API; hide the entry and drop the selection.
    removedSubtitleIDs.insert(info.subtitleID)
    if subtitleModel.selectedSubtitleInfo?.subtitleID == info.subtitleID {
      subtitleModel.selectedSubtitleInfo = nil
      subtitleText = nil
      subtitleImage = nil
    }
  }

  func setSubDelay(seconds: Double) {
    subtitleModel.subtitleDelay = seconds
  }

  func setAudioDelay(seconds: Double) {
    pendingAudioDelay = seconds
    applyAudioDelayToSelectedTrack()
  }

  /// KSMEPlayer only: FFmpeg audio tracks expose a per-track delay. The AVPlayer
  /// path has no equivalent — the setting is a silent no-op there.
  private func applyAudioDelayToSelectedTrack() {
    guard let player = layer?.player else { return }
    for track in player.tracks(mediaType: .audio) {
      if let ffTrack = track as? FFmpegAssetTrack, track.isEnabled {
        ffTrack.delay = pendingAudioDelay
      }
    }
  }

  func applySubtitleAppearanceFromSettings(_ settings: SubtitleAppearanceSettings) {
    subtitleAppearance = settings
    setSubDelay(seconds: settings.delaySeconds)
  }

  /// Drives the subtitle overlay from an external clock — used while a cast
  /// engagement is presenting (the layer is stopped, but external SRT subtitles
  /// can still be rendered over the cast placeholder).
  func updateSubtitleCue(at seconds: TimeInterval) {
    guard !isDisposed else { return }
    if subtitleModel.subtitle(currentTime: seconds) {
      let part = subtitleModel.parts.first
      subtitleText = part?.text
      subtitleImage = part?.image
    }
  }

  // MARK: - Watchdog

  private func scheduleLoadTimeoutWatchdog() {
    cancelLoadTimeoutWatchdog()
    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.isDisposed else { return }
      if !self.isPlaybackEstablished, self.playbackFailureMessage == nil {
        self.playbackFailureMessage = L("playback.error.timeout")
      }
    }
    loadTimeoutWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 16, execute: item)
  }

  private func cancelLoadTimeoutWatchdog() {
    loadTimeoutWorkItem?.cancel()
    loadTimeoutWorkItem = nil
  }

  private func bumpSurfaceRevision() {
    surfaceRevision += 1
  }

  private func refreshDiagnostics() {
    guard let player = layer?.player else { return }
    let size = player.naturalSize
    let w = Int(size.width)
    let h = Int(size.height)
    if videoDisplayWidth != w { videoDisplayWidth = w }
    if videoDisplayHeight != h { videoDisplayHeight = h }
    let fps = Double(player.nominalFrameRate)
    if streamFPS != fps { streamFPS = fps }
    if let info = player.dynamicInfo {
      if renderFPS != info.displayFPS { renderFPS = info.displayFPS }
      let dropped = Int64(info.droppedVideoFrameCount)
      if droppedFrameCount != dropped { droppedFrameCount = dropped }
      if avSyncSeconds != info.audioVideoSyncDiff { avSyncSeconds = info.audioVideoSyncDiff }
      let bitrate = Double(info.videoBitrate)
      if videoBitrate != bitrate { videoBitrate = bitrate }
    }
    if let track = player.tracks(mediaType: .video).first(where: { $0.isEnabled }) {
      let codec = Self.codecName(of: track)
      if !codec.isEmpty, videoCodecName != codec { videoCodecName = codec }
    }
    if let track = player.tracks(mediaType: .audio).first(where: { $0.isEnabled }) {
      let codec = Self.codecName(of: track)
      if !codec.isEmpty, audioCodecName != codec { audioCodecName = codec }
    }
    let isAVPlayer = !(player is KSMEPlayer)
    let ffmpegActive = !isAVPlayer
    if isFFmpegBackendActive != ffmpegActive { isFFmpegBackendActive = ffmpegActive }
    let engineName = isAVPlayer ? "avplayer" : "ffmpeg"
    if hwdecCurrent != engineName { hwdecCurrent = engineName }
    // AVPlayer yolunda native external playback mümkün; FFmpeg yolundaki remux
    // adaylığını controller hesaplar.
    if isAirPlayVideoCapable != isAVPlayer { isAirPlayVideoCapable = isAVPlayer }
  }

  /// FFmpeg track'lerinde `codecName` her zaman dolu ama profil ekli gelir ("h264 (High)");
  /// formatDescription canlı TS'te extradata gelene kadar nil kalabilir — tespit codecName'in
  /// normalize edilmiş ilk kelimesine dayanır.
  private static func codecName(of track: MediaPlayerTrack) -> String {
    if let ffTrack = track as? FFmpegAssetTrack, !ffTrack.codecName.isEmpty {
      return RemuxHLSWriter.normalizeCodec(ffTrack.codecName)
    }
    guard let desc = track.formatDescription else { return "" }
    let code = CMFormatDescriptionGetMediaSubType(desc)
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
      UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
    ]
    return (String(bytes: bytes, encoding: .ascii) ?? "")
      .trimmingCharacters(in: .whitespaces).lowercased()
  }
}

// MARK: - KSPlayerLayerDelegate

extension KSPlayerEngine: KSPlayerLayerDelegate {
  func player(layer: KSPlayerLayer, state: KSPlayerState) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isDisposed, layer === self.layer else { return }
      switch state {
      case .initialized, .preparing:
        if !self.isBuffering { self.isBuffering = true }
      case .readyToPlay:
        self.cancelLoadTimeoutWatchdog()
        if !self.isPlaybackEstablished { self.isPlaybackEstablished = true }
        if self.isBuffering { self.isBuffering = false }
        self.isSeekable = layer.player.seekable
        // AVPlayer path: true AirPlay external playback.
        layer.player.allowsExternalPlayback = true
        self.applyAudioDelayToSelectedTrack()
        self.attachEmbeddedSubtitleSourceIfNeeded()
        self.bumpSurfaceRevision()
      case .buffering:
        if !self.isBuffering { self.isBuffering = true }
      case .bufferFinished:
        if self.isBuffering { self.isBuffering = false }
        if self.isPaused != !layer.player.isPlaying {
          self.isPaused = !layer.player.isPlaying
        }
      case .paused:
        if !self.isPaused { self.isPaused = true }
      case .playedToTheEnd:
        if !self.isCompleted { self.isCompleted = true }
        if !self.isPaused { self.isPaused = true }
      case .error:
        break  // message arrives via finish(error:)
      }
      if state == .bufferFinished || state == .readyToPlay {
        let playing = layer.player.isPlaying
        if self.isPaused == playing { self.isPaused = !playing }
      }
      self.refreshPiPState()
      self.refreshDiagnostics()
    }
  }

  func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isDisposed, layer === self.layer else { return }
      let now = CFAbsoluteTimeGetCurrent()
      // mpv motorundaki 0.12s pozisyon throttle'ının karşılığı.
      if now - self.lastPositionPublish >= 0.12 {
        self.lastPositionPublish = now
        if self.position != currentTime { self.position = currentTime }
        let total = totalTime.isFinite ? max(totalTime, 0) : 0
        if self.duration != total { self.duration = total }
        let playable = layer.player.playableTime
        if playable.isFinite, self.bufferTimelineEnd != playable {
          self.bufferTimelineEnd = playable
          self.cacheDurationSeconds = max(playable - currentTime, 0)
        }
        self.refreshDiagnostics()
      }
      if self.subtitleModel.subtitle(currentTime: currentTime) {
        let part = self.subtitleModel.parts.first
        self.subtitleText = part?.text
        self.subtitleImage = part?.image
      }
    }
  }

  func player(layer: KSPlayerLayer, finish error: Error?) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isDisposed, layer === self.layer else { return }
      self.cancelLoadTimeoutWatchdog()
      if let error {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
          switch ns.code {
          case NSURLErrorTimedOut:
            self.playbackFailureMessage = L("playback.error.timeout")
          case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
               NSURLErrorNotConnectedToInternet:
            self.playbackFailureMessage = L("playback.error.cannot_reach")
          default:
            self.playbackFailureMessage = L("playback.error.failed_check_network")
          }
        } else {
          self.playbackFailureMessage = L("playback.error.failed_check_network")
        }
      } else {
        self.isCompleted = true
        self.isPaused = true
      }
    }
  }

  func player(layer _: KSPlayerLayer, bufferedCount _: Int, consumeTime _: TimeInterval) {}
}
