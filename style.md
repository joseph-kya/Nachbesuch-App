# Stil

Wie die Oberfläche dieser App aussieht und warum. Verbindlich für iOS und —
sinngemäß übersetzt — für Android.

Die App wird im Stehen bedient, einhändig, oft in der Sonne, mit einer Tasche in
der anderen Hand. Das ist keine Nebenbedingung, sondern der ganze Maßstab: jedes
Element, das eine halbe Sekunde Nachdenken kostet, kostet sie an einer Haustür.

---

## 1. Der Grundsatz

> „Weniger, aber besser — weil es sich auf das Wesentliche konzentriert und die
> Produkte nicht mit Unwesentlichem belastet werden."
> — Dieter Rams, *Gutes Design ist so wenig Design wie möglich*

Minimalismus ist hier **kein Aussehen**, sondern ein Verfahren: Etwas wird
weggelassen, bis das Weglassen weh tut. Ein weißer Bildschirm mit dünner Schrift
ist nicht minimalistisch, wenn er dieselben zwölf Entscheidungen enthält.

Die operative Frage bei jedem Element lautet nicht *„stört es?"*, sondern
**„welche Frage beantwortet es, und wird diese Frage hier gestellt?"** Was keine
gestellte Frage beantwortet, kommt weg — oder eine Ebene tiefer.

Daraus folgen drei Regeln, in dieser Reihenfolge:

1. **Streichen.** Braucht es das Element überhaupt?
2. **Verschieben.** Wenn ja — muss es *hier* stehen, oder reicht ein Tipp tiefer?
   (Progressive Disclosure: das Sekundäre auf die zweite Ebene, damit das Primäre
   Aufmerksamkeit bekommt.)
3. **Erst dann gestalten.** Gestaltung ist der letzte Schritt, nicht der erste.

---

## 2. Was auf welche Ebene gehört

iOS 26 hat zwei Ebenen, und die Trennung ist keine Geschmacksfrage:

| Ebene | Material | Was dort lebt |
|---|---|---|
| **Inhalt** | System-Hintergründe, `contentCard` | Karte, Listenzeilen, Archiv, alles Gelesene |
| **Navigation / Steuerung** | Liquid Glass (`mapChrome` / `navigationGlass`) | Schwebende Panels, Tab-Leiste, Werkzeugleisten |

**Regeln:**

- **Glas nie auf Glas.** Verschachtelte `glassEffect`-Modifier sind ausdrücklich
  unerwünscht — sie erzeugen visuelle Redundanz und Matsch. Ein Block *innerhalb*
  einer Karte bekommt `contentPanel` (flache getönte Füllung), nie noch eine
  Glasschicht.
- **Ko-lokalisierte Panels teilen sich einen `GlassEffectContainer`**, damit die
  Formen ineinander morphen und in einem Durchgang gerendert werden.
- **Kein zusätzlicher Hintergrund, kein zusätzlicher Rahmen** an Leistenknöpfen,
  um ihnen Gewicht zu geben. Hierarchie entsteht durch **Anordnung und
  Gruppierung**, nicht durch Dekoration.
- **Ein Scroll-Edge-Effekt pro Ansicht.** Nicht mischen, nicht stapeln.
- Glas respektiert *Transparenz reduzieren* und *Kontrast erhöhen* — bei
  Eigenbau-Panels muss der undurchsichtige Pfad ausdrücklich mitgebaut werden
  (siehe `AdaptiveSurface.swift`).

---

## 3. Farbe

Ein Akzent, sonst Semantik. Mehr nicht.

- **Der Akzent ist die vom Benutzer gewählte Farbe** — immer über
  `@Environment(\.appAccent)`, nie `Color.accentColor` (das löst auf den
  Asset-Catalog auf und ignoriert die Wahl) und nie ein fest verdrahtetes
  `.red`. Ein fest verdrahtetes Rot neben einem getönten Bedienelement ist ein
  Fehler, kein Stilmittel.
- **Farbe trägt Bedeutung oder sie kommt weg.** Die Status-Töne
  (`VisitOutcome.tint`) und die Dringlichkeitstöne des `RevisitGlance`
  (überfällig → rot, bald → orange, später → indigo) sind Bedeutung. Ein
  farbiger Verlauf, der nichts benennt, ist Dekoration.
- **Dekorative Verläufe: höchstens einer, und so schwach, dass man ihn nur
  vermisst, wenn er fehlt.** Der Hintergrund existiert einzig, damit das Glas
  etwas zum Brechen hat — nicht als Gestaltungsfläche.
- Nie Farbe als einziger Informationsträger: jeder Ton bekommt ein Symbol oder
  eine Zahl daneben.

---

## 4. Typografie

- Ausschließlich Dynamic-Type-Stile (`.headline`, `.subheadline`, `.caption`).
  Keine festen Punktgrößen für Text.
- **Höchstens drei Größen pro Panel.** Wer eine vierte braucht, hat zu viel im
  Panel.
- Gewicht statt Größe für Hierarchie: `.semibold` auf `.subheadline` schlägt eine
  Stufe größer.
- Zahlen, die sich ändern, immer `.monospacedDigit()` — sonst zappelt die Zeile.
- `minimumScaleFactor` ist die letzte Rettung, kein Layout. Ein auf drei Zeilen
  umbrochenes, in der Wortmitte getrenntes Label ist kaputt; eine Zeile, die
  etwas kleiner skaliert, ist lesbar.

---

## 5. Form und Maß

- Radien aus `AppRadius`, Abstände aus `AppSpacing`, Trefferflächen aus
  `AppTouch`. Keine Zahlen aus dem Gefühl heraus im Code.
- **Konzentrische Radien:** der innere Radius ist der äußere minus dem Abstand.
  Ineinanderliegende Formen richten sich damit rechnerisch aus statt ungefähr.
- Keine eingeschnürten oder ausgestellten Ecken — sie erzeugen Spannung und
  brechen die Balance.
- **44 pt Trefferfläche**, immer. `.tappable()` erlaubt ein optisch kleines
  Element mit voller Trefferfläche.

---

## 6. Steuerelemente und Menüs

- **Ein Bildschirm, eine primäre Aktion.** Sie ist die breiteste und die einzige
  gefüllte.
- **Symbole ohne Beschriftung nur, wenn sie universell sind** (Lupe, Plus, Ort).
  Drei unbeschriftete runde Symbole nebeneinander sind ein Rätsel, kein
  Bedienelement — genau daran ist die alte Routenleiste gescheitert.
- **Text- und Symbolknöpfe nicht in einer Gruppe mischen** — das liest sich als
  ein einziger Knopf.
- **Ein Menü, das alles auflistet, ist ein Menü, das niemand liest.** Menüs
  werden in Abschnitte gruppiert, damit sie als zwei Entscheidungen gelesen
  werden statt als acht Befehle. Ein `Picker` im Menü wird zum Untermenü und
  zeigt seinen Wert in der Elternzeile — zwei Zeilen statt fünf.
- **Keine Aktion zweimal.** Steht etwas im Menü, gehört derselbe Knopf nicht
  zusätzlich in eine Karte darüber.
- Bildschirmspezifische Aktionen gehören nicht in die dauerhafte Tab-Leiste.

---

## 7. Bewegung

- Bewegung erklärt eine Veränderung oder sie unterbleibt. Nichts bewegt sich,
  um hübsch zu sein.
- Alle Kurven aus `Motion.swift` (`.appFeedback`, `.appSettle`), nie inline.
- **Jede** Animation prüft `accessibilityReduceMotion`.
- Wiederholende Effekte (Puls) laufen nur, solange sie etwas bedeuten.

---

## 8. Barrierefreiheit — nicht verhandelbar

- Jedes zusammengesetzte Element: `accessibilityElement(children: .ignore)` plus
  ein selbst formulierter Label/Value. Ein Screenreader darf nie „großer roter
  Kreis" vorlesen.
- Die Information des Chips gehört **einmal** in die Vorlesekette, nicht zweimal.
- Dynamic Type bis zu den Accessibility-Größen: Statistiken **umbrechen**
  (`FlowLayout`), sie stapeln sich nicht zu einer Spalte, die den halben
  Bildschirm frisst.
- *Transparenz reduzieren* und *Kontrast erhöhen* haben in jedem Eigenbau-Panel
  einen undurchsichtigen Pfad.

---

## 9. Prüfliste vor dem Commit

- [ ] Habe ich etwas **entfernt**? Wenn eine Änderung nur hinzufügt, ist die
      erste Frage aus §1 nicht gestellt worden.
- [ ] Kein `Color.accentColor`, kein fest verdrahtetes `.red` als Akzent.
- [ ] Kein `glassEffect` innerhalb eines `glassEffect`.
- [ ] Keine Zahl im Code, die in `AppRadius`/`AppSpacing`/`AppTouch` stünde.
- [ ] Jede Animation kennt `reduceMotion`.
- [ ] Jedes Symbol ohne Beschriftung hat ein `accessibilityLabel`.
- [ ] Bei größter Dynamic-Type-Stufe nichts abgeschnitten, nichts in der
      Wortmitte getrennt.

---

## Quellen

- [Apple HIG — Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Get to know the new design system — WWDC25 Session 356](https://developer.apple.com/videos/play/wwdc2025/356/)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Dieter Rams — Ten principles for good design](https://designmanifestos.org/dieter-rams-ten-principles-for-good-design/)
- [NN/g — Progressive Disclosure](https://www.nngroup.com/videos/progressive-disclosure/)
- [NN/g — Managing Visual Complexity](https://www.nngroup.com/videos/managing-visual-complexity/)
