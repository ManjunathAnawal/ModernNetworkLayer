//
//  UserProfileView.swift
//  NetworkLayer
//
//  The View layer is intentionally "dumb": it only reads `viewModel.state`
//  and calls `viewModel.onAppear()/.retry()`. It has zero knowledge of
//  networking, tokens, or caching — that's the point of the layering.
//
import SwiftUI

public struct UserProfileView: View {
    @State private var viewModel: UserProfileViewModel
    /// Coordinator-compatible: navigation actions are expressed as a
    /// closure/route emitted upward rather than the View pushing onto a
    /// `NavigationStack` itself. This keeps the View reusable regardless
    /// of whether the app's navigation is coordinator-driven,
    /// `NavigationStack`-path-driven, or embedded in a sheet.
    private let onRequestLogin: () -> Void

    public init(viewModel: UserProfileViewModel, onRequestLogin: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onRequestLogin = onRequestLogin
    }

    public var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading profile...")
            case .loaded(let user):
                content(for: user)
            case .suspended:
                ContentUnavailableView(
                    "Account Suspended",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Contact support for assistance.")
                )
            case .offline:
                ContentUnavailableView(
                    "You're Offline",
                    systemImage: "wifi.slash",
                    description: Text("Check your connection and try again.")
                )
                .overlay(alignment: .bottom) { retryButton }
            case .error(let message):
                ContentUnavailableView(
                    "Something Went Wrong",
                    systemImage: "exclamationmark.circle",
                    description: Text(message)
                )
                .overlay(alignment: .bottom) { retryButton }
            }
        }
        .task { viewModel.onAppear() }
    }

    private func content(for user: User) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(user.displayName).font(.title2.bold())
            Text(user.email).foregroundStyle(.secondary)
            Text(user.status.rawValue.capitalized)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
        .padding()
    }

    private var retryButton: some View {
        Button("Retry") { viewModel.retry() }
            .buttonStyle(.borderedProminent)
            .padding()
    }
}

// MARK: - Coordinator compatibility sketch
//
// A typical Coordinator-pattern route enum for this feature. The
// Coordinator owns navigation state; it constructs the ViewModel (wiring
// in the real UseCase/Repository/APIClient graph) and hands the View a
// plain closure for any navigation the View needs to request, exactly as
// `onRequestLogin` does above. This keeps the View and ViewModel fully
// ignorant of `NavigationStack`, `UINavigationController`, or whatever
// routing mechanism the app uses — only the Coordinator knows.
//
// enum AppRoute: Hashable {
//     case userProfile(userID: String)
//     case login
// }
//
// @MainActor
// final class AppCoordinator {
//     private let dependencies: AppDependencies
//     var path: [AppRoute] = []
//
//     init(dependencies: AppDependencies) { self.dependencies = dependencies }
//
//     @ViewBuilder
//     func view(for route: AppRoute) -> some View {
//         switch route {
//         case .userProfile(let userID):
//             let repo = UserRepositoryImpl(client: dependencies.apiClient)
//             let useCase = FetchUserProfileUseCase(repository: repo)
//             UserProfileView(
//                 viewModel: UserProfileViewModel(userID: userID, useCase: useCase),
//                 onRequestLogin: { [weak self] in self?.path.append(.login) }
//             )
//         case .login:
//             LoginView(coordinator: self)
//         }
//     }
// }
