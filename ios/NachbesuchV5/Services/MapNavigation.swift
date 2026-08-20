import CoreLocation
import MapKit

enum MapNavigation {
    static func openWalkingRoute(to house: House) {
        openWalkingRoute(to: house.coordinate, name: house.address)
    }

    static func openWalkingRoute(to coordinate: CLLocationCoordinate2D, name: String) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        item.name = name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }
}
