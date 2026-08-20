import Foundation
import SwiftData

/// The persisted schema, pinned to an explicit version.
///
/// The app previously used `.modelContainer(for:)`, which resolves migrations by
/// inference only and calls `fatalError` when the store cannot be opened. That made
/// the *next* non-additive model change a permanent launch crash for every existing
/// install, with no way for anyone to get their data out — for an app whose entire
/// value is door-by-door field work that cannot be re-collected.
///
/// V1 captures today's shape verbatim so nothing migrates now. Future changes add a
/// `SchemaV2` and a `MigrationStage` here.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [House.self, Gebiet.self, CampaignDay.self]
    }
}

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Result of opening the store, so the UI can tell the difference between "working"
/// and "your data is still on disk but unreadable".
enum StoreLoadResult {
    case ready(ModelContainer)
    /// The on-disk store could not be opened. Carries a scratch container so the app
    /// still launches, plus the underlying error and the store's location so the
    /// user can be offered a copy of the file.
    case failed(ModelContainer, error: any Error, storeURL: URL?)

    var container: ModelContainer {
        switch self {
        case .ready(let container): container
        case .failed(let container, _, _): container
        }
    }

    var failure: (error: any Error, storeURL: URL?)? {
        switch self {
        case .ready: nil
        case .failed(_, let error, let url): (error, url)
        }
    }
}

enum AppStore {
    static let storeURL: URL = URL.applicationSupportDirectory
        .appending(path: "default.store", directoryHint: .notDirectory)

    /// Opens the real store, falling back to an in-memory one so a corrupt database
    /// degrades to "the app opens and explains itself" instead of "the app is dead".
    static func load() -> StoreLoadResult {
        let schema = Schema(versionedSchema: SchemaV1.self)
        do {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: AppMigrationPlan.self,
                configurations: configuration
            )
            return .ready(container)
        } catch {
            let scratch = try? ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
            guard let scratch else {
                // Nothing at all can be opened — there is no meaningful recovery from
                // here, and continuing would crash on the first query anyway.
                fatalError("Weder der gespeicherte noch ein temporärer Datenspeicher konnte geöffnet werden: \(error)")
            }
            return .failed(scratch, error: error, storeURL: storeURL)
        }
    }
}
