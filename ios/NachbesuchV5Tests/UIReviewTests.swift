import SwiftUI
import Testing
@testable import NachbesuchV5

/// Render the shared content at phone width in both appearances and at AX5.
/// PNGs are retained in the simulator's temporary directory for visual review.
@Suite("UI review renders")
@MainActor
struct UIReviewTests {
    @Test(arguments: [false, true], [false, true])
    func resultControls(dark: Bool, largeText: Bool) throws {
        let content = VStack(alignment: .leading, spacing: AppSpacing.regular) {
            Text("Ergebnis").font(.headline)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: largeText ? 1 : 2),
                spacing: AppSpacing.snug
            ) {
                ForEach(VisitOutcome.primary) { outcome in
                    OutcomeButton(outcome: outcome, isSelected: outcome == .joined) {}
                }
            }
            LaterButton(isSelected: false, bookedAt: nil) {}
            LaterButton(isSelected: true, bookedAt: Date.now.addingTimeInterval(-900)) {}
            Text("Lange Notizen bleiben lesbar und werden nicht durch eine erfundene Zeichenbegrenzung eingeschränkt.")
                .font(.subheadline)
        }
        .padding(AppSpacing.regular)
        .contentCard(elevated: false)
        .padding(AppSpacing.regular)
        .frame(width: 390)
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.dynamicTypeSize, largeText ? .accessibility5 : .large)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        #expect(image.size.width == 390)
        #expect(image.size.height > 300)
        let data = try #require(image.pngData())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-review-\(dark ? "dark" : "light")-\(largeText ? "ax5" : "standard").png")
        try data.write(to: url)
        print("UI_REVIEW_IMAGE \(url.path)")
    }
}
