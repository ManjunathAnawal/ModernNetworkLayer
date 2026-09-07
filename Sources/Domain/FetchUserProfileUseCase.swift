//
//  FetchUserProfileUseCase.swift
//  NetworkLayer
//
//  TRADE-OFF NOTE — a UseCase-per-operation vs. calling Repository
//  directly from ViewModels:
//  For this single, trivial "fetch by id" operation, a UseCase that does
//  nothing but forward to the Repository looks like pure ceremony. We
//  still model it explicitly because:
//    1. Business rules land here, not in the ViewModel or Repository.
//       E.g. below we add "treat suspended accounts as a domain-level
//       error" — a rule about what a fetched user MEANS, not about how to
//       fetch it. If we skipped the UseCase, this logic would end up
//       either duplicated across every ViewModel that fetches a user, or
//       incorrectly pushed into the Repository (which should stay a pure
//       data-access seam with no business semantics).
//    2. UseCases are the natural place to COMPOSE multiple repositories
//       (e.g. "fetch user + fetch their permissions + merge") without
//       ViewModels needing to know about, or hold references to, more
//       than one repository.
//  When to skip the UseCase layer: small apps / prototypes where you're
//  confident business logic will never grow beyond "call the repository,"
//  or a screen that is a thin, direct passthrough with zero domain rules —
//  forcing a UseCase there is needless indirection. As an app scales past
//  a handful of screens, the consistency of "ViewModels only ever talk to
//  UseCases" tends to pay for itself.
//
import Foundation

public protocol FetchUserProfileUseCaseProtocol: Sendable {
    func execute(userID: String) async throws -> User
}

public enum UserProfileError: Error, Equatable {
    case accountSuspended
    case network(NetworkError)
}

public struct FetchUserProfileUseCase: FetchUserProfileUseCaseProtocol {
    private let repository: UserRepository

    public init(repository: UserRepository) {
        self.repository = repository
    }

    public func execute(userID: String) async throws -> User {
        do {
            let user = try await repository.fetchUser(id: userID)
            // Domain rule: a suspended account is not a "successful fetch"
            // from the app's point of view — it's a distinct error state
            // the UI needs to branch on (e.g. show a "contact support"
            // screen instead of a normal profile).
            guard user.status != .suspended else {
                throw UserProfileError.accountSuspended
            }
            return user
        } catch let error as NetworkError {
            throw UserProfileError.network(error)
        }
    }
}
