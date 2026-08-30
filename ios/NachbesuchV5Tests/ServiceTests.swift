import CoreLocation
import CoreGraphics
import Foundation
import Testing
import UIKit
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

    /// The list draws this instead of the whole address, because the street is
    /// already the section header above the row.
    @Test("Hausnummer ist die Gegenprobe zum Straßennamen")
    func extractsHouseNumber() {
        #expect(StreetNameParser.houseNumber(from: "Am Augarten 3") == "3")
        #expect(StreetNameParser.houseNumber(from: "Teststraße 1, 1010 Wien") == "1")
        #expect(StreetNameParser.houseNumber(from: "Thaliastraße\u{00A0}12") == "12")
    }

    /// Punctuation is stripped from the street but must survive in the number:
    /// the slash in "12a/3" is part of what names the door.
    @Test("Nummernzusätze bleiben erhalten")
    func keepsHouseNumberQualifiers() {
        #expect(StreetNameParser.houseNumber(from: "Thaliastraße 12a/3") == "12a/3")
        #expect(StreetNameParser.houseNumber(from: "Kirchgasse 5 Stiege 2") == "5 Stiege 2")
    }

    /// `nil`, not an empty string — the row falls back to naming itself with the
    /// address when there is no number to show.
    @Test("Ohne Nummer gibt es keine Nummer")
    func hasNoHouseNumberWhenAddressHasNone() {
        #expect(StreetNameParser.houseNumber(from: "Hauptplatz") == nil)
        #expect(StreetNameParser.houseNumber(from: "Am Hof, 1010 Wien") == nil)
        #expect(StreetNameParser.houseNumber(from: "12 Hauptstraße") == nil)
    }

    @Test("PLZ und Ort fallen weg")
    func dropsLocality() {
        #expect(StreetNameParser.withoutLocality("Am Sonnenhang 6, 9210 Pörtschach") == "Am Sonnenhang 6")
        #expect(StreetNameParser.withoutLocality("Hauptplatz") == "Hauptplatz")
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
        // Zwei: die unerfasste Tür des dritten Hauses **und** das „Niemand da" des
        // ersten. Hier stand 1, weil die Karte „offen" als `unitCount - completed`
        // gerechnet hat — also nur die noch gar nicht angefassten Türen. Eine Tür
        // mit „Niemand da" ist erfasst und trotzdem offen; genau deshalb meldete die
        // Karte 12, wo die Liste fürs selbe Gebiet 40 meldete.
        #expect(snapshot.stats.openCount == 2)
    }

    /// Ein Haus, dessen einzige ausstehende Tür eine gebuchte Uhrzeit hat, galt als
    /// erledigt: die Tür *ist* erfasst, also `completedCount == unitCount`, und sie
    /// ist nicht `notHome`, also war `followUpCount` 0. Ein Haus, an dem man um
    /// 18:00 zugesagt hat, fiel damit aus jeder Zählung offener Arbeit heraus.
    @Test("Ein Haus mit gebuchtem „Später“ hat offene Arbeit")
    func laterDoorCountsAsOpen() {
        let pin = MapPinSnapshotBuilder.pin(
            for: raw([DoorResult(label: "1", outcome: .later, revisitAt: .now.addingTimeInterval(3600))]),
            scope: .combined
        )
        #expect(pin.openCount == 1)
        #expect(pin.hasOpenWork)
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
        let offset = cache.centerOffset
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
    @Test("Der Pin hängt über seiner Koordinate")
    func theAnchorSitsAboveTheCoordinate() {
        let offset = PinArtCache.shared.centerOffset
        #expect(offset.y < 0)
        #expect(offset.x == 0)
    }

    /// The invariant that makes resizing race-free.
    ///
    /// Every tier must render into the same bitmap. If a tier change altered
    /// `bounds`, the per-frame tier swap would move geometry MapKit is positioning
    /// mid-gesture, and the pin could end up off its coordinate — a timing-dependent
    /// failure that reproduces on some zooms and not others.
    @MainActor
    @Test("Alle Pin-Größen teilen sich dieselbe Bitmap-Größe")
    func everyScaleSharesTheCanvas() {
        let cache = PinArtCache.shared
        let reference = cache.pinImage(for: PinArtCache.Key(
            outcome: .joined, text: "", isSelected: false, isDark: false, scale: .full
        ))

        for scale in [PinScale.full, .compact, .dot] {
            let image = cache.pinImage(for: PinArtCache.Key(
                outcome: .joined, text: "", isSelected: false, isDark: false, scale: scale
            ))
            #expect(
                image.size == reference.size,
                "\(scale) rendert in eine andere Bitmap-Größe — ein Größenwechsel würde bounds ändern"
            )
        }
    }

    /// The canvas is shared, so a smaller tier has to be drawn *up from the tip*
    /// rather than centred in the bitmap. Sizes matching is not enough — if the head
    /// rectangle were still anchored at the top-left padding, every dot would render
    /// high inside its canvas and sit visibly above its house.
    @MainActor
    @Test("Jede Größe wird an der Spitze verankert gezeichnet")
    func everyScaleIsDrawnAnchoredAtTheTip() throws {
        let cache = PinArtCache.shared

        func alpha(_ image: UIImage, atFractionX fx: CGFloat, fractionY fy: CGFloat) throws -> Int {
            let cg = try #require(image.cgImage)
            let x = min(max(Int(CGFloat(cg.width) * fx), 0), cg.width - 1)
            let y = min(max(Int(CGFloat(cg.height) * fy), 0), cg.height - 1)
            var pixel = [UInt8](repeating: 0, count: 4)
            let space = CGColorSpaceCreateDeviceRGB()
            let context = try #require(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
            return Int(pixel[3])
        }

        for scale in [PinScale.full, .compact, .dot] {
            let image = cache.pinImage(for: PinArtCache.Key(
                outcome: .joined, text: "", isSelected: false, isDark: false, scale: scale
            ))
            // Just above the tip: every tier must have ink here.
            let atTip = try alpha(image, atFractionX: 0.5, fractionY: 0.92)
            #expect(atTip > 0, "\(scale) zeichnet nichts an der Spitze")
        }

        // The smallest tier must leave the top of the shared canvas empty — that is
        // what proves it grew upward from the tip instead of down from the padding.
        let dot = cache.pinImage(for: PinArtCache.Key(
            outcome: .joined, text: "", isSelected: false, isDark: false, scale: .dot
        ))
        #expect(try alpha(dot, atFractionX: 0.5, fractionY: 0.05) == 0, "Punkt-Pin klebt oben statt an der Spitze")
    }

    /// The guard against sizes that depend on how you got to a zoom level.
    ///
    /// The tier used to come out of a transition table seeded with the previous
    /// tier, so zooming out to 2 km and zooming in to 2 km produced different pins,
    /// and a fast pinch that skipped a band stayed a tier behind. A pure function
    /// cannot do either, and this pins that down.
    @MainActor
    @Test("Die Pin-Größe hängt nur vom Zoom ab, nicht vom Weg dorthin")
    func pinScaleDependsOnlyOnZoom() {
        #expect(MapCoordinator.scale(forMetersAcross: 300) == .full)
        #expect(MapCoordinator.scale(forMetersAcross: 2_000) == .compact)
        #expect(MapCoordinator.scale(forMetersAcross: 9_000) == .dot)

        // Every zoom, approached from both directions and in arbitrary jumps, has
        // exactly one answer.
        let zooms = [80.0, 500, 1_399, 1_400, 2_999, 3_000, 12_000, 50_000]
        for meters in zooms {
            let expected = MapCoordinator.scale(forMetersAcross: meters)
            for _ in 0..<3 {
                #expect(MapCoordinator.scale(forMetersAcross: meters) == expected)
            }
        }
        // Monotonic: zooming out never makes a pin bigger.
        let order: [PinScale: Int] = [.full: 0, .compact: 1, .dot: 2]
        for (near, far) in zip(zooms, zooms.dropFirst()) {
            let a = order[MapCoordinator.scale(forMetersAcross: near)]!
            let b = order[MapCoordinator.scale(forMetersAcross: far)]!
            #expect(a <= b, "\(near) m → \(far) m lässt den Pin wachsen")
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
            houseNumber: StreetNameParser.houseNumber(from: address),
            shortAddress: StreetNameParser.withoutLocality(address),
            markerOutcome: nil, unitCount: 1, completedCount: 0,
            followUpCount: 0, joinedCount: 0, laterCount: 0, openCount: 1,
            createdAt: .now, searchText: "", latitude: latitude, longitude: longitude,
            recordedAt: nil, nextRevisitAt: nil
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
