import Foundation

/// Global audio/video sync offset, persisted across playbacks.
/// Positive values delay the audio; negative values play it earlier.
enum AudioDelayPersistence {
    static let range: ClosedRange<Double> = -2.0...2.0
    static let step: Double = 0.025

    private static let key = "playback.audioDelaySeconds"

    static func load() -> Double {
        let raw = UserDefaults.standard.double(forKey: key)
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    static func save(_ seconds: Double) {
        UserDefaults.standard.set(seconds, forKey: key)
    }
}
