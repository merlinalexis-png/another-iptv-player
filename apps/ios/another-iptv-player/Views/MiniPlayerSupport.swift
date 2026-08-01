import Combine
import SwiftUI

/// Intent policy for the fullscreen-player pull-down gesture. Keeping the slop,
/// direction lock, progress mapping, and release decision together prevents small
/// vertical touch drift from visibly moving or minimizing the player.
enum FullscreenPlayerPullDownPolicy {
    static let activationDistance: CGFloat = 44
    static let verticalDominance: CGFloat = 1.25
    static let directCommitProgress: CGFloat = 0.52
    static let minimumFlickProgress: CGFloat = 0.18
    static let projectedCommitProgress: CGFloat = 0.68

    static func shouldActivate(translation: CGSize) -> Bool {
        translation.height > activationDistance
            && translation.height > abs(translation.width) * verticalDominance
    }

    static func activeDistance(fullDistance: CGFloat) -> CGFloat {
        max(fullDistance - activationDistance, 1)
    }

    static func progress(translationHeight: CGFloat, fullDistance: CGFloat) -> CGFloat {
        let traveled = max(0, translationHeight - activationDistance)
        return min(1, traveled / activeDistance(fullDistance: fullDistance))
    }

    static func shouldCommit(
        progress: CGFloat,
        projectedProgress: CGFloat,
        velocityY: CGFloat
    ) -> Bool {
        progress >= directCommitProgress
            || (
                progress >= minimumFlickProgress
                    && projectedProgress >= projectedCommitProgress
                    && velocityY > 0
            )
    }
}

/// Linear interpolation between `a` and `b` by `t` (unclamped).
func miniLerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

/// Holds the live drag translation of the docked mini card plus its drag-to-dismiss fade.
/// Observed ONLY by `MiniCardDragLayer`, never by the PlayerView body — so repositioning the card
/// is a cheap pure translation and does not re-render the heavy player subtree (which would re-run
/// the video surface update and make the picture visibly glitch while dragging). PlayerView holds
/// it via `@State` (which does not subscribe), and the drag gesture mutates these directly.
final class MiniCardDragModel: ObservableObject {
    @Published var offset: CGSize = .zero
    /// Live dismiss fade, driven from the card's off-screen fraction while dragging toward any
    /// edge (1 = fully opaque, ~0.2 = about to be released off-screen). Kept on the model so the
    /// fade and the offset update in the same re-render as the card moves — no lockstep drift.
    @Published var dismissOpacity: Double = 1
}

/// Repositions the docked mini-card group by the live drag offset and applies the drag-to-dismiss
/// fade — the ONLY thing that re-renders while the card is being dragged. Everything expensive
/// (the masked/scaled video) lives in `content`, which is evaluated once by the parent and merely
/// re-offset here, so playback is untouched.
struct MiniCardDragLayer<Content: View>: View {
    @ObservedObject var model: MiniCardDragModel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .offset(model.offset)
            .opacity(model.dismissOpacity)
    }
}

/// Off-screen / dismiss geometry for the floating mini card. Kept next to the metrics so the live
/// drag fade and the release decision agree on when a card is "heading off the edge". Dismissal is
/// deliberately POSITION-only (how far the card has actually left the app), never velocity/flick —
/// a quick reposition swipe must re-dock, only physically dragging the card out closes it.
enum MiniPlayerDismissPolicy {
    /// Fraction of the card that must clear a screen edge (left, right, or bottom) at release for a
    /// dismiss. 0.5 = the card's center has reached the screen edge (half the card outside).
    static let releaseFraction: CGFloat = 0.5
    /// Opacity floor while dragging toward an edge, so the card stays faintly visible pre-release.
    static let minLiveOpacity: Double = 0.28

    /// How far the card (centered at `center`, size `card`) pokes past the nearest of the left,
    /// right, or bottom screen edges, expressed as a fraction of the card's own extent on that
    /// axis. 0 = fully on-screen; 1 = fully cleared. The top edge is intentionally excluded — the
    /// card docks under the status bar there and an upward drag should re-dock, not dismiss.
    static func offscreenFraction(center: CGPoint, card: CGSize, container: CGSize) -> CGFloat {
        let halfW = card.width / 2
        let halfH = card.height / 2
        let offLeft = max(0, halfW - center.x)
        let offRight = max(0, center.x + halfW - container.width)
        let offBottom = max(0, center.y + halfH - container.height)
        let hFrac = max(offLeft, offRight) / max(card.width, 1)
        let vFrac = offBottom / max(card.height, 1)
        return min(1, max(hFrac, vFrac))
    }

    /// Live card opacity for an off-screen fraction. Fades toward `minLiveOpacity` over the run-up
    /// to `releaseFraction` (not the full 0→1 travel) so the "about to close" dim is obvious well
    /// before the card is fully out — the release point already reads as nearly dismissed.
    static func liveOpacity(offscreenFraction frac: CGFloat) -> Double {
        let progress = min(1, Double(frac) / Double(releaseFraction))
        return minLiveOpacity + (1 - minLiveOpacity) * (1 - progress)
    }
}

/// The four screen corners the floating mini player can dock to.
enum MiniPlayerCorner: Equatable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

/// Geometry for the in-app floating mini player card.
///
/// The card floats in a screen corner above the tab bar. Its aspect ratio follows the
/// currently displayed video (clamped) so the frame hugs the picture like system PiP,
/// instead of forcing a fixed 16:9 slot that would letterbox or crop odd streams.
enum MiniPlayerMetrics {
    /// Gap between the card and the screen / safe-area edge.
    static let margin: CGFloat = 12
    static let cornerRadius: CGFloat = 16
    /// Extra bottom space reserved for the bottom tab bar on compact widths so the
    /// card floats *above* it and the tabs stay tappable. iPad `.sidebarAdaptable`
    /// has no bottom bar, so callers pass 0 there. Standard UITabBar height.
    static let tabBarAllowance: CGFloat = 49

    static func cardWidth(container: CGSize) -> CGFloat {
        min(container.width * 0.48, 240)
    }

    /// Card size honoring the video's displayed aspect (clamped so extreme streams still
    /// yield a sensible card). Height is bounded by `maxHeight` (derived from the available
    /// vertical space) so a portrait video in a short/landscape container can't produce a
    /// card taller than the screen or one that barely shrinks — width is then re-derived from
    /// the clamped height to keep the aspect.
    static func cardSize(container: CGSize, videoAspect: CGFloat, maxHeight: CGFloat) -> CGSize {
        let aspect = min(max(videoAspect, 0.62), 2.4)
        var w = cardWidth(container: container)
        var h = w / aspect
        if h > maxHeight {
            h = maxHeight
            w = h * aspect
        }
        return CGSize(width: w, height: h)
    }

    static func cardOrigin(
        corner: MiniPlayerCorner,
        size: CGSize,
        container: CGSize,
        safeArea: EdgeInsets,
        bottomInset: CGFloat
    ) -> CGPoint {
        // Rest the card against the physical screen edges. In landscape the leading/trailing
        // safe-area insets (notch / camera housing) are large (~50pt each on iPhone); honoring
        // them left a wide empty strip on both sides. The user wants the card flush to the edge,
        // so we inset horizontally by only `margin` from the real container edge.
        let leftX = margin
        let rightX = container.width - margin - size.width
        let topY = safeArea.top + margin
        // Leave a small `margin` gap above the reserved bottom navigation/tab-bar region so the
        // card doesn't crowd the bar (sitting perfectly flush read as too close on device).
        let bottomY = container.height - bottomInset - margin - size.height
        switch corner {
        case .topLeading: return CGPoint(x: leftX, y: topY)
        case .topTrailing: return CGPoint(x: rightX, y: topY)
        case .bottomLeading: return CGPoint(x: leftX, y: bottomY)
        case .bottomTrailing: return CGPoint(x: rightX, y: bottomY)
        }
    }
}

/// Interactive chrome drawn on top of the shrunk video card: tap-to-expand, play/pause,
/// close, and a drag handle for moving between corners / swiping away. Rendered unscaled
/// at the card's position; the live video shows through from the transformed player below.
struct MiniPlayerChrome: View {
    @ObservedObject var player: VideoPlayerController
    let cornerRadius: CGFloat
    let isLoading: Bool
    let onExpand: () -> Void
    let onClose: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (_ translation: CGSize, _ velocity: CGSize) -> Void

    var body: some View {
        ZStack {
            // Tap-to-expand hit layer, behind the buttons so the buttons win their taps.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onExpand() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(L("player.a11y.expand_mini_player"))

            // Top row: play/pause on the leading (top-left, YouTube-style), close on the trailing.
            VStack {
                HStack(alignment: .top) {
                    Group {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .frame(width: 32, height: 32)
                        } else {
                            Button {
                                player.togglePlayPause()
                            } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(.black.opacity(0.4), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(player.isPlaying ? L("player.a11y.pause") : L("player.a11y.play"))
                        }
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("common.close"))
                }
                Spacer()
            }
            .padding(6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .simultaneousGesture(
            // Measure in the GLOBAL (fixed) space, not `.local`: the card is repositioned by this
            // very drag, so a `.local` translation would be measured against a frame that moves
            // with the finger — a feedback loop that makes the card judder back and forth.
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { onDragChanged($0.translation) }
                .onEnded {
                    onDragEnded($0.translation, CGSize(width: $0.velocity.width, height: $0.velocity.height))
                }
        )
    }
}
