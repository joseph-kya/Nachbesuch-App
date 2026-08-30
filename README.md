# Nachbesuch

Native Apps für Haustür-Nachbesuche auf iOS und Android.

- `ios/` — produktive SwiftUI/SwiftData-App für iOS 26 mit Swift 6
- `android/` — native Kotlin/Compose-App mit eigenem Build und [Portierungsstatus](android/porting-status.md)
- `scripts/` — lokale Sicherheitsprüfungen für Git

Die beiden Apps teilen dieselbe fachliche Bedeutung für Gebiete, Häuser, Türen,
Tag 1/Tag 2, Backup und Export. Ihre Implementierungen und Build-Systeme bleiben
klar getrennt.

## Arbeiten an diesem Projekt

    git clone https://github.com/joseph-kya/Nachbesuch-App.git && cd Nachbesuch-App
    ln -sf ../../scripts/pre-commit .git/hooks/pre-commit   # blockt Felddaten im Commit

    cd ios
    xcodebuild -scheme NachbesuchV5 -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

    cd ../android
    ./gradlew test

- `next-steps.md` — was als Nächstes zu tun ist, in welcher Reihenfolge
- `status.md` — was gerade läuft, was blockiert ist
- `porting.md` — fachlicher Android-Portierungsplan und Paritätsvertrag
- `android/API_KEY_SECURITY.md` — verbindliche Regeln für Google Maps auf Android

---

## iOS-App

**iOS 26 · Xcode 26 · Swift 6 · Bundle-ID `at.volkshilfe.nachbesuch.v5`**

Version 6 ist eine vollständige Überarbeitung von Version 5. Die **gespeicherte
Datenform ist unverändert** — bestehende Installationen behalten ihre Gebiete,
Häuser und Ergebnisse, ohne Backup-Import.

## Die drei Tabs

**Karte** — die Arbeitsoberfläche. Pins setzen, Status eintragen, Gebiet zeichnen,
OSM-Import, Satellit, Orte ein-/ausblenden, Standortverfolgung.

**Liste** — die Nachbesuchs-Arbeitsliste. Nach Straßen gruppiert, offene Türen
zuerst, Filter-Chips mit Live-Zählern und Wischen für Schnellstatus mit
benanntem Undo.

**Archiv** — Gedächtnis und Abrechnung. Bilanz des aktiven Gebiets, taggruppierte
Gebietsliste, Suche, Export (PDF/Text) und vollständiges JSON-Backup.

---

## Was in Version 6 neu ist

### Standort ist jetzt wirklich live
Vorher wurde der Standort **einmalig** abgefragt (`requestLocation()`, gefolgt von
einem sofortigen `stopUpdatingLocation()`), zusätzlich blockiert durch ein
180-Sekunden-Fenster. Der Punkt bewegte sich deshalb nur ein paar Mal pro Sitzung.

Jetzt läuft ein echter Stream, solange die Karte sichtbar ist — und **nur** dann:
- `startUpdatingLocation()` mit `kCLLocationAccuracyNearestTenMeters` und
  `distanceFilter = 3` (Apples Empfehlung für Fußgänger-Apps: sichtbar flüssig,
  ohne das GPS den ganzen Tag auf Volllast zu fahren)
- `pausesLocationUpdatesAutomatically = false` — iOS pausiert sonst bei
  „Stillstand" und **nimmt von selbst nicht wieder auf**; wer zwei Minuten an einer
  Tür steht, hatte danach einen eingefrorenen Punkt
- Fixes, die zu alt oder zu ungenau sind, werden verworfen

### Richtungsanzeige
Ein eigener Standort-Puck mit Genauigkeits-Halo und **Richtungskegel**, der dem
Kompass folgt — wie in Apple Karten.

MapKit zeichnet den Kegel selbst nur im Modus `.followWithHeading`, und der dreht
und zoomt die Karte mit. Für eine App, in der man ständig frei verschiebt, ist das
unbrauchbar; der Puck ist deshalb eine eigene Annotation-View. Der Kegel:
- rechnet die Kartendrehung heraus, zeigt also immer die echte Himmelsrichtung
- wird über einen zirkulären Tiefpassfilter geglättet (Grad lassen sich nicht
  direkt mitteln — 359° und 1° liegen ein Grad auseinander)
- **wird breiter, wenn der Kompass unsicher ist**, statt eine Präzision vorzutäuschen

> Der Kegel braucht ein Magnetometer und erscheint deshalb **nur auf echter
> Hardware**, nicht im Simulator.

### Die Karte bleibt, wo du sie gelassen hast
Vorher wurde bei jedem Öffnen neu auf den Standort zentriert: die Merker-Variable
war einfacher View-State (also bei jedem Kaltstart zurückgesetzt) und wurde beim
Tab-Wechsel zusätzlich absichtlich wieder scharf gestellt. Schlimmer noch — das
automatische Zentrieren hat die gespeicherte Position gleich mit überschrieben.

Die Regel ist jetzt bewusst kompromisslos: **einmal pro Installation.**
- Beim allerersten Start fliegt die Karte auf deinen Standort, deutlich enger als
  vorher (~350 m statt ~1,1 km) — Hausnummern sind sofort lesbar
- Danach: jeder Start, jeder Tab-Wechsel, jedes Zurückholen aus dem Hintergrund
  stellt exakt die letzte Ansicht wieder her
- Bewegt wird die Karte nur noch, wenn du den Standort-Knopf drückst
- Auch das **ausgewählte Gebiet** wird jetzt gemerkt

### Orte auf der Karte
Vorher blendete `pointOfInterestFilter = .excludingAll` jedes Geschäft aus. Jetzt
zeigt die Karte Supermärkte, Bäckereien, Banken, Bankomaten, Apotheken,
Haltestellen, Ämter, Schulen, Parks und mehr — antippbar für Details.

Der Schlüssel dazu ist `emphasisStyle = .muted`: die Grundkarte wird entsättigt,
damit die Orte lesbar bleiben, **ohne** den roten Haus-Pins die Aufmerksamkeit zu
stehlen. Drei Stufen im Menü: **Aus**, **Orientierung** (kuratiert), **Alle Orte**.

### Pins: ein Haus, ein Pin — auf jeder Zoomstufe

Clustering ist ersatzlos entfernt. Es war die Quelle fast aller Pin-Fehler, und es
löste ein Problem, das die App gar nicht hat.

Der alte Stand schaltete zwischen „gruppiert" und „einzeln" über ein selbstgebautes
Band um: zwei Signale (Bildbreite **und** Anzahl sichtbarer Pins), beide mit eigener
Hysterese, ausgewertet am Ende jeder Kamerabewegung. Daraus folgte alles, was an der
Karte nervte:

- **Der Zustand hing vom Weg ab, nicht vom Ort.** Zweimal dieselbe Stelle, einmal
  hinein- und einmal herausgezoomt, ergab zwei verschiedene Karten.
- **Eine schnelle Geste erwischte den Umschaltmoment.** MapKit besitzt `transform`
  und `center` einer Annotation, solange eine Cluster-Animation läuft; der Umschalter
  schrieb in dieselben Views. Ob das kollidierte, entschied das Frame-Timing — daher
  „bei manchen Zooms, bei anderen nicht".
- **`clusteringIdentifier` im Nachhinein zu setzen wirkt nicht zuverlässig.** MapKit
  liest die Eigenschaft, wenn eine View entsteht. Bereits bestehende Cluster blieben
  stehen, ihre Mitglieder blieben verborgen.

Jetzt gilt: **ein Haus ist ein Pin, vom weitesten Überblick bis auf Straßenniveau.**
Nichts wird zusammengefasst, nichts aufgeteilt, nichts ausgeblendet
(`collisionMode = .none`). Damit gibt es keinen Modus mehr, den eine Geste halb
angewendet erwischen kann — egal wie schnell man zoomt.

Was der Zoom noch ändert, ist allein die **Größe** der Grafik, und die ist eine
reine Funktion der Kamera:

| Bildbreite | Darstellung |
|---|---|
| bis 1,4 km | volle Größe mit Glyph |
| 1,4–3 km | kleiner, Glyph bleibt |
| ab 3 km | reiner Punkt |

Kein vorheriger Zustand, keine Hysterese, keine Übergangstabelle: dieselbe Zoomstufe
ergibt immer dieselbe Größe. Hysterese war früher nötig, weil ein Stufenwechsel die
Geometrie verschob — heute ist er nur noch ein Bildtausch auf identischer
Leinwand mit identischem Ankerpunkt, also unsichtbar und beliebig oft machbar.

Dass das ohne Clustering trägt, liegt an der Pin-Grafik selbst:

- **Pin-Grafik inklusive Text vorgerendert.** Ein Pin ist ein reiner Bild-Halter:
  keine Unteransichten, kein Layout-Durchlauf, keine Textmessung pro Pin
- Statusänderungen aktualisieren **nur die betroffenen Pins**, nicht alle
- Pins blenden sich beim Hereinscrollen **nicht** ein — die Alpha-Animation pro View
  war der teuerste vermeidbare Posten beim Schwenken und der einzige Weg, auf dem ein
  wiederverwendeter Pin halbdurchsichtig zurückkommen konnte
- `displayPriority` wird immer explizit gesetzt und nie `.required`: der Standardwert
  nimmt jeden Pin aus MapKits Budget heraus — der klassische Grund, warum Karten mit
  eigenen Annotationen bei Menge einbrechen. Häuser mit offenen Nachbesuchen stehen
  höher, falls MapKit doch einmal wählen muss

Getestet mit 3.000 Pins auf einmal, ohne Gruppierung, flüssig.

**Liegen Pins wirklich aufeinander**, öffnet ein Tipp eine Auswahlliste. Der Radius
ist bewusst klein (30 % des Pin-Kopfes): Pins, die sich nur berühren, sind einzeln
antippbar — MapKit trifft die oberste View unter dem Finger. Nur ein Pin, dessen
Mittelpunkt unter einem anderen Kopf liegt, ist gar nicht erreichbar, und genau der
bekommt die Liste. Das funktioniert jetzt auf **jeder** Zoomstufe; früher gab es die
Liste nur oberhalb der Cluster-Grenze.

### Tag 1 und Tag 2 sind jetzt wirklich getrennt
Das war der schwerste Fehler im alten Stand. Der Zugriff auf den Tag-2-Wert fiel
still auf den Tag-1-Wert zurück, wodurch:
- **jede Tag-2-Statistik rechnerisch identisch mit der Gesamtsumme war** — der
  Tag-1/Tag-2-Vergleich verglich eine Zahl mit sich selbst
- die **Tag-2-Arbeitsliste invertiert** war: Türen, für die man zurückkam, galten
  als erledigt
- „Alle offenen Türen markieren" am Tag 2 genau die Türen übersprang, um die es ging
- ein Tipp in der Gesamtansicht den einen Tag las und den anderen schrieb, sodass
  Eintragungen wirkungslos aussahen — und Tag-1-Daten überschrieben wurden

Jetzt: `DayScope` als Typ statt roher 0/1/2, strikte Statistik pro Tag, eine
getrennte Anzeige-Logik für Pins und Zeilen, und der Schreib-Tag ergibt sich aus
dem Kalender des Gebiets — nicht daraus, was der Umschalter gerade zeigt.

### Datensicherheit
- **Schema-Versionierung.** Vorher hätte die nächste Modelländerung jede
  bestehende Installation beim Start zum Absturz gebracht, ohne Weg an die Daten.
  Jetzt gibt es `SchemaV1`, einen Migrationsplan und einen Wiederherstellungs-
  Bildschirm, der die Datenbank zum Sichern anbietet, falls sie sich nicht öffnen lässt.
- **Backups sind nicht mehr still verlustbehaftet.** Ein Haus mit unlesbaren
  Türdaten wurde vorher mit *null* Türen ins Backup geschrieben. Jetzt bricht der
  Vorgang mit einer klaren Meldung ab.
- **Import führt nicht mehr fremde Gebiete zusammen.** Vorher wurde jedes Gebiet
  mit demselben Kalendertag verschmolzen — unabhängig von ID, Name und Ort.
  Jetzt wird ausschließlich über die ID zugeordnet.
- **Import rollt bei Fehlern zurück**, statt halbe Änderungen liegen zu lassen,
  die der nächste beliebige Speichervorgang mitschreibt.
- Unlesbare Türdaten werden **nie überschrieben**; das Haus wird als beschädigt
  markiert und für Bearbeitung gesperrt.
- Migrationen setzen ihr „erledigt"-Kennzeichen **nach** dem erfolgreichen
  Speichern (vorher davor — ein Abbruch strandete die Daten dauerhaft).

### Weitere Korrekturen
- Der Gebiets-Schwerpunkt nutzt die Flächenformel statt des Mittelwerts der
  Stützpunkte. Bei einer freihändig gezogenen Grenze zog der Mittelwert zur dicht
  gezeichneten Kante und konnte **außerhalb** des Gebiets landen — und genau
  dieser Punkt bestimmt die automatische Benennung.
- Das Fadenkreuz hängt jetzt an einem nullhohen Anker: das Haus landet dort, wo
  gezielt wurde (vorher ~25 pt daneben, also 8–15 m).
- Straßennamen brechen nicht mehr am eigenen Importformat („Am Hof, 1010 Wien"
  ergab die Straße „Am Hof," mit Komma — eine zweite Sektion neben der richtigen).
- „übermorgen" ist in der Suche erreichbar (Schlüsselwörter werden jetzt gefaltet
  verglichen).
- Undo dreht den Änderungsstempel nicht mehr zurück; die Karte zeigte sonst
  weiterhin den zurückgenommenen Status.
- Reverse-Geocoding ist über einen Actor serialisiert und gecacht — vorher liefen
  die Anfragen ins Rate-Limit und der Rest wurde nie benannt.
- Duplikatprüfung warnt nur noch bei tatsächlich gleicher Adresse, nicht bei jedem
  Nachbarhaus im Umkreis von zwölf Metern.
- Kein erfundenes Ersatzgebiet mehr, wenn du das letzte löschst.

### Export
Der alte Export warf **jede** Adresse ins Dokument — auch die, an denen nie jemand
war — und listete pro Mehrparteienhaus jede unbeantwortete Tür einzeln als „Offen".
Ein Rundgang mit 4.972 Adressen ergab ein PDF, in dem die eigentliche Arbeit
zwischen Hunderten leeren Zeilen unterging.

Jetzt:
- **Nur besuchte Adressen** (abschaltbar). Eine Adresse ohne einen einzigen Eintrag
  ist kein Arbeitsnachweis.
- Mehrparteienhäuser zeigen „3 von 8 Türen" und listen **nur die beantworteten**.
- Nach Straßen gruppiert, wie man auch arbeitet.
- Die Zusammenfassung nennt nur Ergebnisse, die tatsächlich vorkamen — keine
  Spalte voller Nullen.
- **Tag 2 exportiert nur echte Zweitbesuche.** Eine Tür, die am Tag 1 erledigt und
  nie wieder besucht wurde, gehört nicht in einen Tag-2-Bericht.
- Notizen lassen sich weglassen (interne Stichworte wie „Hund").

Das PDF ist ein Dokument, keine App-Ansicht: eine Schrift, wenige Größen, feine
Trennlinien, kein Farbeinsatz. Vorher zog sich ein roter Balken über den Kopf,
darunter vier eingefärbte Kennzahl-Kacheln, hinter jeder Adresse eine graue Karte,
und im Fließtext standen Emoji. Der Textexport ist entsprechend knapp und
lässt sich direkt in eine Mail einfügen.

### Pin-Größen
Die Umschaltung zwischen großen und kleinen Pins hatte drei Fehler, die zusammen
dafür sorgten, dass Pins manchmal im „farblosen" Zustand hängen blieben:

1. **Der Zustand wurde nur zugestellt, nie abgeholt.** Beim Umschalten bekamen nur
   Annotationen im *sichtbaren* Rechteck die neue Größe. Views, die MapKit knapp
   außerhalb schon gebaut hatte, behielten die alte Grafik und schoben sich beim
   Wischen veraltet ins Bild. Jetzt liest jede View die Größe selbst — bei jedem
   `configure` und bei jedem `prepareForDisplay` —, kann also gar nicht mehr veralten.
2. **Die kleine Stufe warf den Glyph komplett weg.** Aus jedem Einzelhaus wurde ein
   anonymer farbiger Punkt. Der Glyph bleibt jetzt in beiden nutzbaren Stufen; nur
   die reine Punkt-Stufe verzichtet darauf, und die liegt jenseits des Zooms, ab dem
   ohnehin gruppiert wird.
3. **Die Schwelle lag bei 800 m** mit symmetrischer Hysterese bis 550 m — also mitten
   im normalen Arbeitszoom. Jetzt ist die Hysterese **absichtlich unsymmetrisch**:
   die große Stufe zu verlassen braucht klaren Abstand (über 1,5 km), zurück geht es
   sofort ab 1,3 km. Im Zweifel gewinnt immer die lesbare Darstellung.

Die Größe wird bei jedem Frame der Geste neu bestimmt, folgt also dem Zoom, statt
erst beim Loslassen zu springen.

Die **Pin-Form** ist die ursprüngliche: Kreis mit kurzer Spitze, weißer Ring auf
dem Kreis. Sie skaliert jetzt sauber über alle drei Größenstufen mit.

### Kennzahlen
Die Kopfleiste zeigt **alle fünf** Werte, in der Reihenfolge, in der eine Runde
tatsächlich läuft: Häuser · offene Nachbesuche · frühes Nein · spätes Nein · dabei.
Womit du anfängst steht vorne, das Ergebnis steht hinten.

### Uhrzeiten
Jede Eintragung trägt jetzt ihre Uhrzeit — im Hausdetail an jeder Tür, in der Liste
hinter dem Status. Die Daten dafür lagen schon immer vor, sie wurden nur nirgends
gezeigt.

Im **PDF** ordnet die Uhrzeit den ganzen Bericht: die Adressen stehen in der
Reihenfolge, in der du sie besucht hast, und innerhalb eines Mehrparteienhauses die
Türen in der Reihenfolge, in der du sie abgearbeitet hast. Die Uhrzeit selbst wird
**nicht** gedruckt — sie sortiert, sie erscheint nicht. Damit ist die frühere
Gruppierung nach Straßen im PDF entfallen; der Bericht liest sich jetzt als Ablauf
der Runde statt als Verzeichnis.

### Keine Routenfunktion

Die Routenfunktion ist vollständig entfernt: kein Planer, kein Wegenetz, kein
Routen-Zustand und auch kein Sprung zu Apple Maps. Bei den kurzen Abständen im Feld
kostet der App-Wechsel mehr Aufmerksamkeit, als er spart.

Stattdessen zeigt die Karte lokal und nachvollziehbar den **nächsten offenen Besuch**.
Ein Tipp öffnet das Haus direkt in Nachbesuch. Entfernung und fällige „Später“-Termine
helfen bei der Auswahl, ohne eine optimierte Gehroute vorzutäuschen.

### „Nächste zuerst"
Die Liste kann nach **Entfernung** sortieren und zeigt dann pro Zeile, wie weit das
Haus weg ist. Genau das braucht man auf der Straße: nicht „welches Haus habe ich
zuerst angelegt", sondern „was ist hier in der Nähe noch offen".

Details, die es brauchbar machen:
- Der Bezugspunkt wandert erst mit, wenn du dich **wirklich bewegt** hast (25 m).
  Sonst würde ein zappelnder GPS-Punkt die Liste unter dem Daumen umsortieren.
- Das GPS läuft **nur**, solange diese Sortierung gewählt und der Tab sichtbar ist.
  Karte und Liste teilen sich einen Dienst mit Referenzzählung — wer zuletzt geht,
  macht die Ortung aus.
- Entfernungen über die äquirektanguläre Näherung statt `CLLocation.distance` —
  auf Stadtebene zentimetergenau und ohne ein Objekt pro Zeile bei jeder Positionsaktualisierung.

### Menüs und Kartensteuerung
Das Drei-Punkte-Menü der Karte hatte acht flache Einträge, davon zwei doppelt:
„Pins auswählen" lag dort **und** als Knopf in der Kopfleiste, und „Nächsten
Nachbesuch öffnen" war ein einmaliger Navigationsbefehl mitten zwischen
Karteneinstellungen. Ein Menü, das alles auflistet, liest niemand.

Jetzt stehen dort vier Zeilen in zwei Gruppen:
- **Gebiet** — einzeichnen/bearbeiten, Häuser aus Kartendaten laden
- **Darstellung** — Kartenstil und Orte, jeweils als Untermenü, das seinen
  aktuellen Wert schon auf der Elternzeile anzeigt (zwei Zeilen statt fünf)

Entfernt: „Pins auswählen" (Dopplung), „Nächsten Nachbesuch öffnen" und der
Verkehrs-Schalter — Stau-Daten helfen niemandem, der zu Fuß von Tür zu Tür geht.
Die zugehörige Verkehrs-Verkabelung ist mit ausgebaut, statt tot herumzuliegen.

**Neu: „Zum Gebiet".** Ein Knopf, der die ganze Runde ins Bild holt — nützlich,
wenn du gerade woanders bist. Er erscheint **nur, wenn er etwas zu tun hat**: liegt
das Gebiet ohnehin im Bild, ist er nicht da. Der Ausschnitt kommt aus der
gezeichneten Grenze, sonst aus der Ausdehnung der Pins, und wird beim Aufbau der
Pins einmal mitberechnet statt später nachgescannt.

Auch die übrigen Menüs sind gruppiert: das Archiv trennt „Neues Gebiet" von der
Sicherung, das Hausdetail trennt Wegfindung von „was für ein Haus ist das".

### Liquid Glass und Bewegung
Die Bedienelemente über der Karte waren zwar aus Glas, aber **jedes für sich** —
sechs unabhängige Effekte, keiner in einem `GlassEffectContainer`. Genau davor warnt
Apple: getrennte Effekte kosten Leistung, können nicht ineinander übergehen und
verschmelzen nicht.

Jetzt:
- **Ein Container pro Cluster** (oben, unten, Filterleiste). Der Abstand des
  Containers entspricht dem des inneren Stacks — ist er größer, verschmelzen die
  Formen schon im Ruhezustand zu einem Klumpen.
- **Einzelne Glas-Controls statt großer Glasflächen.** Aus dem selbstgebauten Panel
  sind `.buttonStyle(.glass)` und `.glassProminent` geworden; Glas in Glas zu
  schachteln ist ausdrücklich unerwünscht.
- **Die Kopfleiste verwandelt sich.** Übersicht und Auswahlmodus teilen sich eine
  `glassEffectID`, also formt sich eine Leiste um, statt dass zwei Panels kreuzblenden.
- **Filter-Chips sind Glas**; der ausgewählte ist prominent eingefärbt. Das ersetzt
  eine handgebaute `matchedGeometryEffect`-Kapsel samt Namespace, Reduce-Motion-
  Sonderfall und der im Dunkelmodus unsichtbaren Zähler-Plakette.
- **Suchfeld klappt zusammen** (`searchToolbarBehavior(.minimize)`) — spart in Liste
  und Archiv eine komplette Zeile.
- **`safeAreaBar` statt `safeAreaInset`** für eigene Leisten: zieht zusätzlich den
  Scroll-Kanteneffekt korrekt unter die Leiste.
- **Karten und Listenzeilen sind Glas — aber eine ruhigere Sorte** als die
  schwebende Chrome: Material, Haarlinie am Rand, dezenter Schatten. Flache
  `secondarySystemGroupedBackground`-Flächen lasen sich vor dem getönten Hintergrund
  als weiße Kästen. Darin liegende Blöcke bekommen eine einfache Füllung statt Glas
  — Glas auf Glas wird matschig.
- **Der Abstand eines `GlassEffectContainer` muss kleiner sein als der Abstand
  zwischen den Formen darin.** Bei 10 pt Container gegen 8 pt Zeilenabstand
  verschmolzen sämtliche Listenzeilen zu einer einzigen weißen Fläche — die Liste
  sah überhaupt nicht mehr nach Karten aus. Jetzt: 2 pt Container, 10 pt Zeilenabstand.
- **Kein `interactive`-Glas und keine eigene Morph-Identität pro Zeile.** Dutzende
  Zeilen, die jede für sich Berührungen verfolgen und eine Matched-Geometry-Animation
  aushandeln, waren der Grund für das Stocken beim Auf- und Zuklappen einer Straße;
  der Druckeffekt kommt aus dem Button-Style. Zeilen werfen außerdem keinen Schatten
  (ein Offscreen-Pass pro Zeile).
- **Radien:** Karten 28 pt, Zeilen 22 pt, durchgehend `.continuous`.
- **Reduzierte Transparenz** schaltet eigene Panels auf eine deckende Fläche um;
  Systemcontrols erledigen das selbst.

Bewegung, sparsam eingesetzt:
- Zahlen zählen in die richtige Richtung (`numericText(value:)` statt `numericText()`,
  das die Richtung nicht kennt) — und stets in einem Animationskontext, sonst tut der
  Modifier schlicht nichts.
- Fortschrittsbalken animieren ihren Wert, statt zu springen.
- Eine Zeile in der Liste **wächst in ihr Detail-Blatt** und schrumpft beim
  Zurückziehen wieder hinein (`matchedTransitionSource` + `.navigationTransition(.zoom)`).
- Symbol-Effekte nur dort, wo sie etwas bedeuten: Puls, solange ein Standort gesucht
  wird; ein kurzer Bounce, wenn ein Hinweis erscheint oder ein Gebiet aktiv wird.
- Wiederholte Effekte sind an „Bewegung reduzieren" gekoppelt.

### Oberfläche
- Tabs bleiben am Leben — Suchtext, Filter, Scrollposition und eingeklappte
  Straßen überleben den Tab-Wechsel (vorher wurde jeder inaktive Tab durch eine
  leere Fläche ersetzt und damit komplett verworfen)
- Listen bauen ihren Datenbestand **einmal pro Datenänderung** auf, nicht pro
  Tastenanschlag
- Status hat neben Farbe und Emoji ein eigenes **Symbol** — unterscheidbar auch
  bei Farbsehschwäche
- VoiceOver liest verständliche Texte statt „großer roter Kreis"
- 44-pt-Trefferflächen durchgehend
- Dynamic Type bis zu den Barrierefreiheits-Größen; Kacheln brechen um statt zu
  schrumpfen
- „Reduzierte Bewegung" und „Transparenz reduzieren" werden respektiert
- Apples Rechtshinweis und Maßstab bleiben frei — die schwebenden Bedienelemente
  melden ihre Höhe an MapKit (das Verdecken ist ein App-Review-Ablehnungsgrund)

---

## Aufbau

```
ios/                     iOS-App, Xcode-Projekt und XCTest-Suite
  NachbesuchV5/
    App/                 Einstieg, Schema + Wiederherstellung, RootView
    DesignSystem/        Maße, Bewegung, Oberflächen, Layout
    Location/            Standort + Kompass
    Map/                 MKMapView, Koordinator, Pins, Kamera, Orte, Chrome
    Models/              House, Gebiet, DoorResult, DayScope, OutcomeTally
    Features/            Karte, Liste, Archiv, Bilanz, geteilte Ansichten
    Services/            Backup, Export, OSM-Import, Benennung, Suche, Index
  NachbesuchV5Tests/     iOS-Tests
android/                 Android-App mit app, data, domain und ui Modulen
scripts/                 versionierte Repository-Sicherheitsprüfungen
```

Zwei Regeln tragen die Kartenleistung:
1. **Die Kartenansicht wird nie abgebaut.** Vorher zerlegte jedes Herunterziehen
   des Kontrollzentrums die `MKMapView` samt Kacheln und Annotationen.
2. **Gesten lösen keine SwiftUI-Neuberechnung aus.** Die Kamera liegt außerhalb
   des SwiftUI-Abhängigkeitsgraphen.

## Tests

Die Tests laufen im Swift-6-Modus,
mit Schwerpunkt auf den oben korrigierten Fehlern:
Tag-Semantik, Änderungsstempel, Schutz beschädigter Daten, Gebiets-Invarianten,
Schwerpunktberechnung, Straßennamen, Suche, Bilanz, Export-Umfang und Pin-Aufbau
bis 10.000 Häuser. Die Upgrade-Regressionstests decken zusätzlich beschädigte
Hausdaten, den korrekten Tag-2-Nenner, die deterministische Auswahl des nächsten
Besuchs und sichtbare Überläufe des Erinnerungsbudgets ab.

```bash
xcodebuild test -project ios/NachbesuchV5.xcodeproj -scheme NachbesuchV5 -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Testdaten für Leistungsmessungen (nur DEBUG)

```bash
SIMCTL_CHILD_NACHBESUCH_SEED=5000 xcrun simctl launch booted at.volkshilfe.nachbesuch.v5
```

Optional `NACHBESUCH_SPAN` (Zoom), `NACHBESUCH_TAB` (`list`/`archive`) und
`NACHBESUCH_SHEET=export`. Legt ein separates „Testgebiet" an und lässt vorhandene
Daten unberührt.

Beispiel-PDF zum Ansehen der Layouts:

```bash
TEST_RUNNER_NACHBESUCH_DUMP_PDF=1 xcodebuild test -project ios/NachbesuchV5.xcodeproj -scheme NachbesuchV5 -only-testing:NachbesuchV5Tests/PDFDumpTests …
```

## Starten

`ios/NachbesuchV5.xcodeproj` öffnen, iPhone oder Simulator wählen, Run.
Beim ersten Start Standortzugriff erlauben.
