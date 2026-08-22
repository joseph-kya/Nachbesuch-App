import CoreLocation
import Foundation
import MapKit
import Testing
@testable import NachbesuchV5

@Suite("Straßennamen")
struct StreetNameParserTests {

    @Test("Hausnummer wird abgetrennt")
    func splitsAtHouseNumber() {
        #expect(StreetNameParser.street(from: "Thaliastraße 12a/3") == "Thaliastraße")
        #expect(StreetNameParser.street(from: "Am Augarten 3") == "Am Augarten")
    }

    /// The app's own OSM importer emits "<Straße> <Nr>, <PLZ> <Ort>". Without
    /// truncating at the comma an address with no house number took the postal code
    /// for one, producing a street with a trailing comma — a duplicate section in the
    /// list, right next to the correct one.
    @Test("Importer-Format mit Komma erzeugt keine Doppel-Sektion")
    func handlesImporterFormat() {
        #expect(StreetNameParser.street(from: "Teststraße 1, 1010 Wien") == "Teststraße")
        #expect(StreetNameParser.street(from: "Am Hof, 1010 Wien") == "Am Hof")
    }

    @Test("Geschützte Leerzeichen brechen die Erkennung nicht")
    func handlesNonBreakingSpace() {
        #expect(StreetNameParser.street(from: "Thaliastraße\u{00A0}12") == "Thaliastraße")
    }

    @Test("Ohne Hausnummer bleibt die Eingabe erhalten")
    func fallsBackWithoutHouseNumber() {
        #expect(StreetNameParser.street(from: "Hauptplatz") == "Hauptplatz")
        #expect(StreetNameParser.street(from: "12 Hauptstraße") == "12 Hauptstraße")
    }
}

@Suite("Gebiets-Schwerpunkt")
struct CentroidTests {

    /// A hand-traced boundary has wildly uneven vertex density. The vertex mean was
    /// dragged toward whichever edge was traced slowly — and since this point is the
    /// only input to reverse geocoding, a territory could be named after the wrong
    /// municipality.
    @Test("Ungleich dichte Stützpunkte verschieben den Schwerpunkt nicht")
    func denseEdgeDoesNotSkewCentroid() throws {
        // Real coordinates, not a unit square at the origin — (0, 0) is deliberately
        // rejected as null island, which is what a failed geocode looks like.
        let south = 48.0, north = 48.2, west = 16.0, east = 16.2
        var square: [CLLocationCoordinate2D] = [
            .init(latitude: south, longitude: west),
            .init(latitude: south, longitude: east)
        ]
        // Twenty extra points along one edge, as a slowly-traced finger produces.
        for step in 1..<20 {
            square.append(.init(latitude: south + (north - south) * Double(step) / 20, longitude: east))
        }
        square.append(.init(latitude: north, longitude: east))
        square.append(.init(latitude: north, longitude: west))

        let centroid = try #require(GebietCentroidCalculator.centroid(of: square))
        #expect(abs(centroid.latitude - 48.1) < 0.01)
        #expect(abs(centroid.longitude - 16.1) < 0.01)

        let vertexMean = try #require(GebietCentroidCalculator.centroid(ofCoordinates: square))
        #expect(vertexMean.longitude > centroid.longitude, "Der reine Mittelwert kippt zur dichten Kante")
    }

    @Test("Ein einfaches Quadrat hat seinen Mittelpunkt in der Mitte")
    func simpleSquare() throws {
        let square: [CLLocationCoordinate2D] = [
            .init(latitude: 48.0, longitude: 16.0),
            .init(latitude: 48.0, longitude: 16.2),
            .init(latitude: 48.2, longitude: 16.2),
            .init(latitude: 48.2, longitude: 16.0)
        ]
        let centroid = try #require(GebietCentroidCalculator.centroid(of: square))
        #expect(abs(centroid.latitude - 48.1) < 0.0001)
        #expect(abs(centroid.longitude - 16.1) < 0.0001)
    }

    @Test("Null Island wird verworfen")
    func rejectsNullIsland() {
        let coordinates: [CLLocationCoordinate2D] = [
            .init(latitude: 0, longitude: 0),
            .init(latitude: 48.2, longitude: 16.3)
        ]
        let centroid = GebietCentroidCalculator.centroid(ofCoordinates: coordinates)
        #expect(centroid?.latitude ?? 0 > 40, "Ein fehlgeschlagener Geocode darf den Schwerpunkt nicht in den Atlantik ziehen")
    }
}

@Suite("Archivsuche")
struct ArchiveSearchTests {

    private func makeIndex(
        name: String = "Mödling",
        addresses: String = "Hauptstraße 1",
        open: Int = 0,
        joined: Int = 0,
        date: Date = .now
    ) -> (ArchiveIndex, UUID) {
        let id = UUID()
        var overall = OutcomeTally.empty
        overall.unitCount = 4
        overall.completed = 4 - open
        overall.open = open
        overall.joined = joined
        let entry = ArchiveEntry(
            gebietID: id,
            houseCount: 1,
            overall: overall,
            day1: overall,
            day2: .empty,
            pendingRevisits: open,
            searchText: SearchText.fold("\(name) \(addresses)"),
            dateText: SearchText.fold(
                "\(date.formatted(.dateTime.weekday(.wide))) heute"
            ),
            day1Date: Gebiet.campaignCalendar.startOfDay(for: date),
            day2Date: nil
        )
        return (ArchiveIndex(entries: [id: entry]), id)
    }

    @Test("Umlaut-unempfindliche Suche")
    func diacriticInsensitive() {
        let (index, id) = makeIndex()
        let results = ArchiveSearchEngine.search(query: "modling", index: index, order: [id])
        #expect(results.count == 1)
    }

    @Test("Mehrwortsuche verlangt alle Begriffe")
    func allTokensMustMatch() {
        let (index, id) = makeIndex()
        #expect(ArchiveSearchEngine.search(query: "mödling hauptstraße", index: index, order: [id]).count == 1)
        #expect(ArchiveSearchEngine.search(query: "mödling wien", index: index, order: [id]).isEmpty)
    }

    /// Keyword tables used to be raw literals compared against folded tokens, so a
    /// user typing "übermorgen" produced "ubermorgen" and the word was unreachable.
    @Test("Relative Datumswörter funktionieren auch mit Umlaut")
    func relativeDateKeywordsWork() throws {
        let calendar = Gebiet.campaignCalendar
        let dayAfterTomorrow = try #require(
            calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: .now))
        )
        let (index, id) = makeIndex(date: dayAfterTomorrow)
        #expect(ArchiveSearchEngine.search(query: "übermorgen", index: index, order: [id]).count == 1)
        #expect(ArchiveSearchEngine.search(query: "ubermorgen", index: index, order: [id]).count == 1)
        #expect(ArchiveSearchEngine.search(query: "heute", index: index, order: [id]).isEmpty)
    }

    @Test("Statuswörter filtern nach Ergebnis")
    func statusKeywords() {
        let (openIndex, openID) = makeIndex(open: 2)
        #expect(ArchiveSearchEngine.search(query: "offen", index: openIndex, order: [openID]).count == 1)

        let (doneIndex, doneID) = makeIndex(open: 0, joined: 1)
        #expect(ArchiveSearchEngine.search(query: "offen", index: doneIndex, order: [doneID]).isEmpty)
        #expect(ArchiveSearchEngine.search(query: "dabei", index: doneIndex, order: [doneID]).count == 1)
    }

    @Test("Namenstreffer ranken vor Adresstreffern")
    func nameRanksAboveAddress() {
        let nameID = UUID()
        let addressID = UUID()
        let base = OutcomeTally.empty
        func entry(id: UUID, text: String) -> ArchiveEntry {
            ArchiveEntry(
                gebietID: id, houseCount: 1, overall: base, day1: base, day2: base,
                pendingRevisits: 0,
                searchText: SearchText.fold(text), dateText: "",
                day1Date: .now, day2Date: nil
            )
        }
        let index = ArchiveIndex(entries: [
            nameID: entry(id: nameID, text: "Ottakring Testgasse 1"),
            addressID: entry(id: addressID, text: "Mödling Ottakringer Straße 5")
        ])
        let results = ArchiveSearchEngine.search(query: "ottakring", index: index, order: [addressID, nameID])
        #expect(results.first?.gebietID == nameID)
    }
}

@Suite("Bilanz")
struct BilanzTests {

    private func seed(_ doors: [DoorResult]) -> BilanzStatsEngine.HouseSeed {
        BilanzStatsEngine.HouseSeed(unitsData: try! AppCoders.unitsEncoder().encode(doors))
    }

    @Test("Tag 1 und Tag 2 werden getrennt gezählt")
    func daysAreSeparate() {
        let snapshot = BilanzStatsEngine.build(from: [
            seed([
                DoorResult(label: "1", outcome: .notHome),
                DoorResult(label: "2", outcome: .joined),
                DoorResult(label: "3", outcome: .notHome, day2Outcome: .joined),
                DoorResult(label: "4")
            ])
        ])
        #expect(snapshot.day1.completed == 3)
        #expect(snapshot.day2.completed == 1, "Nur die echte Zweitbesuchs-Eintragung zählt")
        #expect(snapshot.overall.completed == 3)
        #expect(snapshot.overall.joined == 2)
        #expect(snapshot.pendingRevisits == 1, "Tür 1 wartet noch")
        #expect(snapshot.revisitTargets == 3, "Türen 1, 3 und 4 waren Ziele")
    }

    @Test("Der Tag-2-Fortschritt misst an den Nachbesuchs-Zielen")
    func day2ProgressUsesTargets() {
        let snapshot = BilanzStatsEngine.build(from: [
            seed([
                DoorResult(label: "1", outcome: .joined),
                DoorResult(label: "2", outcome: .joined),
                DoorResult(label: "3", outcome: .notHome, day2Outcome: .lateNo)
            ])
        ])
        #expect(snapshot.revisitTargets == 1)
        #expect(snapshot.day2Progress == 1.0, "Das einzige Ziel wurde erreicht → 100 %")
    }
}

@Suite("Kartenpins")
struct MapPinTests {

    private func raw(_ doors: [DoorResult], address: String = "Teststraße 1") -> RawMapHouse {
        RawMapHouse(
            id: UUID(), address: address, latitude: 48.2, longitude: 16.3,
            unitsData: try! AppCoders.unitsEncoder().encode(doors)
        )
    }

    @Test("Pin-Snapshot zählt Marker und Tageszähler in einem Durchlauf")
    func buildsCounts() {
        let snapshot = MapPinSnapshotBuilder.build(
            from: [
                raw([DoorResult(label: "1", outcome: .notHome)]),
                raw([DoorResult(label: "1", outcome: .joined)]),
                raw([DoorResult(label: "1"), DoorResult(label: "2", outcome: .joined)])
            ],
            scope: .combined
        )
        #expect(snapshot.stats.houseCount == 3)
        #expect(snapshot.stats.followUpCount == 1)
        #expect(snapshot.stats.joinedCount == 2)
        #expect(snapshot.stats.openCount == 1)
    }

    @Test("Marker-Text folgt dem Tagesbereich")
    func markerTextFollowsScope() {
        let house = raw([DoorResult(label: "1", outcome: .notHome)])
        let day2Pin = MapPinSnapshotBuilder.pin(for: house, scope: .day2)
        #expect(day2Pin.markerOutcome == nil, "Am Tag 2 ist die Tür wieder offen")
        let combinedPin = MapPinSnapshotBuilder.pin(for: house, scope: .combined)
        #expect(combinedPin.markerOutcome == .notHome)
    }

    @Test("Patch aktualisiert nur die geänderten Pins")
    func patchIsSurgical() {
        let unchanged = raw([DoorResult(label: "1", outcome: .joined)], address: "A 1")
        let changing = raw([DoorResult(label: "1")], address: "B 2")
        let base = MapPinSnapshotBuilder.build(from: [unchanged, changing], scope: .combined)
        #expect(base.stats.joinedCount == 1)

        let updated = RawMapHouse(
            id: changing.id, address: changing.address,
            latitude: changing.latitude, longitude: changing.longitude,
            unitsData: try! AppCoders.unitsEncoder().encode([DoorResult(label: "1", outcome: .notHome)])
        )
        let patched = MapPinSnapshotBuilder.patch(base, with: [updated], scope: .combined)
        #expect(patched.pinsByID.count == 2)
        #expect(patched.stats.joinedCount == 1, "Der unveränderte Pin bleibt gezählt")
        #expect(patched.stats.followUpCount == 1)
    }

    @Test("Unbrauchbare Koordinaten erreichen MapKit nicht")
    func invalidCoordinatesAreExcluded() {
        let valid = raw([DoorResult(label: "1")])
        let invalid = RawMapHouse(
            id: UUID(), address: "Ohne Position", latitude: 0, longitude: 0,
            unitsData: try! AppCoders.unitsEncoder().encode([DoorResult(label: "1", outcome: .joined)])
        )
        let snapshot = MapPinSnapshotBuilder.build(from: [valid, invalid], scope: .combined)
        #expect(snapshot.pinsByID.count == 1)
        #expect(snapshot.stats.houseCount == 1)
        #expect(snapshot.stats.joinedCount == 0)
    }

    @Test("Ein räumlicher Patch berechnet den Ausschnitt neu")
    func spatialPatchRebuildsBounds() throws {
        let original = raw([DoorResult(label: "1")])
        let base = MapPinSnapshotBuilder.build(from: [original], scope: .combined)
        let moved = RawMapHouse(
            id: original.id, address: original.address,
            latitude: 47.0, longitude: 15.0, unitsData: original.unitsData
        )
        let patched = MapPinSnapshotBuilder.patch(base, with: [moved], scope: .combined)
        let bounds = try #require(patched.bounds)
        #expect(abs(bounds.center.latitude - 47.0) < 0.0001)
        #expect(abs(bounds.center.longitude - 15.0) < 0.0001)
    }

    /// 10 000 houses is well past a realistic territory; the snapshot build is the
    /// only O(n) step in the pin pipeline and must stay off the critical path.
    @Test("Zehntausend Häuser bleiben in einem Durchlauf verarbeitbar")
    func scalesToTenThousand() {
        let doors = [DoorResult(label: "1", outcome: .notHome)]
        let data = try! AppCoders.unitsEncoder().encode(doors)
        let houses = (0..<10_000).map { index in
            RawMapHouse(
                id: UUID(), address: "Straße \(index)",
                latitude: 48.2 + Double(index) * 0.00001,
                longitude: 16.3, unitsData: data
            )
        }
        let snapshot = MapPinSnapshotBuilder.build(from: houses, scope: .combined)
        #expect(snapshot.pinsByID.count == 10_000)
        #expect(snapshot.stats.followUpCount == 10_000)
    }
}

@Suite("Pin-Grafik")
struct PinArtTests {

    @MainActor
    @Test("Gleiche Variante liefert dasselbe zwischengespeicherte Bild")
    func cachesByVariant() {
        let cache = PinArtCache.shared
        let key = PinArtCache.Key(
            outcome: .notHome, text: "🔴", isSelected: false, isDark: false, scale: .full
        )
        #expect(cache.pinImage(for: key) === cache.pinImage(for: key))
    }

    @MainActor
    @Test("Die Pin-Spitze sitzt auf der Koordinate")
    func anchorSitsOnTip() {
        let cache = PinArtCache.shared
        let offset = cache.centerOffset(for: .full)
        #expect(offset.y < 0, "Der Pin hängt über seiner Koordinate")
        #expect(offset.x == 0)
    }

    /// The whole point of the rewrite: zooming out must not silently strip the
    /// emoji off every pin.
    @MainActor
    @Test("Der Glyph überlebt die kleinere Pin-Größe")
    func glyphSurvivesCompactScale() {
        #expect(PinScale.full.showsGlyph)
        #expect(PinScale.compact.showsGlyph)
        #expect(!PinScale.dot.showsGlyph, "Nur die reine Punkt-Stufe verzichtet auf den Glyph")
        #expect(PinScale.compact.headDiameter < PinScale.full.headDiameter)
        #expect(PinScale.dot.headDiameter < PinScale.compact.headDiameter)
    }

    @MainActor
    @Test("Große Zoomsprünge landen sofort in der richtigen Pin-Stufe")
    func largeZoomJumpsDoNotNeedASecondCallback() {
        #expect(MapPinPresentationPolicy.scale(current: .full, metersAcross: 8_000) == .dot)
        #expect(MapPinPresentationPolicy.scale(current: .dot, metersAcross: 700) == .full)
    }

    @MainActor
    @Test("Pin-Größen haben stabile Hysterese")
    func pinScaleHysteresisIsStable() {
        #expect(MapPinPresentationPolicy.scale(current: .full, metersAcross: 1_500) == .full)
        #expect(MapPinPresentationPolicy.scale(current: .full, metersAcross: 1_700) == .compact)
        #expect(MapPinPresentationPolicy.scale(current: .compact, metersAcross: 1_400) == .compact)
        #expect(MapPinPresentationPolicy.scale(current: .compact, metersAcross: 1_200) == .full)
        #expect(MapPinPresentationPolicy.scale(current: .dot, metersAcross: 3_000) == .dot)
        #expect(MapPinPresentationPolicy.scale(current: .dot, metersAcross: 2_700) == .compact)
    }

    @MainActor
    @Test("Cluster-Grenzen flackern nicht am selben Zoom")
    func clusterGateHasHysteresis() {
        #expect(MapPinPresentationPolicy.clusters(
            currentlyEnabled: false, metersAcross: 3_100, visiblePins: 200
        ) == false)
        #expect(MapPinPresentationPolicy.clusters(
            currentlyEnabled: false, metersAcross: 3_300, visiblePins: 200
        ))
        #expect(MapPinPresentationPolicy.clusters(
            currentlyEnabled: true, metersAcross: 2_600, visiblePins: 200
        ))
        #expect(MapPinPresentationPolicy.clusters(
            currentlyEnabled: true, metersAcross: 2_300, visiblePins: 200
        ) == false)
    }

    @MainActor
    @Test("Viele sichtbare Pins aktivieren den Sicherheits-Cluster unabhängig vom Zoom")
    func densityCanEnableClustering() {
        #expect(MapPinPresentationPolicy.clusters(
            currentlyEnabled: false, metersAcross: 900, visiblePins: 1_200
        ))
        #expect(MapPinPresentationPolicy.clusters(
            currentlyEnabled: true, metersAcross: 900, visiblePins: 900
        ))
        #expect(MapPinPresentationPolicy.clusters(
            currentlyEnabled: true, metersAcross: 900, visiblePins: 800
        ) == false)
    }

    @MainActor
    @Test("Kartenausschnitt wird aus horizontalen MapKit-Metern berechnet")
    func viewportWidthUsesMapPoints() {
        #expect(MapPinPresentationPolicy.viewportMetersAcross(
            mapPointsAcross: 500, metersPerMapPoint: 2
        ) == 1_000)
        #expect(MapPinPresentationPolicy.viewportMetersAcross(
            mapPointsAcross: .infinity, metersPerMapPoint: 2
        ) == 0)
    }

    @MainActor
    @Test("Clustergrößen wachsen nur in wenigen stabilen Stufen")
    func clusterDiameterUsesStableTiers() {
        #expect(MapPinPresentationPolicy.clusterDiameter(for: 2) == 42)
        #expect(MapPinPresentationPolicy.clusterDiameter(for: 9) == 42)
        #expect(MapPinPresentationPolicy.clusterDiameter(for: 10) == 46)
        #expect(MapPinPresentationPolicy.clusterDiameter(for: 99) == 46)
        #expect(MapPinPresentationPolicy.clusterDiameter(for: 100) == 52)
    }

    @MainActor
    @Test("Jede Größe hängt über ihrer Koordinate")
    func everyScaleAnchorsOnTheTip() {
        for scale in [PinScale.full, .compact, .dot] {
            let offset = PinArtCache.shared.centerOffset(for: scale)
            #expect(offset.y < 0)
            #expect(offset.x == 0)
        }
    }

    @MainActor
    @Test("Große Zahlen werden abgekürzt")
    func abbreviatesLargeCounts() {
        #expect(PinArtCache.abbreviated(42) == "42")
        #expect(PinArtCache.abbreviated(1500) == "1.5k")
        #expect(PinArtCache.abbreviated(24000) == "24k")
    }
}

@Suite("MapKit-Clusterübergang")
struct MapClusterTransitionTests {

    @MainActor
    @Test("Nach maximalem Herauszoomen entstehen frische, exakt positionierte Pins")
    func farOutThenBackInRebuildsAnnotationIdentity() throws {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let coordinator = MapCoordinator()
        mapView.delegate = coordinator
        coordinator.mapView = mapView

        let data = try AppCoders.unitsEncoder().encode([DoorResult(label: "1")])
        let raw = [
            RawMapHouse(
                id: UUID(), address: "A 1", latitude: 48.2100,
                longitude: 16.3100, unitsData: data
            ),
            RawMapHouse(
                id: UUID(), address: "A 2", latitude: 48.2105,
                longitude: 16.3105, unitsData: data
            )
        ]
        let snapshot = MapPinSnapshotBuilder.build(from: raw, scope: .combined)

        mapView.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.21, longitude: 16.31),
            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
        ), animated: false)
        coordinator.applyData(
            mapView, pins: snapshot, structuralVersion: 1, contentVersion: 1,
            changedHouseIDs: [], selectedHouseIDs: nil
        )
        let before = Dictionary(uniqueKeysWithValues: mapView.annotations.compactMap {
            ($0 as? HouseAnnotation).map { ($0.houseID, $0) }
        })
        #expect(before.count == 2)

        mapView.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.21, longitude: 16.31),
            span: MKCoordinateSpan(latitudeDelta: 0.001, longitudeDelta: 0.001)
        ), animated: false)
        coordinator.updateClusteringGate(mapView)

        let after = Dictionary(uniqueKeysWithValues: mapView.annotations.compactMap {
            ($0 as? HouseAnnotation).map { ($0.houseID, $0) }
        })
        #expect(after.count == before.count)
        for house in raw {
            let old = try #require(before[house.id])
            let fresh = try #require(after[house.id])
            #expect(old !== fresh, "Alte MapKit-Clusteridentität darf nicht wiederverwendet werden")
            #expect(fresh.coordinate.latitude == house.latitude)
            #expect(fresh.coordinate.longitude == house.longitude)
        }
    }
}

@Suite("Adress-Normalisierung")
struct AddressNormalizerTests {

    /// The manual sheet and the bulk importer used to fold differently, so they
    /// disagreed about what counted as the same address.
    @Test("Manuelle Eingabe und Import normalisieren identisch")
    func sharedNormalization() {
        #expect(AddressNormalizer.normalize("Thaliastraße 12") == AddressNormalizer.normalize("THALIASTRASSE 12"))
        #expect(AddressNormalizer.normalize("Mödlinger Gasse 3") == AddressNormalizer.normalize("Modlinger  Gasse 3"))
    }

    @Test("Unterschiedliche Adressen bleiben unterschiedlich")
    func distinctAddressesStayDistinct() {
        #expect(AddressNormalizer.normalize("Hauptstraße 1") != AddressNormalizer.normalize("Hauptstraße 2"))
    }
}

@Suite("Gebietsausschnitt")
struct MapBoundsTests {

    @Test("Der Ausschnitt umschließt alle Pins")
    func boundsCoverAllPins() throws {
        let bounds = try #require(MapBounds.around([
            .init(latitude: 48.20, longitude: 16.30),
            .init(latitude: 48.24, longitude: 16.36),
            .init(latitude: 48.22, longitude: 16.33)
        ]))
        #expect(abs(bounds.center.latitude - 48.22) < 0.0001)
        #expect(abs(bounds.center.longitude - 16.33) < 0.0001)
        // Mit Rand, damit Pins nicht am Bildschirmrand kleben.
        #expect(bounds.region.span.latitudeDelta > 0.04)
    }

    /// Ein einzelnes Haus darf keinen Ausschnitt der Breite null erzeugen — MapKit
    /// kommt aus einer Region ohne Ausdehnung nicht mehr heraus.
    @Test("Ein einzelnes Haus bekommt eine brauchbare Mindestgröße")
    func singleHouseGetsUsableSpan() throws {
        let bounds = try #require(MapBounds.around([.init(latitude: 48.21, longitude: 16.31)]))
        #expect(bounds.region.span.latitudeDelta >= 0.004)
        #expect(bounds.region.isUsable)
    }

    @Test("Unbrauchbare Koordinaten fließen nicht ein")
    func rejectsImplausibleCoordinates() throws {
        let bounds = try #require(MapBounds.around([
            .init(latitude: 0, longitude: 0),
            .init(latitude: 48.21, longitude: 16.31)
        ]))
        #expect(bounds.minLatitude > 40, "Null Island darf den Ausschnitt nicht aufziehen")
    }

    @Test("Ohne Koordinaten gibt es keinen Ausschnitt")
    func emptyInputHasNoBounds() {
        #expect(MapBounds.around([]) == nil)
    }

    @Test("Der Pin-Aufbau liefert den Ausschnitt gleich mit")
    func snapshotCarriesBounds() throws {
        let doors = [DoorResult(label: "Haushalt", outcome: .joined)]
        let data = try AppCoders.unitsEncoder().encode(doors)
        let snapshot = MapPinSnapshotBuilder.build(
            from: [
                RawMapHouse(id: UUID(), address: "A 1", latitude: 48.20, longitude: 16.30, unitsData: data),
                RawMapHouse(id: UUID(), address: "B 2", latitude: 48.24, longitude: 16.36, unitsData: data)
            ],
            scope: .combined
        )
        let bounds = try #require(snapshot.bounds)
        #expect(abs(bounds.center.latitude - 48.22) < 0.0001)
    }
}

@Suite("Entfernungs-Sortierung")
struct DistanceSortTests {

    private func row(_ address: String, latitude: Double, longitude: Double) -> HouseRowModel {
        HouseRowModel(
            id: UUID(), address: address, note: "", street: "Teststraße",
            markerOutcome: nil, unitCount: 1, completedCount: 0,
            followUpCount: 0, joinedCount: 0, openCount: 1,
            createdAt: .now, searchText: "", latitude: latitude, longitude: longitude,
            recordedAt: nil
        )
    }

    @Test("Näheres Haus steht vorne")
    func nearestComesFirst() {
        let origin = CLLocationCoordinate2D(latitude: 48.2100, longitude: 16.3100)
        let sorted = HouseListBuilder.sortByDistance([
            row("Weit", latitude: 48.2200, longitude: 16.3200),
            row("Nah", latitude: 48.2101, longitude: 16.3101)
        ], from: origin)
        #expect(sorted.map(\.address) == ["Nah", "Weit"])
    }

    @Test("Die Entfernung wird realistisch berechnet")
    func distanceIsRealistic() throws {
        let origin = CLLocationCoordinate2D(latitude: 48.2100, longitude: 16.3100)
        // Rund 111 m nördlich.
        let sorted = HouseListBuilder.sortByDistance(
            [row("Nord", latitude: 48.2110, longitude: 16.3100)], from: origin
        )
        let distance = try #require(sorted.first?.distance)
        #expect(abs(distance - 110.5) < 5)
    }

    @Test("Entfernungen werden lesbar formatiert")
    func formatsDistance() {
        var near = row("A", latitude: 0, longitude: 0)
        near.distance = 84
        #expect(near.formattedDistance == "80 m")

        var far = row("B", latitude: 0, longitude: 0)
        far.distance = 2340
        #expect(far.formattedDistance == "2,3 km" || far.formattedDistance == "2.3 km")

        let unknown = row("C", latitude: 0, longitude: 0)
        #expect(unknown.formattedDistance == nil, "Ohne Standort keine Entfernung")
    }
}
