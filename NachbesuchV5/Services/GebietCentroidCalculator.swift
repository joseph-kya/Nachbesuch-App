import CoreLocation
import Foundation

nonisolated enum GebietCentroidCalculator {
    /// Area-weighted centroid of a polygon (the shoelace formula).
    ///
    /// The previous implementation averaged the vertices. Boundaries here are traced
    /// by hand on a moving map, so vertex density is wildly uneven — a slowly-traced
    /// edge contributes dozens of points, a fast one contributes three — and the
    /// vertex mean is dragged toward the dense edge. It can land outside the polygon
    /// entirely. Since this point is the sole input to reverse geocoding, that meant
    /// a territory could be named after a neighbouring municipality.
    static func centroid(of boundary: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        let points = sanitized(boundary)
        guard !points.isEmpty else { return nil }
        guard points.count >= 3 else { return points.first }

        var twiceArea = 0.0
        var x = 0.0
        var y = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let cross = current.longitude * next.latitude - next.longitude * current.latitude
            twiceArea += cross
            x += (current.longitude + next.longitude) * cross
            y += (current.latitude + next.latitude) * cross
        }

        // A degenerate polygon (all points collinear or coincident) has zero area and
        // no meaningful centroid — fall back to the vertex mean there.
        guard abs(twiceArea) > 1e-12 else { return mean(points) }
        let factor = 1 / (3 * twiceArea)
        let candidate = CLLocationCoordinate2D(latitude: y * factor, longitude: x * factor)
        return StoredCoordinate(candidate).isPlausible ? candidate : mean(points)
    }

    /// Centroid of a loose set of points, e.g. the houses of a territory.
    static func centroid(ofCoordinates coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        let points = sanitized(coordinates)
        guard !points.isEmpty else { return nil }
        return mean(points)
    }

    /// Drops NaN, out-of-range values and null island — the last being what a failed
    /// geocode looks like, and enough to drag a Viennese centroid into the Atlantic.
    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(coordinates.count)
        for coordinate in coordinates where StoredCoordinate(coordinate).isPlausible {
            // A closed ring repeats its first vertex; counting it twice biases the mean.
            if let last = result.last,
               last.latitude == coordinate.latitude,
               last.longitude == coordinate.longitude {
                continue
            }
            result.append(coordinate)
        }
        if result.count > 2, let first = result.first, let last = result.last,
           first.latitude == last.latitude, first.longitude == last.longitude {
            result.removeLast()
        }
        return result
    }

    private static func mean(_ points: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        let latitude = points.reduce(0.0) { $0 + $1.latitude } / count
        let longitude = points.reduce(0.0) { $0 + $1.longitude } / count
        let candidate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return StoredCoordinate(candidate).isPlausible ? candidate : nil
    }
}
