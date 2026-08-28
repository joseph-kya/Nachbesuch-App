import CoreLocation
import MapKit

enum MapNavigation {
    static func openWalkingRoute(to house: House) {
        openWalkingRoute(to: house.coordinate, name: house.address)
    }

    static func openWalkingRoute(to coordinate: CLLocationCoordinate2D, name: String) {
        let item = mapItem(at: coordinate)
        item.name = name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    /// `MKMapItem(location:address:)` is iOS 26-only; the placemark initialiser it
    /// replaced is deprecated there but is the only one that exists on iOS 18.
    private static func mapItem(at coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #available(iOS 26, *) {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return MKMapItem(location: location, address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }
}
