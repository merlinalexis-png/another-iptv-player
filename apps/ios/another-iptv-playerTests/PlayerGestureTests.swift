import CoreGraphics
import Testing
@testable import another_iptv_player

struct PlayerGestureTests {
    private let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let compactTrack = CGSize(width: 52, height: 160)

    @Test func edgeSliderExclusionMatchesCapsulesInsteadOfFullHeightStrips() {
        #expect(isExcluded(CGPoint(x: 42, y: 422)))
        #expect(isExcluded(CGPoint(x: 348, y: 422)))

        // Same horizontal strips, but outside the vertically centered capsules:
        // these remain valid video tap/long-press targets.
        #expect(!isExcluded(CGPoint(x: 42, y: 120)))
        #expect(!isExcluded(CGPoint(x: 348, y: 724)))
    }

    @Test func centerVideoSurfaceRemainsInteractive() {
        #expect(!isExcluded(CGPoint(x: bounds.midX, y: bounds.midY - 140)))
        #expect(!isExcluded(CGPoint(x: bounds.midX, y: bounds.midY + 140)))
    }

    @Test func sliderHitSlopProtectsSlowGestureStarts() {
        // Capsule begins at x=16 and is 52pt wide. The 8pt slop protects a
        // hesitant touch immediately beside it without swallowing the edge.
        #expect(isExcluded(CGPoint(x: 9, y: bounds.midY)))
        #expect(!isExcluded(CGPoint(x: 7, y: bounds.midY)))
    }

    @Test func activeSpeedHoldSurvivesTransientBuffering() {
        #expect(
            PlayerSpeedHoldGesturePolicy.recognizerEnabled(
                canBegin: false,
                isActive: true
            )
        )
        #expect(
            !PlayerSpeedHoldGesturePolicy.recognizerEnabled(
                canBegin: false,
                isActive: false
            )
        )
    }

    @Test func pullDownRequiresIntentionalVerticalTravel() {
        #expect(
            !FullscreenPlayerPullDownPolicy.shouldActivate(
                translation: CGSize(width: 2, height: 30)
            )
        )
        #expect(
            !FullscreenPlayerPullDownPolicy.shouldActivate(
                translation: CGSize(width: 46, height: 50)
            )
        )
        #expect(
            FullscreenPlayerPullDownPolicy.shouldActivate(
                translation: CGSize(width: 10, height: 60)
            )
        )
    }

    @Test func pullDownProgressStartsWithoutVisualJump() {
        let fullDistance: CGFloat = 260
        #expect(
            FullscreenPlayerPullDownPolicy.progress(
                translationHeight: FullscreenPlayerPullDownPolicy.activationDistance,
                fullDistance: fullDistance
            ) == 0
        )
        #expect(
            FullscreenPlayerPullDownPolicy.progress(
                translationHeight: fullDistance,
                fullDistance: fullDistance
            ) == 1
        )
    }

    @Test func pullDownFlickNeedsMinimumPhysicalProgress() {
        #expect(
            !FullscreenPlayerPullDownPolicy.shouldCommit(
                progress: 0.1,
                projectedProgress: 1,
                velocityY: 1_500
            )
        )
        #expect(
            FullscreenPlayerPullDownPolicy.shouldCommit(
                progress: 0.2,
                projectedProgress: 0.75,
                velocityY: 1_200
            )
        )
        #expect(
            FullscreenPlayerPullDownPolicy.shouldCommit(
                progress: 0.53,
                projectedProgress: 0.53,
                velocityY: 0
            )
        )
    }

    private func isExcluded(_ point: CGPoint) -> Bool {
        PlayerEdgeSliderGestureExclusion.contains(
            point,
            in: bounds,
            trackSize: compactTrack,
            leadingInset: 16,
            trailingInset: 16
        )
    }
}
