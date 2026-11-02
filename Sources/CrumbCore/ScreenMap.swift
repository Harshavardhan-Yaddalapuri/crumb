import CoreGraphics

/// Converts between screen points (top-left origin, y down: Finder's desktop coordinates)
/// and the overlay's world plane (metres, origin at the screen centre, y up) seen by an orthographic camera.
public struct ScreenMap: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let pointsPerMeter: Double

    public init(width: Double, height: Double, pointsPerMeter: Double) {
        self.width = width
        self.height = height
        self.pointsPerMeter = pointsPerMeter
    }

    /// Value for `OrthographicCameraComponent.scale`: half the visible height, in metres.
    public var cameraScale: Float { Float(height / 2 / pointsPerMeter) }

    public func world(_ p: CGPoint) -> SIMD2<Float> {
        SIMD2(Float((p.x - width / 2) / pointsPerMeter), Float((height / 2 - p.y) / pointsPerMeter))
    }

    public func screen(_ w: SIMD2<Float>) -> CGPoint {
        CGPoint(x: width / 2 + Double(w.x) * pointsPerMeter, y: height / 2 - Double(w.y) * pointsPerMeter)
    }
}
