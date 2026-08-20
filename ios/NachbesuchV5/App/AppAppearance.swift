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

struct AppearanceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance.mode") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("appearance.accent") private var accentRaw = AppAccent.volkshilfe.rawValue

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
                            columns: [GridItem(.adaptive(minimum: 112), spacing: AppSpacing.snug)],
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

                    Text("Die Einstellung gilt sofort für Karte, Liste und Archiv.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(AppSpacing.regular)
            }
            .background { AppBackdrop() }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
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
        .padding(AppSpacing.regular)
        .contentCard(cornerRadius: AppRadius.card)
    }
}
