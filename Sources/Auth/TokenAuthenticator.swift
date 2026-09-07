//
//  TokenAuthenticator.swift
//  NetworkLayer
//
//  Bridges `TokenStore` into the request lifecycle: attaches the
//  Authorization header before a request goes out ("request adaptation"),
//  and decides whether a 401 response is recoverable via refresh-and-retry
//  ("response interception"). Kept separate from `APIClient` so the retry/
//  backoff engine and the auth-refresh engine can be tested and reasoned
//  about independently (single responsibility).
//
import Foundation

public protocol RequestAuthenticating: Sendable {
    /// Mutates (a copy of) the request to attach credentials. Endpoints
    /// that opt out of auth (e.g. `POST /login`) skip this via
    /// `Endpoint.requiresAuth == false`.
    func authenticate(_ request: URLRequest) async throws -> URLRequest

    /// Given a request that just failed with 401 and the access token it
    /// was sent with, attempts a refresh and returns a re-authenticated
    /// request to retry. Throws `.unauthorized` if unrecoverable.
    func handleUnauthorized(originalRequest: URLRequest, sentAccessToken: String) async throws -> URLRequest
}

public struct TokenAuthenticator: RequestAuthenticating {
    private let tokenStore: TokenStore

    public init(tokenStore: TokenStore) {
        self.tokenStore = tokenStore
    }

    public func authenticate(_ request: URLRequest) async throws -> URLRequest {
        var mutable = request
        let token = try await tokenStore.validAccessToken()
        mutable.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return mutable
    }

    public func handleUnauthorized(originalRequest: URLRequest, sentAccessToken: String) async throws -> URLRequest {
        let newToken = try await tokenStore.handleUnauthorized(staleAccessToken: sentAccessToken)
        var retryRequest = originalRequest
        retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
        return retryRequest
    }
}
