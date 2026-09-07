//
//  PostEndpoint.swift
//  SamplePostsApp
//
//  Declares the request to JSONPlaceholder using the `Endpoint` protocol
//  from the NetworkLayer package. JSONPlaceholder is free, requires no
//  API key, and its /posts endpoint returns a raw JSON ARRAY at the top
//  level (not wrapped in an object) — that's why the repository below
//  decodes as `LossyArray<Post>` directly rather than into a wrapper type:
//  `LossyArray`'s `init(from:)` works against any decoder, keyed or not,
//  so it can sit at the top level of a response just as easily as behind
//  a JSON key.
//
import Foundation
import NetworkLayer

enum PostEndpoint: Endpoint {
    case fetchPosts
    case fetchPost(id: Int)

    var baseURL: URL { URL(string: "https://jsonplaceholder.typicode.com")! }

    var path: String {
        switch self {
        case .fetchPosts: return "/posts"
        case .fetchPost(let id): return "/posts/\(id)"
        }
    }

    var method: HTTPMethod { .get }

    // JSONPlaceholder is a public, unauthenticated demo API — no bearer
    // token needed, so we skip the auth-attachment step entirely.
    var requiresAuth: Bool { false }

    // Posts are static demo data that never changes, so we cache
    // aggressively: repeat visits to the list within 5 minutes are served
    // instantly from URLCache with zero network round trip.
    var cachePolicy: CachePolicy {
        switch self {
        case .fetchPosts: return .staticData(maxAge: 300)
        case .fetchPost: return .staticData(maxAge: 300)
        }
    }

    var isRetryable: Bool { true } // Both are GETs — safe to retry.
}
