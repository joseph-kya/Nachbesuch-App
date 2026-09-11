import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case volkshilfe, orange, blue, purple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volkshilfe: "Volkshilfe"
        case .orange: "Orange"
        case .blue: "Blau"
        case .purple: "Violett"
        }
    }

    var color: Color {
        switch self {
        case .volkshilfe: .red
        case .orange: .orange
        case .blue: .blue
        case .purple: .purple
        }
    }
}

/// The chosen accent, as a value views can do colour maths on.
///
/// `Color.accentColor` cannot do this job: it resolves to the **asset catalog**
/// `AccentColor` — the deep Volkshilfe red — and ignores both the `.tint()` applied
/// to the tab view and the accent the user picked in the settings sheet. Every
/// surface built from `Color.accentColor.opacity(…)` therefore drew a *different,
/// darker red* than the tinted controls beside it, which is exactly the mismatch
/// you saw walking from the map into the list. It also meant picking "Blau" left
/// the backdrops and street icons stubbornly red.
///
/// `ShapeStyle.tint` fixes the plain fills but not the ones that need `.opacity`,
/// so the accent travels as an explicit environment value instead.
private struct AppAccentKey: EnvironmentKey {
    static let defaultValue: Color = AppAccent.volkshilfe.color
}

extension EnvironmentValues {
    var appAccent: Color {
        get { self[AppAccentKey.self] }
        set { self[AppAccentKey.self] = newValue }
    }
}

struct AppearanceSettingsSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance.mode") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("appearance.accent") private var accentRaw = AppAccent.volkshilfe.rawValue
    @AppStorage(ReminderSettings.dailyListKey) private var dailyListRemindersEnabled = false
    /// Whether the system will actually deliver anything. Checked on appear so a
    /// toggle that is on but muted in iOS Settings cannot silently lie.
    @State private var notificationsAllowed = true

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    private var accent: Binding<AppAccent> {
        Binding(
            get: { AppAccent(rawValue: accentRaw) ?? .volkshilfe },
            set: { accentRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.loose) {
                    settingsGroup("Darstellung", systemImage: "circle.lefthalf.filled") {
                        Picker("Darstellung", selection: appearance) {
                            ForEach(AppAppearance.allCases) { value in
                                Label(value.title, systemImage: value.systemImage).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .sensoryFeedback(.selection, trigger: appearanceRaw)
                    }

                    settingsGroup("Akzentfarbe", systemImage: "paintpalette.fill") {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 260 : 140), spacing: AppSpacing.snug)],
                            spacing: AppSpacing.snug
                        ) {
                            ForEach(AppAccent.allCases) { value in
                                Button {
                                    accent.wrappedValue = value
                                } label: {
                                    HStack(spacing: AppSpacing.tight) {
                                        Circle()
                                            .fill(value.color)
                                            .frame(width: 18, height: 18)
                                        Text(value.title)
                                            .font(.subheadline.weight(.medium))
                                        Spacer(minLength: 0)
                                        if accent.wrappedValue == value {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(value.color)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: AppTouch.minimum)
                                    .contentPanel(cornerRadius: AppRadius.control)
                                }
                                .buttonStyle(PressableRowStyle())
                                .accessibilityAddTraits(
                                    accent.wrappedValue == value ? .isSelected : []
                                )
                            }
                        }
                        .sensoryFeedback(.selection, trigger: accentRaw)
                    }

                    settingsGroup("Erinnerungen", systemImage: "bell.badge.fill") {
                        Toggle(isOn: $dailyListRemindersEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ans Senden der Liste erinnern")
                                    .font(.subheadline.weight(.medium))
                                Text(reminderTimesText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: AppTouch.minimum)
                        .sensoryFeedback(.selection, trigger: dailyListRemindersEnabled)

                        if dailyListRemindersEnabled && !notificationsAllowed {
                            Label(
                                "Mitteilungen sind für Nachbesuch ausgeschaltet. Die Erinnerung erscheint erst, wenn du sie in den iOS-Einstellungen erlaubst.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("Termine unter „Später“ erinnern unabhängig von diesem Schalter an den nächsten Besuch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Erinnerungen benötigen erlaubte Mitteilungen. Die App versendet keine Listen automatisch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsGroup("Über Nachbesuch", systemImage: "info.circle") {
                        NavigationLink {
                            AppInformationView()
                        } label: {
                            Label("Datenschutz & Support", systemImage: "hand.raised")
                                .frame(minHeight: AppTouch.minimum)
                        }
                    }

                }
                .padding(AppSpacing.regular)
            }
            .background { AppBackdrop() }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: dailyListRemindersEnabled) {
                await ReminderService.applyDailyListReminders(enabled: dailyListRemindersEnabled)
                notificationsAllowed = await ReminderService.isAuthorized()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    /// "Mo–Fr · 14:00, 16:00 und 18:00" — built from the schedule rather than typed
    /// out, so the label cannot drift from the times actually booked.
    private var reminderTimesText: String {
        let times = ReminderService.dailyListHours.map { String(format: "%02d:00", $0) }
        let joined: String
        if let last = times.last, times.count > 1 {
            joined = "\(times.dropLast().joined(separator: ", ")) und \(last)"
        } else {
            joined = times.joined()
        }
        return "Mo–Fr · \(joined)"
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.snug) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.regular)
        .contentCard(cornerRadius: AppRadius.card)
    }
}
