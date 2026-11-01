import CoreGraphics
import Foundation

/// Decides what a two-finger trackpad gesture is for, once it has moved far enough to tell.
/// The decision holds for the rest of the gesture, so a mostly sideways swipe that drifts
/// vertically keeps scrubbing instead of switching to panning halfway through.
public struct ScrollGesture: Equatable {
    public enum Intent: Equatable {
        case undecided
        /// Horizontal swipe on a video: seek.
        case scrub
        /// Anything else: pan the pane if it's zoomed.
        case pan
    }

    public private(set) var intent: Intent = .undecided
    private var travelled: CGSize = .zero
    /// Points of travel before the direction is decided.
    public static let lockDistance: CGFloat = 4

    public init() {}

    /// Feeds one gesture delta (in finger direction) and returns the locked intent.
    public mutating func feed(_ delta: CGSize, canScrub: Bool) -> Intent {
        guard intent == .undecided else { return intent }
        travelled.width += delta.width
        travelled.height += delta.height
        guard hypot(travelled.width, travelled.height) >= Self.lockDistance else { return .undecided }
        intent = canScrub && abs(travelled.width) > abs(travelled.height) ? .scrub : .pan
        return intent
    }
}

public enum ScrubMath {
    /// Panes narrower than this scrub as if they were this wide, so small panes aren't twitchy.
    public static let minimumSpan: CGFloat = 400

    /// Moves `time` by a finger movement: one swipe across the pane covers the whole video.
    /// Moving fingers right goes forward. The result stays within `0...duration`.
    public static func advance(_ time: Double, by fingerDistance: CGFloat,
                               paneWidth: CGFloat, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let span = Double(max(paneWidth, minimumSpan))
        return min(max(time + Double(fingerDistance) / span * duration, 0), duration)
    }

    /// "0:07", "12:34" or "1:02:03".
    public static func timecode(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
