# ModernNetworkLayer

[![Swift](https://img.shields.io/badge/Swift-5.10%20%2F%206-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2017%2B%20%7C%20macOS%2014%2B-blue.svg)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`ModernNetworkLayer` is a lightweight, production-ready Swift package for
modern iOS and macOS apps. Built with Swift 5.10 / Swift 6 strict
concurrency, it gives you a protocol-oriented, fully testable networking
stack — without pulling in Alamofire or any third-party dependency.

---

## ⚡ Features

- **Modern Swift Concurrency** — built entirely on `async`/`await` and `Sendable` types.
- **Protocol-Oriented** — every piece (`NetworkClient`, `TokenRefreshing`, `NetworkMonitoring`) is an interface, so you can mock anything.
- **Auth & Token Management** — token storage, automatic header injection, and single-flight refresh on 401 (no duplicate refresh calls from concurrent requests).
- **Request Deduplication** — identical in-flight requests collapse into one network call.
- **Smart Retry** — exponential backoff with jitter, honors the server's `Retry-After` header.
- **Resilient Decoding** — `LossyCodable` and `SafeDecodable` let a single malformed array element or field degrade gracefully instead of crashing the whole decode.
- **Keychain-Backed Storage** — sensitive tokens never touch `UserDefaults`.
- **Unit Testable** — mock via standard `URLProtocol`, no live network calls needed.
- **Multi-Platform** — iOS 17.0+ and macOS 14.0+.

---

## 📦 Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/ManjunathAnawal/ModernNetworkLayer.git
```

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ManjunathAnawal/ModernNetworkLayer.git", from: "1.0.0")
]
```

---

## 🚀 Quick Start

### 1. Define an endpoint

```swift
import Foundation
import NetworkLayer

enum UserEndpoint: Requestable {
    case fetchProfile(userId: String)

    var path: String {
        switch self {
        case .fetchProfile(let userId): return "/api/v1/users/\(userId)"
        }
    }

    var method: HTTPMethod { .get }
    var headers: [String: String]? { ["Content-Type": "application/json"] }
}
```

### 2. Execute a request

```swift
import NetworkLayer

struct UserProfile: Decodable, Sendable {
    let id: String
    let name: String
    let email: String
}

final class UserRepository {
    private let client: NetworkServicing

    init(client: NetworkServicing = NetworkManager()) {
        self.client = client
    }

    func getUser(id: String) async throws -> UserProfile {
        let endpoint = UserEndpoint.fetchProfile(userId: id)
        return try await client.execute(endpoint)
    }
}
```

That's it — auth, retry, dedup, caching, and resilient decoding are
already handled for you underneath `client.execute(_:)`.

---

## 🏗 How It Works

Every request flows through one hub, `APIClient`, which runs these
checks in order: **dedup → cache → connectivity → auth → network call →
retry-on-failure → decode**. Shared mutable state (tokens, in-flight
requests) always lives inside an `actor`, never behind a plain bool
flag, so concurrent 401s or concurrent identical requests never trigger
duplicate work.

| Layer | File | Job |
|---|---|---|
| Networking hub | `APIClient.swift` | Orchestrates every request |
| Auth | `TokenStore.swift` / `TokenAuthenticator.swift` | Store, attach, and refresh tokens |
| Retry | `RetryPolicy.swift` | Backoff + jitter, respects `Retry-After` |
| Dedup | `RequestDeduplicator.swift` | Collapses identical concurrent requests |
| Decoding | `LossyCodable.swift` / `SafeDecodable.swift` | Survives partially-malformed server data |

A full step-by-step walkthrough of one request's life lives in
[`NetworkLayer-Technical-Guide.md`](NetworkLayer-Technical-Guide.md).

---

## 🧪 Unit Testing & Mocking

Since `NetworkServicing` is protocol-based, inject a mocked session via
`URLProtocol` — no real network calls, no flakiness:

```swift
import XCTest
@testable import NetworkLayer

final class NetworkLayerTests: XCTestCase {
    func testFetchProfileSuccess() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = NetworkManager(session: session)
        // Assert against the MockURLProtocol response...
    }
}
```

---

## 📄 License

Available under the [MIT License](LICENSE).
