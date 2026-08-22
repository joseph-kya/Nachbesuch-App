import MapKit
import UIKit

// MARK: - Annotations

/// One house on the map. Annotations are created once per house and then live for
/// as long as the house does — panning and zooming never add or remove them, which
/// is what keeps pins from flickering or vanishing mid-gesture.
final class HouseAnnotation: NSObject, MKAnnotation {
    let houseID: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// Latest rendered payload. Mutated in place; the view re-reads it on configure.
    var pin: MapPinSnapshot
    var isPinSelected: Bool

    var title: String? { pin.address }

    init(houseID: UUID, pin: MapPinSnapshot, isPinSelected: Bool) {
        self.houseID = houseID
        coordinate = pin.coordinate
        self.pin = pin
        self.isPinSelected = isPinSelected
    }
}

/// A corner the user dropped while tracing a territory boundary.
final class DraftPointAnnotation: NSObject, MKAnnotation {
    let number: Int
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { "Gebietspunkt \(number)" }

    init(number: Int, coordinate: CLLocationCoordinate2D) {
        self.number = number
        self.coordinate = coordinate
    }
}

/// The recommended walking route. A subclass so the renderer can distinguish it
/// from a territory boundary, which is also a polyline when it has two points.
///
/// `nonisolated` because `MKPolyline` is, and the project defaults new types to the
/// main actor.
nonisolated final class RoutePolyline: MKPolyline {}

/// The house you are meant to walk to next.
///
/// Kept as its own annotation rather than baked into the pin artwork: the marker
/// then survives every pin scale — it is just as visible when the pins have shrunk
/// to dots — and it can animate without re-rendering a cached bitmap.
final class NextStopAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { "Nächstes Haus auf der Route" }

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

// MARK: - House pin

/// A bare image host. All geometry and text is baked into the cached bitmap by
/// `PinArtCache`, so configuring a pin is one image assignment — no subviews, no
/// Auto Layout, no text measurement. That is what lets thousands of pins pan at
/// full frame rate.
final class HousePinView: MKAnnotationView {
    static let reuseIdentifier = "HousePin"
    static let clusteringIdentifier = "HousePinCluster"

    weak var coordinator: MapCoordinator?

    private var renderedKey: PinArtCache.Key?

    #if DEBUG
    /// Where this pin's tip currently sits relative to where its own coordinate says
    /// it should, in points. Used by the placement diagnostic; the tip is the part
    /// that must land on the building, so this is what "the pin is in the wrong
    /// place" actually means — measuring `center` instead cancels a stale
    /// `centerOffset` out and always reports success.
    func tipOffsetFromCoordinate(in mapView: MKMapView) -> CGPoint? {
        guard let house = annotation as? HouseAnnotation, let image else { return nil }
        let target = mapView.convert(house.coordinate, toPointTo: mapView)
        let tip = CGPoint(
            x: center.x + transform.tx,
            y: center.y + transform.ty + image.size.height / 2 - PinArtCache.shared.shadowPadding
        )
        return CGPoint(x: tip.x - target.x, y: tip.y - target.y)
    }
    #endif

    /// Read from the coordinator on every configure rather than pushed in.
    ///
    /// This is the fix for pins getting stuck in the wrong size: the coordinator
    /// used to push a new value only to annotations inside the *visible* rect, so
    /// any view MapKit had already realised just outside it kept the old artwork
    /// and scrolled in stale. Pulling means a view cannot be out of date — and
    /// `prepareForDisplay()` re-reads it every time MapKit is about to show one.
    private var scale: PinScale {
        coordinator?.pinScale ?? .full
    }

    /// Nudges a realised view to re-read the scale immediately, so the change is
    /// visible on the current frame instead of at the next redisplay.
    func refreshScale() {
        applyArt()
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        // Our own recognizer opens the sheet the instant the finger lifts, instead
        // of waiting out MapKit's selection round trip.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        addInteraction(UIContextMenuInteraction(delegate: self))

        // Re-render the cached bitmap when light/dark changes; the pin artwork bakes
        // the appearance in, so it cannot adapt on its own.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HousePinView, _) in
            view.configure()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var annotation: MKAnnotation? {
        didSet { applyArt() }
    }

    /// Apple's own clustering sample configures in `prepareForDisplay()` rather than
    /// `init`, because this runs on every reuse — which is exactly when a recycled
    /// view would otherwise still be showing the previous house's artwork.
    override func prepareForDisplay() {
        super.prepareForDisplay()
        applyArt()
    }

    func configure() {
        applyArt()
    }

    private func applyArt() {
        guard let annotation = annotation as? HouseAnnotation else { return }
        let pin = annotation.pin

        // `MKAnnotationView.displayPriority` defaults to `.required`, and a required
        // view is never culled and **never clusters away**. Leaving the default on a
        // custom subclass forces MapKit to render every single pin — the classic
        // reason a custom-annotation map dies at scale where an
        // `MKMarkerAnnotationView` map (which defaults to `.defaultLow`) does not.
        // So priority is always explicit here, and never `.required`.
        displayPriority = pin.hasOpenWork
            ? .defaultHigh
            : (pin.joinedCount > 0 ? MKFeatureDisplayPriority(600) : .defaultLow)
        zPriority = annotation.isPinSelected
            ? .max
            : (pin.hasOpenWork ? .defaultSelected : .defaultUnselected)

        let scale = scale
        let key = PinArtCache.Key(
            outcome: pin.markerOutcome,
            // The glyph is kept at every scale that can render it — losing the
            // emoji was the single most confusing thing about the old behaviour.
            text: scale.showsGlyph ? pin.markerText : "",
            isSelected: annotation.isPinSelected,
            isDark: traitCollection.userInterfaceStyle == .dark,
            scale: scale
        )
        // Accessibility is payload, not artwork. An address or count can change
        // while the bitmap key stays identical.
        accessibilityLabel = Self.accessibilityText(for: pin)
        guard key != renderedKey else { return }
        renderedKey = key
        let cache = PinArtCache.shared
        // Swapping the artwork replaces `bounds`, and `frame` is undefined while a
        // non-identity transform is applied. MapKit puts its own transform on member
        // views for the whole duration of a cluster animation — measured at 78 art
        // swaps under a live transform during a single zoom-out/zoom-in round trip,
        // each with a different translation. Neutralise, swap, restore, so the two
        // never interleave.
        let activeTransform = transform
        if !activeTransform.isIdentity { transform = .identity }
        image = cache.pinImage(for: key)
        centerOffset = cache.centerOffset(for: scale)
        if !activeTransform.isIdentity { transform = activeTransform }
    }

    private static func accessibilityText(for pin: MapPinSnapshot) -> String {
        if pin.unitCount == 1 {
            return "\(pin.address), \(pin.markerOutcome.displayTitleRaw)"
        }
        return "\(pin.address), \(pin.completedCount) von \(pin.unitCount) Türen erledigt, "
            + "\(pin.followUpCount) offene Nachbesuche"
    }

    @objc private func handleTap() {
        guard let annotation = annotation as? HouseAnnotation else { return }
        coordinator?.houseTapped(annotation.houseID)
    }

    /// Compact and dot artwork remains comfortably tappable. The visual hierarchy
    /// may shrink with zoom, but the interaction target never should.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let horizontal = max((44 - bounds.width) / 2, 0)
        let vertical = max((44 - bounds.height) / 2, 0)
        return bounds.insetBy(dx: -horizontal, dy: -vertical).contains(point)
    }

    /// A freshly placed house drops onto the map.
    func performDrop() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        transform = CGAffineTransform(translationX: 0, y: -70).scaledBy(x: 0.9, y: 0.9)
        alpha = 0
        UIView.animate(
            withDuration: 0.55,
            delay: 0,
            usingSpringWithDamping: 0.66,
            initialSpringVelocity: 0.2
        ) {
            self.transform = .identity
            self.alpha = 1
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // A view recycled mid fade-in must never come back half-transparent.
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
        renderedKey = nil
    }

}

extension HousePinView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let annotation = annotation as? HouseAnnotation else { return nil }
        // Built lazily: nothing is constructed until the long press actually lands.
        return UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: { [weak self] in
                self?.coordinator?.previewProvider?(annotation.pin)
            },
            actionProvider: { [weak self] _ in
                self?.coordinator?.menuProvider?(annotation.pin)
            }
        )
    }
}

// MARK: - Cluster bubble

/// The bubble MapKit renders for a merged group. Its artwork — including the count —
/// is a cached bitmap, so a cluster costs the same as a pin.
final class ClusterBubbleView: MKAnnotationView {
    static let reuseIdentifier = "ClusterBubble"

    weak var coordinator: MapCoordinator?

    private var memberObservation: NSKeyValueObservation?
    private struct RenderedState: Equatable {
        let count: Int
        let hasOpenWork: Bool
        let isDark: Bool
    }
    private var renderedState: RenderedState?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .required
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: ClusterBubbleView, _) in
            view.invalidateArt()
            view.configure()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit { memberObservation?.invalidate() }

    override var annotation: MKAnnotation? {
        didSet {
            memberObservation?.invalidate()
            memberObservation = nil
            guard let cluster = annotation as? MKClusterAnnotation else { return }
            // MapKit mutates `memberAnnotations` in place while zooming, without
            // handing the view a new annotation — without KVO the number goes stale.
            memberObservation = cluster.observe(
                \.memberAnnotations,
                options: [.initial]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.configure() }
            }
        }
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        configure()
    }

    /// Forces the next `configure()` to re-render even if the count is unchanged —
    /// used when a member's payload changed the bubble's accent colour.
    func invalidateArt() {
        renderedState = nil
    }

    func configure() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let count = cluster.memberAnnotations.count
        var hasOpenWork = false
        for member in cluster.memberAnnotations {
            if let house = member as? HouseAnnotation, house.pin.hasOpenWork {
                hasOpenWork = true
                break
            }
        }

        accessibilityLabel = hasOpenWork
            ? "\(count) Häuser, offene Arbeit dabei. Zum Vergrößern tippen."
            : "\(count) Häuser. Zum Vergrößern tippen."
        let state = RenderedState(
            count: count,
            hasOpenWork: hasOpenWork,
            isDark: traitCollection.userInterfaceStyle == .dark
        )
        guard state != renderedState else { return }
        renderedState = state

        image = PinArtCache.shared.clusterImage(
            count: count,
            hasOpenWork: hasOpenWork,
            isDark: state.isDark
        )
        centerOffset = PinArtCache.shared.clusterCenterOffset
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer.removeAllAnimations()
        alpha = 1
        renderedState = nil
        memberObservation?.invalidate()
        memberObservation = nil
    }
}

// MARK: - Boundary draft point

final class DraftPointView: MKAnnotationView {
    static let reuseIdentifier = "DraftPoint"

    private static let side: CGFloat = 26
    private static let artwork: UIImage = {
        let side = DraftPointView.side
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side + 6, height: side + 6),
            format: format
        )
        return renderer.image { context in
            let rect = CGRect(x: 3, y: 3, width: side, height: side)
            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 3,
                color: UIColor.black.withAlphaComponent(0.3).cgColor
            )
            UIColor.systemRed.setFill()
            UIBezierPath(ovalIn: rect).fill()
            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            UIColor.white.setStroke()
            ring.stroke()
        }
    }()

    private let numberLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
        image = Self.artwork
        frame = CGRect(x: 0, y: 0, width: Self.side + 6, height: Self.side + 6)
        numberLabel.frame = bounds
        numberLabel.textAlignment = .center
        numberLabel.font = .systemFont(ofSize: 12, weight: .bold)
        numberLabel.textColor = .white
        addSubview(numberLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var annotation: MKAnnotation? {
        didSet {
            guard let draft = annotation as? DraftPointAnnotation else { return }
            numberLabel.text = "\(draft.number)"
            accessibilityLabel = "Gebietspunkt \(draft.number)"
        }
    }
}


// MARK: - Next stop marker

/// A slowly breathing blue ring around the next house on the route.
///
/// Sits *under* the pin (`zPriority = .min`) and takes no touches, so the house
/// itself still behaves exactly as every other pin — the ring only says "this one".
final class NextStopHaloView: MKAnnotationView {
    static let reuseIdentifier = "NextStopHalo"

    weak var coordinator: MapCoordinator?

    private static let side: CGFloat = 96
    private let ring = CAShapeLayer()
    private let pulse = CAShapeLayer()
    /// A small blue arrow bobbing above the pin. The ring alone can be lost in a
    /// dense row of pins; something pointing *down at* the house cannot.
    private let arrow = CAShapeLayer()
    private var renderedScale: PinScale?

    private var scale: PinScale { coordinator?.pinScale ?? .full }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        isUserInteractionEnabled = false
        // Never culled, never clustered: the whole point is that it is on screen
        // whenever the route is running.
        displayPriority = .required
        collisionMode = .none
        // Drawn on TOP: on a dense street the marker has to win over the pins that
        // happen to overlap it, otherwise the one house you need is the one hidden.
        zPriority = .max
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)

        for layer in [pulse, ring] {
            layer.frame = bounds
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = UIColor.systemBlue.cgColor
            self.layer.addSublayer(layer)
        }
        ring.lineWidth = 3.5
        ring.fillColor = UIColor.systemBlue.withAlphaComponent(0.10).cgColor
        ring.shadowColor = UIColor.systemBlue.cgColor
        ring.shadowOpacity = 0.55
        ring.shadowRadius = 6
        ring.shadowOffset = .zero
        pulse.lineWidth = 3

        arrow.fillColor = UIColor.systemBlue.cgColor
        arrow.strokeColor = UIColor.white.cgColor
        arrow.lineWidth = 1.5
        arrow.lineJoin = .round
        arrow.shadowColor = UIColor.black.cgColor
        arrow.shadowOpacity = 0.3
        arrow.shadowRadius = 2
        arrow.shadowOffset = CGSize(width: 0, height: 1)
        arrow.frame = bounds
        layer.addSublayer(arrow)

        accessibilityLabel = "Nächstes Haus auf der Route"
        isAccessibilityElement = true
        applyScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        applyScale()
        startPulsing()
    }

    /// Re-reads the pin scale, exactly like `HousePinView` does, so the ring keeps
    /// hugging the pin head instead of drifting when the pins resize.
    func refreshScale() {
        applyScale()
    }

    private func applyScale() {
        let scale = scale
        guard scale != renderedScale else { return }
        renderedScale = scale
        // The ring is sized off the pin head so it reads as "around this pin" at
        // every tier, and it is anchored to the head rather than to the tip.
        let diameter = min(scale.headDiameter * 1.6, Self.side - 8)
        let inset = (Self.side - diameter) / 2
        let path = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).cgPath
        ring.path = path
        pulse.path = path
        arrow.path = Self.arrowPath(centerX: bounds.midX, bottomY: inset - 7)
        centerOffset = PinArtCache.shared.headCenterOffset(for: scale)
    }

    /// A downward chevron, tip just above the ring.
    private static func arrowPath(centerX: CGFloat, bottomY: CGFloat) -> CGPath {
        let halfWidth: CGFloat = 8
        let height: CGFloat = 11
        let path = UIBezierPath()
        path.move(to: CGPoint(x: centerX - halfWidth, y: bottomY - height))
        path.addLine(to: CGPoint(x: centerX + halfWidth, y: bottomY - height))
        path.addLine(to: CGPoint(x: centerX, y: bottomY))
        path.close()
        return path.cgPath
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Layer animations are removed when a view leaves the window; restart rather
        // than leave a dead ring behind.
        if window != nil { startPulsing() }
    }

    /// Restarts the animation after the app returns from the background, where the
    /// system strips every running `CAAnimation`.
    @objc private func applicationDidBecomeActive() {
        startPulsing()
    }

    private func startPulsing() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        guard !UIAccessibility.isReduceMotionEnabled else {
            pulse.isHidden = true
            pulse.removeAnimation(forKey: "pulse")
            arrow.removeAnimation(forKey: "bob")
            return
        }
        pulse.isHidden = false
        if arrow.animation(forKey: "bob") == nil {
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = -3
            bob.toValue = 2
            bob.duration = 0.9
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arrow.add(bob, forKey: "bob")
        }
        guard pulse.animation(forKey: "pulse") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.9
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.add(group, forKey: "pulse")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pulse.removeAnimation(forKey: "pulse")
        arrow.removeAnimation(forKey: "bob")
        renderedScale = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Raw presentation helpers for the UIKit map layer, which deliberately does not
/// import SwiftUI.
extension Optional where Wrapped == VisitOutcome {
    var displayTitleRaw: String { self?.title ?? "noch kein Status" }
}
