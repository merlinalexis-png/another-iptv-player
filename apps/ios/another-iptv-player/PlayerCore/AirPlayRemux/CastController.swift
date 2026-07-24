import AVFoundation
import Combine
import Foundation
import UIKit

/// Source-time bookkeeping for a remux cast. The local HLS timeline starts at 0,
/// which corresponds to `offset` seconds inside the source content.
struct RemuxTimeline: Equatable {
  var offset: TimeInterval
  /// Duration of the source content when known (0 = unknown).
  var knownDuration: TimeInterval

  func sourceTime(fromLocal local: TimeInterval) -> TimeInterval {
    offset + local
  }

  func localTarget(forSource target: TimeInterval) -> TimeInterval {
    max(target - offset, 0)
  }

  /// Total duration to present: the real source duration when known, otherwise
  /// the growing written range (offset + local player duration).
  func totalDuration(localPlayerDuration: TimeInterval) -> TimeInterval {
    knownDuration > 0 ? knownDuration : offset + localPlayerDuration
  }
}

/// App-level AirPlay cast orchestrator. Owns the whole cast lifecycle — remux
/// session, cast player, route observation — as one explicit state machine.
/// The playback engine knows nothing about casting: it is stopped when a cast
/// engagement starts and reloaded (via `resumeDirectPlayback`) when it ends.
///
/// Invariants (each one was a field-fragility root cause before this existed):
/// - Single connection: while an engagement exists only the remux writer (or the
///   cast player, for natively playable URLs) touches the source URL; content
///   changes never warm up the phone-side player first.
/// - One AVPlayer per engagement: content changes swap the player item, never the
///   player, so the AirPlay route is not torn down and re-acquired on every zap.
/// - Single exit path: every failure/disconnect funnels through `endCasting`,
///   which always resumes direct playback — there is no state in which neither
///   the engine nor the cast player exists.
/// - No ambient triggers: casting starts only from the AirPlay button or an
///   explicit content-change continuation; the route observer can only end an
///   existing engagement (confirmed drop) or cancel the picker grace window.
final class CastController: ObservableObject {
  // MARK: - Types

  struct Content {
    var url: URL
    var isLive: Bool
    var userAgent: String?
    /// Source-time second playback should (re)start from.
    var startAt: TimeInterval
    /// Source duration when already known from the direct player (0 = unknown).
    var knownDuration: TimeInterval
    /// AVPlayer can play the URL natively — cast it directly, no remux session.
    var nativelyPlayable: Bool
    /// Playback was paused when the engagement began; start the cast paused too.
    var startPaused: Bool = false
  }

  private struct Pending {
    /// nil while waiting for a delayed retry (no session in flight).
    var session: AirPlayRemuxSession?
    var content: Content
    /// One delayed retry is allowed after a transient start failure (panel
    /// connection limits: dying connections need a few seconds to clear).
    var retryUsed: Bool
    /// Button-flow completion (opens the route picker on success). Carried in the
    /// state so every exit path — including a retry or endCasting — resolves it;
    /// an unresolved completion leaves the UI spinner stuck forever.
    var completion: ((Bool) -> Void)?
  }

  private struct Active {
    /// nil for natively playable content (cast player plays the URL directly).
    let session: AirPlayRemuxSession?
    var content: Content
    var timeline: RemuxTimeline
    /// AVPlayer can join a growing event playlist at its live edge; corrected once.
    var didCorrectLiveEdgeJoin = false
  }

  private enum State {
    case idle
    /// Session starting; direct playback is already stopped; spinner presented.
    case preparing(Pending)
    case casting(Active)
    /// In-content seek refresh: `current` keeps playing until `next` is ready.
    case refreshing(current: Active, next: Pending)
  }

  // MARK: - Published presentation

  /// True whenever an engagement exists — the owner presents cast state instead
  /// of engine state and routes transport calls here.
  @Published private(set) var isPresenting = false
  @Published private(set) var position: TimeInterval = 0
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var isPaused = false
  @Published private(set) var isBuffering = false
  @Published private(set) var isCompleted = false
  @Published private(set) var isSeekable = false
  @Published private(set) var isPlaybackEstablished = false
  @Published private(set) var isExternalPlaybackActive = false
  /// Bumped when `castVideoView` may point to a new view.
  @Published private(set) var surfaceRevision = 0

  // MARK: - Owner hooks

  /// Stop the direct-playback engine (releases its source connection).
  var stopDirectPlayback: (() -> Void)?
  /// Resume direct playback of `content` at the given source position.
  var resumeDirectPlayback: ((Content, TimeInterval) -> Void)?
  /// Source-time tick while casting (drives the subtitle overlay).
  var onTimeTick: ((TimeInterval) -> Void)?
  private var ownerToken: UUID?

  var castVideoView: UIView? { castPlayer?.view }

  /// The engagement survives content changes; `VideoPlayerController.play`
  /// routes new content through `playContent` while this is true.
  var isEngaged: Bool {
    if case .idle = state { return false }
    return true
  }

  // MARK: - Private state

  private var state: State = .idle
  private var castPlayer: AirPlayCastPlayer?
  /// An AirPlay route became active at some point during this engagement.
  private var routeWasActiveDuringEngagement = false
  private var routeDropConfirmWork: DispatchWorkItem?
  private var pickerGraceWork: DispatchWorkItem?
  private var retryWork: DispatchWorkItem?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var isDisposed = false
  private var cancellables = Set<AnyCancellable>()

  // MARK: - Cross-screen handoff

  /// PlayerView is screen-scoped, but an AirPlay AVPlayer must outlive navigation
  /// between player screens. The closing owner parks its live controller here;
  /// the next VideoPlayerController takes the SAME instance and swaps only the
  /// content item, preserving the external route and TV picture.
  private static var parkedCrossScreenController: CastController?

  /// Native AVPlayer external playback is owned by KSPlayer rather than this
  /// controller. When that screen closes, the AVPlayer disappears but iOS can
  /// leave the audio route on AirPlay. Remember that short handoff window so the
  /// next (usually FFmpeg/live) item is promoted into this cast pipeline instead
  /// of opening locally and sending audio only.
  private static var nativeExternalContinuationDeadline: Date?
  /// Suppresses a late marker from the outgoing controller after the incoming
  /// controller has already claimed the native AirPlay route. SwiftUI may create
  /// the new screen before calling `onDisappear` on the old one.
  private static var nativeExternalClaimDeadline: Date?

  static func markNativeExternalPlaybackForNextLoad() {
    if let claimedUntil = nativeExternalClaimDeadline, claimedUntil >= Date() {
      return
    }
    nativeExternalContinuationDeadline = Date().addingTimeInterval(30)
  }

  static func claimNativeExternalPlaybackFromActiveController() {
    nativeExternalContinuationDeadline = nil
    nativeExternalClaimDeadline = Date().addingTimeInterval(10)
  }

  static func takeNativeExternalPlaybackContinuation() -> Bool {
    guard let deadline = nativeExternalContinuationDeadline else { return false }
    nativeExternalContinuationDeadline = nil
    guard deadline >= Date() else { return false }
    // Do not strand normal playback in a cast prepare state if the user actually
    // disconnected while moving between screens.
    let routeIsActive = AVAudioSession.sharedInstance().currentRoute.outputs
      .contains { $0.portType == .airPlay }
    if routeIsActive {
      nativeExternalClaimDeadline = Date().addingTimeInterval(10)
    }
    return routeIsActive
  }

  static func takeCrossScreenHandoff() -> CastController? {
    guard let parked = parkedCrossScreenController else { return nil }
    parkedCrossScreenController = nil
    guard !parked.isDisposed, parked.isEngaged else {
      parked.dispose()
      return nil
    }
    return parked
  }

  /// Detaches screen-owned callbacks while playback continues on the TV. Route
  /// observation remains active; if AirPlay disconnects before another screen
  /// takes ownership, the normal endCasting path still tears everything down.
  func attachOwner(
    token: UUID,
    stopDirectPlayback: @escaping () -> Void,
    resumeDirectPlayback: @escaping (Content, TimeInterval) -> Void,
    onTimeTick: @escaping (TimeInterval) -> Void
  ) {
    ownerToken = token
    self.stopDirectPlayback = stopDirectPlayback
    self.resumeDirectPlayback = resumeDirectPlayback
    self.onTimeTick = onTimeTick
    clearCrossScreenHandoffIfNeeded()
  }

  /// Returns true when the caller must leave this controller alive: either an
  /// engagement was parked, or a newer screen has already taken ownership.
  func parkForCrossScreenHandoff(owner token: UUID) -> Bool {
    guard ownerToken == token else {
      return true
    }
    ownerToken = nil
    guard !isDisposed, isEngaged else { return false }
    if let previous = Self.parkedCrossScreenController, previous !== self {
      previous.dispose()
    }
    stopDirectPlayback = nil
    resumeDirectPlayback = nil
    onTimeTick = nil
    Self.parkedCrossScreenController = self
    return true
  }

  private func clearCrossScreenHandoffIfNeeded() {
    if Self.parkedCrossScreenController === self {
      Self.parkedCrossScreenController = nil
    }
  }

  init() {
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.handleRouteChange() }
      .store(in: &cancellables)
  }

  // MARK: - Public API

  /// UHF-style flow behind the AirPlay button: stop the engine, build the local
  /// HLS session, start the cast player; `completion(true)` means the UI should
  /// open the system route picker now.
  func startRemuxCast(content: Content, completion: @escaping (Bool) -> Void) {
    guard !isDisposed, case .idle = state else {
      completion(false)
      return
    }
    stopDirectPlayback?()
    // Telefon oynatıcısının panel bağlantısı asenkron kapanır; yeni bağlantıyı
    // 1 sn geciktir (bağlantı-limitli panelde ilk açılış çakışması).
    beginRemuxSession(
      content: content, replacing: nil, retryUsed: false,
      openDelaySeconds: 1.0, completion: completion
    )
  }

  /// Continues a native external-playback route after its screen-scoped AVPlayer
  /// was torn down. Unlike the AirPlay button flow there is no picker completion:
  /// the route is already selected and only the video-bearing player must be
  /// re-established.
  func continueNativeExternalPlayback(with content: Content) {
    guard !isDisposed, case .idle = state else { return }
    stopDirectPlayback?()
    if content.nativelyPlayable {
      let player = ensureCastPlayer()
      player.load(
        url: content.url,
        startAt: content.startAt > 0.5 ? content.startAt : nil,
        autoPlay: !content.startPaused
      )
      transition(to: .casting(Active(
        session: nil,
        content: content,
        timeline: RemuxTimeline(offset: 0, knownDuration: content.knownDuration)
      )))
      presentLoading(of: content)
      armRouteWatch()
    } else {
      beginRemuxSession(
        content: content, replacing: nil, retryUsed: false,
        openDelaySeconds: 1.0, completion: nil
      )
    }
  }

  /// Content change (zap, auto-next episode) while engaged: route the new content
  /// through the cast pipeline directly — the engine stays stopped.
  func playContent(_ content: Content) {
    guard !isDisposed, isEngaged else { return }
    let outgoing = currentSession()
    stopAllSessions()
    if content.nativelyPlayable {
      castPlayer?.pause()
      let player = ensureCastPlayer()
      player.load(
        url: content.url,
        startAt: content.startAt > 0.5 ? content.startAt : nil,
        autoPlay: !content.startPaused
      )
      transition(to: .casting(Active(
        session: nil,
        content: content,
        timeline: RemuxTimeline(offset: 0, knownDuration: content.knownDuration)
      )))
      presentLoading(of: content)
      armRouteWatch()
    } else {
      // The old item is left PLAYING (not paused): a live AVPlayer item paused at
      // the edge of a now-static playlist relinquishes the external screen fast,
      // dropping the AirPlay route mid-zap. Its local segments persist (30s) so it
      // holds the TV until the new item swaps in. The new writer waits for the old
      // session's SOURCE connection to actually close before opening — matching why
      // the clean button rebuild is reliable (freed panel slot), not a blind delay.
      beginRemuxSession(
        content: content, replacing: nil, retryUsed: false,
        openDelaySeconds: 3.0, previousToDrain: outgoing, completion: nil
      )
    }
  }

  /// The session currently holding the source connection (for drain-before-open).
  private func currentSession() -> AirPlayRemuxSession? {
    switch state {
    case .idle: return nil
    case let .preparing(pending): return pending.session
    case let .casting(active): return active.session
    case let .refreshing(current, _): return current.session
    }
  }

  /// Ends the engagement deliberately and resumes direct playback.
  func stopCasting() {
    endCasting(resume: true, reason: "user request")
  }

  /// Owner teardown (player screen closing): stop everything, no resume.
  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    ownerToken = nil
    clearCrossScreenHandoffIfNeeded()
    stopAllSessions()
    castPlayer?.dispose()
    castPlayer = nil
    transition(to: .idle)
    endBackgroundHold()
    cancellables.removeAll()
  }

  // MARK: - Transport (routed here by the owner while presenting)

  func play() {
    switch state {
    case var .preparing(pending):
      // Desired-state latch only: the cast player still holds the SUPERSEDED item;
      // playing it would resume the old content's buffered tail on the TV
      // (the field-reported old/new alternation). The new session honors the latch.
      pending.content.startPaused = false
      state = .preparing(pending)  // direct assignment: pending timers must survive
      if isPaused { isPaused = false }
    case .refreshing, .casting:
      guard let castPlayer else { return }
      if isCompleted {
        castPlayer.seek(to: 0)
        if isCompleted { isCompleted = false }
      }
      castPlayer.play()
    case .idle:
      break
    }
  }

  func pause() {
    switch state {
    case var .preparing(pending):
      pending.content.startPaused = true
      state = .preparing(pending)
      if !isPaused { isPaused = true }
    default:
      castPlayer?.pause()
    }
  }

  func setRate(_ rate: Float) {
    castPlayer?.setRate(rate)
  }

  func setVolume(_ value: Double) {
    castPlayer?.setVolume(Float(min(max(value, 0), 125) / 100))
  }

  func seek(toSource target: TimeInterval) {
    let target = max(target, 0)
    switch state {
    case .idle:
      return
    case var .preparing(pending):
      // Session still starting; remember the new target and restart from it once
      // ready would waste the buffered start — just re-aim the pending content.
      pending.content.startAt = target
      state = .preparing(pending)
      if position != target { position = target }
    case let .casting(active):
      seekWhileCasting(active, target: target)
    case let .refreshing(current, next):
      // Re-aim the refresh: drop the in-flight session, start over at the target.
      next.session?.stop()
      var content = next.content
      content.startAt = target
      if position != target { position = target }
      beginRemuxSession(content: content, replacing: current, retryUsed: next.retryUsed, completion: nil)
    }
  }

  // MARK: - State machine core

  /// Single transition point: every pending timer belongs to the state that
  /// scheduled it and dies with it.
  private func transition(to newState: State) {
    routeDropConfirmWork?.cancel()
    routeDropConfirmWork = nil
    pickerGraceWork?.cancel()
    pickerGraceWork = nil
    retryWork?.cancel()
    retryWork = nil
    state = newState
    let presenting = isEngaged
    if isPresenting != presenting { isPresenting = presenting }
    if !presenting {
      routeWasActiveDuringEngagement = false
    }
  }

  /// Single exit path for every failure/disconnect/deliberate stop. Always
  /// resumes direct playback when asked — regardless of which sub-state the
  /// engagement died in (this was the black-screen-wedge class of bugs).
  private func endCasting(resume: Bool, reason: String) {
    guard !isDisposed, isEngaged else { return }
    Log.info("AirPlayCast", "ending cast (\(reason))")
    let resumeInfo: (Content, TimeInterval)?
    let pendingCompletion: ((Bool) -> Void)?
    switch state {
    case .idle:
      resumeInfo = nil
      pendingCompletion = nil
    case let .preparing(pending):
      resumeInfo = (pending.content, pending.content.startAt)
      pendingCompletion = pending.completion
    case let .casting(active):
      resumeInfo = (active.content, position)
      pendingCompletion = nil
    case let .refreshing(_, next):
      // The seek target is where the user wants to be.
      resumeInfo = (next.content, next.content.startAt)
      pendingCompletion = next.completion
    }
    pendingCompletion?(false)
    // The engagement ended while this controller is alive (failure, route drop,
    // user request) — a later screen must not resurrect it.
    clearCrossScreenHandoffIfNeeded()
    stopAllSessions()
    castPlayer?.dispose()
    castPlayer = nil
    bumpSurfaceRevision()
    transition(to: .idle)
    endBackgroundHold()
    resetPresentation()
    if resume, let (content, at) = resumeInfo {
      resumeDirectPlayback?(content, at)
    }
  }

  private func stopAllSessions() {
    switch state {
    case .idle:
      break
    case let .preparing(pending):
      pending.session?.stop()
    case let .casting(active):
      active.session?.stop()
    case let .refreshing(current, next):
      current.session?.stop()
      next.session?.stop()
    }
  }

  // MARK: - Session lifecycle

  /// Starts a remux session for `content`. With `replacing` set (in-content seek
  /// refresh) the old session keeps playing until the new one is ready.
  private func beginRemuxSession(
    content: Content,
    replacing current: Active?,
    retryUsed: Bool,
    openDelaySeconds: Double = 0,
    previousToDrain: AirPlayRemuxSession? = nil,
    completion: ((Bool) -> Void)?
  ) {
    let session: AirPlayRemuxSession
    do {
      session = try AirPlayRemuxSession(
        sourceURL: content.url,
        startOffsetSeconds: content.startAt,
        isLive: content.isLive,
        userAgent: content.userAgent,
        // Refresh (user actively waiting at the scrubber): low buffer gate.
        // Fresh start: high buffer gate so playback starts with a cushion.
        minimumBufferSeconds: current == nil ? 12 : 5,
        openDelaySeconds: openDelaySeconds,
        previousToDrain: previousToDrain
      )
    } catch {
      // Rare (temp dir creation). Resume the REQUESTED content directly — the
      // stale state must not decide (it would resurrect the previous content),
      // and in the button flow the engine is already stopped: not resuming
      // would leave a black screen.
      Log.error("AirPlayCast", "session create failed: \(error.localizedDescription)")
      completion?(false)
      stopAllSessions()
      castPlayer?.dispose()
      castPlayer = nil
      bumpSurfaceRevision()
      transition(to: .idle)
      endBackgroundHold()
      resetPresentation()
      resumeDirectPlayback?(content, content.startAt)
      return
    }
    let pending = Pending(
      session: session, content: content, retryUsed: retryUsed, completion: completion
    )
    if let current {
      transition(to: .refreshing(current: current, next: pending))
    } else {
      transition(to: .preparing(pending))
      presentLoading(of: content)
    }
    if isAirPlayRouteActive { routeWasActiveDuringEngagement = true }
    beginBackgroundHold()
    session.onError = { [weak self, weak session] error in
      guard let self, let session else { return }
      self.handleSessionRuntimeError(session, error)
    }
    Log.info("AirPlayCast", "starting remux at \(Int(content.startAt))s for \(content.isLive ? "live" : "vod") content")
    session.start { [weak self, weak session] result in
      guard let self, let session, !self.isDisposed, self.isPendingSession(session) else {
        session?.stop()
        return
      }
      switch result {
      case let .success(localURL):
        self.sessionDidStart(session, localURL: localURL)
      case let .failure(error):
        self.handleSessionStartFailure(session, error: error)
      }
    }
  }

  private func isPendingSession(_ session: AirPlayRemuxSession) -> Bool {
    switch state {
    case let .preparing(pending):
      return pending.session === session
    case let .refreshing(_, next):
      return next.session === session
    case .idle, .casting:
      return false
    }
  }

  private func sessionDidStart(_ session: AirPlayRemuxSession, localURL: URL) {
    let content: Content
    let completion: ((Bool) -> Void)?
    switch state {
    case let .preparing(pending):
      content = pending.content
      completion = pending.completion
    case let .refreshing(current, next):
      current.session?.stop()
      content = next.content
      completion = next.completion
    case .idle, .casting:
      session.stop()
      return
    }
    endBackgroundHold()
    let player = ensureCastPlayer()
    player.load(url: localURL, startAt: nil, autoPlay: !content.startPaused)
    // The input seek may have failed on a non-seekable source: the writer then
    // remuxes from 0:00 and reports it — presenting the requested offset would
    // show one position while the TV plays another.
    let actualOffset = session.effectiveStartOffsetSeconds
    let timeline = RemuxTimeline(
      offset: actualOffset,
      knownDuration: content.knownDuration > 0
        ? content.knownDuration
        : session.sourceDurationSeconds
    )
    transition(to: .casting(Active(session: session, content: content, timeline: timeline)))
    if position != actualOffset { position = actualOffset }
    if isBuffering { isBuffering = false }
    armRouteWatch()
    completion?(true)
    // A seek that arrived while preparing re-aimed `content.startAt`, but this
    // session was already remuxing from its original offset — chase the target.
    // Never chase when the input could not seek (it would loop rebuilding).
    if actualOffset == session.startOffsetSeconds,
       abs(content.startAt - session.startOffsetSeconds) > 2 {
      seek(toSource: content.startAt)
    }
  }

  private func handleSessionStartFailure(_ session: AirPlayRemuxSession, error: Error) {
    Log.error("AirPlayCast", "session start failed: \(error.localizedDescription)")
    session.stop()
    switch state {
    case let .preparing(pending) where pending.session === session:
      // One delayed retry for transient failures — panel connection limits clear
      // once the previous connections die. The button flow retries too (spinner
      // stays up via the carried completion): failing permanently on the first
      // collision was the field-reported first-start failure.
      if !pending.retryUsed, Self.isTransientStartError(error) {
        var waiting = pending
        waiting.session = nil
        waiting.retryUsed = true
        transition(to: .preparing(waiting))
        let work = DispatchWorkItem { [weak self] in
          guard let self, !self.isDisposed,
                case let .preparing(p) = self.state, p.session == nil
          else { return }
          self.beginRemuxSession(
            content: p.content, replacing: nil, retryUsed: true, completion: p.completion
          )
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
      } else {
        pending.completion?(false)
        var cleared = pending
        cleared.completion = nil  // resolved above; endCasting must not double-call
        transition(to: .preparing(cleared))
        endCasting(resume: true, reason: "prepare failed")
      }
    case let .refreshing(current, next) where next.session === session:
      // Fall back to the still-playing current session.
      next.completion?(false)
      transition(to: .casting(current))
      let local = castPlayer?.currentTime ?? 0
      let reported = current.timeline.sourceTime(fromLocal: local)
      if position != reported { position = reported }
      if isBuffering { isBuffering = false }
      armRouteWatch()
    default:
      break
    }
  }

  /// At most one in-place session rebuild per this interval; a second runtime
  /// error inside it ends the cast (prevents rebuild loops on a dead source).
  private var lastRuntimeRebuildAt: Date?

  /// Writer/source error after the session started serving.
  private func handleSessionRuntimeError(_ session: AirPlayRemuxSession, _ error: Error) {
    guard !isDisposed else { return }
    switch state {
    case let .casting(active) where active.session === session:
      // Live panel resets and VOD network hiccups are routine; tearing the whole
      // cast down for each one is the field-reported "picture cuts out". Rebuild
      // the session in place once; only a persistent failure ends the cast.
      if lastRuntimeRebuildAt.map({ Date().timeIntervalSince($0) < 30 }) ?? false {
        endCasting(resume: true, reason: "session error: \(error.localizedDescription)")
      } else {
        lastRuntimeRebuildAt = Date()
        Log.info("AirPlayCast", "session error; rebuilding in place: \(error.localizedDescription)")
        let outgoing = active.session
        outgoing?.stop()
        // Keep the item playing (holds the external screen); the new writer drains
        // the old source connection before reopening the panel.
        var content = active.content
        content.startAt = content.isLive ? 0 : position
        beginRemuxSession(
          content: content, replacing: nil, retryUsed: false,
          openDelaySeconds: 3.0, previousToDrain: outgoing, completion: nil
        )
      }
    case let .refreshing(current, next) where current.session === session:
      // Current died while the refresh is in flight: keep waiting for the next
      // session; presentation is already pinned at the seek target.
      current.session?.stop()
      castPlayer?.pause()
      transition(to: .preparing(Pending(
        session: next.session,
        content: next.content,
        retryUsed: next.retryUsed,
        completion: next.completion
      )))
    default:
      break  // stale session; already superseded
    }
  }

  private static func isTransientStartError(_ error: Error) -> Bool {
    if let remuxError = error as? RemuxHLSWriter.RemuxError {
      if case .openInputFailed = remuxError { return true }
      return false
    }
    let ns = error as NSError
    // AirPlayRemux code 2 = playlist not produced in time (source slow to open).
    return ns.domain == "AirPlayRemux" && ns.code == 2
  }

  // MARK: - Cast player

  private func ensureCastPlayer() -> AirPlayCastPlayer {
    if let castPlayer { return castPlayer }
    let player = AirPlayCastPlayer()
    castPlayer = player
    bumpSurfaceRevision()
    player.onTime = { [weak self] time in self?.handleCastTime(time) }
    player.onStateChange = { [weak self] in self?.handleCastStateChange() }
    player.onError = { [weak self] error in self?.handleCastError(error) }
    player.onEnded = { [weak self] in self?.handleCastEnded() }
    return player
  }

  private func handleCastTime(_ time: TimeInterval) {
    // During a refresh the old player may still tick; ignore so the scrubber
    // stays pinned at the seek target.
    guard case let .casting(active) = state, let castPlayer else { return }
    let reported = active.session == nil ? time : active.timeline.sourceTime(fromLocal: time)
    if position != reported { position = reported }
    // The writer's VOD pacing gate follows the playback position.
    active.session?.updatePlaybackPosition(reported)
    let total = active.session == nil
      ? castPlayer.duration
      : active.timeline.totalDuration(localPlayerDuration: castPlayer.duration)
    if duration != total { duration = total }
    onTimeTick?(reported)
    guard active.session != nil else { return }
    // Self-heal: fell behind the served window (long pause on a live sliding
    // window, or the event playlist trimmed) — refresh the session in place.
    let window = castPlayer.seekableRange
    if window.end > 2, time + 1 < window.start, !castPlayer.isPaused {
      Log.info("AirPlayCast", "fell behind served window; refreshing session")
      if active.content.isLive {
        // The active session must be stopped BEFORE the rebuild: beginRemuxSession
        // transitions away from .casting and would otherwise orphan a running
        // writer that holds a panel connection forever.
        active.session?.stop()
        var content = active.content
        content.startAt = 0
        beginRemuxSession(
          content: content, replacing: nil, retryUsed: true,
          openDelaySeconds: 1.0, completion: nil
        )
      } else {
        seek(toSource: reported)
      }
    }
  }

  private func handleCastStateChange() {
    guard let castPlayer else { return }
    let externalNow = castPlayer.isExternalPlaybackActive
    let externalJustActivated = externalNow && !isExternalPlaybackActive
    if isExternalPlaybackActive != externalNow {
      isExternalPlaybackActive = externalNow
    }
    guard case var .casting(active) = state else { return }
    // AirPlay handoff: the Apple TV fetches the playlist ITSELF and performs its
    // own join — the phone-side player's earlier position corrections do not carry
    // over. EXT-X-START pins fresh joins to 0; this is the safety net for players
    // that ignore it AND it preserves an in-window position the user had seeked to.
    if externalJustActivated, active.session != nil, !active.content.isLive {
      let localExpected = active.timeline.localTarget(forSource: position)
      if abs(castPlayer.currentTime - localExpected) > 5 {
        Log.info("AirPlayCast", "correcting position after AirPlay handoff")
        castPlayer.seek(to: localExpected)
      }
    }
    if isPaused != castPlayer.isPaused { isPaused = castPlayer.isPaused }
    if isBuffering != castPlayer.isBuffering { isBuffering = castPlayer.isBuffering }
    if castPlayer.isReadyToPlay {
      if !isPlaybackEstablished { isPlaybackEstablished = true }
      let seekable = !(active.content.isLive && active.session != nil)
      if isSeekable != seekable { isSeekable = seekable }
      // AVPlayer can treat a growing event playlist as live and join at its
      // edge; remuxed VOD must start from local 0 (the requested offset).
      if active.session != nil, !active.content.isLive, !active.didCorrectLiveEdgeJoin {
        active.didCorrectLiveEdgeJoin = true
        state = .casting(active)
        if castPlayer.currentTime > 3 {
          castPlayer.seek(to: 0)
        }
      }
    }
  }

  private func handleCastError(_ error: Error) {
    // During .preparing/.refreshing the loaded item is the SUPERSEDED one — its
    // failure (e.g. old session's deleted playlist 404ing into .failed) must not
    // abort the healthy new session.
    guard case .casting = state else {
      Log.error("AirPlayCast", "stale cast item error ignored during transition: \(error.localizedDescription)")
      return
    }
    Log.error("AirPlayCast", "cast playback failed: \(error.localizedDescription)")
    endCasting(resume: true, reason: "cast player error")
  }

  private func handleCastEnded() {
    guard case .casting = state else { return }
    // Played to the end of the written playlist (ENDLIST): drives auto-next.
    if !isCompleted { isCompleted = true }
    if !isPaused { isPaused = true }
  }

  // MARK: - Seek helpers

  private func seekWhileCasting(_ active: Active, target: TimeInterval) {
    guard let castPlayer else { return }
    if active.session == nil {
      castPlayer.seek(to: target)
      if position != target { position = target }
      return
    }
    if active.content.isLive { return }  // live remux is not seekable
    let local = active.timeline.localTarget(forSource: target)
    let window = castPlayer.seekableRange
    if window.end > 2, local >= window.start + 1, local < window.end - 1 {
      castPlayer.seek(to: local)
      if position != target { position = target }
    } else {
      // Outside the written range: pin the scrubber at the target and rebuild
      // the session from there; the old session keeps playing meanwhile.
      if position != target { position = target }
      if !isBuffering { isBuffering = true }
      var content = active.content
      content.startAt = target
      beginRemuxSession(content: content, replacing: active, retryUsed: false, completion: nil)
    }
  }

  // MARK: - Route observation

  private var isAirPlayRouteActive: Bool {
    AVAudioSession.sharedInstance().currentRoute.outputs
      .contains { $0.portType == .airPlay }
  }

  /// The route observer has exactly two jobs: cancel a pending drop when the
  /// route comes back, and end the engagement when a drop is confirmed. It never
  /// starts anything. Drops are ignored while `.preparing`: stopping the direct
  /// player flaps the route by itself, and the prepare window has its own
  /// failure handling — acting on the echo of our own teardown was a root cause
  /// of the historical zap breakage.
  private func handleRouteChange() {
    guard !isDisposed, isEngaged else { return }
    if isAirPlayRouteActive {
      routeDropConfirmWork?.cancel()
      routeDropConfirmWork = nil
      routeWasActiveDuringEngagement = true
      pickerGraceWork?.cancel()
      pickerGraceWork = nil
    } else if routeWasActiveDuringEngagement, routeDropConfirmWork == nil {
      switch state {
      case .casting, .refreshing:
        // Content finished: the TV may drop the route at the end of playback while
        // the 5s auto-next countdown runs. Acting on it would resurrect the ended
        // content at its final seconds (the field-reported old/new alternation) —
        // the countdown owns this window; the next content re-arms route watching.
        if isCompleted { break }
        scheduleRouteDropConfirm()
      case .idle, .preparing:
        break
      }
    }
  }

  /// After entering a presenting state with no active route: either the user has
  /// not picked a device yet (grace window — cancelling the picker produces no
  /// event at all) or a drop is pending confirmation.
  private func armRouteWatch() {
    guard !isAirPlayRouteActive else {
      routeWasActiveDuringEngagement = true
      return
    }
    if routeWasActiveDuringEngagement {
      scheduleRouteDropConfirm()
    } else {
      schedulePickerGrace()
    }
  }

  /// AirPlay routes flap briefly when an external-playback AVPlayer elsewhere is
  /// torn down; act only on a drop that persists.
  private func scheduleRouteDropConfirm() {
    routeDropConfirmWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isDisposed else { return }
      self.routeDropConfirmWork = nil
      guard !self.isAirPlayRouteActive else { return }
      self.endCasting(resume: true, reason: "route drop confirmed")
    }
    routeDropConfirmWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
  }

  private func schedulePickerGrace() {
    pickerGraceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isDisposed else { return }
      self.pickerGraceWork = nil
      guard self.isEngaged, !self.isAirPlayRouteActive,
            self.castPlayer?.isExternalPlaybackActive != true
      else { return }
      self.endCasting(resume: true, reason: "no AirPlay route selected in time")
    }
    pickerGraceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
  }

  // MARK: - Presentation helpers

  private func presentLoading(of content: Content) {
    if position != content.startAt { position = content.startAt }
    if duration != content.knownDuration { duration = content.knownDuration }
    if !isBuffering { isBuffering = true }
    if isCompleted { isCompleted = false }
    if isPaused != content.startPaused { isPaused = content.startPaused }
    // Not established: the owner must present "loading", and auto-resume paths
    // (remote play, interruption end) must not think playback is running — they
    // would resume the superseded item on the TV.
    if isPlaybackEstablished { isPlaybackEstablished = false }
  }

  private func resetPresentation() {
    if position != 0 { position = 0 }
    if duration != 0 { duration = 0 }
    if isPaused { isPaused = false }
    if isBuffering { isBuffering = false }
    if isCompleted { isCompleted = false }
    if isSeekable { isSeekable = false }
    if isPlaybackEstablished { isPlaybackEstablished = false }
    if isExternalPlaybackActive { isExternalPlaybackActive = false }
  }

  private func bumpSurfaceRevision() {
    surfaceRevision += 1
  }

  // MARK: - Background hold

  /// The prepare window (engine stopped, cast not yet playing) has no audio and
  /// no playback keeping the process alive; a background task covers it if the
  /// user locks the screen mid-handover.
  private func beginBackgroundHold() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AirPlayCastPrepare") {
      [weak self] in
      self?.endBackgroundHold()
    }
  }

  private func endBackgroundHold() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }
}
