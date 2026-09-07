//
//  PostRepository.swift
//  SamplePostsApp
//
//  Data layer: the only place that knows about `PostEndpoint` and the
//  `LossyArray` decoding detail. Everything above this (UseCase, ViewModel,
//  View) only ever sees a plain `[Post]`.
//
import Foundation
import NetworkLayer

protocol PostRepository: Sendable {
    func fetchPosts() async throws -> [Post]
}

final class PostRepositoryImpl: PostRepository {
    private let client: NetworkClient

    init(client: NetworkClient) {
        self.client = client
    }

    func fetchPosts() async throws -> [Post] {
        // Decoding into `LossyArray<Post>` means that if JSONPlaceholder
        // (or a flaky proxy in front of it) ever returns one malformed
        // record, the other 99 still render instead of blanking the
        // whole list. `droppedCount` is logged so silent data loss stays
        // visible in your console/analytics rather than disappearing.
        let result = try await client.request(PostEndpoint.fetchPosts, as: LossyArray<Post>.self)
        if result.droppedCount > 0 {
            print("⚠️ PostRepository: dropped \(result.droppedCount) malformed post(s)")
        }
        return result.wrappedValue
    }
}
