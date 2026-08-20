import MapKit
import UIKit

/// Apple-Maps-style user location puck: accuracy halo, white-ringed blue core and a
/// directional cone that follows the compass.
///
/// MapKit's stock puck only shows a heading cone while the map is in
/// `.followWithHeading`. Canvassers pan the map constantly, so the direction
/// indicator has to survive free panning — hence a custom view.
final class UserLocationPuckView: MKAnnotationView {
    static let reuseIdentifier = "UserLocationPuck"

    private let haloLayer = CAShapeLayer()
    private let coneLayer = CALayer()
    private let coneMask = CAShapeLayer()
    private let coreLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()

    private static let coreDiameter: CGFloat = 22
    private static let coneRadius: CGFloat = 46
    /// Half-angle of the cone. Widens when the compass reading is poor, exactly like
    /// Apple Maps, so the cone honestly communicates uncertainty.
    private static let minimumHalfAngle: CGFloat = .pi / 10
    private static let maximumHalfAngle: CGFloat = .pi / 3.2

    /// Compass heading in degrees clockwise from true north, or `nil` to hide the cone.
    private var headingDegrees: Double?
    private var headingHalfAngle: CGFloat = UserLocationPuckView.minimumHalfAngle
    /// The map's own rotation, subtracted so the cone points at the real-world bearing.
    private var mapHeadingDegrees: Double = 0
    private var renderedRotation: CGFloat = .greatestFiniteMagnitude
    private var isPulsing = false

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        isEnabled = false
        // The puck must never be swallowed by clustering or collision culling.
        displayPriority = .required
        collisionMode = .circle
        zPriority = .max

        let side = Self.coneRadius * 2
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        let center = CGPoint(x: side / 2, y: side / 2)

        haloLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.16).cgColor
        haloLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.28).cgColor
        haloLayer.lineWidth = 0.5
        layer.addSublayer(haloLayer)

        pulseLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.25).cgColor
        pulseLayer.opacity = 0
        layer.addSublayer(pulseLayer)

        // The cone is a gradient wedge: bright at the puck, fading outward.
        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.type = .radial
        gradient.colors = [
            UIColor.systemBlue.withAlphaComponent(0.55).cgColor,
            UIColor.systemBlue.withAlphaComponent(0.0).cgColor
        ]
        gradient.locations = [0.0, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        coneLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        coneLayer.addSublayer(gradient)
        coneLayer.mask = coneMask
        coneMask.frame = coneLayer.bounds
        coneMask.fillColor = UIColor.white.cgColor
        coneLayer.isHidden = true
        layer.addSublayer(coneLayer)

        ringLayer.fillColor = UIColor.white.cgColor
        ringLayer.shadowColor = UIColor.black.cgColor
        ringLayer.shadowOpacity = 0.28
        ringLayer.shadowRadius = 3
        ringLayer.shadowOffset = CGSize(width: 0, height: 1)
        ringLayer.path = UIBezierPath(
            arcCenter: center,
            radius: Self.coreDiameter / 2,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        ).cgPath
        layer.addSublayer(ringLayer)

        coreLayer.fillColor = UIColor.systemBlue.cgColor
        coreLayer.path = UIBezierPath(
            arcCenter: center,
            radius: Self.coreDiameter / 2 - 3,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        ).cgPath
        layer.addSublayer(coreLayer)

        updateHaloRadius(Self.coreDiameter / 2 + 6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Updates

    /// Applies a new compass reading. Rotation is animated along the shortest arc so
    /// the cone never spins the long way round when crossing north.
    func apply(headingDegrees: Double?, accuracy: Double?, mapHeadingDegrees: Double) {
        self.headingDegrees = headingDegrees
        self.mapHeadingDegrees = mapHeadingDegrees
        if let accuracy, accuracy >= 0 {
            // 5° reading → tight cone, 45°+ → wide cone.
            let normalized = min(max((accuracy - 5) / 40, 0), 1)
            headingHalfAngle = Self.minimumHalfAngle
                + (Self.maximumHalfAngle - Self.minimumHalfAngle) * normalized
        }
        refreshCone()
    }

    /// Accuracy halo in screen points, derived from the horizontal accuracy and the
    /// map's current scale by the caller.
    func apply(accuracyRadiusInPoints radius: CGFloat) {
        updateHaloRadius(max(radius, Self.coreDiameter / 2 + 6))
    }

    func setPulsing(_ pulsing: Bool) {
        guard pulsing != isPulsing else { return }
        isPulsing = pulsing
        if pulsing, !UIAccessibility.isReduceMotionEnabled {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            pulseLayer.path = UIBezierPath(
                arcCenter: center,
                radius: Self.coreDiameter / 2,
                startAngle: 0,
                endAngle: .pi * 2,
                clockwise: true
            ).cgPath
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 2.6
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 2.0
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pulseLayer.add(group, forKey: "pulse")
        } else {
            pulseLayer.removeAnimation(forKey: "pulse")
            pulseLayer.opacity = 0
        }
    }

    private func updateHaloRadius(_ radius: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        haloLayer.path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: true
        ).cgPath
    }

    private func refreshCone() {
        guard let headingDegrees else {
            coneLayer.isHidden = true
            return
        }
        coneLayer.isHidden = false

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Rebuild the wedge only when its width actually changed.
        let wedge = UIBezierPath()
        wedge.move(to: center)
        wedge.addArc(
            withCenter: center,
            radius: Self.coneRadius,
            startAngle: -.pi / 2 - headingHalfAngle,
            endAngle: -.pi / 2 + headingHalfAngle,
            clockwise: true
        )
        wedge.close()
        coneMask.path = wedge.cgPath

        let target = CGFloat((headingDegrees - mapHeadingDegrees) * .pi / 180)
        guard target != renderedRotation else { return }

        // Shortest-arc: never rotate more than 180° for a single reading.
        var delta = target - (renderedRotation == .greatestFiniteMagnitude ? target : renderedRotation)
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        let previous = renderedRotation == .greatestFiniteMagnitude ? target : renderedRotation
        renderedRotation = previous + delta

        CATransaction.begin()
        // Compass noise arrives many times a second; a short implicit animation
        // smooths it without lagging behind the real bearing.
        CATransaction.setAnimationDuration(UIAccessibility.isReduceMotionEnabled ? 0 : 0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        coneLayer.setAffineTransform(CGAffineTransform(rotationAngle: renderedRotation))
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        headingDegrees = nil
        renderedRotation = .greatestFiniteMagnitude
        coneLayer.isHidden = true
        setPulsing(false)
    }
}
