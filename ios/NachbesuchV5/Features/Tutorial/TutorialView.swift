import SwiftUI

/// First-run tour of the app's essential features (Karte, Haus erfassen,
/// Liste, Später, Archiv, Sicherung).
///
/// One implementation for both presentation tiers: the pages are built from
/// `contentCard` and the app backdrop, so iOS 26 renders them in glass and
/// iOS 18 on the opaque branch — the same split every other screen uses.
/// Reached deliberately from Archiv → ⋯ → Anleitung, never unasked.
/// bewusst kein „Nicht mehr zeigen"-Schalter und kein Auto-Zeigen nach
/// Schemawechsel — die Anleitung erscheint nur auf Wunsch aus dem Archiv, ein
/// Schalter hätte nichts zu schalten und ein Auto-Aufpoppen bräche genau das.
struct TutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAccent) private var accent

    @State private var page = TutorialView.initialPage
    /// single selection haptic per Weiter-tap, including the final
    /// "Los geht's" which changes no page and would miss a page-trigger.
    @State private var advanceTaps = 0

    /// Screenshot/review harness: open directly on a page.
    /// `SIMCTL_CHILD_NACHBESUCH_TUTORIAL_PAGE=3 xcrun simctl launch …`
    private static var initialPage: Int {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["NACHBESUCH_TUTORIAL_PAGE"],
           let index = Int(raw),
           TutorialPage.all.indices.contains(index) {
            return index
        }
        #endif
        return 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(TutorialPage.all) { entry in
                        TutorialCard(page: entry)
                            .tag(entry.id)
                            .padding(.horizontal, AppSpacing.regular)
                            .padding(.vertical, AppSpacing.snug)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.appSettle(reduceMotion: reduceMotion), value: page)

                // active pill morph — Capsule 16 vs 6, appFeedback.
                // System dots hidden above; these carry German VO labels.
                HStack(spacing: 6) {
                    ForEach(TutorialPage.all) { entry in
                        TutorialDot(isActive: entry.id == page, accent: accent)
                    }
                }
                .padding(.vertical, AppSpacing.tight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Seite \(page + 1) von \(TutorialPage.all.count)")

                Button(action: advance) {
                    Text(page < TutorialPage.all.count - 1 ? "Weiter" : "Los geht's")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: AppTouch.minimum)
                }
                .compatGlassButton(prominent: true)
                .buttonBorderShape(.capsule)
                .tint(accent)
                .sensoryFeedback(.selection, trigger: advanceTaps)
                .padding(.horizontal, AppSpacing.regular)
                .padding(.bottom, AppSpacing.regular)
                .accessibilityLabel(page < TutorialPage.all.count - 1 ? "Weiter zur nächsten Seite" : "Anleitung schließen")
            }
            .background { AppBackdrop() }
            .navigationTitle("Anleitung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { finish() }
                        .accessibilityLabel("Anleitung schließen")
                }
            }
        }
    }

    private func advance() {
        advanceTaps += 1
        if page < TutorialPage.all.count - 1 {
            page += 1
        } else {
            finish()
        }
    }

    private func finish() {
        dismiss()
    }
}

/// One tour page: a hero, one sentence, and at most three pointed rows.
/// Three rows is a ceiling, not a target — a fourth row means the page is
/// saying two things and wants splitting.
struct TutorialPage: Identifiable {
    struct Point: Hashable {
        let symbol: String
        let text: String
    }

    let id: Int
    let systemImage: String
    let title: String
    let intro: String
    let points: [Point]

    static let all: [TutorialPage] = [
        TutorialPage(
            id: 0,
            systemImage: "figure.walk",
            title: "Willkommen bei Nachbesuch",
            intro: "Dein ruhiger Begleiter für Nachbesuche von Tür zu Tür.",
            points: [
                Point(symbol: "map.fill", text: "Sehen, wo es weitergeht"),
                Point(symbol: "checkmark.circle.fill", text: "Jeden Besuch mit einem Tipp eintragen"),
                Point(symbol: "archivebox.fill", text: "Am Ende belegen und sichern"),
            ]
        ),
        TutorialPage(
            id: 1,
            systemImage: "map.fill",
            title: "Die Karte ist die Arbeit",
            intro: "Pins setzen, Status sehen, Gebiet abstecken.",
            points: [
                Point(symbol: "plus.circle.fill", text: "„Haus hinzufügen“ erfasst das Haus im Fadenkreuz"),
                Point(symbol: "pentagon.fill", text: "„Gebiet einzeichnen“ markiert deine Runde"),
                Point(symbol: "square.and.arrow.down.fill", text: "„Häuser laden“ holt Adressen aus Kartendaten"),
            ]
        ),
        TutorialPage(
            id: 2,
            systemImage: "house.fill",
            title: "Ein Haus, ein Pin",
            intro: "Antippen öffnet das Haus, jede Tür bekommt ihren Status.",
            points: [
                Point(symbol: "heart.fill", text: "Dabei, Nein, Niemand da — ein Tipp genügt"),
                Point(symbol: "clock.fill", text: "„Später“ bucht gleich die Uhrzeit dazu"),
                Point(symbol: "exclamationmark.triangle.fill", text: "Die Duplikat-Warnung meint es ernst: lieber öffnen als doppelt anlegen"),
            ]
        ),
        TutorialPage(
            id: 3,
            systemImage: "list.bullet.clipboard.fill",
            title: "Die Liste führt dich",
            intro: "Nach Straßen gruppiert, offene Türen zuerst.",
            points: [
                Point(symbol: "line.3.horizontal.decrease.circle.fill", text: "Filter-Chips zeigen nur, was du brauchst"),
                Point(symbol: "arrow.left.and.right", text: "Wischen setzt Schnellstatus, Undo macht's rückgängig"),
                Point(symbol: "location.fill", text: "„Nächste zuerst“ sortiert nach Entfernung zu dir"),
            ]
        ),
        TutorialPage(
            id: 4,
            systemImage: "bell.badge.fill",
            title: "Termine im Blick",
            intro: "Gebuchte Uhrzeiten melden sich von selbst.",
            points: [
                Point(symbol: "clock.badge.checkmark.fill", text: "„Später“ erinnert pünktlich an die Tür"),
                Point(symbol: "calendar.badge.clock", text: "Optional: Mo–Fr ans Senden der Liste erinnern lassen"),
                Point(symbol: "arrow.clockwise", text: "Tag 2 gehört den echten Zweitbesuchen"),
            ]
        ),
        TutorialPage(
            id: 5,
            systemImage: "archivebox.fill",
            title: "Archiv: Bilanz und Beleg",
            intro: "Was die Runde gebracht hat — und der Nachweis dafür.",
            points: [
                Point(symbol: "chart.bar.fill", text: "Die Bilanz zeigt den Stand deines Gebiets"),
                Point(symbol: "doc.richtext.fill", text: "PDF für die Ablage, Text für die Nachricht"),
                Point(symbol: "arrow.down.doc.fill", text: "Backup erstellen, bevor du etwas löschst"),
            ]
        ),
        TutorialPage(
            id: 6,
            systemImage: "externaldrive.fill",
            title: "Deine Daten bleiben deine",
            intro: "Jeder zeichnet sein eigenes Gebiet — und sichert es selbst.",
            points: [
                Point(symbol: "person.fill", text: "Gebiete und Notizen werden auf deinem Gerät gespeichert"),
                Point(symbol: "clock.arrow.circlepath", text: "Die App sichert täglich automatisch im Hintergrund"),
                Point(symbol: "trash.fill", text: "Sicherung teilen oder in Dateien speichern, bevor du ein Gebiet löschst"),
            ]
        ),
    ]
}

private struct TutorialDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool
    let accent: Color

    var body: some View {
        Capsule(style: .continuous)
            .fill(isActive ? AnyShapeStyle(accent) : AnyShapeStyle(.quaternary))
            .frame(width: isActive ? 16 : 6, height: 6)
            .animation(.appFeedback(reduceMotion: reduceMotion), value: isActive)
            .accessibilityHidden(true)
    }
}

private struct TutorialCard: View {
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 44
    let page: TutorialPage

    /// Capped: at AX5 the uncapped metric reaches ~176 pt, pushing the points
    /// off-screen and forcing the ScrollView + card to re-layout across all 7
    /// preloaded pages. Decorative hero stays decorative.
    private var cappedHero: CGFloat { min(heroSize, 60) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.regular) {
                Image(systemName: page.systemImage)
                    .font(.system(size: cappedHero))
                    .foregroundStyle(.white)
                    .frame(width: cappedHero * 2, height: cappedHero * 2)
                    .background(accent.gradient, in: Circle())
                    .overlay { GlassSheen(shape: Circle()) }
                    .accessibilityHidden(true)

                Text(page.title)
                    .font(.title2.weight(.bold))

                Text(page.intro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(page.points, id: \.self) { point in
                    HStack(alignment: .top, spacing: AppSpacing.snug) {
                        Image(systemName: point.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(accent)
                            .frame(width: 26)
                            .accessibilityHidden(true)
                        Text(point.text)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(AppSpacing.loose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentCard(cornerRadius: AppRadius.card)
        .accessibilityElement(children: .contain)
    }
}
