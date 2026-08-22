import UIKit

/// How much room a pin gets at the current zoom.
///
/// The glyph survives into `.compact` on purpose: a single compact flag that
/// **dropped the emoji entirely** turned every house into an anonymous coloured
/// dot at an ordinary working zoom.
enum PinScale: Sendable, Hashable {
    /// Full size, glyph.
    case full
    /// Smaller, glyph kept.
    case compact
    /// Bare dot. Overview zoom, where an address is unreadable anyway.
    case dot

    var showsGlyph: Bool { self != .dot }

    var headDiameter: CGFloat {
        switch self {
        case .full: 34
        case .compact: 25
        case .dot: 15
        }
    }
}

/// Fully pre-rendered pin artwork — geometry *and* text baked into a single
/// `UIImage`.
///
/// The old pins composed a `UIImage` with a live `UILabel` and a `UIImageView` on
/// top, so every visible pin paid a UIKit layout pass on each configure. Baking the
/// glyph into the bitmap makes an annotation view a bare image host: panning with
/// thousands of pins costs nothing but compositing.
///
/// The key space is small and bounded — five outcomes × the handful of glyphs
/// actually on screen ("🔴", "3/8", …) × scale × selected × dark — and an LRU keeps
/// a pathological dataset from growing it without limit.
@MainActor
final class PinArtCache {
    static let shared = PinArtCache()

    struct Key: Hashable {
        let outcome: VisitOutcome?
        let text: String
        let isSelected: Bool
        let isDark: Bool
        let scale: PinScale
    }

    private let ringWidth: CGFloat = 2.5
    /// Room for the drop shadow so it is never clipped by the bitmap edge.
    private let shadowPadding: CGFloat = 4

    private var cache: [Key: UIImage] = [:]
    private var order: [Key] = []
    private let limit = 260

    // MARK: Geometry

    /// Proportions of the original pin: a circle with a short pointed tip. Scaled
    /// with the head so the silhouette is identical at every size.
    private func tipHeight(for scale: PinScale) -> CGFloat {
        scale.headDiameter * (10.0 / 34.0)
    }

    private func tipWidth(for scale: PinScale) -> CGFloat {
        scale.headDiameter * (12.0 / 34.0)
    }

    /// **One canvas for every tier.**
    ///
    /// Tiers rendering into differently sized bitmaps would change the annotation
    /// view's `bounds`, and the tier swap runs from `mapViewDidChangeVisibleRegion`
    /// — once per frame of a pinch, while MapKit is positioning that same view.
    ///
    /// A fixed canvas removes the conflict rather than trying to sequence it: the
    /// artwork can be replaced on any frame, at any speed, because the geometry
    /// MapKit positions never changes. This is what makes resizing race-free.
    private var canvasSize: CGSize {
        CGSize(
            width: PinScale.full.headDiameter + shadowPadding * 2,
            height: PinScale.full.headDiameter + tipHeight(for: .full) + shadowPadding * 2
        )
    }

    /// Where the pin's tip sits inside the bitmap — identical in every tier, so a
    /// smaller pin is drawn *up* from the same point rather than in a smaller frame.
    private var tipPoint: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height - shadowPadding)
    }

    /// The head rectangle for a tier, anchored so its tip lands on `tipPoint`.
    private func headRect(for scale: PinScale) -> CGRect {
        CGRect(
            x: tipPoint.x - scale.headDiameter / 2,
            y: tipPoint.y - tipHeight(for: scale) - scale.headDiameter,
            width: scale.headDiameter,
            height: scale.headDiameter
        )
    }

    /// Offset that puts the pin's point exactly on the annotation coordinate.
    ///
    /// One value for every tier, because the canvas is one size for every tier.
    /// Resizing a pin therefore never moves it: the bitmap is swapped, the geometry
    /// MapKit positions stays put.
    var centerOffset: CGPoint {
        CGPoint(x: 0, y: -(canvasSize.height / 2 - shadowPadding))
    }

    /// Offset that centres something on the pin's **head** rather than on its tip.
    ///
    /// The tip sits on the coordinate, so anything meant to ring the head has to be
    /// lifted by the tip plus half the head — otherwise it hangs under the pin,
    /// which is exactly where a fixed offset put it.
    func headCenterOffset(for scale: PinScale) -> CGPoint {
        CGPoint(x: 0, y: -(tipHeight(for: scale) + scale.headDiameter / 2))
    }

    // MARK: Lookup

    func pinImage(for key: Key) -> UIImage {
        if let cached = cache[key] { return cached }
        let image = renderPin(key)
        cache[key] = image
        order.append(key)
        if order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return image
    }

    func purge() {
        cache.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    // MARK: Rendering

    private func fillColor(for outcome: VisitOutcome?) -> UIColor {
        switch outcome {
        case .none: UIColor(red: 0.42, green: 0.47, blue: 0.56, alpha: 1)
        case .notHome: .systemRed
        case .earlyNo: .systemOrange
        case .lateNo: UIColor(red: 0.52, green: 0.54, blue: 0.58, alpha: 1)
        case .joined: .systemPink
        // Matches `VisitOutcome.later.tint`; the pin palette is hand-written here
        // because these are `UIColor`s baked into a rendered image cache.
        case .later: .systemIndigo
        }
    }

    /// Circle plus a separate tapered tip, appended into one path so the drop
    /// shadow reads as a single object. The white ring is stroked on the **circle
    /// only** — that is what gives this pin its original look.
    private func pinPath(head: CGRect, scale: PinScale) -> UIBezierPath {
        let centre = CGPoint(x: head.midX, y: head.midY)
        let tipHeight = tipHeight(for: scale)
        let tipWidth = tipWidth(for: scale)
        let tipBase = head.maxY - head.height * (3.0 / 34.0)

        let body = UIBezierPath(ovalIn: head)
        let tip = UIBezierPath()
        tip.move(to: CGPoint(x: centre.x - tipWidth / 2, y: tipBase))
        tip.addQuadCurve(
            to: CGPoint(x: centre.x, y: head.maxY + tipHeight),
            controlPoint: CGPoint(x: centre.x - tipWidth / 2.6, y: tipBase + tipHeight * 0.62)
        )
        tip.addQuadCurve(
            to: CGPoint(x: centre.x + tipWidth / 2, y: tipBase),
            controlPoint: CGPoint(x: centre.x + tipWidth / 2.6, y: tipBase + tipHeight * 0.62)
        )
        tip.close()
        body.append(tip)
        return body
    }

    private func renderPin(_ key: Key) -> UIImage {
        let size = canvasSize
        let head = headRect(for: key.scale)

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let cg = context.cgContext

            cg.saveGState()
            cg.setShadow(
                offset: CGSize(width: 0, height: 2),
                blur: key.isDark ? 5 : 4,
                color: UIColor.black.withAlphaComponent(key.isDark ? 0.55 : 0.3).cgColor
            )
            fillColor(for: key.outcome).setFill()
            pinPath(head: head, scale: key.scale).fill()
            cg.restoreGState()

            let ring = UIBezierPath(ovalIn: head.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
            ring.lineWidth = ringWidth
            UIColor.white.setStroke()
            ring.stroke()

            if key.isSelected {
                let halo = UIBezierPath(ovalIn: head.insetBy(dx: -2.5, dy: -2.5))
                halo.lineWidth = 3
                UIColor.systemBlue.setStroke()
                halo.stroke()
            }

            guard key.scale.showsGlyph, !key.text.isEmpty else { return }
            drawGlyph(key.text, in: head)
        }
    }

    private func drawGlyph(_ text: String, in rect: CGRect) {
        // Emoji render in their own colours; counters are white on the pin fill.
        let isEmoji = text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        let inset = rect.insetBy(dx: ringWidth + 0.5, dy: ringWidth + 0.5)

        let fontSize: CGFloat = isEmoji
            ? inset.height * 0.78
            : (text.count > 3 ? inset.height * 0.40 : inset.height * 0.50)

        func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            var result: [NSAttributedString.Key: Any] = [
                .font: isEmoji
                    ? UIFont.systemFont(ofSize: size)
                    : UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
                .paragraphStyle: paragraph
            ]
            if !isEmoji { result[.foregroundColor] = UIColor.white }
            return result
        }

        var attributed = NSAttributedString(string: text, attributes: attributes(fontSize))
        var bounds = attributed.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        // Shrink to fit rather than clipping a long "12/24".
        if bounds.width > inset.width {
            attributed = NSAttributedString(
                string: text,
                attributes: attributes(fontSize * (inset.width / bounds.width))
            )
            bounds = attributed.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
        }

        attributed.draw(in: CGRect(
            x: rect.midX - bounds.width / 2,
            y: rect.midY - bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        ))
    }
}
