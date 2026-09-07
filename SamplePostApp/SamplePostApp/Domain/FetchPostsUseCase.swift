//
//  FetchPostsUseCase.swift
//  SamplePostsApp
//
import Foundation
import NetworkLayer

protocol FetchPostsUseCaseProtocol: Sendable {
    func execute() async throws -> [Post]
}

struct FetchPostsUseCase: FetchPostsUseCaseProtocol {
    private let repository: PostRepository

    init(repository: PostRepository) {
        self.repository = repository
    }

    func execute() async throws -> [Post] {
        let posts = try await repository.fetchPosts()
        // Example domain rule: hide empty/placeholder posts rather than
        // showing blank rows — a real app would have richer rules here.
        return posts.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
