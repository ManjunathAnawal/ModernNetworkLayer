//
//  UserProfileViewModel.swift
//  NetworkLayer
//
//  Demonstrates View -> ViewModel -> UseCase wiring using the modern
//  `@Observable` macro (iOS 17+) instead of `ObservableObject` +
//  `@Published`. `@Observable` tracks property access at the SwiftUI View
//  level with fine granularity (a View only re-renders for the exact
//  properties it reads), which is both less boilerplate and more
//  efficient than `@Published`'s "any change re-renders every observer"
//  model.
//
//  MAIN-ACTOR NOTE:
//  The ViewModel is pinned to `@MainActor` because it drives UI state
//  (`state`, published directly to SwiftUI). The UseCase call itself
//  (`useCase.execute`) hops OFF the main actor implicitly the moment it
//  awaits `URLSession`/`JSONDecoder` work inside `APIClient` (see the
//  off-main-thread decoding note in APIClient.swift); we only hop back to
//  MainActor implicitly when the `await` resumes inside this
//  `@MainActor`-isolated function, which the Swift compiler guarantees
//  automatically — no manual `DispatchQueue.main.async` needed anywhere
//  in this stack.
//
import Foundation

@Observable
@MainActor
public final class UserProfileViewModel {
    public enum ViewState: Equatable {
        case idle
        case loading
        case loaded(User)
        case suspended
        case offline
        case error(String)
    }

    public private(set) var state: ViewState = .idle

    private let useCase: FetchUserProfileUseCaseProtocol
    private let userID: String

    /// Tracks the current load `Task` so a rapid second call (e.g. user
    /// yanks pull-to-refresh twice) cancels the first instead of racing
    /// two loads that could resolve out of order and flicker the UI.
    private var loadTask: Task<Void, Never>?

    public init(userID: String, useCase: FetchUserProfileUseCaseProtocol) {
        self.userID = userID
        self.useCase = useCase
    }

    public func onAppear() {
        guard case .idle = state else { return } // Avoid refetch on every re-appear.
        load()
    }

    public func retry() {
        load()
    }

    private func load() {
        loadTask?.cancel()
        state = .loading

        loadTask = Task {
            do {
                let user = try await useCase.execute(userID: userID)
                // `Task.isCancelled` check after the `await` above guards
                // against the classic "user navigated away before the
                // response came back" race — we simply drop a stale
                // result instead of updating `state` for a screen no one
                // is looking at anymore.
                guard !Task.isCancelled else { return }
                state = .loaded(user)
            } catch is CancellationError {
                // Silent — a new load superseded this one intentionally.
            } catch UserProfileError.accountSuspended {
                state = .suspended
            } catch UserProfileError.network(.offline) {
                state = .offline
            } catch UserProfileError.network(let networkError) {
                state = .error(Self.message(for: networkError))
            } catch {
                state = .error("Something went wrong. Please try again.")
            }
        }
    }

    private static func message(for error: NetworkError) -> String {
        switch error {
        case .unauthorized: return "Your session expired. Please sign in again."
        case .http(let statusCode, _, _): return "Server error (\(statusCode)). Please try again."
        case .retryExhausted: return "The server is taking too long to respond."
        default: return "Something went wrong. Please try again."
        }
    }
}
