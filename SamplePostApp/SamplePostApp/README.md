# SamplePostsApp

A minimal SwiftUI app demonstrating the `NetworkLayer` package end-to-end
against a real, free, no-auth-required API:
**https://jsonplaceholder.typicode.com/posts**

## What it demonstrates

- `Endpoint` conformance (`PostEndpoint`) pointing at a real third-party API
- `APIClient` wired up **without** a `TokenAuthenticator` — showing the
  minimum setup for a public API that needs no auth
- `LossyArray<Post>` decoding a **top-level JSON array** directly (not
  behind a wrapper object) — proving the pattern works outside a
  `@propertyWrapper`-on-a-struct-field context too
- `staticData(maxAge: 300)` caching — reopen the list within 5 minutes and
  it loads instantly from `URLCache`, no network call
- Full Clean Architecture flow: `PostListView` → `PostListViewModel`
  (`@Observable`) → `FetchPostsUseCase` → `PostRepositoryImpl` → `APIClient`
- Pull-to-refresh, offline state, and error state UI

## Files

```
SamplePostsApp.swift          – @main App entry / composition root
Model/Post.swift              – matches JSONPlaceholder's post shape
Networking/PostEndpoint.swift – Endpoint conformance for /posts
Data/PostRepository.swift     – NetworkClient → domain model mapping
Domain/FetchPostsUseCase.swift
Presentation/PostListViewModel.swift
Presentation/PostListView.swift
```

## How to run it

This is a set of source files for an **Xcode App target**, not a
standalone SPM executable (SwiftUI's `App` lifecycle needs Xcode's app
bundle/Info.plist). See the step-by-step guide for creating the Xcode
project, adding `NetworkLayer` as a local Swift Package dependency, and
dropping these files in.
