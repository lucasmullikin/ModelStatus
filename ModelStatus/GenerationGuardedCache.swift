import Foundation

/// A cache keyed by an `Identifier` with:
///
/// 1. A **generation counter** that's bumped on `reset()`. Async fetchers
///    capture the current generation at `beginFetch(_:)` time and only commit
///    results back via `apply(_:for:capturedGeneration:)` when the counter
///    still matches — so a fetch that started against an old configuration
///    can't pollute the post-reset cache.
///
/// 2. An **in-flight set** so a fast menu repaint that calls
///    `beginFetch(_:)` while a previous fetch is still running won't spawn
///    a duplicate request.
///
/// Generic over the value type so the same primitive serves the
/// capabilities-per-instance and available-models-per-instance caches in
/// `AppDelegate`. Both used to be open-coded with parallel mirror state
/// (`capabilitiesInFlight`, `availableModelsInFlight`, a separate
/// `configGeneration` counter); this consolidates them.
///
/// `@MainActor` because the only callers are AppKit menu builders. If a future
/// caller needs to use this from a different actor, swap to an actor type.
@MainActor
final class GenerationGuardedCache<Identifier: Hashable, Value> {
    /// Audit-round-D50-hard: each beginFetch returns a (generation, token)
    /// pair. The token uniquely identifies this fetch even within a single
    /// generation. apply/finishFetch require BOTH to match — so a late-
    /// returning fetch can't commit a stale value after finishFetch already
    /// cleared the in-flight marker and a newer beginFetch issued a fresh
    /// token. The earlier Set<Identifier>-only model allowed exactly this
    /// late-commit race.
    struct FetchToken: Hashable {
        let generation: UInt64
        let id: UInt64
    }

    private var cache: [Identifier: Value] = [:]
    /// Maps key → token for the currently-active fetch. Replaces the old
    /// `Set<Identifier>` in-flight tracker.
    private var inFlight: [Identifier: FetchToken] = [:]
    private var generation: UInt64 = 0
    private var nextTokenID: UInt64 = 0

    /// Bump the generation token, clear cache + in-flight markers. Any fetch
    /// captured against the previous generation will be discarded when it
    /// returns through `apply`.
    func reset() {
        cache.removeAll()
        inFlight.removeAll()
        generation &+= 1
    }

    /// Cached value for `key`, or nil if not fetched (or invalidated).
    func value(for key: Identifier) -> Value? { cache[key] }

    /// Whether a fetch for `key` is currently mid-flight.
    func isInFlight(_ key: Identifier) -> Bool { inFlight[key] != nil }

    /// Mark `key` as in-flight and return a fetch token to capture for the
    /// async work. Returns nil if a fetch is already in flight (caller should
    /// skip its work). The token carries both the generation and a per-fetch
    /// id so a late apply from a completed-then-cleared fetch can't overwrite
    /// a newer fetch's committed value.
    func beginFetch(_ key: Identifier) -> FetchToken? {
        guard inFlight[key] == nil else { return nil }
        nextTokenID &+= 1
        let token = FetchToken(generation: generation, id: nextTokenID)
        inFlight[key] = token
        return token
    }

    /// Apply a fetch result. The result is committed iff the captured token
    /// (a) matches the current generation AND (b) is still the active in-flight
    /// token for that key. Otherwise the result is dropped as stale.
    @discardableResult
    func apply(_ value: Value, for key: Identifier, capturedToken: FetchToken) -> Bool {
        guard capturedToken.generation == generation,
              inFlight[key] == capturedToken else { return false }
        cache[key] = value
        inFlight.removeValue(forKey: key)
        return true
    }

    /// Clear the in-flight marker WITHOUT committing a value. Call this from
    /// failure / cancellation / timeout paths so a transient fetch error
    /// doesn't permanently block re-fetch of the key until the next `reset()`.
    /// Only clears if the captured token is still the active one — guards
    /// against clearing a newer fetch's marker.
    func finishFetch(for key: Identifier, capturedToken: FetchToken) {
        guard capturedToken.generation == generation,
              inFlight[key] == capturedToken else { return }
        inFlight.removeValue(forKey: key)
    }
}
