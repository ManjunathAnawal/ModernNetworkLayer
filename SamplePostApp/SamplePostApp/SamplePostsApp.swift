//
//  SamplePostsApp.swift
//  SamplePostsApp
//
//  App-level composition root. JSONPlaceholder needs no auth, so this
//  wiring is deliberately simpler than the full `AppDependencies` example
//  in the NetworkLayer package (no TokenStore/TokenAuthenticator needed) —
//  it shows the MINIMUM you need to stand up `APIClient` for a real,
//  unauthenticated public API.
//
import SwiftUI
import NetworkLayer

@main
struct SamplePostsApp: App {
    // Held for the lifetime of the app; `NetworkMonitor.start()` begins
    // listening for connectivity changes and should keep running for as
    // long as the app can make requests.
    let monitor = NetworkMonitor()
    private let apiClient: NetworkClient
    private let viewModel: PostListViewModel

    init() {
        let client = APIClient(
            session: .shared,
            monitor: monitor,
            cache: ResponseCache(),
            deduplicator: RequestDeduplicator(),
            authenticator: nil,       // No token needed for this public API.
            retryPolicy: .default
        )
        self.apiClient = client

        let repository = PostRepositoryImpl(client: client)
        let useCase = FetchPostsUseCase(repository: repository)
        self.viewModel = PostListViewModel(useCase: useCase)

        let monitorRef = monitor
        Task { await monitorRef.start() }    }

    var body: some Scene {
        WindowGroup {
            PostListView(viewModel: viewModel)
        }
    }
}
