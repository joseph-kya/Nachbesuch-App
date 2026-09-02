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

// MARK: - House pin

/// A bare image host. All geometry and text is baked into the cached bitmap by
/// `PinArtCache`, so configuring a pin is one image assignment — no subviews, no
/// Auto Layout, no text measurement. That is what lets thousands of pins pan at
/// full frame rate.
final class HousePinView: MKAnnotationView {
    static let reuseIdentifier = "HousePin"

    weak var coordinator: MapCoordinator?

    private var renderedKey: PinArtCache.Key?

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
        // **Never culled, never merged.** A canvasser has to visit every house, so a
        // pin silently losing its spot to a neighbour is worse than two pins
        // overlapping: overlapping pins are visibly a stack, and a tap on one offers
        // the list. This is also what makes the map behave the same at every zoom —
        // there is no mode to switch, so no zoom speed can catch it mid-switch.
        collisionMode = .none
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

    /// Configuring here rather than in `init` is what keeps a recycled view from
    /// showing the previous house's artwork: this runs on every reuse.
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

        // `MKAnnotationView.displayPriority` defaults to `.required` on a custom
        // subclass, which opts every pin out of MapKit's rendering budget — the
        // classic reason a custom-annotation map dies at scale where an
        // `MKMarkerAnnotationView` map (which defaults to `.defaultLow`) does not.
        // So priority is always explicit here, and never `.required`; houses with
        // open work outrank finished ones if MapKit ever has to choose.
        displayPriority = pin.followUpCount > 0
            ? .defaultHigh
            : (pin.joinedCount > 0 ? MKFeatureDisplayPriority(600) : .defaultLow)

        // Semantic identity is independent of bitmap identity. Address-only edits
        // must reach VoiceOver even when the cached artwork is unchanged.
        accessibilityLabel = Self.accessibilityText(for: pin)

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
        guard key != renderedKey else { return }
        renderedKey = key
        let cache = PinArtCache.shared
        image = cache.pinImage(for: key)
        centerOffset = cache.centerOffset
    }

    private static func accessibilityText(for pin: MapPinSnapshot) -> String {
        if pin.isDamaged {
            return "\(pin.address), Daten beschädigt, Wiederherstellung nötig"
        }
        if pin.unitCount == 1 {
            return "\(pin.address), \(pin.markerOutcome.displayTitleRaw)"
        }
        return "\(pin.address), \(pin.completedCount) von \(pin.unitCount) Türen erledigt, "
            + "\(pin.followUpCount) offene Nachbesuche"
    }

    @objc private func handleTap() {
        guard let annotation = annotation as? HouseAnnotation else { return }
        coordinator?.houseTappedFromGesture(annotation.houseID)
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



/// Raw presentation helpers for the UIKit map layer, which deliberately does not
/// import SwiftUI.
extension Optional where Wrapped == VisitOutcome {
    var displayTitleRaw: String { self?.title ?? "noch kein Status" }
}
