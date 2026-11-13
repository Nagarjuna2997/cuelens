import CoreGraphics
import Foundation

struct EyeAim: Equatable, Sendable {
    let left: CGPoint
    let right: CGPoint

    func averaged(with newer: Self, weight: Double) -> Self {
        func blend(_ old: CGPoint, _ new: CGPoint) -> CGPoint {
            CGPoint(x: old.x + (new.x - old.x) * weight, y: old.y + (new.y - old.y) * weight)
        }
        return EyeAim(left: blend(left, newer.left), right: blend(right, newer.right))
    }
}

struct GazeCalibration {
    let lens: EyeAim
    var reading: EyeAim?

    func weight(for aim: EyeAim) -> Double {
        guard let reading else { return 1 }
        // Use the calibrated reading direction to distinguish that glance from a blink or large look away.
        let axis = [reading.left.x - lens.left.x, reading.left.y - lens.left.y,
                    reading.right.x - lens.right.x, reading.right.y - lens.right.y]
        let offset = [aim.left.x - lens.left.x, aim.left.y - lens.left.y,
                      aim.right.x - lens.right.x, aim.right.y - lens.right.y]
        let length = axis.reduce(0) { $0 + $1 * $1 }
        guard length > 0.008 else { return 1 }
        let projection = zip(axis, offset).reduce(0) { $0 + $1.0 * $1.1 } / length
        let error = zip(axis, offset).reduce(0.0) { result, pair in
            let residual = pair.1 - projection * pair.0
            return result + residual * residual
        }.squareRoot()
        let offAxis = max(0, min(1, (error - 0.20) / 0.40))
        let tooFar = max(0, min(1, (abs(projection - 0.55) - 0.75) / 0.70))
        return 1 - max(offAxis, tooFar)
    }
}

struct GazeSampler {
    private(set) var frames = 0
    private var average: EyeAim?

    mutating func add(_ aim: EyeAim) {
        frames += 1
        average = average?.averaged(with: aim, weight: 1 / Double(frames)) ?? aim
    }

    var result: EyeAim? { frames >= 5 ? average : nil }
}
