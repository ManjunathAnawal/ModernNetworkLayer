# NetworkLayer

A production-grade networking + API layer for a SwiftUI app built with
Clean Architecture (**View → ViewModel → UseCase → Repository**), modern
Swift Concurrency (`async/await`, `actor`, `@Observable`), and a
Coordinator-compatible presentation layer.

## Requirements
- Swift 5.10+, iOS 17+ (for `@Observable` / `ContentUnavailableView`)
- No third-party dependencies

## Running the tests

```bash
swift test
```

The suite uses **Swift Testing** (`import Testing`) rather than XCTest,
targeting `swift test` on macOS 14+ so it also runs in CI without a
simulator. All networking tests intercept `URLSession` via
`MockURLProtocol` (real `URLSession`, zero live network calls); actor
concurrency behavior (deduplication, token refresh coalescing) is proven
using real `TaskGroup`s, not simulated with sleeps and hope.

## Module map

```
Sources/
  Core/
    NetworkError.swift        – unified error taxonomy
    NetworkMonitor.swift      – NWPathMonitor-backed connectivity actor
    CachePolicy.swift         – per-endpoint cache policy + URLCache wrapper
    RequestDeduplicator.swift – actor: single-flight in-flight request coalescing
  Auth/
    KeychainHelper.swift      – Keychain Services wrapper (+ in-memory test double)
    TokenStore.swift          – actor: token persistence + single-flight refresh
    TokenAuthenticator.swift  – request adaptation (Authorization header) + 401 recovery
  Client/
    Endpoint.swift            – declarative request description
    RetryPolicy.swift         – exponential backoff + full jitter + Retry-After
    APIClient.swift           – orchestrates monitor→cache→dedup→auth→transport→retry
  Codable/
    LossyCodable.swift        – @LossyArray: drop malformed elements, keep the rest
    SafeDecodable.swift       – UnknownCaseRepresentable: forward-compatible enums
    JSONDecoder+Robust.swift  – shared decoder config (snake_case, flexible ISO8601)
  Domain/                     – protocols + business rules (framework-agnostic)
  Data/                       – concrete Repository + Endpoint definitions
  Presentation/               – @Observable ViewModel, View, Coordinator sketch
  AppDependencies.swift       – composition root (manual DI)
Tests/
  Mocks/                      – MockURLProtocol, TestDoubles
  *.swift                     – one suite per component, described below
```

## Request lifecycle (what `APIClient` actually does, in order)

1. **Deduplication key** computed from method + URL + body hash.
2. If an **identical request is already in flight**, await its result
   instead of starting a new one (`RequestDeduplicator`).
3. **Cache check** — a fresh entry (per `CachePolicy`) short-circuits the
   network entirely.
4. **Connectivity gate** — `NetworkMonitor.isConnected()` is checked
   *before* touching `URLSession`. Offline + no cache → `.offline` is
   thrown near-instantly instead of waiting out a socket timeout. Offline
   + stale cache → the stale cache is served rather than failing.
5. **Auth attachment** — `TokenAuthenticator` fetches (and transparently
   refreshes, if needed) a valid access token and attaches it.
6. **Transport + retry** — the request executes; retryable failures
   (429/5xx/timeouts) are retried with jittered exponential backoff,
   honoring a server `Retry-After` header when present.
7. **401 recovery** — a 401 triggers exactly one coordinated token refresh
   (shared across concurrent requests) and one retry with the new token;
   a second consecutive 401 is surfaced as a normal HTTP error rather than
   looping.
8. **Cache write** — successful, cacheable GET responses are stored for
   next time.
9. **Off-main decoding** — `JSONDecoder.decode` runs inside the `async`
   function's own execution context (background, via the cooperative
   thread pool), never on `@MainActor`; `@Observable` ViewModels hop back
   to the main actor automatically at their own `await` resumption point.

## Key architectural trade-offs (see inline `TRADE-OFF NOTE` comments for full detail)

| Decision | Why | When to choose the alternative |
|---|---|---|
| Single flat `NetworkError` enum | Simple exhaustive `switch` at ViewModel call sites | Multi-module SDK shipped externally — namespace per module instead |
| `URLCache`-backed response cache | Free, correct HTTP cache semantics, no bespoke code | Need to cache *decoded domain models* with custom invalidation — add a repository-level cache on top |
| Actors for `RequestDeduplicator` / `TokenStore` / `NetworkMonitor` | Automatic serialization of async-mutated state, no manual locking | Extremely hot synchronous path where actor-hop overhead is measured to matter — use `NSLock` instead |
| Jittered exponential backoff | Avoids thundering-herd retries against a recovering backend | Low-traffic internal tools where herd effects don't matter — fixed delay is simpler |
| `LossyArray` (drop malformed elements) | One bad record shouldn't blank an entire screen | Payload where partial data is *worse* than no data (e.g. financial ledgers) — decode strictly instead |
| `UnknownCaseRepresentable` fallback enums | Backend ships new enum values ahead of app releases; must not crash-decode | Field is genuinely optional and "unrecognized" isn't a meaningful UI state — use `Optional` instead |
| Keychain via raw Security APIs | Avoids a third-party dependency for something this security-sensitive | A team already standardized on a vetted wrapper (e.g. KeychainAccess) — reuse it |
| UseCase layer even for thin passthroughs | Business rules (e.g. "suspended account is an error state") have one home; ViewModels never hold >1 repository | Small app/prototype with zero domain rules — call the Repository directly |
| Domain model conforms to `Decodable` directly | Fewer types, faster to ship | Wire format is unstable / must support multiple API versions — separate DTO + mapper in `Data/` |
| Manual DI (`AppDependencies`) | Compile-time checked, zero dependency, easy to read top-to-bottom | Large object graph, multiple build flavors, scoped lifetimes — adopt a DI framework |

## Test coverage summary

- **Connectivity**: `NetworkMonitorTests` (contract), `APIClientTests`
  (offline throws without touching the network; offline + stale cache
  fallback).
- **Caching**: `CachePolicyTests` (freshness/expiry math in isolation),
  `APIClientTests` (fresh-cache hit skips network; `.none` policy never
  caches).
- **Deduplication**: `RequestDeduplicatorTests` (concurrent coalescing,
  sequential independence, shared failure propagation).
- **Token refresh / 401**: `TokenStoreTests` (single-flight coalescing
  under real concurrent load, stale-401 double-refresh guard, permanent
  failure clears session), `APIClientTests` (end-to-end 401→refresh→retry,
  double-401 doesn't loop).
- **Retry/backoff**: `RetryPolicyTests` (pure decision + backoff math,
  `Retry-After` parsing for both formats), `APIClientTests` (actual retry
  execution, exhaustion, `Retry-After` overriding configured backoff).
- **Codable resilience**: `CodableResilienceTests` (`LossyArray` drops
  only malformed elements, unknown enum cases fall back gracefully, both
  together end-to-end on the `User` domain model).
- **Clean Architecture seams**: `RepositoryAndUseCaseTests` (Repository/
  UseCase tested with zero networking machinery via `MockNetworkClient`).
