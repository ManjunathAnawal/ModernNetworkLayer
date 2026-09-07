//
//  User.swift
//  NetworkLayer
//
//  Example domain model showing the robust-Codable patterns in practice.
//  This lives in `Domain` (not `Data`) because Clean Architecture treats
//  the domain model as the stable, framework-agnostic contract that
//  UseCases and Views depend on — `Decodable` conformance here is a
//  pragmatic simplification for this sample; in a stricter Clean
//  Architecture split you'd have a separate `UserDTO: Decodable` in the
//  `Data` layer mapped to a plain `User` domain struct with no Codable
//  dependency at all. We annotate that trade-off below.
//
//  TRADE-OFF NOTE — Domain model conforms to Decodable vs. separate DTO:
//  Making `User` itself `Decodable` (this file) means one fewer type and
//  one fewer manual mapping function per model — less boilerplate, faster
//  to ship. The downside: any wire-format change (backend renames a JSON
//  field) directly touches your domain type, and the domain layer now has
//  a compile-time dependency on `Foundation`/`Codable` conventions. Use a
//  separate DTO + mapper (in `Data/`) instead when: the wire format is
//  genuinely unstable, you need to support multiple API versions mapping
//  to one stable domain shape, or the domain model needs to be usable in
//  a non-Foundation context (e.g. shared with a server-side Swift target
//  that has its own model). For a typical app-only codebase, the
//  single-type approach here is the pragmatic default.
//
import Foundation

public struct User: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let email: String
    public let status: AccountStatus
    public let createdAt: Date

    public init(id: String, displayName: String, email: String, status: AccountStatus, createdAt: Date) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.status = status
        self.createdAt = createdAt
    }
}

/// Demonstrates the `UnknownCaseRepresentable` pattern from
/// `SafeDecodable.swift`: if the backend ships a brand-new status value
/// this app version has never heard of, decoding still succeeds and the
/// UI can render an "Unknown" badge instead of the whole profile screen
/// crash-decoding.
public enum AccountStatus: String, UnknownCaseRepresentable {
    case active
    case suspended
    case pendingVerification = "pending_verification"
    case unknownStatus = "unknown"

    public static var unknownCase: AccountStatus { .unknownStatus }
}

/// A paginated list response demonstrating `@LossyArray`: if one user
/// record in a 50-item page is malformed, the other 49 still render.
public struct UserListResponse: Decodable, Sendable {
    @LossyArray public var users: [User]
    public let nextPageToken: String?

    public init(users: [User], nextPageToken: String?) {
        self._users = LossyArray(wrappedValue: users)
        self.nextPageToken = nextPageToken
    }
}
