import SwiftUI
import UIKit

/// Gesture recognizers live below SwiftUI's edge sliders, so taps can leak through the
/// transparent SwiftUI drag surface. Reject only the actual capsule frames; excluding a
/// full-height edge strip creates large tap/long-press dead zones.
struct PlayerEdgeSliderGestureExclusion {
  static let hitSlop: CGFloat = 8

  static func contains(
    _ point: CGPoint,
    in bounds: CGRect,
    trackSize: CGSize,
    leadingInset: CGFloat,
    trailingInset: CGFloat
  ) -> Bool {
    guard bounds.width > 0, bounds.height > 0,
          trackSize.width > 0, trackSize.height > 0 else {
      return false
    }

    let originY = bounds.midY - trackSize.height / 2
    let leadingRect = CGRect(
      x: bounds.minX + leadingInset,
      y: originY,
      width: trackSize.width,
      height: trackSize.height
    ).insetBy(dx: -hitSlop, dy: -hitSlop)
    let trailingRect = CGRect(
      x: bounds.maxX - trailingInset - trackSize.width,
      y: originY,
      width: trackSize.width,
      height: trackSize.height
    ).insetBy(dx: -hitSlop, dy: -hitSlop)

    return leadingRect.contains(point) || trailingRect.contains(point)
  }
}

struct PlayerSpeedHoldGesturePolicy {
  static func recognizerEnabled(canBegin: Bool, isActive: Bool) -> Bool {
    canBegin || isActive
  }
}

/// media-kit tarzı: kontroller **kapalıyken** tek parmak `UITapGestureRecognizer` ile göster (sürükleyerek kapatmayı
/// `touchesBegan` ile karıştırmaz). **Açıkken** gizleme yine tap; `UILongPressGestureRecognizer` (2x) ile
/// `require(toFail:)` sırası kullanılır.
/// VOD atlama ±15 sn, play/pause yanındaki SwiftUI düğmeleriyle.
/// Tüm pinch + pan (zoomluyken) bu UIKit container'ında; SwiftUI `.gesture` scaled-view'a
/// attached olduğunda koordinat sistemi bozuluyor ve outer dismiss gesture ile çakışıyor.
/// `hitTest` her zaman `super` döner — gesture recognizer'lar touch'ları yakalar, tap/pinch/pan
/// aynı anda `shouldRecognizeSimultaneouslyWith` ile konuşur.
final class PlayerMediaKitTouchContainerView: UIView, UIGestureRecognizerDelegate {
  fileprivate weak var coordinator: PlayerMediaKitStyleTouchOverlay.Coordinator?

  var videoZoomScale: CGFloat = 1 {
    didSet { videoPan.isEnabled = videoZoomScale > 1.02 }
  }
  var enableSpeedHold: Bool = false
  var isSpeedHoldActive: Bool = false
  var edgeSliderTrackSize: CGSize = .zero
  var edgeSliderLeadingInset: CGFloat = 0
  var edgeSliderTrailingInset: CGFloat = 0

  fileprivate let centerView = MediaKitCenterPanel()
  private let videoPinch = UIPinchGestureRecognizer()
  private let videoPan = UIPanGestureRecognizer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    isOpaque = false
    backgroundColor = .clear

    videoPinch.addTarget(self, action: #selector(handleVideoPinch(_:)))
    videoPinch.cancelsTouchesInView = false
    videoPinch.delegate = self
    addGestureRecognizer(videoPinch)

    videoPan.addTarget(self, action: #selector(handleVideoPan(_:)))
    videoPan.cancelsTouchesInView = false
    videoPan.delegate = self
    videoPan.minimumNumberOfTouches = 1
    videoPan.maximumNumberOfTouches = 1
    videoPan.isEnabled = false  // yalnızca zoomluyken aktif
    addGestureRecognizer(videoPan)

    addSubview(centerView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    centerView.frame = bounds
  }

  func bindToCoordinator(_ c: PlayerMediaKitStyleTouchOverlay.Coordinator) {
    coordinator = c
    centerView.coordinator = c
    syncPanels()
  }

  func syncPanels() {
    let show = coordinator?.showControls.wrappedValue ?? true
    centerView.configureRecognizers(
      showControls: show,
      enableSpeedHold: enableSpeedHold,
      isSpeedHoldActive: isSpeedHoldActive,
      edgeSliderTrackSize: edgeSliderTrackSize,
      edgeSliderLeadingInset: edgeSliderLeadingInset,
      edgeSliderTrailingInset: edgeSliderTrailingInset
    )
  }

  @objc private func handleVideoPinch(_ g: UIPinchGestureRecognizer) {
    switch g.state {
    case .began:
      let loc = g.location(in: self)
      coordinator?.onVideoPinchBegan(loc, bounds.size)
    case .changed:
      coordinator?.onVideoPinchChanged(g.scale)
    case .ended, .cancelled, .failed:
      coordinator?.onVideoPinchEnded()
    default:
      break
    }
  }

  @objc private func handleVideoPan(_ g: UIPanGestureRecognizer) {
    switch g.state {
    case .changed:
      let t = g.translation(in: self)
      coordinator?.onVideoPanChanged(CGSize(width: t.x, height: t.y))
    case .ended, .cancelled, .failed:
      let t = g.translation(in: self)
      coordinator?.onVideoPanEnded(CGSize(width: t.x, height: t.y))
    default:
      break
    }
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

private final class MediaKitCenterPanel: UIView, UIGestureRecognizerDelegate {
  fileprivate weak var coordinator: PlayerMediaKitStyleTouchOverlay.Coordinator?

  private let showTap = UITapGestureRecognizer()
  private let hideTap = UITapGestureRecognizer()
  private let speedHold = UILongPressGestureRecognizer()
  private var controlsVisible = true
  private var edgeSliderTrackSize: CGSize = .zero
  private var edgeSliderLeadingInset: CGFloat = 0
  private var edgeSliderTrailingInset: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: .zero)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = true

    showTap.addTarget(self, action: #selector(showTapRecognized))
    showTap.numberOfTapsRequired = 1
    showTap.cancelsTouchesInView = false
    showTap.delegate = self
    addGestureRecognizer(showTap)

    hideTap.addTarget(self, action: #selector(hideTapRecognized))
    hideTap.numberOfTapsRequired = 1
    hideTap.cancelsTouchesInView = false
    hideTap.delegate = self
    addGestureRecognizer(hideTap)

    speedHold.addTarget(self, action: #selector(speedHoldRecognized(_:)))
    speedHold.minimumPressDuration = 0.42
    speedHold.allowableMovement = 80
    speedHold.cancelsTouchesInView = false
    speedHold.delegate = self
    addGestureRecognizer(speedHold)

    showTap.require(toFail: speedHold)
    hideTap.require(toFail: speedHold)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configureRecognizers(
    showControls: Bool,
    enableSpeedHold: Bool,
    isSpeedHoldActive: Bool,
    edgeSliderTrackSize: CGSize,
    edgeSliderLeadingInset: CGFloat,
    edgeSliderTrailingInset: CGFloat
  ) {
    controlsVisible = showControls
    self.edgeSliderTrackSize = edgeSliderTrackSize
    self.edgeSliderLeadingInset = edgeSliderLeadingInset
    self.edgeSliderTrailingInset = edgeSliderTrailingInset
    showTap.isEnabled = !showControls && !isSpeedHoldActive
    hideTap.isEnabled = showControls && !isSpeedHoldActive
    // Once the hold has begun, transient buffering must not disable (and therefore
    // cancel) the recognizer. The user's finger-up remains the single end condition.
    speedHold.isEnabled = PlayerSpeedHoldGesturePolicy.recognizerEnabled(
      canBegin: enableSpeedHold,
      isActive: isSpeedHoldActive
    )
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    // The 2x speed-hold must work from EVERY point, including over the edge sliders.
    // The sliders are drag-only (minimumDistance 8), so a stationary hold can never be
    // mistaken for a slider adjustment — there is nothing to exclude it from.
    if gestureRecognizer === speedHold { return true }
    // The edge sliders only exist while the chrome is visible; with controls hidden,
    // every point must remain a valid video gesture target. While visible, a single tap
    // over a slider capsule is still swallowed so it doesn't fight the slider drag.
    guard controlsVisible else { return true }
    return !PlayerEdgeSliderGestureExclusion.contains(
      touch.location(in: self),
      in: bounds,
      trackSize: edgeSliderTrackSize,
      leadingInset: edgeSliderLeadingInset,
      trailingInset: edgeSliderTrailingInset
    )
  }

  @objc private func showTapRecognized() {
    coordinator?.requestShowChromeFromUIKit()
  }

  @objc private func hideTapRecognized() {
    coordinator?.requestHideChromeFromUIKit()
  }

  @objc private func speedHoldRecognized(_ g: UILongPressGestureRecognizer) {
    switch g.state {
    case .began:
      coordinator?.requestSpeedHoldBeganFromUIKit()
    case .ended, .cancelled, .failed:
      coordinator?.requestSpeedHoldEndedFromUIKit()
    default:
      break
    }
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

struct PlayerMediaKitStyleTouchOverlay: UIViewRepresentable {
  @Binding var showControls: Bool
  let isSeekDisabled: Bool
  let videoZoomScale: CGFloat
  let isSpeedHoldActive: Bool
  let isSpeedHoldEnabled: Bool
  let edgeSliderTrackSize: CGSize
  let edgeSliderLeadingInset: CGFloat
  let edgeSliderTrailingInset: CGFloat
  /// Disabled while the player is shrinking into / sitting in the mini card, so the
  /// UIKit tap/pinch/pan recognizers don't intercept touches meant for the mini chrome.
  var interactionEnabled: Bool = true
  let onResetTimer: () -> Void
  let onInvalidateTimer: () -> Void
  let onSpeedHoldBegan: () -> Void
  let onSpeedHoldEnded: () -> Void
  let onVideoPinchBegan: (CGPoint, CGSize) -> Void
  let onVideoPinchChanged: (CGFloat) -> Void
  let onVideoPinchEnded: () -> Void
  let onVideoPanChanged: (CGSize) -> Void
  let onVideoPanEnded: (CGSize) -> Void
  var onVideoSurfaceTap: (() -> Void)? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(
      showControls: $showControls,
      onResetTimer: onResetTimer,
      onInvalidateTimer: onInvalidateTimer,
      onSpeedHoldBegan: onSpeedHoldBegan,
      onSpeedHoldEnded: onSpeedHoldEnded,
      onVideoPinchBegan: onVideoPinchBegan,
      onVideoPinchChanged: onVideoPinchChanged,
      onVideoPinchEnded: onVideoPinchEnded,
      onVideoPanChanged: onVideoPanChanged,
      onVideoPanEnded: onVideoPanEnded,
      onVideoSurfaceTap: onVideoSurfaceTap
    )
  }

  func makeUIView(context: Context) -> PlayerMediaKitTouchContainerView {
    let v = PlayerMediaKitTouchContainerView()
    v.bindToCoordinator(context.coordinator)
    return v
  }

  func updateUIView(_ uiView: PlayerMediaKitTouchContainerView, context: Context) {
    context.coordinator.showControls = $showControls
    context.coordinator.onResetTimer = onResetTimer
    context.coordinator.onInvalidateTimer = onInvalidateTimer
    context.coordinator.onSpeedHoldBegan = onSpeedHoldBegan
    context.coordinator.onSpeedHoldEnded = onSpeedHoldEnded
    context.coordinator.onVideoPinchBegan = onVideoPinchBegan
    context.coordinator.onVideoPinchChanged = onVideoPinchChanged
    context.coordinator.onVideoPinchEnded = onVideoPinchEnded
    context.coordinator.onVideoPanChanged = onVideoPanChanged
    context.coordinator.onVideoPanEnded = onVideoPanEnded
    context.coordinator.onVideoSurfaceTap = onVideoSurfaceTap
    uiView.videoZoomScale = videoZoomScale
    uiView.enableSpeedHold = isSpeedHoldEnabled && !isSeekDisabled && videoZoomScale <= 1.02
    uiView.isSpeedHoldActive = isSpeedHoldActive
    uiView.edgeSliderTrackSize = edgeSliderTrackSize
    uiView.edgeSliderLeadingInset = edgeSliderLeadingInset
    uiView.edgeSliderTrailingInset = edgeSliderTrailingInset
    uiView.isUserInteractionEnabled = interactionEnabled
    uiView.syncPanels()
    uiView.setNeedsLayout()
  }

  final class Coordinator: NSObject {
    var showControls: Binding<Bool>
    var onResetTimer: () -> Void
    var onInvalidateTimer: () -> Void
    var onSpeedHoldBegan: () -> Void
    var onSpeedHoldEnded: () -> Void
    var onVideoPinchBegan: (CGPoint, CGSize) -> Void
    var onVideoPinchChanged: (CGFloat) -> Void
    var onVideoPinchEnded: () -> Void
    var onVideoPanChanged: (CGSize) -> Void
    var onVideoPanEnded: (CGSize) -> Void
    var onVideoSurfaceTap: (() -> Void)?

    init(
      showControls: Binding<Bool>,
      onResetTimer: @escaping () -> Void,
      onInvalidateTimer: @escaping () -> Void,
      onSpeedHoldBegan: @escaping () -> Void,
      onSpeedHoldEnded: @escaping () -> Void,
      onVideoPinchBegan: @escaping (CGPoint, CGSize) -> Void,
      onVideoPinchChanged: @escaping (CGFloat) -> Void,
      onVideoPinchEnded: @escaping () -> Void,
      onVideoPanChanged: @escaping (CGSize) -> Void,
      onVideoPanEnded: @escaping (CGSize) -> Void,
      onVideoSurfaceTap: (() -> Void)? = nil
    ) {
      self.showControls = showControls
      self.onResetTimer = onResetTimer
      self.onInvalidateTimer = onInvalidateTimer
      self.onSpeedHoldBegan = onSpeedHoldBegan
      self.onSpeedHoldEnded = onSpeedHoldEnded
      self.onVideoPinchBegan = onVideoPinchBegan
      self.onVideoPinchChanged = onVideoPinchChanged
      self.onVideoPinchEnded = onVideoPinchEnded
      self.onVideoPanChanged = onVideoPanChanged
      self.onVideoPanEnded = onVideoPanEnded
      self.onVideoSurfaceTap = onVideoSurfaceTap
    }

    private func runOnMain(_ body: @escaping () -> Void) {
      if Thread.isMainThread {
        body()
      } else {
        DispatchQueue.main.async(execute: body)
      }
    }

    private func setShowControlsAnimated(_ newValue: Bool) {
      // Cross-fade the chrome like the native player. Previously this was a hard cut
      // (Transaction.disablesAnimations) which made the `.opacity` transition inert.
      withAnimation(.easeInOut(duration: 0.28)) {
        showControls.wrappedValue = newValue
      }
    }

    func requestShowChromeFromUIKit() {
      runOnMain { [weak self] in
        guard let self else { return }
        self.onVideoSurfaceTap?()
        guard !self.showControls.wrappedValue else { return }
        self.setShowControlsAnimated(true)
        self.onResetTimer()
      }
    }

    func requestHideChromeFromUIKit() {
      runOnMain { [weak self] in
        guard let self else { return }
        self.onVideoSurfaceTap?()
        guard self.showControls.wrappedValue else { return }
        self.setShowControlsAnimated(false)
        self.onInvalidateTimer()
      }
    }

    func requestSpeedHoldBeganFromUIKit() {
      runOnMain { [weak self] in
        self?.onSpeedHoldBegan()
      }
    }

    func requestSpeedHoldEndedFromUIKit() {
      runOnMain { [weak self] in
        self?.onSpeedHoldEnded()
      }
    }
  }
}
