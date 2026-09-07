//
//  UserRepository.swift
//  NetworkLayer
//
//  Protocol lives in `Domain` per Clean Architecture's Dependency
//  Inversion: the domain/use-case layer defines WHAT it needs, and the
//  `Data` layer provides HOW (network + local persistence). This means
//  UseCases and ViewModels can be unit tested against a mock repository
//  with zero knowledge of URLSession, Keychain, or any networking detail.
//
import Foundation

public protocol UserRepository: Sendable {
    func fetchUser(id: String) async throws -> User
    func fetchUsers(pageToken: String?) async throws -> UserListResponse
    func updateDisplayName(userID: String, newName: String) async throws -> User
}
