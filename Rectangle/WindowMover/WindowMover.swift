/// WindowMover.swift

import Foundation

protocol WindowMover {
    func moveWindow(toRect rect: CGRect, resultParameters: ResultParameters)
}

/// Time-based geometry used by the accessibility window animation. Keeping the
/// interpolation independent from AX makes it deterministic and unit testable.
enum WindowFrameAnimation {
    static let defaultDuration: Float = 0.16
    static let minimumDuration: TimeInterval = 0.08
    static let maximumDuration: TimeInterval = 0.4

    static func sanitizedDuration(_ duration: Float) -> TimeInterval {
        min(maximumDuration, max(minimumDuration, TimeInterval(duration)))
    }

    static func easeOutCubic(_ progress: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, progress))
        let remaining = 1 - clamped
        return 1 - remaining * remaining * remaining
    }

    static func interpolate(from start: CGRect, to target: CGRect, progress: CGFloat) -> CGRect {
        let eased = easeOutCubic(progress)
        return CGRect(
            x: start.origin.x + (target.origin.x - start.origin.x) * eased,
            y: start.origin.y + (target.origin.y - start.origin.y) * eased,
            width: start.width + (target.width - start.width) * eased,
            height: start.height + (target.height - start.height) * eased
        )
    }
}

/// Runs at most one short window animation at a time. Rectangle actions are
/// history-dependent, so a new action first finishes the pending animation and
/// records its exact final frame before calculating the next action.
final class WindowFrameAnimator {
    private struct ActiveAnimation {
        let generation: UInt
        let timer: DispatchSourceTimer
        let startFrame: CGRect
        let targetFrame: CGRect
        let startedAt: TimeInterval
        let duration: TimeInterval
        let applyFrame: (CGRect) -> Void
        let completion: () -> Void
    }

    private static let frameInterval = DispatchTimeInterval.milliseconds(16)
    private static let slowFrameThreshold: TimeInterval = 0.04

    private var activeAnimation: ActiveAnimation?
    private var generation: UInt = 0

    var isAnimating: Bool { activeAnimation != nil }

    func animate(from startFrame: CGRect,
                 to targetFrame: CGRect,
                 duration: TimeInterval,
                 applyFrame: @escaping (CGRect) -> Void,
                 completion: @escaping () -> Void) {
        finishActiveAnimation()

        guard duration > 0, !startFrame.isNull, !targetFrame.isNull else {
            applyFrame(targetFrame)
            completion()
            return
        }

        generation &+= 1
        let currentGeneration = generation
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let animation = ActiveAnimation(
            generation: currentGeneration,
            timer: timer,
            startFrame: startFrame,
            targetFrame: targetFrame,
            startedAt: ProcessInfo.processInfo.systemUptime,
            duration: duration,
            applyFrame: applyFrame,
            completion: completion
        )
        activeAnimation = animation

        timer.schedule(deadline: .now() + Self.frameInterval,
                       repeating: Self.frameInterval,
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.tick(generation: currentGeneration)
        }
        timer.resume()
    }

    func finishActiveAnimation() {
        guard let animation = activeAnimation else { return }
        complete(animation)
    }

    private func tick(generation: UInt) {
        guard let animation = activeAnimation,
              animation.generation == generation
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let progress = min(1, (now - animation.startedAt) / animation.duration)
        if progress >= 1 {
            complete(animation)
            return
        }

        let frame = WindowFrameAnimation.interpolate(from: animation.startFrame,
                                                     to: animation.targetFrame,
                                                     progress: CGFloat(progress))
        let frameStartedAt = ProcessInfo.processInfo.systemUptime
        animation.applyFrame(frame)

        // AX writes can block for some applications. A time-based animation
        // already skips delayed frames; if one write is especially slow, land
        // immediately instead of extending a visibly laggy transition.
        if ProcessInfo.processInfo.systemUptime - frameStartedAt > Self.slowFrameThreshold {
            Logger.log("Window animation AX update was slow; completing immediately")
            complete(animation)
        }
    }

    private func complete(_ animation: ActiveAnimation) {
        guard activeAnimation?.generation == animation.generation else { return }
        activeAnimation = nil
        animation.timer.setEventHandler {}
        animation.timer.cancel()
        animation.applyFrame(animation.targetFrame)
        animation.completion()
    }

    deinit {
        activeAnimation?.timer.setEventHandler {}
        activeAnimation?.timer.cancel()
    }
}

/// Repositions a window that may not fill its snap zone. Pure geometry, no side effects.
///
/// Per axis: if the zone touches exactly one screen edge on that axis, anchor the window
/// to that edge; if it spans the full axis (both edges) or floats inside (neither), center.
/// `window` and `zone` must be in the same (screen-flipped) coordinate space, where the
/// `.top` edge corresponds to maxY and `.bottom` to minY (matching the rest of Rectangle).
enum ClampedWindowAligner {

    static func aligned(window: CGRect, inZone zone: CGRect, sharedEdges: Edge) -> CGRect {
        var result = window

        if window.width != zone.width {
            if sharedEdges.contains(.left), !sharedEdges.contains(.right) {
                result.origin.x = zone.minX
            } else if sharedEdges.contains(.right), !sharedEdges.contains(.left) {
                result.origin.x = zone.maxX - window.width
            } else {
                result.origin.x = round((zone.width - window.width) / 2.0) + zone.minX
            }
        }

        if window.height != zone.height {
            if sharedEdges.contains(.top), !sharedEdges.contains(.bottom) {
                result.origin.y = zone.maxY - window.height
            } else if sharedEdges.contains(.bottom), !sharedEdges.contains(.top) {
                result.origin.y = zone.minY
            } else {
                result.origin.y = round((zone.height - window.height) / 2.0) + zone.minY
            }
        }

        return result
    }
}

/// For resizable windows that clamp smaller than their snap zone (e.g. FaceTime keeping a
/// fixed aspect ratio), `StandardWindowMover` leaves them at the zone's leading corner with
/// a gap on the screen-edge side. Re-anchor or center them according to `moveFixedSizeToEdge`.
/// No-op when the window already fills the zone.
class EdgeAlignmentWindowMover: WindowMover {

    func moveWindow(toRect rect: CGRect, resultParameters: ResultParameters) {
        guard resultParameters.action.resizes else { return }

        let windowElement = resultParameters.windowElement
        let currentWindowRect: CGRect = windowElement.frame
        if currentWindowRect.isNull { return }

        let sharedEdges = Defaults.moveFixedSizeToEdge.value.alignmentEdges(
            for: resultParameters.calcResult.initialRect.screenFlipped,
            in: resultParameters.visibleFrameOfScreen.screenFlipped
        )

        let adjusted = ClampedWindowAligner.aligned(window: currentWindowRect,
                                                    inZone: rect.screenFlipped,
                                                    sharedEdges: sharedEdges)

        if !adjusted.equalTo(currentWindowRect) {
            windowElement.setFrame(adjusted)
        }
    }
}

enum EdgeAlignment: Int {
    case edgesAndCorners = 1
    case corners = 2
    case centered = 3

    func alignmentEdges(for rect: CGRect, in screenFrame: CGRect) -> Edge {
        let sharedEdges = rect.sharedEdges(withRect: screenFrame)

        switch self {
        case .edgesAndCorners:
            return sharedEdges
        case .corners:
            return sharedEdges.isCorner ? sharedEdges : .none
        case .centered:
            return .none
        }
    }
}
