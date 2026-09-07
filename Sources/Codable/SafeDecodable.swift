//
//  SafeDecodable.swift
//  NetworkLayer
//
//  Establishes the pattern for enums decoded from server strings that
//  MUST NOT fail decoding just because the backend ships a new case the
//  app doesn't know about yet (extremely common: backend teams ship new
//  enum values ahead of app releases; without this, older app versions
//  crash-decode entire responses containing even ONE record with a new
//  status value).
//
//  TRADE-OFF NOTE — `unknown(String)` case vs. `Optional` fallback:
//  We add an explicit `.unknown(String)` case (preserving the raw value)
//  rather than making the property `Status?` and defaulting to `nil` on
//  mismatch. Reasoning: `nil` erases information (you can no longer tell
//  "field was absent" from "field had an unrecognized value" from "field
//  really means unknown"), whereas `.unknown("archived_v2")` preserves the
//  raw string for logging/analytics AND lets calling code render a
//  reasonable "Unknown status" UI state rather than silently treating an
//  unrecognized status the same as a missing one. Use plain `Optional`
//  instead when the field is genuinely optional in the API contract and
//  "unrecognized" isn't a meaningful UI state worth distinguishing.
//
import Foundation

/// Conform your enum to this, implement `init(rawValue:)` as the compiler-
/// synthesized one from `String` raw values, and get free
/// forward-compatible decoding.
public protocol UnknownCaseRepresentable: RawRepresentable, Decodable where RawValue == String {
    static var unknownCase: Self { get }
}

public extension UnknownCaseRepresentable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownCase
    }
}

// MARK: - Example domain enum demonstrating the pattern (see Domain/User.swift)
//
// enum AccountStatus: String, UnknownCaseRepresentable {
//     case active, suspended, pendingVerification = "pending_verification"
//     case unknown = "unknown"
//     static var unknownCase: AccountStatus { .unknown }
// }
