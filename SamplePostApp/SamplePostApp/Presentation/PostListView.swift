//
//  PostListView.swift
//  SamplePostsApp
//
import SwiftUI

struct PostListView: View {
    @State private var viewModel: PostListViewModel

    init(viewModel: PostListViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Posts")
                .task { viewModel.onAppear() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Loading posts…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let posts):
            List(posts) { post in
                VStack(alignment: .leading, spacing: 6) {
                    Text(post.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(post.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text("User #\(post.userId)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .refreshable { viewModel.refresh() } // Pull-to-refresh re-triggers the fetch.

        case .offline:
            ContentUnavailableView(
                "You're Offline",
                systemImage: "wifi.slash",
                description: Text("Check your connection and try again.")
            )
            .overlay(alignment: .bottom) { retryButton }

        case .error(let message):
            ContentUnavailableView(
                "Couldn't Load Posts",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .overlay(alignment: .bottom) { retryButton }
        }
    }

    private var retryButton: some View {
        Button("Retry") { viewModel.refresh() }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 32)
    }
}
