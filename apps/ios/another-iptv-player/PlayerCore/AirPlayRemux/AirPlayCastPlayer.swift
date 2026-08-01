import AVFoundation
import Foundation
import UIKit

/// Thin AVPlayer wrapper that plays cast content (remuxed local HLS, or natively
/// playable source URLs) with external playback enabled. KSAVPlayer is deliberately
/// NOT used here: its synchronous track-playability check at readyToPlay races on
/// HLS and failed instantly with "VideoTracks are not even playable".
///
/// The player instance is long-lived: one AVPlayer per cast engagement, with
/// `load(url:)` swapping AVPlayerItems. Tearing down an external-playback AVPlayer
/// flaps the AirPlay route, so content changes must never recreate the player.
final class AirPlayCastPlayer: NSObject {
  final class View: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  }

  let view = View()
  private let player = AVPlayer()
  private var item: AVPlayerItem?
  private var timeObserver: Any?
  private var playerObservations: [NSKeyValueObservation] = []
  private var itemObservation: NSKeyValueObservation?
  private var reportedError = false
  /// When the current item is a remux stream carrying an HLS WebVTT subtitle rendition,
  /// enable it (so it shows on the AirPlay target) once the item is ready. Cleared after
  /// the first selection so a later status change doesn't re-trigger it.
  private var selectLegibleOnReady = false

  var onTime: ((TimeInterval) -> Void)?
  var onStateChange: (() -> Void)?
  var onError: ((Error) -> Void)?
  /// Item reached its end (played up to ENDLIST) — drives "completed" state.
  var onEnded: (() -> Void)?

  var currentTime: TimeInterval {
    let t = player.currentTime().seconds
    return t.isFinite ? max(t, 0) : 0
  }

  /// Duration of the range written so far on a growing event playlist.
  var duration: TimeInterval {
    let d = item?.duration.seconds ?? 0
    return d.isFinite ? max(d, 0) : 0
  }

  /// Seekable window of a live(-looking) stream. `duration` can be indefinite on
  /// a growing playlist; in-window seek decisions use this instead.
  var seekableRange: (start: TimeInterval, end: TimeInterval) {
    var minStart = TimeInterval.greatestFiniteMagnitude
    var maxEnd: TimeInterval = 0
    for value in item?.seekableTimeRanges ?? [] {
      let range = value.timeRangeValue
      let start = range.start.seconds
      let end = range.end.seconds
      if start.isFinite { minStart = min(minStart, start) }
      if end.isFinite { maxEnd = max(maxEnd, end) }
    }
    return (minStart == .greatestFiniteMagnitude ? 0 : minStart, maxEnd)
  }

  var isPaused: Bool { player.rate == 0 }
  var isBuffering: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
  var isReadyToPlay: Bool { item?.status == .readyToPlay }
  var isExternalPlaybackActive: Bool { player.isExternalPlaybackActive }

  override init() {
    super.init()
    player.allowsExternalPlayback = true
    player.usesExternalPlaybackWhileExternalScreenIsActive = true
    view.playerLayer.player = player
    view.playerLayer.videoGravity = .resizeAspect

    playerObservations.append(player.observe(\.timeControlStatus) { [weak self] _, _ in
      DispatchQueue.main.async { self?.onStateChange?() }
    })
    playerObservations.append(player.observe(\.isExternalPlaybackActive) { [weak self] _, _ in
      DispatchQueue.main.async { self?.onStateChange?() }
    })
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 4), queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.onTime?(self.currentTime)
    }
  }

  /// Swaps the current item for a new URL. The AVPlayer (and with it the active
  /// AirPlay route) stays alive across loads.
  func load(url: URL, startAt: TimeInterval?, autoPlay: Bool, preferredLegible: Bool = false) {
    if let item {
      NotificationCenter.default.removeObserver(
        self, name: .AVPlayerItemDidPlayToEndTime, object: item
      )
    }
    itemObservation = nil
    reportedError = false
    selectLegibleOnReady = preferredLegible
    let newItem = AVPlayerItem(asset: AVURLAsset(url: url))
    item = newItem
    itemObservation = newItem.observe(\.status) { [weak self] observedItem, _ in
      DispatchQueue.main.async {
        guard let self, self.item === observedItem else { return }
        if observedItem.status == .failed, !self.reportedError {
          self.reportedError = true
          self.onError?(
            observedItem.error
              ?? NSError(
                domain: "AirPlayCastPlayer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "cast item failed"]
              ))
        } else {
          if observedItem.status == .readyToPlay, self.selectLegibleOnReady {
            self.selectLegibleOnReady = false
            self.enableFirstLegibleOption(on: observedItem)
          }
          self.onStateChange?()
        }
      }
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(itemDidPlayToEnd(_:)),
      name: .AVPlayerItemDidPlayToEndTime, object: newItem
    )
    player.replaceCurrentItem(with: newItem)
    if let startAt, startAt > 0.5 {
      player.seek(
        to: CMTime(seconds: startAt, preferredTimescale: 600),
        toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity
      )
    }
    if autoPlay { player.play() }
  }

  /// Turn on the (single) WebVTT subtitle rendition we added to the remux master, so it
  /// renders on the AirPlay target. Only called when we authored that rendition, so the
  /// first legible option is ours; a no-op if the group is absent (e.g. fMP4 skipped it).
  private func enableFirstLegibleOption(on item: AVPlayerItem) {
    let asset = item.asset
    Task { @MainActor in
      guard let group = try? await asset.loadMediaSelectionGroup(for: .legible),
            let option = group.options.first,
            self.item === item
      else { return }
      item.select(option, in: group)
    }
  }

  @objc private func itemDidPlayToEnd(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let item = self.item,
            (notification.object as? AVPlayerItem) === item
      else { return }
      self.onEnded?()
    }
  }

  func play() { player.play() }
  func pause() { player.pause() }

  func seek(to seconds: TimeInterval, completion: ((Bool) -> Void)? = nil) {
    player.seek(
      to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600),
      toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
      toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
    ) { finished in
      completion?(finished)
    }
  }

  /// Rate changes only apply while playing; a rate set while paused must not
  /// resume playback (long-press 2x while paused used to un-pause the cast).
  func setRate(_ rate: Float) {
    if rate <= 0 {
      player.pause()
    } else if player.rate > 0 {
      player.rate = rate
    }
  }

  func setVolume(_ value: Float) {
    player.volume = min(max(value, 0), 1)
  }

  func dispose() {
    NotificationCenter.default.removeObserver(self)
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    playerObservations.removeAll()
    itemObservation = nil
    onTime = nil
    onStateChange = nil
    onError = nil
    onEnded = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    item = nil
    view.playerLayer.player = nil
  }
}
