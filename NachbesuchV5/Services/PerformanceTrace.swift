import os

/// Instruments signposts.
///
/// Guarded by `isEnabled`: the previous version allocated a signpost ID and emitted
/// both intervals unconditionally, in release builds, from inside the house-decode
/// path that runs for every house on every list render.
///
/// `OSSignposter` also carries the interval name inside the state token, so a
/// mismatched begin/end name is no longer expressible — the old API took the name as
/// a duplicated string literal at each call site.
nonisolated enum PerformanceTrace {
    static let signposter = OSSignposter(
        subsystem: "at.volkshilfe.nachbesuch",
        category: .pointsOfInterest
    )

    nonisolated static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        return signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    nonisolated static func end(_ name: StaticString, id: OSSignpostIntervalState?) {
        guard let id, signposter.isEnabled else { return }
        signposter.endInterval(name, id)
    }
}
