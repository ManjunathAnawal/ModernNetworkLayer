//
//  PostListViewModel.swift
//  SamplePostsApp
//
import Foundation
import NetworkLayer

@Observable
@MainActor
final class PostListViewModel {
    enum ViewState {
        case idle
        case loading
        case loaded([Post])
        case offline
        case error(String)
    }

    private(set) var state: ViewState = .idle
    private let useCase: FetchPostsUseCaseProtocol
    private var loadTask: Task<Void, Never>?

    init(useCase: FetchPostsUseCaseProtocol) {
        self.useCase = useCase
    }

    func onAppear() {
        guard case .idle = state else { return }
        load()
    }

    func refresh() {
        load()
    }

    private func load() {
        loadTask?.cancel()
        state = .loading

        loadTask = Task {
            do {
                let posts = try await useCase.execute()
                guard !Task.isCancelled else { return }
                state = .loaded(posts)
            } catch is CancellationError {
                // Superseded by a newer load — ignore silently.
            } catch NetworkError.offline {
                state = .offline
            } catch let error as NetworkError {
                state = .error(Self.message(for: error))
            } catch {
                state = .error("Something went wrong. Pull to refresh to try again.")
            }
        }
    }

    private static func message(for error: NetworkError) -> String {
        switch error {
        case .http(let statusCode, _, _):
            return "Server returned an error (\(statusCode))."
        case .retryExhausted:
            return "The server took too long to respond after several attempts."
        case .decoding:
            return "The response couldn't be understood."
        default:
            return "Something went wrong. Pull to refresh to try again."
        }
    }
}
