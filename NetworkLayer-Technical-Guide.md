# The Life of a Network Request

### A beginner-friendly journey through the NetworkLayer package

---

## Before We Start: The Big Picture

Forget file names for a second. Picture **one request** — a user opens
a screen, and data needs to travel from a server in the cloud to a list
on their phone. That data crosses **eight checkpoints** before it ever
becomes pixels on screen.

This guide follows **one request, start to finish**, like a package
being shipped through a delivery network. Every component you built
is a checkpoint on that route.

```
 SwiftUI View  →  ViewModel  →  UseCase  →  Repository  →  Endpoint
      ↓                                                        ↓
  (renders)                                              ┌─────────────┐
      ↑                                                  │  APIClient  │
      └──────────────── decoded data ───────────────────┤  (the hub)  │
                                                          └─────────────┘
                                                                 ↓
                              Dedup → Cache → Connectivity → Auth → URLSession → Retry
```

Let's walk it one step at a time.

---

## Part 1 — The Story: One Request's Complete Journey

**Scenario:** the user opens the Posts screen for the first time.

### Checkpoint 1 — The Tap (View)

The `PostListView` appears. SwiftUI calls `.task { viewModel.onAppear() }`.
The View doesn't know what an API is. It only knows one thing:
*"tell the ViewModel I'm visible."*

```swift
.task { viewModel.onAppear() }
```

### Checkpoint 2 — The ViewModel Takes Charge

`PostListViewModel.onAppear()` flips its state to `.loading`.
SwiftUI immediately re-renders — the user sees a spinner **before**
any network call has even started.

```
state = .loading   →   View shows ProgressView
```

The ViewModel then hands the real work to a `Task`, and delegates the
actual *business logic* downward. It does not know what a URL is.

### Checkpoint 3 — The UseCase Applies Business Rules

`FetchPostsUseCase.execute()` is where **domain rules** live — things
that have nothing to do with networking. In our sample: *"hide posts
with an empty title."* In the full package: *"a suspended account is
an error, not a success."*

> 💡 **Why does this layer exist?** So business rules never leak into
> the ViewModel (which only cares about UI state) or the Repository
> (which only cares about fetching data).

### Checkpoint 4 — The Repository Translates

`PostRepositoryImpl.fetchPosts()` is the translator between **your
app's language** (`[Post]`) and **the network's language**
(`Endpoint`, `Data`, JSON). It builds a `PostEndpoint.fetchPosts`
value — a plain description of *what* to fetch, not *how*.

```
Endpoint = "GET https://jsonplaceholder.typicode.com/posts,
            cache for 5 minutes, no auth needed, retryable"
```

The Repository then hands that description to `APIClient` and waits.

### Checkpoint 5 — APIClient: The Hub Where Everything Converges

This is the heart of the system. Every enterprise feature you asked
for lives here, and they all fire **in a strict order**, like security
checkpoints at an airport:

```
┌─────────────────────────────────────────────────────────────────┐
│                          APIClient                               │
│                                                                   │
│   ①  Dedup Check ──── "Is this exact request already flying?"    │
│         │ no                                                     │
│         ▼                                                        │
│   ②  Cache Check ──── "Do I already have a fresh answer?"        │
│         │ no fresh cache          │ yes → return cached data      │
│         ▼                          (network never touched!)      │
│   ③  Connectivity ─── "Is the device even online?"               │
│         │ yes            │ no → try stale cache, else .offline   │
│         ▼                                                        │
│   ④  Attach Auth ──── "Do I need a token? Is it still valid?"    │
│         │                                                         │
│         ▼                                                        │
│   ⑤  URLSession ──── the ACTUAL network call happens HERE        │
│         │                                                         │
│         ▼                                                        │
│   ⑥  Check response ── success? failure? 401? retryable error?  │
│         │                                                         │
│         ▼                                                        │
│   ⑦  Store in Cache (only if successful + cacheable)             │
│         │                                                         │
│         ▼                                                        │
│   ⑧  Decode JSON off the main thread                             │
└─────────────────────────────────────────────────────────────────┘
```

Let's zoom into the two steps everyone asks about.

### Checkpoint 6 — What Happens on Failure? (Retry weaves in naturally)

Say step ⑤ comes back with a `503 Service Unavailable`. The story
doesn't end — `APIClient` doesn't panic and doesn't just retry blindly
either. It asks three questions, one after another:

| Question | Answer drives... |
|---|---|
| Is this endpoint even allowed to retry? | GET = usually yes, risky POST = usually no |
| Is this status code transient? | 429/500s = yes, 400/404 = no, don't waste time |
| Did the server tell me how long to wait? | Honor `Retry-After` if present |

If retry is warranted, it waits — **not** a fixed delay, but a
**jittered, exponentially growing** delay, so if 10,000 phones all
failed at once, they don't all retry at the exact same millisecond
and hammer the recovering server again.

```
Attempt 1 fails → wait ~0.3s (random, up to base delay)
Attempt 2 fails → wait ~1.1s (random, up to 2× base delay)
Attempt 3 fails → wait ~3.4s (random, up to 4× base delay)
                → give up, surface the error
```

This isn't a separate system bolted on — it's simply what happens
*inside* step ⑥, before the request is considered finished.

### Checkpoint 7 — What Happens on a 401? (Token refresh weaves in naturally)

Same checkpoint ⑥, different branch. A `401` means "your token is no
good." Instead of failing the request outright, `APIClient` pauses
this ONE request and asks `TokenStore`: *"can you get me a valid
token?"*

Here's the part that matters at scale: if **ten screens** all hit a
401 in the same instant (common after backgrounding the app for a
while), all ten don't each start their own refresh call. They all
ask the same question and get funneled into **one shared refresh**:

```
Request A ─┐
Request B ─┼──►  TokenStore.refresh()  ──► ONE network call ──► new token
Request C ─┘                                                        │
                                                                     ▼
                                          A, B, C all retry with the SAME new token
```

Once the fresh token arrives, the *original* request is retried
automatically, invisibly to the ViewModel. The ViewModel never even
knows a refresh happened — it just eventually gets its data (or a
real, final error if the refresh itself failed).

### Checkpoint 8 — The Trip Home

Data flows back up **the exact same corridor it came down**:

```
URLSession → APIClient (decodes JSON off-main) → Repository (returns [Post])
    → UseCase (applies business rule) → ViewModel (state = .loaded([Post]))
    → View (re-renders, SwiftUI diffs the List automatically)
```

The user sees posts appear. Total elapsed knowledge, from the View's
perspective: *"I called onAppear, and later my state changed."* That
simplicity is the entire point of the architecture — every checkpoint
above is invisible to the layer above it.

---

## Part 2 — Why Package It? (The Business Case)

You could've written all this logic directly inside one View. Here's
why wrapping it as a **separate Swift Package** pays for itself:

| Benefit | What it actually means in practice |
|---|---|
| **Reusability** | Drop `NetworkLayer` into a second app tomorrow — zero rewrite. Only the `Endpoint`s and models change. |
| **Testability** | 50+ tests run in milliseconds with zero real network calls, because every dependency is a protocol (`NetworkClient`, `TokenRefreshing`, `NetworkMonitoring`). |
| **Maintainability** | Fix a retry bug **once**, in one file — every feature and every app using the package gets the fix. |
| **Scalability** | Add a new feature (e.g. "Comments") by writing ONE new `Endpoint` + `Repository`. The dedup, caching, auth, and retry machinery is already done. |
| **Team velocity** | A junior dev building a new screen only ever touches `View → ViewModel → UseCase → Repository`. They never need to understand `URLSession` internals to ship a feature. |
| **Single source of truth** | Token refresh logic, cache policy, and retry rules are defined once — no two features can silently drift into different (buggy) networking behavior. |

> **In one sentence:** the package turns "how do I safely make a
> network call" from a question every feature answers separately,
> into a question answered **once, correctly, and tested.**

---

## Part 3 — The Same Story, Now Inside a Real App

This is exactly how `SamplePostsApp` uses the package — same
checkpoints, same order, just with concrete names filled in.

```
┌─────────────────────────────────────────────────────────────────┐
│                        SamplePostsApp                            │
│                                                                   │
│  PostListView            "I appeared, tell my ViewModel"         │
│        │                                                          │
│        ▼                                                          │
│  PostListViewModel       state = .loading  →  spinner shows       │
│        │                                                          │
│        ▼                                                          │
│  FetchPostsUseCase       "filter out empty-title posts"           │
│        │                                                          │
│        ▼                                                          │
│  PostRepositoryImpl      builds PostEndpoint.fetchPosts            │
│        │                                                          │
│        ▼                                                          │
│  ═══════════ NetworkLayer package boundary ═══════════            │
│        │                                                          │
│        ▼                                                          │
│  APIClient   ①dedup ②cache ③online? ④(no auth needed) ⑤fetch      │
│        │                                                          │
│        ▼                                                          │
│  jsonplaceholder.typicode.com/posts   ← the real internet          │
│        │                                                          │
│        ▼                                                          │
│  LossyArray<Post> decode   (one bad post ≠ blank screen)           │
│        │                                                          │
│  ═══════════════════════════════════════════════════════          │
│        ▼                                                          │
│  state = .loaded([Post])  →  List renders  →  user sees posts      │
└─────────────────────────────────────────────────────────────────┘
```

### The One Difference Worth Noticing

Notice `PostEndpoint.requiresAuth` is `false`, and `AppDependencies`
wires `APIClient` with `authenticator: nil`. That's it — checkpoint ④
(token attachment) is simply **skipped** for this app, because
JSONPlaceholder is a public API. Nothing else in the story changes.
This proves the architecture scales *down* to "no auth needed" just
as cleanly as it scales *up* to "coordinate ten concurrent refreshes."

---

## Cheat Sheet: Layer → File → Job

| Layer | File | One-line job |
|---|---|---|
| View | `PostListView.swift` | Show state, forward taps |
| ViewModel | `PostListViewModel.swift` | Hold UI state, own the `Task` |
| UseCase | `FetchPostsUseCase.swift` | Apply business rules |
| Repository | `PostRepositoryImpl.swift` | Translate domain ↔ network |
| Endpoint | `PostEndpoint.swift` | Describe *what* to fetch |
| APIClient | `APIClient.swift` | Orchestrate every checkpoint |
| Dedup | `RequestDeduplicator.swift` | Collapse identical concurrent calls |
| Cache | `CachePolicy.swift` | Skip the network when data is fresh |
| Connectivity | `NetworkMonitor.swift` | Fail fast when offline |
| Auth | `TokenStore.swift` / `TokenAuthenticator.swift` | Attach + refresh tokens safely |
| Retry | `RetryPolicy.swift` | Survive transient failures gracefully |
| Decoding | `LossyCodable.swift` / `SafeDecodable.swift` | Survive imperfect server data |

---

## Closing Thought

Every "enterprise feature" in this system — caching, dedup, retries,
token refresh — is really just **one question**, asked at the right
checkpoint, before the request is allowed to continue:

> *"Given everything I know right now, is it actually necessary to
> hit the network — and if I do, how do I do it safely?"*

That single question, asked consistently in one place, is what turns
a pile of `URLSession` calls into a system you can trust.
