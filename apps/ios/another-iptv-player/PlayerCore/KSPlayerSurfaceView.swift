import AVKit
import Combine
import SwiftUI
import UIKit

/// AirPlay hedef seçici (yalnız KSPlayer motoru; AVPlayer yolunda gerçek external
/// playback, FFmpeg yolunda sistem yansıtması olarak çalışır).
struct AirPlayRoutePickerButton: UIViewRepresentable {
  var tintColor: UIColor = .white

  func makeUIView(context _: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.tintColor = tintColor
    view.activeTintColor = .systemBlue
    view.prioritizesVideoDevices = true
    return view
  }

  func updateUIView(_: AVRoutePickerView, context _: Context) {}
}

/// Görünmez route picker: `trigger` her arttığında sistem cihaz seçici popup'ını
/// programatik açar. UHF akışında remux hazır olduktan sonra kullanılır.
struct HiddenAirPlayRoutePicker: UIViewRepresentable {
  var trigger: Int

  final class Coordinator {
    var lastTrigger: Int?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.prioritizesVideoDevices = true
    view.alpha = 0.02
    view.isUserInteractionEnabled = false
    context.coordinator.lastTrigger = trigger
    return view
  }

  func updateUIView(_ view: AVRoutePickerView, context: Context) {
    guard context.coordinator.lastTrigger != trigger else { return }
    context.coordinator.lastTrigger = trigger
    // AVRoutePickerView programatik açma API'si sunmaz; içindeki butona dokunma
    // gönderilir (yaygın, App Store'da kabul gören yaklaşım).
    for subview in view.subviews {
      if let button = subview as? UIButton {
        button.sendActions(for: .touchUpInside)
        break
      }
    }
  }
}

/// Hosts the KSPlayer video view plus our own subtitle overlay. While a cast
/// engagement is presenting, the cast player's view is hosted instead and an
/// "AirPlay" placeholder covers the surface when video actually leaves the phone.
struct KSPlayerVideoSurface: View {
  @ObservedObject var engine: KSPlayerEngine
  @ObservedObject var cast: CastController
  var manualPiPTrigger: Int
  var pipEnabled: Bool
  /// Arka plan davranışı `KSOptions.canBackgroundPlay` üzerinden KSPlayerLayer'a
  /// bırakılır (PiP aktifken dokunmaz); burada scenePhase yönetimi yapılmaz.
  var continuePlayingInBackground: Bool

  @State private var lastProcessedPiPTrigger: Int?

  private var isExternallyPlaying: Bool {
    cast.isPresenting ? cast.isExternalPlaybackActive : engine.isExternalPlaybackActive
  }

  var body: some View {
    KSPlayerVideoSurfaceHost(
      engine: engine,
      cast: cast,
      surfaceRevision: engine.surfaceRevision + cast.surfaceRevision,
      castPresenting: cast.isPresenting
    )
    .overlay {
      if isExternallyPlaying {
        AirPlayActivePlaceholder()
      }
    }
    .overlay(alignment: .bottom) {
      KSSubtitleOverlay(
        text: engine.subtitleText,
        image: engine.subtitleImage,
        appearance: engine.subtitleAppearance
      )
    }
    .onAppear {
      if lastProcessedPiPTrigger == nil { lastProcessedPiPTrigger = manualPiPTrigger }
    }
    .onChange(of: manualPiPTrigger) { _, newValue in
      guard pipEnabled, newValue != lastProcessedPiPTrigger, !cast.isPresenting else { return }
      lastProcessedPiPTrigger = newValue
      engine.togglePictureInPicture()
    }
  }
}

/// Shown over the local surface while video plays on the AirPlay target — the
/// black surface is otherwise indistinguishable from a playback failure.
private struct AirPlayActivePlaceholder: View {
  var body: some View {
    ZStack {
      Color.black
      VStack(spacing: 10) {
        Image(systemName: "airplay.video")
          .font(.system(size: 40, weight: .regular))
          .foregroundStyle(.white.opacity(0.85))
        Text(L("player.airplay_active"))
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.white.opacity(0.7))
      }
    }
    .allowsHitTesting(false)
  }
}

private struct KSPlayerVideoSurfaceHost: UIViewRepresentable {
  let engine: KSPlayerEngine
  let cast: CastController
  /// Param olarak geçirilir ki değişim updateUIView'ı tetiklesin (engine fallback'te
  /// KSPlayer yeni bir player/view yaratır; cast devri view'ı değiştirir).
  let surfaceRevision: Int
  let castPresenting: Bool

  private var hostedView: UIView? {
    castPresenting ? cast.castVideoView : engine.videoView
  }

  func makeUIView(context _: Context) -> KSPlayerVideoContainerUIView {
    let view = KSPlayerVideoContainerUIView()
    view.attachIfNeeded(hostedView)
    return view
  }

  func updateUIView(_ uiView: KSPlayerVideoContainerUIView, context _: Context) {
    uiView.attachIfNeeded(hostedView)
  }
}

final class KSPlayerVideoContainerUIView: UIView {
  private weak var hostedView: UIView?

  func attachIfNeeded(_ videoView: UIView?) {
    guard let videoView else { return }
    if hostedView === videoView, videoView.superview === self { return }
    hostedView?.removeFromSuperview()
    hostedView = videoView
    videoView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(videoView)
    NSLayoutConstraint.activate([
      videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
      videoView.topAnchor.constraint(equalTo: topAnchor),
      videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}

/// Text/image cue rendering with the user's subtitle appearance settings applied.
/// ASS-styled attributed strings are flattened to plain text — same behavior as the
/// mpv engine's `sub-ass-override=force`.
private struct KSSubtitleOverlay: View {
  let text: NSAttributedString?
  let image: UIImage?
  let appearance: SubtitleAppearanceSettings

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
      } else if let text, !text.string.isEmpty {
        Text(text.string)
          .font(styledFont)
          .italic(appearance.italic)
          .kerning(appearance.letterSpacing)
          .lineSpacing(max(appearance.lineHeight - 1, 0) * CGFloat(appearance.fontSize))
          .multilineTextAlignment(textAlignment)
          .foregroundStyle(Color(hex6: appearance.textColorHex6))
          .shadow(
            color: Color(hex6: appearance.outlineColorHex6),
            radius: max(appearance.outlineSize, 0.5)
          )
          .padding(.horizontal, CGFloat(appearance.padding) + 8)
          .padding(.vertical, 4)
          .background(backgroundFill)
      }
    }
    .padding(.bottom, CGFloat(max(appearance.verticalOffset, 0)) + 12)
    .allowsHitTesting(false)
  }

  private var styledFont: Font {
    Font.custom(appearance.fontWeight.iosPostscriptName, size: CGFloat(appearance.fontSize))
  }

  private var textAlignment: TextAlignment {
    switch appearance.textAlignment {
    case .left: return .leading
    case .right: return .trailing
    case .center, .justify: return .center
    }
  }

  @ViewBuilder private var backgroundFill: some View {
    if appearance.backgroundEnabled {
      RoundedRectangle(cornerRadius: 4)
        .fill(Color(hex6: appearance.backgroundColorHex6).opacity(appearance.backgroundOpacity))
    }
  }
}

private extension Color {
  init(hex6: UInt32) {
    self.init(
      red: Double((hex6 >> 16) & 0xFF) / 255.0,
      green: Double((hex6 >> 8) & 0xFF) / 255.0,
      blue: Double(hex6 & 0xFF) / 255.0
    )
  }
}
