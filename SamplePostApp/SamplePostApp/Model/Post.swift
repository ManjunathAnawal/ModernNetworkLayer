//
//  Post.swift
//  SamplePostsApp
//
//  Domain model matching https://jsonplaceholder.typicode.com/posts
//  Sample response shape:
//  { "userId": 1, "id": 1, "title": "...", "body": "..." }
//
import Foundation

struct Post: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let userId: Int
    let title: String
    let body: String
}
