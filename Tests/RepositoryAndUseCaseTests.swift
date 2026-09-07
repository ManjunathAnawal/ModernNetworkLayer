//
//  RepositoryAndUseCaseTests.swift
//  NetworkLayerTests
//
//  Demonstrates the payoff of Clean Architecture's layering: these tests
//  exercise `UserRepositoryImpl` and `FetchUserProfileUseCase` with ZERO
//  networking machinery involved (no URLSession, no MockURLProtocol) —
//  only `MockNetworkClient`, a plain in-memory protocol conformance.
//
import Testing
@testable import NetworkLayer
import Foundation

@Suite("UserRepository & FetchUserProfileUseCase")
struct RepositoryAndUseCaseTests {

    private func makeUser(id: String = "1", status: AccountStatus = .active) -> User {
        User(id: id, displayName: "Test User", email: "test@example.com", status: status, createdAt: Date())
    }

    @Test("Repository forwards the decoded model from NetworkClient")
    func repositoryForwardsDecodedModel() async throws {
        let expected = makeUser()
        let client = MockNetworkClient()
        client.resultProvider = { _ in expected }

        let repository = UserRepositoryImpl(client: client)
        let result = try await repository.fetchUser(id: "1")
        #expect(result == expected)
    }

    @Test("UseCase returns the user for a normal active account")
    func useCaseReturnsActiveUser() async throws {
        let expected = makeUser(status: .active)
        let client = MockNetworkClient()
        client.resultProvider = { _ in expected }
        let useCase = FetchUserProfileUseCase(repository: UserRepositoryImpl(client: client))

        let result = try await useCase.execute(userID: "1")
        #expect(result == expected)
    }

    @Test("UseCase converts a suspended account into a domain-level error")
    func useCaseRejectsSuspendedAccount() async throws {
        let suspendedUser = makeUser(status: .suspended)
        let client = MockNetworkClient()
        client.resultProvider = { _ in suspendedUser }
        let useCase = FetchUserProfileUseCase(repository: UserRepositoryImpl(client: client))

        do {
            _ = try await useCase.execute(userID: "1")
            Issue.record("Expected .accountSuspended to be thrown")
        } catch let error as UserProfileError {
            #expect(error == .accountSuspended)
        }
    }

    @Test("UseCase wraps a NetworkError from the repository as .network")
    func useCaseWrapsNetworkErrors() async throws {
        let client = MockNetworkClient()
        client.resultProvider = { _ in throw NetworkError.offline }
        let useCase = FetchUserProfileUseCase(repository: UserRepositoryImpl(client: client))

        do {
            _ = try await useCase.execute(userID: "1")
            Issue.record("Expected .network(.offline) to be thrown")
        } catch let error as UserProfileError {
            #expect(error == .network(.offline))
        }
    }

    @Test("Repository passes the correct page token through to the endpoint")
    func repositoryPassesPageTokenThrough() async throws {
        let client = MockNetworkClient()
        var capturedPath: String?
        client.resultProvider = { endpoint in
            capturedPath = try endpoint.urlRequest().url?.absoluteString
            return UserListResponse(users: [], nextPageToken: nil)
        }
        let repository = UserRepositoryImpl(client: client)
        _ = try await repository.fetchUsers(pageToken: "abc123")

        #expect(capturedPath?.contains("page_token=abc123") == true)
    }
}
