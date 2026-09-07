```markdown
# ModernNetworkLayer

`ModernNetworkLayer` is a lightweight, production-ready Swift package designed for modern iOS and macOS applications. Built with Swift 5.10 / Swift 6 strict concurrency, it provides a protocol-oriented, testable, and robust network architecture.

---

## ⚡ Features

* **Modern Swift Concurrency**: Built from the ground up using `async`/`await` and `Sendable` types.
* **Protocol-Oriented**: Highly decoupled interfaces for endpoints, requests, and networking clients.
* **Authentication & Token Management**: Native token store management, automatic header injection, and token refresh interceptors.
* **Keychain Integration**: Secure storage layer for sensitive authentication credentials.
* **Unit Testable**: Easily mockable using standard `URLProtocol` implementations without hitting live servers.
* **Multi-Platform Support**: Target iOS 17.0+ and macOS 14.0+.

---

## 📦 Installation

### Swift Package Manager (SPM)

Add `ModernNetworkLayer` directly to your Xcode project:

1. Open Xcode and select **File > Add Package Dependencies...**
2. Enter the repository URL:
   ```text
   [https://github.com/ManjunathAnawal/ModernNetworkLayer.git](https://github.com/ManjunathAnawal/ModernNetworkLayer.git)

```

3. Set the **Dependency Rule** to `Up to Next Major Version` with `1.0.0`.
4. Select your target and click **Add Package**.

Or add it to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "[https://github.com/ManjunathAnawal/ModernNetworkLayer.git](https://github.com/ManjunathAnawal/ModernNetworkLayer.git)", from: "1.0.0")
]

```

---

## 🚀 Quick Start

### 1. Define an Endpoint

Implement your request configuration conforming to `Requestable` (or your endpoint protocol):

```swift
import Foundation
import NetworkLayer

enum UserEndpoint: Requestable {
    case fetchProfile(userId: String)
    
    var path: String {
        switch self {
        case .fetchProfile(let userId):
            return "/api/v1/users/\(userId)"
        }
    }
    
    var method: HTTPMethod {
        return .get
    }
    
    var headers: [String: String]? {
        return ["Content-Type": "application/json"]
    }
}

```

### 2. Execute a Network Request

```swift
import NetworkLayer

struct UserProfile: Decodable, Sendable {
    let id: String
    let name: String
    let email: String
}

class UserRepository {
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

---

## 🧪 Unit Testing & Mocking

Since `NetworkServicing` is protocol-based, you can inject mock configurations or `URLProtocol` handlers directly into `NetworkManager` during tests:

```swift
import XCTest
@testable import NetworkLayer

final class NetworkLayerTests: XCTestCase {
    func testFetchProfileSuccess() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        
        let client = NetworkManager(session: session)
        // Perform assertions against MockURLProtocol response...
    }
}

```

---

## 📄 License

This project is available under the MIT License.

```
